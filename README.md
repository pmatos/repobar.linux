# RepoBar for Linux

[![Linux build (this repo)](https://github.com/pmatos/repobar.linux/actions/workflows/linux-build.yml/badge.svg?branch=main)](https://github.com/pmatos/repobar.linux/actions/workflows/linux-build.yml)
[![Linux build (fork)](https://github.com/pmatos/repobar/actions/workflows/linux-build.yml/badge.svg?branch=linux)](https://github.com/pmatos/repobar/actions/workflows/linux-build.yml)

A Linux port of [steipete/RepoBar](https://github.com/steipete/RepoBar) — a system-tray app that surfaces GitHub repositories, issues, pull requests, releases, CI state, and local checkout status in a single menu.

**Status: bootstrapping.** Not yet usable. See the [issue tracker](https://github.com/pmatos/repobar.linux/issues) for the planned phases of work.

## Project shape

This is a two-repository project:

| Repo | Role |
| --- | --- |
| [`pmatos/repobar.linux`](https://github.com/pmatos/repobar.linux) (this repo) | Linux-specific UI shell (GTK4 + libadwaita), packaging, scripts, distro configs. |
| [`pmatos/repobar`](https://github.com/pmatos/repobar) | Hard fork of `steipete/RepoBar`, with a `linux` branch carrying Linux-portability changes to `RepoBarCore` and the CLI. Rebased on upstream periodically. |

The fork is included here as a git submodule pinned to the `linux` branch:

```
git clone --recurse-submodules git@github.com:pmatos/repobar.linux.git
```

## Goals

- CLI (`repobar`) ported to Linux end-to-end.
- GTK4 / Adwaita system-tray app with parity with the macOS menu bar UX.
- Native packaging for Arch and Ubuntu LTS.

## Toolchain

Builds with Swift 6.2 on Arch and Ubuntu 22.04 / 24.04. See [docs/install-toolchain.md](docs/install-toolchain.md) for one-shot install and the verifier script that proves the install steps work against clean container images.

## Build & run (tracer)

System packages required at the moment (Arch names; equivalents documented in [`docs/adr/0001-tray-strategy.md`](docs/adr/0001-tray-strategy.md)):

```
libayatana-appindicator   # publishes the StatusNotifierItem on D-Bus
gtk3                       # required at runtime by libayatana-appindicator3
```

From the repo root:

```
eval "$(Scripts/install-toolchain.sh --print-env)"
swift build
./.build/debug/RepoBarGtk      # Ctrl-C to quit
```

The tracer publishes a static tray icon and a GLib main loop. Any
StatusNotifierItem host renders the icon — DankMaterialShell on Niri,
KDE Plasma, XFCE's tray plugin, and waybar's tray module all work out
of the box. **GNOME caveat**: vanilla GNOME has no SNI host. Install
[AppIndicator and KStatusNotifierItem Support](https://extensions.gnome.org/extension/615/appindicator-support/)
or you will not see the icon. See the ADR for the tradeoffs that led
to libayatana-appindicator3.

## Desktop integration

`Scripts/install-desktop.sh` installs the `repobar.desktop` entry, the
hicolor icon set (16–512 px PNGs under `share/icons/hicolor/<size>/apps/`),
and the systemd user service unit (`share/systemd/user/repobar.service`)
into a configurable prefix. Distro packagers should pass `--destdir` and
`--no-cache-update` so the package manager owns the post-install cache step.

```
sudo Scripts/install-desktop.sh --prefix /usr/local
# or, for a packaging build:
Scripts/install-desktop.sh --prefix /usr --destdir "$pkgdir" --no-cache-update
```

The unit's `ExecStart=` is substituted with `<prefix>/bin/RepoBarGtk` at
install time. Override the binary location with `--bindir /opt/foo/bin` if
your packaging puts the binary somewhere else.

The icons are regenerated from the 1024×1024 master in the submodule
(`repobar/Icon.icon/Assets/repobaricon.png`) via `Scripts/regenerate-icons.sh`.
End-to-end install / uninstall / desktop-file-validate / icon-cache /
systemd-analyze tests live in `Scripts/install-desktop.test.sh`.

### Auto-start on login

Once the unit is installed and the `RepoBarGtk` binary is on the path that
`ExecStart=` points at, enable it as a per-user service:

```
systemctl --user daemon-reload
systemctl --user enable --now repobar.service
# Tail logs:
journalctl --user -u repobar.service -f
# Stop and disable:
systemctl --user disable --now repobar.service
```

The unit is wired to `graphical-session.target` (so it stops on logout and
won't start in a TTY-only session) and restarts on failure with a 5 s delay,
giving up after 3 failures in 60 s.

## Architecture, scope, and progress

See the open issues for vertical-slice work items. Architecture and contributor docs land in `docs/` as part of issue [#34](https://github.com/pmatos/repobar.linux/issues/34).

## License

MIT, following upstream RepoBar. See [`repobar/LICENSE`](repobar/LICENSE) in the submodule.
