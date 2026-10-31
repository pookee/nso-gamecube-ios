// swift-tools-version:5.9

import PackageDescription

let package = Package(
  name: "NSOGCKit",
  platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16)],
  products: [
    .library(name: "NSOGCKit", targets: ["NSOGCKit"])
  ],
  targets: [
    .target(
      name: "NSOGCKit",
      linkerSettings: [.linkedFramework("CoreBluetooth")]
    ),
    .testTarget(name: "NSOGCKitTests", dependencies: ["NSOGCKit"]),
  ]
)
