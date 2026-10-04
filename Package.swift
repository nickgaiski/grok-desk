// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrokDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GrokDesk", targets: ["GrokDesk"]),
        .executable(name: "GrokDeskRoutineRunner", targets: ["GrokDeskRoutineRunner"]),
    ],
    dependencies: [.package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"), .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")],
    targets: [
        .target(name: "GrokDeskCore", dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]),
        .executableTarget(name: "GrokDeskRoutineRunner", dependencies: ["GrokDeskCore"]),
        .executableTarget(
            name: "GrokDesk",
            dependencies: ["GrokDeskCore", .product(name: "TOMLKit", package: "TOMLKit"), .product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.copy("Resources/default.metallib")],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(name: "GrokDeskTests", dependencies: ["GrokDeskCore"], resources: [.copy("Fixtures")]),
    ]
)
