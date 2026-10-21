import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore

func mallocInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return stats.size_in_use
}

func mib(_ bytes: Int) -> Double {
    (Double(bytes) / 1_048_576 * 10).rounded() / 10
}

final class ChannelWatch: Sendable {
    private let counts = NIOLockedValueBox((opened: 0, closed: 0))
    private let onClose: @Sendable () -> Void

    init(onClose: @escaping @Sendable () -> Void) {
        self.onClose = onClose
    }

    var open: Int { counts.withLockedValue { $0.opened - $0.closed } }

    func watch(_ channel: Channel) -> EventLoopFuture<Void> {
        counts.withLockedValue { $0.opened += 1 }
        channel.closeFuture.whenComplete { _ in
            self.counts.withLockedValue { $0.closed += 1 }
            self.onClose()
        }
        return channel.eventLoop.makeSucceededVoidFuture()
    }
}

struct Line: Encodable {
    var event: String
    var ahcRef: String
    var registry: String
    var body: String
    var http: String
    var bodyMiB: Int
    var phase: String?
    var channel: String?
    var status: UInt?
    var version: String?
    var responseBodyBytes: Int?
    var seconds: Double?
    var pulled: Int?
    var chunks: Int?
    var iteratorReleased: Bool?
    var retainedMiB: Double?
    var openConnections: Int?
    var openH2Streams: Int?
    var outcome: String?
    var message: String?

    func emit() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }
}
