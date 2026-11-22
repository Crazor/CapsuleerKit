import Foundation
import Testing
import os
@testable import CapsuleerCore

/// Collects lines written by a `StderrLogSink`.
final class LineCollector: Sendable {
    private let state = OSAllocatedUnfairLock<[String]>(initialState: [])
    func append(_ line: String) { state.withLock { $0.append(line) } }
    var lines: [String] { state.withLock { $0 } }
}

/// A fixed clock: 2026-11-22T11:35:59.250Z.
private struct FixedTime: TimeSource {
    func now() -> Date { Date(timeIntervalSince1970: 1_795_347_359.25) }
    func sleep(for duration: Duration) async throws {}
}

private func makeSink(minimumLevel: LogLevel = .info, revealPrivate: Bool = false) -> (StderrLogSink, LineCollector) {
    let collector = LineCollector()
    let sink = StderrLogSink(minimumLevel: minimumLevel, revealPrivate: revealPrivate, timeSource: FixedTime()) { collector.append($0) }
    return (sink, collector)
}

@Suite struct StderrLogSinkTests {
    @Test func formatsOneLine() {
        let (sink, out) = makeSink()
        sink.log(.info, .http, "GET https://sde.evetech.net/tranquility/latest/", metadata: ["status": "200", "duration": "0.12s"])
        #expect(out.lines == ["2026-11-22T11:35:59.250Z info [http] GET https://sde.evetech.net/tranquility/latest/ duration=0.12s status=200\n"])
    }

    @Test func noMetadata() {
        let (sink, out) = makeSink()
        sink.log(.warning, .sde, "table unchanged")
        #expect(out.lines == ["2026-11-22T11:35:59.250Z warning [sde] table unchanged\n"])
    }

    @Test func filtersBelowMinimumLevel() {
        let (sink, out) = makeSink(minimumLevel: .notice)
        for level in LogLevel.allCases {
            sink.log(level, .cache, "m")
        }
        #expect(out.lines.count == 3)
        #expect(out.lines.map { $0.split(separator: " ")[1] } == ["notice", "warning", "error"])
    }

    @Test func debugSinkLogsEverything() {
        let (sink, out) = makeSink(minimumLevel: .debug)
        for level in LogLevel.allCases { sink.log(level, .cache, "m") }
        #expect(out.lines.count == LogLevel.allCases.count)
    }

    @Test func redactsPrivateMetadataByDefault() {
        let (sink, out) = makeSink()
        sink.log(.info, .sso, "token refreshed", metadata: ["scopes": "3"], privateMetadata: ["character": "2112345678"])
        let line = out.lines.first ?? ""
        #expect(line.hasSuffix("token refreshed scopes=3 character=<private>\n"))
        #expect(!line.contains("2112345678"))
    }

    @Test func revealsPrivateMetadataWhenAsked() {
        let (sink, out) = makeSink(revealPrivate: true)
        sink.log(.info, .sso, "token refreshed", privateMetadata: ["character": "2112345678"])
        #expect(out.lines.first?.hasSuffix("token refreshed character=2112345678\n") == true)
    }

    @Test func quotesAndEscapesValues() {
        let (sink, out) = makeSink()
        sink.log(.error, .http, "failed\nsecond line", metadata: ["message": "not \"found\"", "empty": "", "path": #"a\b"#])
        #expect(out.lines == [#"2026-11-22T11:35:59.250Z error [http] failed\nsecond line empty="" message="not \"found\"" path=a\b"# + "\n"])
    }
}

@Suite struct OSLogSinkTests {
    @Test func levelMapping() {
        #expect(OSLogSink.osLogType(for: .debug) == .debug)
        #expect(OSLogSink.osLogType(for: .info) == .info)
        #expect(OSLogSink.osLogType(for: .notice) == .default)
        #expect(OSLogSink.osLogType(for: .warning) == .error)
        #expect(OSLogSink.osLogType(for: .error) == .error)
    }

    @Test func cachesOneLoggerPerCategory() {
        let sink = OSLogSink(subsystem: "CapsuleerKitTests")
        sink.log(.debug, .http, "one", metadata: ["a": "1"])
        sink.log(.info, .http, "two", privateMetadata: ["character": "1"])
        sink.log(.error, .cache, "three", metadata: ["a": "1"], privateMetadata: ["b": "2"])
        let copy = sink
        copy.log(.notice, .http, "four")
        #expect(sink.cachedLoggerCount == 2)
    }

    @Test func skipsBelowMinimumLevel() {
        let sink = OSLogSink(subsystem: "CapsuleerKitTests", minimumLevel: .warning)
        sink.log(.info, .sde, "dropped")
        #expect(sink.cachedLoggerCount == 0)
        sink.log(.warning, .sde, "kept")
        #expect(sink.cachedLoggerCount == 1)
    }
}
