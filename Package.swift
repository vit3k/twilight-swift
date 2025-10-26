// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "twilight",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "twilight",
            targets: ["twilight"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/CoreOffice/XMLCoder.git", from: "0.17.0")
    ],
    targets: [
        .target(
            name: "CLibMoonlight",
            path: "CLibMoonlight",
            sources: ["LogHelpers.c"],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("../moonlight-common-c/src")
            ],
            linkerSettings: [
                .unsafeFlags(["-L../moonlight-common-c/build", "-lmoonlight-common-c"])
            ]
        ),
        .executableTarget(
            name: "twilight",
            dependencies: [
                .product(name: "XMLCoder", package: "XMLCoder"),
                "CLibMoonlight",
            ],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-L./moonlight-common-c/build", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../moonlight-common-c/build"])
            ]
        ),

    ]
)
