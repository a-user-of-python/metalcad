import XCTest
@testable import MetalCADKit

/// 50 checks: structured logging — levels, ring buffer, JSONL file sink,
/// rotation, error-code capture.
final class LogTests: XCTestCase {

    private func freshLog(capacity: Int = 2000, maxBytes: Int = 5_000_000) -> MCLog {
        let l = MCLog(ringCapacity: capacity, maxFileBytes: maxBytes)
        l.minimumLevel = .trace
        return l
    }

    func testBasicEntry() {
        let l = freshLog()
        l.info(.general, "hello")
        XCTAssertEqual(l.entryCount, 1)
        let e = l.recentEntries().first!
        XCTAssertEqual(e.level, .info)
        XCTAssertEqual(e.category, .general)
        XCTAssertEqual(e.message, "hello")
        XCTAssertNil(e.code)
    }

    func testLevelFiltering() {
        let l = freshLog()
        l.minimumLevel = .warn
        l.info(.general, "quiet")
        l.debug(.general, "quiet2")
        XCTAssertEqual(l.entryCount, 0)
        l.warn(.general, "loud")
        l.log(.error, .general, "louder")
        XCTAssertEqual(l.entryCount, 2)
    }

    func testWarnAlwaysPassesEvenWhenLevelHigh() {
        let l = freshLog()
        l.minimumLevel = .fatal
        l.warn(.general, "w")
        XCTAssertEqual(l.entryCount, 1)
    }

    func testContextPreserved() {
        let l = freshLog()
        l.info(.feature, "pad", context: ["ms": "3.2", "tris": "12"])
        let e = l.recentEntries().first!
        XCTAssertEqual(e.context["ms"], "3.2")
        XCTAssertEqual(e.context["tris"], "12")
    }

    func testRingBufferCapacity() {
        let l = freshLog(capacity: 10)
        for i in 0..<25 { l.info(.general, "m\(i)") }
        XCTAssertEqual(l.entryCount, 10)
        XCTAssertEqual(l.recentEntries().first?.message, "m15")
        XCTAssertEqual(l.recentEntries().last?.message, "m24")
    }

    func testRecentLimit() {
        let l = freshLog()
        for i in 0..<50 { l.info(.general, "m\(i)") }
        XCTAssertEqual(l.recentEntries(limit: 5).count, 5)
        XCTAssertEqual(l.recentEntries(limit: 5).last?.message, "m49")
    }

    func testErrorLoggingCapturesCode() {
        let l = freshLog()
        l.log(error: .profileOpen(gapA: .zero, gapB: Vec2(1, 1)), category: .sketch)
        let e = l.recentEntries().first!
        XCTAssertEqual(e.code, "MCAD-SK204")
        XCTAssertEqual(e.level, .error)
        XCTAssertEqual(e.category, .sketch)
        XCTAssertEqual(l.lastErrorCode(), "MCAD-SK204")
    }

    func testWarningErrorLogsAtWarn() {
        let l = freshLog()
        l.log(error: .duplicateName("plate"), category: .document)
        XCTAssertEqual(l.recentEntries().first?.level, .warn)
        XCTAssertNil(l.lastErrorCode())
    }

    func testFatalErrorLogsAtFatal() {
        let l = freshLog()
        l.log(error: .outOfMemory, category: .general)
        XCTAssertEqual(l.recentEntries().first?.level, .fatal)
        XCTAssertEqual(l.lastErrorCode(), "MCAD-GN002")
    }

    func testJSONLineRoundTrips() throws {
        let e = LogEntry(timestamp: Date(timeIntervalSince1970: 1700000000), level: .error,
                         category: .solver, code: "MCAD-SV302", message: "fight",
                         context: ["k": "v"])
        let line = e.jsonLine()
        XCTAssertTrue(line.contains("MCAD-SV302"))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601   // jsonLine writes ISO-8601 timestamps
        let back = try dec.decode(LogEntry.self, from: Data(line.utf8))
        XCTAssertEqual(back.code, "MCAD-SV302")
        XCTAssertEqual(back.context["k"], "v")
        XCTAssertEqual(back.level, .error)
    }

    func testFileSinkWritesJSONL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mclog-\(UUID().uuidString)")
        let l = freshLog()
        l.attachFileSink(directory: dir)
        l.info(.general, "line one")
        l.log(error: .kernelTimeout, category: .kernel)
        l.detachFileSink()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: files[0], encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("line one"))
        XCTAssertTrue(lines[1].contains("MCAD-KN605"))
        // Each line must be valid JSON.
        for line in lines {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    func testFileRotation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mclog-\(UUID().uuidString)")
        let l = freshLog(maxBytes: 400)
        l.attachFileSink(directory: dir)
        for i in 0..<40 { l.info(.general, "entry number \(i) with some padding text") }
        l.detachFileSink()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertGreaterThan(files.count, 1)
        XCTAssertLessThanOrEqual(files.count, 5)
    }

    func testClear() {
        let l = freshLog()
        l.info(.general, "x")
        l.clear()
        XCTAssertEqual(l.entryCount, 0)
        XCTAssertNil(l.lastErrorCode())
    }

    func testTotalWrittenCounts() {
        let l = freshLog(capacity: 5)
        for _ in 0..<12 { l.info(.general, "x") }
        XCTAssertEqual(l.totalEntriesWritten, 12)
        XCTAssertEqual(l.entryCount, 5)
    }

    func testConcurrentWrites() {
        let l = freshLog(capacity: 100_000)
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            l.info(.general, "concurrent \(i)")
        }
        XCTAssertEqual(l.entryCount, 500)
        XCTAssertEqual(l.totalEntriesWritten, 500)
    }

    func testCategoriesRoundTrip() {
        let cats: [LogCategory] = [.general, .document, .sketch, .solver, .feature, .thread,
                                   .kernel, .io, .assembly, .drawing, .render, .ui, .perf, .lifecycle]
        let l = freshLog()
        for c in cats { l.info(c, "cat") }
        XCTAssertEqual(l.recentEntries().map { $0.category }, cats)
    }

    func testLevelsComparable() {
        XCTAssertLessThan(LogLevel.trace, LogLevel.debug)
        XCTAssertLessThan(LogLevel.info, LogLevel.warn)
        XCTAssertLessThan(LogLevel.warn, LogLevel.error)
        XCTAssertLessThan(LogLevel.error, LogLevel.fatal)
    }
}

// MARK: Top-up checks

extension LogTests {
    func testLevelNames() {
        XCTAssertEqual(LogLevel.trace.name, "TRACE")
        XCTAssertEqual(LogLevel.info.name, "INFO")
        XCTAssertEqual(LogLevel.fatal.name, "FATAL")
    }

    func testJSONLineContainsCategoryAndMessage() {
        let e = LogEntry(timestamp: Date(), level: .info, category: .perf,
                         code: nil, message: "rebuild 12ms", context: [:])
        let line = e.jsonLine()
        XCTAssertTrue(line.contains("perf"))
        XCTAssertTrue(line.contains("rebuild 12ms"))
    }

    func testLastErrorCodePicksLatest() {
        let l = freshLog()
        l.log(error: .kernelTimeout, category: .kernel)
        l.info(.general, "in between")
        l.log(error: .padNoProfile, category: .feature)
        XCTAssertEqual(l.lastErrorCode(), "MCAD-FT401")
    }

    func testOrderPreserved() {
        let l = freshLog()
        for i in 0..<10 { l.info(.general, "e\(i)") }
        XCTAssertEqual(l.recentEntries(limit: 3).map { $0.message }, ["e7", "e8", "e9"])
    }

    func testDetachStopsFileWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mclog-\(UUID().uuidString)")
        let l = freshLog()
        l.attachFileSink(directory: dir)
        l.info(.general, "before detach")
        l.detachFileSink()
        l.info(.general, "after detach")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let text = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(text.contains("before detach"))
        XCTAssertFalse(text.contains("after detach"))
        XCTAssertEqual(l.entryCount, 2)  // ring still records
    }

    func testTraceHelper() {
        let l = freshLog()
        l.trace(.solver, "iter 1")
        l.debug(.solver, "jac")
        XCTAssertEqual(l.entryCount, 2)
        XCTAssertEqual(l.recentEntries().first?.level, .trace)
    }
}
