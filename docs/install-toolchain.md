# Installing the Swift 6.2 toolchain

This project builds with Swift 6.2 on Linux. Two install paths are documented and verified end-to-end against clean container images of each target distro by [`Scripts/verify-toolchain.sh`](../Scripts/verify-toolchain.sh).

## TL;DR

```bash
git clone --recurse-submodules git@github.com:pmatos/repobar.linux.git
cd repobar.linux
Scripts/install-toolchain.sh          # auto-detects distro, installs Swift 6.2
eval "$(Scripts/install-toolchain.sh --print-env)"
swift --version                       # → Swift version 6.2 (swift-6.2-RELEASE)
```

The installer writes to `~/.swift/swift-6.2-RELEASE/`. Override with `SWIFT_INSTALL_PREFIX=...`.

## Supported targets

| Target | Mechanism | Verified by `Scripts/verify-toolchain.sh` |
| --- | --- | --- |
| Ubuntu 22.04 | official Swift.org tarball | ✅ `ubuntu:22.04` |
| Ubuntu 24.04 | official Swift.org tarball | ✅ `ubuntu:24.04` |
| Arch Linux | official Swift.org Ubuntu 24.04 tarball + library shims | ✅ `archlinux:latest` |

Other distros are unsupported. The installer fails with a clear error when run on an unknown distro; patches welcome.

## Ubuntu 22.04 / 24.04

The installer:

1. `apt-get update` and installs build prerequisites (binutils, gnupg, libcurl4, libedit2, libncurses6, libpython3-dev, libsqlite3-0, libxml2, libz3-dev, plus the `libgcc-*-dev`/`libstdc++-*-dev` pair matching the release).
2. Downloads `swift-6.2-RELEASE-ubuntu<release>.tar.gz` from `download.swift.org`.
3. Extracts to `~/.swift/swift-6.2-RELEASE/`.

After install, source the env hints:

```bash
eval "$(Scripts/install-toolchain.sh --print-env)"
```

Or add the equivalent lines to your shell rc:

```bash
export PATH="$HOME/.swift/swift-6.2-RELEASE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.swift/swift-6.2-RELEASE/usr/lib:${LD_LIBRARY_PATH:-}"
```

## Arch Linux

Swift.org does not ship native Arch builds. The installer uses the Ubuntu 24.04 tarball and adds a small set of compatibility shims in `~/.swift/swift-6.2-RELEASE/usr/lib/` so the dynamic linker resolves Ubuntu-named libraries to their Arch equivalents:

- `libncurses.so.6` → `/usr/lib/libncursesw.so.6` (Arch only ships the widechar build)
- `libtinfo.so.6` → `/usr/lib/libncursesw.so.6`
- `libxml2.so.2` → `/usr/lib/libxml2.so.<latest>` (Arch is on soversion 16; the shim works for SwiftPM's libxml2 usage and emits cosmetic `no version information available` warnings)

Pacman packages installed: `base-devel ca-certificates curl gcc git icu libedit libxml2 ncurses python sqlite tar unzip zlib`. The installer invokes `pacman -Sy --noconfirm --needed` and must be run with appropriate privileges (or rely on `--needed` being a no-op when the packages are already present).

If the libxml2 shim breaks for you (rare; would indicate Swift using an API removed between soversions 2 and 16), install [`libxml2-legacy`](https://aur.archlinux.org/packages/libxml2-legacy) from the AUR and re-run the installer.

## Verification

Run the verifier against any supported container image:

```bash
Scripts/verify-toolchain.sh ubuntu:22.04
Scripts/verify-toolchain.sh ubuntu:24.04
Scripts/verify-toolchain.sh archlinux:latest
```

Each run downloads the image (if not cached), executes `Scripts/install-toolchain.sh` inside a fresh container, asserts `swift --version` reports `6.2.x`, and builds a hello-world SwiftPM package to confirm the toolchain is usable.

A green run looks like:

```
::verify:: swift --version output:
Swift version 6.2 (swift-6.2-RELEASE)
Target: x86_64-unknown-linux-gnu
::verify:: PASS
```

## Quirks worth knowing

- The Ubuntu 22.04 tarball requires `libcurl4-openssl-dev`'s runtime sibling `libcurl4`; the package name is unversioned on both Ubuntu releases.
- Ubuntu 24.04 needs `libgcc-13-dev`/`libstdc++-13-dev` rather than the older `-11`-suffixed packages.
- The Swift binaries are linked against `libncurses.so.6` (the non-widechar build). On Arch this name does not exist — the shim is mandatory, not cosmetic.
- The installer never touches `/etc/ld.so.conf.d` or `/usr/lib`; everything Swift-specific lives under `$SWIFT_INSTALL_PREFIX`. Uninstall is `rm -rf "$SWIFT_INSTALL_PREFIX"`.
- The env hints are idempotent; sourcing them twice is safe.

## Smoke test (manual)

```bash
cd "$(mktemp -d)"
swift package init --type executable --name hello
swift build
./.build/debug/hello
# → Hello, world!
```

This is exactly what the verifier runs inside the container.
