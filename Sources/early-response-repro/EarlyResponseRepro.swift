import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import NIOCore

@main
struct EarlyResponseRepro {
    static func main() async {
        do {
            await Repro(try Options(Array(CommandLine.arguments.dropFirst()))).run()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(64)
        }
    }
}

enum ShutdownOutcome: String {
    case completed
    case failed
    case timedOut
}

struct Repro {
    let options: Options
    let url: String
    let template: Line
    let start = ContinuousClock.now
    let probe = BodyProbe()
    let connections: ChannelWatch
    let streams: ChannelWatch

    init(_ options: Options) {
        let url = options.uploadURL
        let template = Line(
            event: "",
            ahcRef: ProcessInfo.processInfo.environment["AHC_REF"] ?? "unknown",
            registry: URL(string: url)?.host ?? url,
            body: options.body.rawValue,
            http: options.transport.rawValue,
            bodyMiB: options.mib
        )
        let start = self.start
        let closed: @Sendable (String) -> @Sendable () -> Void = { channel in
            {
                var line = template
                line.event = "channelClosed"
                line.channel = channel
                line.seconds = seconds(since: start)
                line.emit()
            }
        }
        self.options = options
        self.url = url
        self.template = template
        self.connections = ChannelWatch(onClose: closed("connection"))
        self.streams = ChannelWatch(onClose: closed("h2Stream"))
    }

    func run() async {
        var configuration = HTTPClient.Configuration()
        configuration.httpVersion = options.transport == .http1 ? .http1Only : .automatic
        configuration.http1_1ConnectionDebugInitializer = { [connections] in connections.watch($0) }
        configuration.http2ConnectionDebugInitializer = { [connections] in connections.watch($0) }
        configuration.http2StreamChannelDebugInitializer = { [streams] in streams.watch($0) }
        let client = HTTPClient(configuration: configuration)
        let baseline = mallocInUse()

        do {
            let response = try await send(client)
            var line = measure("response", baseline: baseline)
            line.status = response.status
            line.version = response.version
            line.responseBodyBytes = response.bodyBytes
            line.seconds = seconds(since: start)
            line.emit()
        } catch {
            var line = measure("error", baseline: baseline)
            line.seconds = seconds(since: start)
            line.message = String(describing: error)
            line.emit()
        }

        try? await Task.sleep(for: .seconds(options.waitSeconds))
        var afterWait = measure("afterWait", baseline: baseline)
        afterWait.seconds = Double(options.waitSeconds)
        afterWait.emit()

        let shutdownStart = ContinuousClock.now
        let outcome = await shutdown(client, timeout: .seconds(options.shutdownTimeoutSeconds))
        var shutdownLine = template
        shutdownLine.event = "shutdown"
        shutdownLine.outcome = outcome.rawValue
        shutdownLine.seconds = seconds(since: shutdownStart)
        shutdownLine.emit()

        try? await Task.sleep(for: .seconds(1))
        measure("afterShutdown", baseline: baseline).emit()
    }

    private func send(_ client: HTTPClient) async throws -> (status: UInt, version: String, bodyBytes: Int) {
        var request = HTTPClientRequest(url: url)
        request.method = .PUT
        request.headers.add(name: "Content-Type", value: "application/octet-stream")
        request.body = .stream(
            ProbedBody(base: makeBodyStream(options.body, chunks: options.mib), probe: probe),
            length: .known(Int64(options.mib * chunkSize))
        )
        let response = try await client.execute(request, timeout: .seconds(120))
        var bodyBytes = 0
        for try await part in response.body { bodyBytes += part.readableBytes }
        return (response.status.code, "\(response.version)", bodyBytes)
    }

    private func measure(_ phase: String, baseline: Int) -> Line {
        var line = template
        line.event = "measure"
        line.phase = phase
        line.pulled = probe.pulled.withLockedValue { $0 }
        line.chunks = options.mib
        line.iteratorReleased = probe.iteratorReleased.withLockedValue { $0 }
        line.retainedMiB = mib(mallocInUse() - baseline)
        line.openConnections = connections.open
        line.openH2Streams = streams.open
        return line
    }

    private func shutdown(_ client: HTTPClient, timeout: Duration) async -> ShutdownOutcome {
        await withCheckedContinuation { continuation in
            let pending = NIOLockedValueBox<CheckedContinuation<ShutdownOutcome, Never>?>(continuation)
            let finish: @Sendable (ShutdownOutcome) -> Void = { outcome in
                pending.withLockedValue { $0.take() }?.resume(returning: outcome)
            }
            Task {
                do {
                    try await client.shutdown()
                    finish(.completed)
                } catch {
                    finish(.failed)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                finish(.timedOut)
            }
        }
    }
}

private func seconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    let value = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return (value * 1000).rounded() / 1000
}
