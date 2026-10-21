import Darwin
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import AsyncHTTPClient

private final class Probe: @unchecked Sendable {
    let pulled = NIOLockedValueBox(0)
    let iteratorReleased = NIOLockedValueBox(false)
}

private final class IteratorBox: @unchecked Sendable {
    var base: AsyncStream<ByteBuffer>.Iterator
    let probe: Probe
    init(_ base: AsyncStream<ByteBuffer>.Iterator, _ probe: Probe) {
        self.base = base
        self.probe = probe
    }
    deinit { probe.iteratorReleased.withLockedValue { $0 = true } }
}

private struct TrackedSequence: AsyncSequence, Sendable {
    typealias Element = ByteBuffer
    let base: AsyncStream<ByteBuffer>
    let probe: Probe

    struct AsyncIterator: AsyncIteratorProtocol {
        let box: IteratorBox
        mutating func next() async -> ByteBuffer? {
            let value = await box.base.next()
            if value != nil { box.probe.pulled.withLockedValue { $0 += 1 } }
            return value
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(box: IteratorBox(base.makeAsyncIterator(), probe)) }
}

private func mallocInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return stats.size_in_use
}

private let chunkSize = 1 << 20
private let chunkCount = 64

private func eagerStream() -> AsyncStream<ByteBuffer> {
    AsyncStream { cont in
        for _ in 0..<chunkCount { cont.yield(ByteBuffer(repeating: 0x61, count: chunkSize)) }
        cont.finish()
    }
}

private func lazyStream() -> AsyncStream<ByteBuffer> {
    let produced = NIOLockedValueBox(0)
    return AsyncStream(unfolding: {
        let n = produced.withLockedValue { v -> Int in
            v += 1
            return v
        }
        return n <= chunkCount ? ByteBuffer(repeating: 0x61, count: chunkSize) : nil
    })
}

final class EarlyResponseBodyLeakTests: XCTestCase {
    private struct Outcome {
        let pulled: Int
        let iteratorReleasedAfterEarlyResponse: Bool
        let retainedBytes: Int
        let iteratorReleasedAfterExplicitCancel: Bool

        var summary: String {
            "pulled=\(pulled)/\(chunkCount) iteratorReleased=\(iteratorReleasedAfterEarlyResponse) "
                + "retainedMiB=\(retainedBytes >> 20) releasedAfterCancel=\(iteratorReleasedAfterExplicitCancel)"
        }
    }

    private func runEarlyResponse(
        status: HTTPResponseStatus,
        makeStream: () -> AsyncStream<ByteBuffer>
    ) async throws -> Outcome {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let baseline = mallocInUse()

        let probe = Probe()
        let transaction = try await park(status: status, loop: loop, probe: probe, makeStream: makeStream)

        try await Task.sleep(for: .milliseconds(500))
        let pulled = probe.pulled.withLockedValue { $0 }
        let releasedAfterEarlyResponse = probe.iteratorReleased.withLockedValue { $0 }
        let retained = mallocInUse() - baseline

        transaction.cancel()
        try await Task.sleep(for: .milliseconds(500))
        let releasedAfterCancel = probe.iteratorReleased.withLockedValue { $0 }
        try await group.shutdownGracefully()

        return Outcome(
            pulled: pulled,
            iteratorReleasedAfterEarlyResponse: releasedAfterEarlyResponse,
            retainedBytes: retained,
            iteratorReleasedAfterExplicitCancel: releasedAfterCancel
        )
    }

    @discardableResult
    private func park(
        status: HTTPResponseStatus,
        loop: EventLoop,
        probe: Probe,
        makeStream: () -> AsyncStream<ByteBuffer>
    ) async throws -> Transaction {
        var request = HTTPClientRequest(url: "https://localhost/v2/x/blobs/uploads/u?digest=sha256:0")
        request.method = .PUT
        request.body = .stream(
            TrackedSequence(base: makeStream(), probe: probe),
            length: .known(Int64(chunkSize * chunkCount))
        )
        let prepared = try HTTPClientRequest.Prepared(request)

        let box = NIOLockedValueBox<Transaction?>(nil)
        let ready = ConditionLock(value: false)
        var responseTask: Task<HTTPClientResponse, Error>? = Task {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<HTTPClientResponse, Error>) in
                box.withLockedValue {
                    $0 = Transaction(
                        request: prepared,
                        requestOptions: .forTests(),
                        logger: Logger(label: "test"),
                        connectionDeadline: .distantFuture,
                        preferredEventLoop: loop,
                        responseContinuation: continuation
                    )
                }
                ready.lock()
                ready.unlock(withValue: true)
            }
        }
        ready.lock(whenValue: true)
        ready.unlock()
        let transaction = box.withLockedValue { $0! }

        let executor = MockRequestExecutor(pauseRequestBodyPartStreamAfterASingleWrite: true, eventLoop: loop)
        executor.runRequest(transaction)
        executor.resumeRequestBodyStream()
        try executor.receiveRequestBody { _ in }
        try executor.receiveRequestBody { _ in }

        try await loop.submit {
            transaction.receiveResponseHead(HTTPResponseHead(version: .http2, status: status))
            transaction.receiveResponseEnd(nil, trailers: nil)
        }.get()
        var response: HTTPClientResponse? = try await responseTask!.value
        responseTask = nil
        XCTAssertEqual(response?.status, status)
        response = nil
        box.withLockedValue { $0 = nil }
        return transaction
    }

    func testParkedPumpForLeaksTool() async throws {
        guard ProcessInfo.processInfo.environment["LEAKS_WAIT"] != nil else { throw XCTSkip("manual leaks(1) probe") }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let probe = Probe()
        try await park(status: .unauthorized, loop: group.next(), probe: probe, makeStream: eagerStream)
        if let path = ProcessInfo.processInfo.environment["LEAKS_PIDFILE"] {
            try "\(getpid())".write(toFile: path, atomically: true, encoding: .utf8)
        }
        try await Task.sleep(for: .seconds(120))
        XCTAssertFalse(probe.iteratorReleased.withLockedValue { $0 })
        try await group.shutdownGracefully()
    }

    func testEarly401ParksBodyPumpForeverWithEagerStream() async throws {
        let outcome = try await runEarlyResponse(status: .unauthorized, makeStream: eagerStream)
        print("EAGER: \(outcome.summary)")
        XCTAssertFalse(
            outcome.iteratorReleasedAfterEarlyResponse,
            "body pump task should still be parked after the early 401"
        )
        XCTAssertLessThan(outcome.pulled, chunkCount)
        XCTAssertGreaterThan(outcome.retainedBytes, (chunkCount - 4) * chunkSize)
        XCTAssertTrue(outcome.iteratorReleasedAfterExplicitCancel)
    }

    func testEarly401ParksBodyPumpForeverWithLazyStream() async throws {
        let outcome = try await runEarlyResponse(status: .unauthorized, makeStream: lazyStream)
        print("LAZY: \(outcome.summary)")
        XCTAssertFalse(
            outcome.iteratorReleasedAfterEarlyResponse,
            "body pump task should still be parked after the early 401"
        )
        XCTAssertLessThan(outcome.retainedBytes, 4 * chunkSize)
        XCTAssertTrue(outcome.iteratorReleasedAfterExplicitCancel)
    }
}
