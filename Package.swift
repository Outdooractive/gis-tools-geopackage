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
        .package(url: "https://github.com/Outdooractive/gis-tools.git", branch: "main"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"]),
            ]),
        .target(
            name: "GISToolsGeoPackage",
            dependencies: [
                .product(name: "GISTools", package: "gis-tools"),
                "CSQLite",
            ]),
        .testTarget(
            name: "GISToolsGeoPackageTests",
            dependencies: ["GISToolsGeoPackage"],
            exclude: ["TestData"]),
    ]
)
