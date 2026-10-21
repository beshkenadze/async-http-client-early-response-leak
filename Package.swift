// swift-tools-version: 6.2

import Foundation
import PackageDescription

let environment = ProcessInfo.processInfo.environment

let asyncHTTPClientPackage: String
let asyncHTTPClient: Package.Dependency
if let path = environment["AHC_PATH"], !path.isEmpty {
    asyncHTTPClientPackage = URL(fileURLWithPath: path).lastPathComponent.lowercased()
    asyncHTTPClient = .package(path: path)
} else if let revision = environment["AHC_REVISION"], !revision.isEmpty {
    asyncHTTPClientPackage = "async-http-client"
    asyncHTTPClient = .package(url: "https://github.com/swift-server/async-http-client.git", revision: revision)
} else {
    asyncHTTPClientPackage = "async-http-client"
    let version = environment["AHC_VERSION"] ?? "1.36.2"
    asyncHTTPClient = .package(url: "https://github.com/swift-server/async-http-client.git", exact: Version(stringLiteral: version))
}

let package = Package(
    name: "async-http-client-early-response-leak",
    platforms: [.macOS("15.0")],
    dependencies: [
        asyncHTTPClient,
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .executableTarget(
            name: "early-response-repro",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: asyncHTTPClientPackage),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
        )
    ]
)
