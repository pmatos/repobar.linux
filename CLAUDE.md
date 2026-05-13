# CLAUDE.md

Project memory for `pmatos/repobar.linux` — a Linux port of [`steipete/RepoBar`](https://github.com/steipete/RepoBar). This file documents conventions and architecture that aren't obvious from the source tree.

## Two-repo architecture

The project lives across **two GitHub repositories**. Always check which one a question or change belongs to before acting.

### `pmatos/repobar.linux` (this repo)

- **Linux UI shell** + everything that should never go upstream.
- Tracks `pmatos/repobar` as a git submodule pinned to its `linux` branch (`.gitmodules`).
- Currently holds: `Scripts/install-toolchain.sh`, `Scripts/verify-toolchain.sh`, `docs/install-toolchain.md`, `docs/adr/`, `README.md`, the submodule pointer.
- Will hold: the `RepoBarGtk` SwiftPM target (GTK4 + libadwaita), `.desktop` file, hicolor icons, systemd user unit, Arch `PKGBUILD`, Ubuntu `debian/`, distro CI matrix.
- **The issue tracker for the whole project lives here.** All GitHub issues — including ones whose fix lands as code on the fork — are filed and closed on `pmatos/repobar.linux`.

### `pmatos/repobar` (fork of `steipete/RepoBar`)

- **Swift code**: `Sources/RepoBarCore/`, `Sources/repobarcli/`, `Tests/RepoBarCoreTests/`, `Tests/repobarcliTests/`.
- Two branches:
  - **`main`** — pristine, mirrors `steipete/RepoBar:main`. Never push here. Used only by the upstream-sync workflow.
  - **`linux`** — every Linux-portability commit lands here. **This is the working branch on the fork.**
- Has `.github/workflows/upstream-sync.yml` which weekly rebases `linux` onto `upstream/main` (see `Scripts/upstream-sync.sh` + `Scripts/upstream-sync.test.sh`).
- Has `.github/workflows/linux-build.yml` which builds `RepoBarCore` and `repobarcli` against ubuntu-22.04, ubuntu-24.04, and archlinux:latest on every PR.

### Choosing which repo a change lands in

- Cross-platform Swift change to `RepoBarCore` / `repobarcli` / their tests → PR on **`pmatos/repobar` against `linux`**. Upstreamable to steipete eventually.
- Linux-specific UI / packaging / scripts / docs → PR on **`pmatos/repobar.linux` against `main`**.
- If unsure: anything `import GTK*` or "open the menu / desktop / package" → this repo. Anything in `RepoBarCore` or `repobar` the CLI → the fork.

### How issues close

GitHub does **not** auto-close cross-repo issue references from a PR that lands on a non-default branch. Concretely: a PR merged on `pmatos/repobar:linux` with `Closes pmatos/repobar.linux#N` in the description does *not* close that issue. Always close manually after merge:

```bash
gh issue close N -R pmatos/repobar.linux \
  --reason completed \
  --comment "Closed by pmatos/repobar PR #<fork-pr> (merged to \`linux\`)."
```

## Toolchain

Swift 6.2 (`swift-6.2-RELEASE`). Install via `Scripts/install-toolchain.sh` from this repo. See `docs/install-toolchain.md` for the full story.

- Arch host with deps already installed: `SWIFT_INSTALL_SKIP_DEPS=1 Scripts/install-toolchain.sh`. The script writes to `~/.swift/swift-6.2-RELEASE/` and never touches `/usr` — uninstall is `rm -rf`.
- Source env for the current shell after install: `eval "$(Scripts/install-toolchain.sh --print-env)"`.
- The verifier `Scripts/verify-toolchain.sh <docker-image>` runs the installer end-to-end in a clean container of ubuntu:22.04, ubuntu:24.04, or archlinux:latest.

Arch quirks worth knowing:
- Arch ships only `libncursesw.so.6` (not `libncurses.so.6`). The installer shims it inside the toolchain's lib dir.
- Arch's `libxml2` is at soversion 16; Ubuntu-built Swift links against `libxml2.so.2`. The installer shims it best-effort and emits cosmetic `no version information available` warnings. Real users on Arch may need `libxml2-legacy` from AUR if a future Swift release uses an API that changed between soversions.

## Build & test workflow

All Swift work happens **inside the submodule** at `repobar/`. From the worktree root:

```bash
cd repobar
eval "$(../Scripts/install-toolchain.sh --print-env)"
swift build --target RepoBarCore
swift build --product repobarcli
swift test --filter <SuiteName>    # e.g. RepoBarCoreTests, repobarcliTests
```

The CLI auths in priority order:
1. `GITHUB_TOKEN` env var (great for local dev with `GITHUB_TOKEN=$(gh auth token) ./.build/debug/repobarcli ...`)
2. Stored OAuth token (via `repobar login` or `repobar import-gh-token`)
3. Stored PAT

See `resolveCLIAuthSource(env:hasOAuth:pat:)` in `Sources/repobarcli/CLIContext.swift`.

## Cross-platform code conventions

- Prefer **`#if canImport(...)`** over `#if os(macOS)` when the gate is a library availability question, not a platform-identity question. The codebase uses `#if canImport(Security)`, `#if canImport(Network)`, `#if canImport(CryptoKit)`, etc.
- `#if os(macOS)` is right when the gate is genuinely about platform identity (e.g. Sparkle, MenuBarExtraAccess, AppAuth-iOS — UI-side packages excluded from the Linux build).
- `Foundation`'s `URLRequest` / `URLSession` / `HTTPURLResponse` live in **`FoundationNetworking`** on Linux. Files using them need:
  ```swift
  #if canImport(FoundationNetworking)
      import FoundationNetworking
  #endif
  ```
- `Darwin` → `Glibc` (or `Musl`) is the standard pattern for low-level POSIX:
  ```swift
  #if canImport(Darwin)
      import Darwin
  #elseif canImport(Glibc)
      import Glibc
  #elseif canImport(Musl)
      import Musl
  #endif
  ```
- **`stdout` / `stdin` / `stderr` globals are not Sendable** on Linux under strict concurrency. Use `FileHandle.standardOutput.fileDescriptor` etc., not `fileno(stdout)`. `fflush(stdout)` is uniquely difficult to make Sendable-safe on Linux — gate that specific call to macOS-only if it appears in a test helper.
- **`apollo-ios` does not build on Linux**. Dropped from `Package.swift`; the hand-rolled `GraphQLClient` actor in `RepoBarCore/API/` is the only GraphQL transport. See `docs/adr/0001-graphql-transport.md` in the fork.
- **swift-corelibs-foundation is missing pieces**: `RelativeDateTimeFormatter`, `NSString.abbreviatingWithTildeInPath`, `applicationSupportDirectory` returns a weird path. Each has a Linux fallback. Pattern: keep the Apple call under `#if canImport(Darwin)` and write a small Linux equivalent in the `#else`.
- **`zlib`** is wrapped as a `systemLibrary` SwiftPM target `CZlib` so `import zlib` works on both platforms. Use `import CZlib`, not `import zlib`.

## Paths on Linux follow XDG basedir

- Tokens: `$XDG_DATA_HOME/repobar/` (fallback `$HOME/.local/share/repobar/`), files with mode `0o600`. Loose perms cause `loadFile` to refuse the read. See `TokenStore.linuxDefaultFileDirectory(env:home:)`.
- Cache: `$XDG_CACHE_HOME/repobar/cache.sqlite` (fallback `$HOME/.cache/repobar/cache.sqlite`). See `HTTPResponseDiskCache.linuxCacheURL(env:home:)`.
- macOS / iOS paths are unchanged.

## Authorship rule

This project's default commit author email is **`p@ocmatos.com`** (personal). The global rule in `~/.claude/CLAUDE.md` about omitting Claude attribution under `pmatos@igalia.com` does *not* apply here — `p@ocmatos.com` permits the standard Claude-Code commit footer unless the user opts out.

Always check `git config user.email` before committing. If a stray local override sets a different email, switch back to `p@ocmatos.com`.

## CI

On the fork:
- **`.github/workflows/linux-build.yml`** — matrix of ubuntu-22.04 / ubuntu-24.04 / archlinux:latest. Installs Swift 6.2 fresh (the installer steps inlined), builds `RepoBarCore` + `repobarcli`, runs `repobarcli --help`. Required to be green before merging into `linux`.
- **`.github/workflows/upstream-sync.yml`** — weekly + manual. Rebases `linux` onto `steipete/RepoBar:main`. Clean rebase = force-push back to `linux`. Conflict = opens a tracking issue on the fork labelled `upstream-sync` (deduped).
- **`.github/workflows/ci.yml`** — upstream's macOS CI. Runs on `main` only, so our `linux` PRs don't trigger it.

This repo has no CI yet; see issue #32 (the matrix is planned but separate from the fork's `linux-build.yml`).

## PR cadence

- One issue, one PR. Branch off the right base (`linux` on the fork; `main` on this repo). Squash-merge with the issue number in the PR title so the merged commit reads cleanly.
- TDD where possible. Write a failing test first, then the impl. The existing test suites are good models — Swift Testing on the fork, bash test driver for shell scripts (`Scripts/upstream-sync.test.sh`, `Scripts/verify-toolchain.sh`).
- Always verify nothing else regressed: `swift test` after a change, not just the targeted filter.

## Common pitfalls

- **Submodule pin lag**: this repo's `main` records a specific `linux` commit SHA. After landing work on the fork's `linux` branch, the submodule pointer here goes out of date until someone explicitly bumps it. The pattern is a one-line PR titled `submodule: bump repobar to latest linux HEAD` (see #37).
- **`Package.swift` dependency arrays don't support `#if`**: SwiftPM conditional manifests rebuild the deps/targets list with `var` + `if` constructs at top level. Don't put `#if` inside an array literal — Swift's parser rejects it. The pattern in `Package.swift` is `var deps: [Target.Dependency] = [...]; #if !os(macOS) { deps += [...] }`.
- **`SwiftPM resources: .copy("Fixtures")`** copies the *directory*. To load a file inside, use `Bundle.module.url(forResource: "name", withExtension: "ext", subdirectory: "Fixtures")` — the `subdirectory:` parameter is mandatory.
- **Tests that mutate process environment fight each other** when run in parallel. Refactor the function under test to take `env: [String: String]` and inject. Examples: `TokenStore.linuxDefaultFileDirectory`, `HTTPResponseDiskCache.linuxCacheURL`, `resolveCLIAuthSource`.
- **GitHub auto-close on cross-repo `Closes` keyword only fires from the default branch.** Merging into `linux` (non-default) doesn't close the linked issue on `pmatos/repobar.linux`. Close manually.
- **`gh repo fork <name>`** preserves the upstream's case in the fork name (`steipete/RepoBar` → `pmatos/RepoBar`). We rename to lowercase (`gh repo rename repobar -R pmatos/RepoBar`) — `pmatos/repobar` is the canonical form across docs, submodule URL, and issue references.
