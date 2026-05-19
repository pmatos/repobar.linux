# Arch package — `repobar-linux-git`

A `PKGBUILD` for building and installing RepoBar on Arch (and Arch-derived)
distros.

## Prerequisites

- Swift 6.2 on `$PATH`. Either:
  - Install the AUR package `swift-bin`, **or**
  - From this repo's root, run
    `Scripts/install-toolchain.sh && eval "$(Scripts/install-toolchain.sh --print-env)"`
    so `swift` is visible to `makepkg`.

The package itself does not list `swift` in `makedepends` because the
official Arch repositories don't ship a Swift toolchain. `namcap` will
warn about a missing build-time dependency; that warning is intentional
(documented in the PKGBUILD header).

## Build

```sh
cd packaging/arch
makepkg -s
```

The resulting `repobar-linux-git-<ver>-1-x86_64.pkg.tar.zst` is a
self-contained tarball (`--static-swift-stdlib` is used, so it does not
depend on a system-wide Swift runtime).

## Install

```sh
sudo pacman -U repobar-linux-git-*-x86_64.pkg.tar.zst
```

This installs:

- `/usr/bin/RepoBarGtk` — the tray app
- `/usr/bin/repobar` — the CLI (renamed from `repobarcli`)
- `/usr/share/applications/repobar.desktop`
- `/usr/share/icons/hicolor/<size>/apps/repobar.png` (16–512 px)
- `/usr/share/systemd/user/repobar.service`
- `/usr/share/licenses/repobar-linux-git/LICENSE`

## Run

Either launch from the application menu (the `.desktop` entry surfaces it),
or auto-start on login via the user unit:

```sh
systemctl --user daemon-reload
systemctl --user enable --now repobar.service
```

See the project [README](../../README.md) for the full UX.

## Updating the package

This is a `-git` package, so `pkgver()` recomputes the version from the
upstream commit count on every build. To pull the latest:

```sh
makepkg -s --clean
```

## Contributing back

Patches to the PKGBUILD land alongside everything else on
[`pmatos/repobar.linux`](https://github.com/pmatos/repobar.linux). When the
project ships a tagged release, this PKGBUILD will gain a non-`-git` sibling.
