// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RepoBarGtk",
    products: [
        .executable(name: "RepoBarGtk", targets: ["RepoBarGtk"]),
    ],
    dependencies: [
        // The fork lives at ./repobar as a git submodule pinned to the `linux`
        // branch (.gitmodules). Using a local path dep lets us consume the
        // Swift package without publishing it.
        .package(path: "repobar"),
    ],
    targets: [
        // libayatana-appindicator3 — the StatusNotifierItem publisher used by
        // Discord, Dropbox, et al. (See docs/adr/0001-tray-strategy.md.) The
        // library is GTK3-based; we use it only via its GLib/GObject surface
        // and never draw GTK widgets ourselves in this target.
        .systemLibrary(
            name: "CAyatanaAppIndicator",
            path: "Sources/CAyatanaAppIndicator",
            pkgConfig: "ayatana-appindicator3-0.1",
            providers: [
                .apt(["libayatana-appindicator3-dev"]),
                .yum(["libayatana-appindicator-gtk3-devel"]),
            ]
        ),
        // libayatana-appindicator3 expects a running GTK3 context (it calls
        // `gtk_icon_theme_get_for_screen` internally), so we link GTK3 and
        // call `gtk_init` on startup even though we never draw widgets.
        .systemLibrary(
            name: "CGtk3",
            path: "Sources/CGtk3",
            pkgConfig: "gtk+-3.0",
            providers: [
                .apt(["libgtk-3-dev"]),
                .yum(["gtk3-devel"]),
            ]
        ),
        .executableTarget(
            name: "RepoBarGtk",
            dependencies: [
                "CAyatanaAppIndicator",
                "CGtk3",
                .product(name: "RepoBarCore", package: "repobar"),
            ],
            path: "Sources/RepoBarGtk"
        ),
        .testTarget(
            name: "RepoBarGtkTests",
            dependencies: [
                "RepoBarGtk",
                .product(name: "RepoBarCore", package: "repobar"),
            ],
            path: "Tests/RepoBarGtkTests",
            swiftSettings: [
                .enableExperimentalFeature("SwiftTesting"),
            ]
        ),
    ]
)
