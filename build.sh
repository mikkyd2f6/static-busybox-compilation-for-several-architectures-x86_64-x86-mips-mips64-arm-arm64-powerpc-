#!/usr/bin/env bash
#
# Build statically-linked busybox for every architecture flavor:
#   x86_64 (native), x86 (i686), arm64 (aarch64), arm32 (armhf),
#   mips64 + mips64el (n64), mips32 + mips32el (o32),
#   ppc64le, ppc32, ppc64be
#
# One binary per flavor (a defconfig busybox with ~400 applets, static).
#
# Outputs:
#   dist/busybox-<ver>-<flavor>-static   stripped static binaries
#   install/<triplet>/                   applet-symlink trees ("make install")
#
# Runs on an x86_64 Ubuntu/Debian host; flavors other than x86_64 are
# cross-compiled with the Ubuntu cross toolchains (via a PATH shim that maps
# the versioned <triplet>-gcc-14 names to the plain names busybox's Kbuild
# expects from CROSS_COMPILE). qemu-user is used to functionally test the
# cross binaries. See README.md for details.
#
set -euo pipefail

BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.38.0}"

NATIVE_TRIPLET=x86_64-linux-gnu
TRIPLETS="${TRIPLETS:-x86_64-linux-gnu i686-linux-gnu aarch64-linux-gnu arm-linux-gnueabihf mips64-linux-gnuabi64 mips64el-linux-gnuabi64 mips-linux-gnu mipsel-linux-gnu powerpc64le-linux-gnu powerpc-linux-gnu powerpc64-linux-gnu}"
CROSS_GCC_VER="${CROSS_GCC_VER:-14}"
JOBS="${JOBS:-$(nproc)}"

BASE="${BASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SRC="$BASE/src"
DIST="$BASE/dist"
mkdir -p "$SRC" "$DIST"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

qemu_for_triplet() {
    case "$1" in
        x86_64-linux-gnu) echo "" ;;
        i686-*)          echo qemu-i386-static ;;
        aarch64-*)       echo qemu-aarch64-static ;;
        arm-*)           echo qemu-arm-static ;;
        mips64el-*)      echo qemu-mips64el-static ;;
        mips64-*)        echo qemu-mips64-static ;;
        mipsel-*)        echo qemu-mipsel-static ;;
        mips-*)          echo qemu-mips-static ;;
        powerpc64le-*)   echo qemu-ppc64le-static ;;
        powerpc64-*)     echo qemu-ppc64-static ;;
        powerpc-*)       echo qemu-ppc-static ;;
        *) echo "unsupported triplet: $1" >&2; return 1 ;;
    esac
}

short_for_triplet() {
    case "$1" in
        x86_64-linux-gnu) echo x86_64 ;;
        i686-*)          echo x86 ;;
        aarch64-*)       echo arm64 ;;
        arm-*)           echo arm32 ;;
        mips64el-*)      echo mips64el ;;
        mips64-*)        echo mips64 ;;
        mipsel-*)        echo mips32el ;;
        mips-*)          echo mips32 ;;
        powerpc64le-*)   echo ppc64le ;;
        powerpc64-*)     echo ppc64be ;;
        powerpc-*)       echo ppc32 ;;
        *) echo "unsupported triplet: $1" >&2; return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# 0. Host dependencies (cross toolchains are assumed installed via apt;
# this prints the exact install line when anything is missing)
# --------------------------------------------------------------------------
check_host_deps() {
    local missing=()
    local t

    command -v gcc >/dev/null || missing+=(build-essential)
    local QEMU
    for t in $TRIPLETS; do
        if [ "$t" != "$NATIVE_TRIPLET" ]; then
            command -v "$t-gcc-$CROSS_GCC_VER" >/dev/null || missing+=("gcc-$CROSS_GCC_VER-$t")
            [ -e "/usr/$t/lib/libc.a" ] || case "$t" in
                i686-*)        missing+=(libc6-dev-i386-cross) ;;
                aarch64-*)     missing+=(libc6-dev-arm64-cross) ;;
                arm-*)         missing+=(libc6-dev-armhf-cross) ;;
                mips64el-*)    missing+=(libc6-dev-mips64el-cross) ;;
                mips64-*)      missing+=(libc6-dev-mips64-cross) ;;
                mipsel-*)      missing+=(libc6-dev-mipsel-cross) ;;
                mips-*)        missing+=(libc6-dev-mips-cross) ;;
                powerpc64le-*) missing+=(libc6-dev-ppc64el-cross) ;;
                powerpc64-*)   missing+=(libc6-dev-ppc64-cross) ;;
                powerpc-*)     missing+=(libc6-dev-powerpc-cross) ;;
            esac
        fi
        QEMU=$(qemu_for_triplet "$t")
        [ -z "$QEMU" ] && continue   # native flavor runs directly, no qemu
        command -v "$QEMU" >/dev/null || missing+=(qemu-user-static)
    done

    # deduplicate
    local uniq=() p
    for p in "${missing[@]:-}"; do
        [ -n "$p" ] || continue
        case " ${uniq[*]:-} " in *" $p "*) ;; *) uniq+=("$p") ;; esac
    done

    if [ "${#uniq[@]}" -gt 0 ]; then
        echo "Missing host packages: ${uniq[*]}" >&2
        echo "Install them with:" >&2
        echo "  sudo apt-get install -y ${uniq[*]}" >&2
        exit 1
    fi
}

# --------------------------------------------------------------------------
# 1. Fetch and unpack source
# --------------------------------------------------------------------------
fetch_sources() {
    cd "$SRC"
    [ -f "busybox-$BUSYBOX_VERSION.tar.bz2" ] || \
        curl -fsSLO "https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2"
    [ -d "busybox-$BUSYBOX_VERSION" ] || tar xf "busybox-$BUSYBOX_VERSION.tar.bz2"
    cd "$BASE"
}

# --------------------------------------------------------------------------
# 3. Build one flavor
# --------------------------------------------------------------------------
build_flavor() {
    local T=$1
    local short
    short=$(short_for_triplet "$T")
    local out="$DIST/busybox-$BUSYBOX_VERSION-$short-static"
    local W="$BASE/build-$T"
    local prefix="$BASE/install/$T"

    log "Building busybox $BUSYBOX_VERSION for $T"
    [ -x "$out" ] && { log "$out already built"; return; }

    # busybox's Kbuild builds in-tree: use a pristine copy per flavor
    rm -rf "$W"
    cp -a "$SRC/busybox-$BUSYBOX_VERSION" "$W"
    cd "$W"

    # Feed kconfig explicitly (yes "") so every config step is non-interactive
    # regardless of what stdin the build environment provides. `yes` dies of
    # SIGPIPE when kconfig stops reading, which trips `set -o pipefail` —
    # hence `|| true`, with the resulting .config validated explicitly.
    yes "" | make defconfig >/dev/null 2>&1 || true
    [ -s .config ] || { echo "make defconfig produced no config for $T" >&2; exit 1; }
    sed -i -e 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' \
           -e 's/^CONFIG_PIE=y$/# CONFIG_PIE is not set/' \
           -e 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' .config
    yes "" | make oldconfig >/dev/null 2>&1 || true
    grep -q '^CONFIG_STATIC=y' .config || { echo "config settle failed for $T" >&2; exit 1; }

    # NOTE: busybox 1.38's Kbuild does not reliably honor a command-line
    # CROSS_COMPILE during a full build (it is honored for explicit file
    # targets, but the `all` goal ends up compiling with the host gcc).
    # Overriding the tools directly on the command line always wins. The same
    # overrides must be passed to `make install` too: install can decide to
    # relink busybox, and without them it would rebuild it with host tools.
    local overrides=""
    if [ "$T" != "$NATIVE_TRIPLET" ]; then
        overrides="HOSTCC=gcc CC=$T-gcc-$CROSS_GCC_VER AR=$T-ar LD=$T-ld STRIP=$T-strip"
    fi

    # shellcheck disable=SC2086
    make -j"$JOBS" $overrides
    # shellcheck disable=SC2086
    make CONFIG_PREFIX="$prefix" install $overrides
    cd "$BASE"

    cp "$prefix/bin/busybox" "$out"
    if [ "$T" = "$NATIVE_TRIPLET" ]; then
        strip "$out"
    else
        "$T-strip" "$out"
    fi
}

# --------------------------------------------------------------------------
# 4. Sanity check the results (functional, under qemu where needed)
# --------------------------------------------------------------------------
verify() {
    log "Results"
    local t short QEMU b n
    for t in $TRIPLETS; do
        short=$(short_for_triplet "$t")
        QEMU=$(qemu_for_triplet "$t")
        b="$DIST/busybox-$BUSYBOX_VERSION-$short-static"
        [ -e "$b" ] || continue
        file "$b" | sed 's/^/  /'
        if [ -n "$QEMU" ]; then
            n=$(timeout 120 "$QEMU" "$b" --list | wc -l)
            timeout 120 "$QEMU" "$b" sh -c "echo \$((6*7))" | sed 's/^/  shell test: /'
            echo "  applets: $n"
        else
            timeout 120 "$b" sh -c "echo \$((6*7))" | sed 's/^/  shell test: /'
            echo "  applets: $(timeout 120 "$b" --list | wc -l)"
        fi
    done
}

main() {
    check_host_deps
    fetch_sources

    local t
    for t in $TRIPLETS; do
        build_flavor "$t"
    done

    verify
    log "Done. Binaries in $DIST"
}

main "$@"
