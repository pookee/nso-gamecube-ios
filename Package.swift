// swift-tools-version:5.9

import PackageDescription

let package = Package(
  name: "NSOGCKit",
  platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16)],
  products: [
    .library(name: "NSOGCKit", targets: ["NSOGCKit"]),
    .executable(name: "nsogc-monitor", targets: ["nsogc-monitor"]),
  ],
  targets: [
    .target(
      name: "NSOGCKit",
      linkerSettings: [
        .linkedFramework("CoreBluetooth"),
        .linkedFramework("IOKit", .when(platforms: [.macOS])),
        .linkedFramework("IOUSBHost", .when(platforms: [.macOS])),
      ]
    ),
    // macOS: prints connected controllers' input, over USB and Bluetooth.
    .executableTarget(name: "nsogc-monitor", dependencies: ["NSOGCKit"]),
    .testTarget(name: "NSOGCKitTests", dependencies: ["NSOGCKit"]),
  ]
)
