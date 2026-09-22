// swift-tools-version:6.1

import PackageDescription

let package = Package(
    name: "gis-tools-geopackage",
    platforms: [
        .iOS(.v15),
        .macOS(.v15),
        .tvOS(.v15),
        .watchOS(.v7),
    ],
    products: [
        .library(
            name: "GISToolsGeoPackage",
            targets: ["GISToolsGeoPackage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Outdooractive/gis-tools", exact: "3.0.0-beta.1"),
    ],
    targets: [
        .systemLibrary(
            name: "OACSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"]),
            ]),
        .target(
            name: "GISToolsGeoPackage",
            dependencies: [
                .product(name: "GISTools", package: "gis-tools"),
                "OACSQLite",
            ]),
        .testTarget(
            name: "GISToolsGeoPackageTests",
            dependencies: ["GISToolsGeoPackage"],
            exclude: ["TestData"]),
    ]
)
