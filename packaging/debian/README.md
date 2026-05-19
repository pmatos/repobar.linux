# Debian / Ubuntu package — `repobar`

A `.deb` source layout for building RepoBar on Ubuntu 22.04 LTS and 24.04 LTS.

## Build prerequisites

```sh
sudo apt-get update
sudo apt-get install -y \
    build-essential debhelper devscripts \
    libgtk-3-dev libayatana-appindicator3-dev pkg-config git
```

Plus a Swift 6.2 toolchain visible to `dpkg-buildpackage`. The simplest path:

```sh
Scripts/install-toolchain.sh
eval "$(Scripts/install-toolchain.sh --print-env)"
```

## Build

```sh
Scripts/build-deb.sh             # produces ../repobar_*.deb
Scripts/build-deb.sh --lintian   # also runs lintian on the result
```

The wrapper symlinks `packaging/debian/` to `debian/` for the duration of
the build (`dpkg-buildpackage` expects `debian/` at the source root) and
removes the symlink on exit. `--static-swift-stdlib` in `debian/rules`
makes the binaries self-contained for the Swift runtime, so the `.deb`
only depends on standard GUI libs already installed on every Ubuntu LTS.

The Build-Depends in `debian/control` intentionally omits `swift` because
apt has no entry for it. `dpkg-buildpackage` is invoked with `-d` so it
doesn't fail the dep check.

## Install

```sh
sudo apt install ./repobar_0.0.0~git*_amd64.deb
```

Files land at:

- `/usr/bin/RepoBarGtk` — tray app
- `/usr/bin/repobar` — CLI
- `/usr/share/applications/repobar.desktop`
- `/usr/share/icons/hicolor/<size>/apps/repobar.png`
- `/usr/share/systemd/user/repobar.service`
- `/usr/share/doc/repobar/copyright`
- `/usr/share/doc/repobar/changelog.Debian.gz`

Then enable the user unit:

```sh
systemctl --user daemon-reload
systemctl --user enable --now repobar.service
journalctl --user -u repobar.service -f
```

## Uninstall

```sh
sudo apt remove repobar
```

Removes everything except the per-user XDG state (tokens at
`$XDG_DATA_HOME/repobar/`, cache at `$XDG_CACHE_HOME/repobar/`); those
are user data, not package files. Run `repobar logout` first if you want
to clear stored credentials.

## CI

The `.github/workflows/linux-build.yml` matrix runs `Scripts/build-deb.sh`
on the ubuntu-22.04 and ubuntu-24.04 legs and uploads each `.deb` as a
workflow-run artifact.
