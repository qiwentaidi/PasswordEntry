// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PasswordEntry",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PasswordEntryDesktop", targets: ["PasswordEntryDesktop"]),
        .executable(name: "PasswordEntryNativeHost", targets: ["PasswordEntryNativeHost"]),
        .executable(name: "PasswordEntrySmoke", targets: ["PasswordEntrySmoke"])
    ],
    targets: [
        .target(name: "PasswordEntryCore"),
        .executableTarget(name: "PasswordEntryDesktop", dependencies: ["PasswordEntryCore"]),
        .executableTarget(name: "PasswordEntryNativeHost", dependencies: ["PasswordEntryCore"]),
        .executableTarget(name: "PasswordEntrySmoke", dependencies: ["PasswordEntryCore"])
    ]
)
