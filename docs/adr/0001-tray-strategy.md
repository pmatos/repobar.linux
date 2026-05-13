# ADR 0001: Tray strategy on Linux

Status: accepted, 2026-05-13

## Context

Modern Linux tray icons are not a single API — they are a freedesktop D-Bus protocol called **StatusNotifierItem (SNI)**, also marketed as the "Ayatana AppIndicator" interface. An app registers an `org.kde.StatusNotifierItem` on the session bus; a panel/shell that implements an `org.kde.StatusNotifierHost` watches `org.kde.StatusNotifierWatcher` and draws the item. There is no Wayland-native tray API and the legacy X11 `_NET_SYSTEM_TRAY_S0` XEmbed protocol is unavailable under Wayland compositors.

In practice every desktop tray icon a Linux user encounters today rides this protocol:

- **Nextcloud** is a Qt app and publishes its SNI item directly through `QSystemTrayIcon`.
- **Dropbox** and **Discord** (Electron) both link `libayatana-appindicator3` and let that library do the D-Bus registration. The Arch-packaged `libappindicator-gtk3` is the same shape.

RepoBar's Linux UI target (`RepoBarGtk`, see issue #9) is a GTK4 + libadwaita app via Adwaita-for-Swift. It needs an icon in whichever shell the user runs — DankMaterialShell on Niri, KDE's plasma-workspace, GNOME with the AppIndicator extension, waybar's tray module, etc. The three plausible Swift-side strategies were:

- **A.** Use Adwaita-for-Swift's own tray support.
- **B.** Wrap `libayatana-appindicator3` as a SwiftPM `systemLibrary` target and call its C API from Swift.
- **C.** Speak the SNI D-Bus protocol directly from Swift.

A is not viable today: Adwaita-for-Swift does not ship a tray binding, and the upstream Adwaita/GNOME story has historically discouraged tray icons (the AppIndicator GNOME-shell extension exists precisely to add them back).

C is theoretically the cleanest — no native dependency, no GTK link for the indicator code path — but there is no mature Swift D-Bus binding. Either we wrap `libdbus-1`/`sd-bus` ourselves, or we write the marshalling/introspection code by hand against the SNI XML interface. The runtime work duplicates what `libayatana-appindicator3` already does, with the bonus that we have to track upstream interface changes ourselves.

B is the path Discord, Dropbox, and basically every other tray-publishing Linux app already take. The library is widely packaged (`libayatana-appindicator` on Arch; `gir1.2-ayatanaappindicator3-0.1` / `libayatana-appindicator3-1` on Debian/Ubuntu), the API surface we need is tiny (`app_indicator_new`, `set_status`, `set_icon_full`, `set_menu`), and the menu it accepts is a `GtkMenu` — already in scope for a GTK4 app.

## Decision

Add a SwiftPM `systemLibrary` target (`CAyatanaAppIndicator`, `pkgConfig: "ayatana-appindicator3-0.1"`) that exposes `libayatana-appindicator3-1`'s C headers, and call it from the new `RepoBarGtk` executable target. RepoBar registers a single `AppIndicator` with the tracked-repo activity badge as the icon and a `GtkMenu` rebuilt from `RepoBarCore`'s `MenuSnapshot`.

We do **not** ship a private vendored copy of the library — the system package is the dependency. README and `PKGBUILD` / `debian/control` list `libayatana-appindicator` (Arch) and `libayatana-appindicator3-1` (Ubuntu LTS) as runtime + build deps.

## Consequences

- **Works on every relevant shell**: DankMaterialShell, KDE Plasma, waybar, GNOME with the AppIndicator extension, XFCE's plugin — they are all SNI hosts and pick up the indicator without per-shell code.
- **Build cost**: one new `systemLibrary` target and a `pkg-config` lookup. The Swift wrapper is small; no Objective-C bridging.
- **Runtime dep on `libayatana-appindicator3-1`**. Already pulled in by Discord/Dropbox/many Electron apps on a typical desktop; not exotic. Documented in install instructions and packaging files.
- **GNOME quirk**: vanilla GNOME has no SNI host; the user must install the AppIndicator extension. Documented next to the install steps so users on stock GNOME aren't surprised when the icon doesn't appear.
- **Future Wayland-native protocol**: if/when wlroots or a freedesktop spec lands a native tray, swapping the indicator-publisher behind RepoBar's UI module is a small change because `RepoBarCore` owns the `MenuSnapshot` and the GTK side already isolates the indicator behind one file.
- **Rejected B-adjacent**: KDE's older `KStatusNotifierItem` C++ class is not a viable surface from Swift; libayatana-appindicator3 sits at the right level (GLib/GObject, easy to wrap).

## Verification

Acceptance for #9 is `./.build/debug/RepoBarGtk` showing a static icon on (a) KDE Plasma and (b) GNOME with the AppIndicator extension. We'll also smoke-test on Niri + DankMaterialShell as the primary author's daily-driver setup.
