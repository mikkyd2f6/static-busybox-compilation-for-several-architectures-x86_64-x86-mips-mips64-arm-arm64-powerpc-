# static-busybox

Statically-linked [BusyBox](https://busybox.net/) for every major Linux
architecture — a single portable binary combining ~400 common Unix utilities
(shell, coreutils, mount, networking tools, ...), with no shared-library
dependencies. The classic rescue/toolkit binary: copy it anywhere and you have
a working userland.

One binary per flavor:

| Binary | Arch | Notes |
|---|---|---|
| `busybox-<ver>-x86_64-static` | x86_64 | native build |
| `busybox-<ver>-x86-static` | i686 | Pentium Pro baseline (CMOV) |
| `busybox-<ver>-arm64-static` | aarch64 LP64 | |
| `busybox-<ver>-arm32-static` | armhf (ARMv7-A hard-float) | not for ARMv6/soft-float |
| `busybox-<ver>-mips64-static` | MIPS64 big-endian, n64 | |
| `busybox-<ver>-mips64el-static` | MIPS64 little-endian, n64 | |
| `busybox-<ver>-mips32-static` | MIPS32 big-endian, o32 | |
| `busybox-<ver>-mips32el-static` | MIPS32 little-endian, o32 | |
| `busybox-<ver>-ppc64le-static` | POWER64 little-endian, ELFv2 | modern POWER8/9/10 |
| `busybox-<ver>-ppc32-static` | PowerPC 32-bit big-endian | classic/embedded |
| `busybox-<ver>-ppc64be-static` | POWER64 big-endian, ELFv1 | legacy |

All are **defconfig** builds (most applets enabled) with `CONFIG_STATIC=y`,
built against glibc 2.40. Check a machine with
`readelf -h /bin/sh | grep -E 'ELF|Machine'` to pick the right flavor.

## Quick start

Requirements: Ubuntu/Debian-ish **x86_64** host with `build-essential`,
`curl`, and the cross toolchains + qemu for every flavor you build:

```bash
sudo apt-get install -y \
    gcc-14-i686-linux-gnu libc6-dev-i386-cross binutils-i686-linux-gnu \
    gcc-14-aarch64-linux-gnu libc6-dev-arm64-cross binutils-aarch64-linux-gnu \
    gcc-14-arm-linux-gnueabihf libc6-dev-armhf-cross binutils-arm-linux-gnueabihf \
    gcc-14-mips64-linux-gnuabi64 libc6-dev-mips64-cross binutils-mips64-linux-gnuabi64 \
    gcc-14-mips64el-linux-gnuabi64 libc6-dev-mips64el-cross binutils-mips64el-linux-gnuabi64 \
    gcc-14-mips-linux-gnu libc6-dev-mips-cross binutils-mips-linux-gnu \
    gcc-14-mipsel-linux-gnu libc6-dev-mipsel-cross binutils-mipsel-linux-gnu \
    gcc-14-powerpc64le-linux-gnu libc6-dev-ppc64el-cross binutils-powerpc64le-linux-gnu \
    gcc-14-powerpc-linux-gnu libc6-dev-powerpc-cross binutils-powerpc-linux-gnu \
    gcc-14-powerpc64-linux-gnu libc6-dev-ppc64-cross binutils-powerpc64-linux-gnu \
    qemu-user-static
```

(The `build.sh` dependency check prints exactly what is missing for the
flavors you have selected, with the matching install line.)

Then:

```bash
./build.sh
```

Binaries land in `dist/`; each flavor also gets an applet-symlink tree under
`install/<triplet>/` (the result of busybox's `make install`) — useful if you
want a ready-made `/bin` `/sbin` layout instead of the single binary.
A full build of all 11 flavors takes roughly 10–15 minutes on a 20-core
machine. The script is re-runnable: sources and finished binaries are
skipped when already present.

### Options

```bash
BUSYBOX_VERSION=1.38.0   # upstream version
TRIPLETS="..."           # space-separated subset of triplets (see build.sh)
CROSS_GCC_VER=14         # cross gcc package series on the host
JOBS=$(nproc)            # parallel jobs
BASE=/path/to/dir        # where to place src/build/install/dist (default: repo dir)
```

## Deploying to a machine

```bash
scp dist/busybox-7.2-arm64-static user@device:/usr/local/bin/busybox
# on the device:
busybox sh          # ash shell
busybox --list      # available applets
busybox --install -s /usr/local/bin   # symlink applets
```

## Verifying on an x86_64 host (qemu)

Unlike strace, busybox needs no ptrace — cross flavors are **fully testable**
under qemu-user, and the build script does exactly that (runs `sh -c` and
counts applets for every flavor). Manually:

```bash
qemu-aarch64-static ./dist/busybox-1.38.0-arm64-static sh -c 'echo hello'
qemu-ppc64le-static ./dist/busybox-1.38.0-ppc64le-static uname -m
```

## Caveats

- Static glibc: name-resolution and NSS-dependent applets (`getent`, DNS in
  `wget`/`ping` lookups, `id` user names) may behave differently than on a
  dynamic system — numeric output or degraded resolution. Same as any
  statically linked glibc tool.
- defconfig applet set: a few applets that need uncommon libs are disabled
  upstream by default; the per-flavor `.config` is kept in `build-<triplet>/`
  if you want to customize and rebuild.

## How it works / notable gotchas

- The x86_64 flavor is a native build; every other flavor is cross-compiled
  with Ubuntu's `<triplet>-gcc-14` + `libc6-dev-*-cross` toolchains.
- BusyBox 1.38's Kbuild does **not** reliably honor a command-line
  `CROSS_COMPILE` during a full build (it works for explicit file targets, but
  the default goal ends up compiling with the host gcc, silently producing
  host-architecture binaries). The build therefore overrides the tools
  directly on the make command line — `HOSTCC=gcc CC=<triplet>-gcc-14
  AR=<triplet>-ar LD=<triplet>-ld STRIP=<triplet>-strip` — which always wins
  over Makefile assignments.
- BusyBox builds in-tree only, so each flavor builds from a pristine copy of
  the source tree (`build-<triplet>/`), where the generated `.config` is kept.
- Static linking is enabled by flipping `CONFIG_STATIC=y` in the defconfig
  (and turning `CONFIG_PIE` off, which conflicts with static).
- The `tc` (traffic control) applet is disabled: busybox 1.38's `tc.c`
  references `TCA_CBQ_*` constants that were removed from modern kernel uapi
  headers, so a defconfig build fails against the glibc 2.40-era headers in
  both the host and the cross sysroots.

Build layout (all gitignored): `src/`, `build-*/`, `install/`, `dist/`.

## License

BusyBox is GPLv2; statically-linked binaries are derivative works, so if you
distribute the binaries you must offer the corresponding source (this repo
plus the pinned upstream version is a reasonable way to do that). No license
is claimed over these build files — add one of your choosing before
publishing.
