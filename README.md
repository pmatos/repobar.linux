# RepoBar for Linux

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

## Architecture, scope, and progress

See the open issues for vertical-slice work items. Architecture and contributor docs land in `docs/` as part of issue [#34](https://github.com/pmatos/repobar.linux/issues/34).

## License

MIT, following upstream RepoBar. See [`repobar/LICENSE`](repobar/LICENSE) in the submodule.
