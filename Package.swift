// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "StepBar", platforms: [.macOS(.v13)], products: [.executable(name: "StepBar", targets: ["StepBar"])], targets: [.executableTarget(name: "StepBar")])
