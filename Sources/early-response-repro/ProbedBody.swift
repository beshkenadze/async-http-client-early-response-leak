import Darwin
import NIOConcurrencyHelpers
import NIOCore

let chunkSize = 1 << 20

final class BodyProbe: Sendable {
    let pulled = NIOLockedValueBox(0)
    let iteratorReleased = NIOLockedValueBox(false)
}

private final class IteratorBox {
    var base: AsyncStream<ByteBuffer>.Iterator
    let probe: BodyProbe

    init(_ base: AsyncStream<ByteBuffer>.Iterator, _ probe: BodyProbe) {
        self.base = base
        self.probe = probe
    }

    deinit { probe.iteratorReleased.withLockedValue { $0 = true } }
}

struct ProbedBody: AsyncSequence, Sendable {
    typealias Element = ByteBuffer

    let base: AsyncStream<ByteBuffer>
    let probe: BodyProbe

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let box: IteratorBox

        mutating func next() async -> ByteBuffer? {
            let value = await box.base.next()
            if value != nil { box.probe.pulled.withLockedValue { $0 += 1 } }
            return value
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(box: IteratorBox(base.makeAsyncIterator(), probe))
    }
}

func makeBodyStream(_ mode: BodyMode, chunks: Int) -> AsyncStream<ByteBuffer> {
    switch mode {
    case .eager:
        return AsyncStream { continuation in
            for _ in 0..<chunks { continuation.yield(randomChunk()) }
            continuation.finish()
        }
    case .lazy:
        let produced = NIOLockedValueBox(0)
        return AsyncStream(unfolding: {
            let index = produced.withLockedValue { count -> Int in
                count += 1
                return count
            }
            return index <= chunks ? randomChunk() : nil
        })
    }
}

private func randomChunk() -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: chunkSize)
    buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: chunkSize) { pointer in
        arc4random_buf(pointer.baseAddress, chunkSize)
        return chunkSize
    }
    return buffer
}
