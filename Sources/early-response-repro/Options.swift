import Foundation

enum BodyMode: String {
    case eager
    case lazy
}

enum Transport: String {
    case h2
    case http1
}

struct Options {
    static let usage =
        "usage: early-response-repro [--body eager|lazy] [--http h2|http1] [--mib 1-64] [--wait SECONDS] [--shutdown-timeout SECONDS] [--registry HOST] [--url URL]"
    static let maximumMiB = 64

    var body = BodyMode.eager
    var transport = Transport.h2
    var mib = 64
    var waitSeconds = 30
    var shutdownTimeoutSeconds = 10
    var registry = "registry-1.docker.io"
    var url: String?

    init(_ arguments: [String]) throws {
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst() else { throw UsageError() }
            switch flag {
            case "--body": body = try Self.parse(BodyMode(rawValue: value))
            case "--http": transport = try Self.parse(Transport(rawValue: value))
            case "--mib": mib = try Self.parse(Int(value).flatMap { (1...Self.maximumMiB).contains($0) ? $0 : nil })
            case "--wait": waitSeconds = try Self.parse(Int(value).flatMap { $0 >= 0 ? $0 : nil })
            case "--shutdown-timeout": shutdownTimeoutSeconds = try Self.parse(Int(value).flatMap { $0 > 0 ? $0 : nil })
            case "--registry": registry = value
            case "--url": url = value
            default: throw UsageError()
            }
        }
    }

    var uploadURL: String {
        url ?? "https://\(registry)/v2/ahc-early-response-\(randomHex(bytes: 6))/probe/blobs/uploads/\(UUID().uuidString.lowercased())?digest=sha256:\(randomHex(bytes: 32))"
    }

    private static func parse<T>(_ value: T?) throws -> T {
        guard let value else { throw UsageError() }
        return value
    }
}

struct UsageError: Error, CustomStringConvertible {
    var description: String { Options.usage }
}

private func randomHex(bytes: Int) -> String {
    (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
}
