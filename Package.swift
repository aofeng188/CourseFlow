// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CourseKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "CourseKit", targets: ["CourseKit"])],
    targets: [
        .target(name: "CourseKit", path: "Shared/Core"),
        .testTarget(name: "CourseKitTests", dependencies: ["CourseKit"], path: "Tests/CoreTests", resources: [.copy("Fixtures")])
    ]
)
