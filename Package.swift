// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeviceHop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DeviceHop",
            linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("CoreBluetooth")]
        )
    ]
)
