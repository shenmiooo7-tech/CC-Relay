import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class TranscriptUsageReaderTests: XCTestCase {
    private let id = "transcript-usage-test"

    private func file(_ scratch: ScratchDirectory) -> URL {
        scratch.paths.claudeCLIHome.appending(path: "projects/project/" + id + ".jsonl")
    }

    private func row(_ usage: [String: Any], type: String = "assistant") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "message": ["usage": usage], "sessionId": id])
    }

    private func lines(_ rows: [Data], trailingNewline: Bool = true) -> Data {
        var data = Data()
        for (index, row) in rows.enumerated() {
            if index > 0 { data.append(10) }
            data.append(row)
        }
        if trailingNewline { data.append(10) }
        return data
    }

    func testLatestAssistantUsageWinsEvenWithALaterUserRowAndNoTrailingNewline() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        let assistant = try row(["input_tokens": 1200, "cache_read_input_tokens": 97_000,
            "cache_creation_input_tokens": 1500, "output_tokens": 300])
        let user = try row(["input_tokens": 900_000], type: "user")
        try AtomicFile.write(lines([assistant]), to: file(scratch))
        let reader = TranscriptUsageReader(paths: scratch.paths)
        XCTAssertEqual(reader.contextTokens(cliSessionID: id), 100_000)
        try AtomicFile.write(lines([try row(["input_tokens": 8]), assistant, user], trailingNewline: false), to: file(scratch))
        XCTAssertEqual(reader.contextTokens(cliSessionID: id), 100_000)
    }

    func testMissingFieldsAreZeroAndMalformedUsageRowsAreSkipped() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        let reader = TranscriptUsageReader(paths: scratch.paths)
        let usable = try row(["input_tokens": 17])
        let missingUsage = Data(#"{"type":"assistant","message":{}}"#.utf8)
        let wrongUsage = Data(#"{"type":"assistant","message":{"usage":"unknown"}}"#.utf8)
        let invalidJSON = Data("unfinished-json".utf8)
        for value: Any in ["3", true, NSNull(), 3.5, [1, 2], ["nested": 1]] {
            try AtomicFile.write(lines([usable, try row(["input_tokens": value]), missingUsage, wrongUsage, invalidJSON]), to: file(scratch))
            XCTAssertEqual(reader.contextTokens(cliSessionID: id), 17)
        }
        try AtomicFile.write(lines([usable, try row([:])]), to: file(scratch))
        XCTAssertEqual(reader.contextTokens(cliSessionID: id), 17)
        try AtomicFile.write(lines([missingUsage, wrongUsage, invalidJSON]), to: file(scratch))
        XCTAssertNil(reader.contextTokens(cliSessionID: id))
        try AtomicFile.write(lines([usable, try row(["input_tokens": Int.max, "output_tokens": 1])]), to: file(scratch))
        XCTAssertEqual(reader.contextTokens(cliSessionID: id), 17)
    }

    func testLocalNoticesAndSubagentRowsDoNotHideTheLatestAnswer() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        let answer = try row(["cache_read_input_tokens": 150_000, "output_tokens": 20])
        let limitNotice = Data(#"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#.utf8)
        let syntheticWithUsage = Data(#"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":9}}}"#.utf8)
        let subagent = Data(#"{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":4000}}}"#.utf8)
        try AtomicFile.write(lines([answer, subagent, syntheticWithUsage, limitNotice, try row(["output_tokens": 0])]), to: file(scratch))
        XCTAssertEqual(TranscriptUsageReader(paths: scratch.paths).contextTokens(cliSessionID: id), 150_020)
        try AtomicFile.write(lines([limitNotice, subagent]), to: file(scratch))
        XCTAssertNil(TranscriptUsageReader(paths: scratch.paths).contextTokens(cliSessionID: id))
    }

    func testCompactionNewerThanTheLatestAnswerGivesNoHint() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        let reader = TranscriptUsageReader(paths: scratch.paths)
        let before = try row(["cache_read_input_tokens": 960_000])
        let boundary = Data(#"{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":960000}}"#.utf8)
        let summary = Data(#"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"summary"}}"#.utf8)
        try AtomicFile.write(lines([before, boundary, summary]), to: file(scratch))
        XCTAssertNil(reader.contextTokens(cliSessionID: id))
        try AtomicFile.write(lines([before, boundary]), to: file(scratch))
        XCTAssertNil(reader.contextTokens(cliSessionID: id))
        try AtomicFile.write(lines([before, summary]), to: file(scratch))
        XCTAssertNil(reader.contextTokens(cliSessionID: id))
        try AtomicFile.write(lines([before, boundary, summary, try row(["cache_creation_input_tokens": 93_000])]), to: file(scratch))
        XCTAssertEqual(reader.contextTokens(cliSessionID: id), 93_000)
    }

    func testRowsCanSpanManyChunksIncludingUTF8Characters() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        let usage = try row(["cache_read_input_tokens": 100_001, "output_tokens": 5])
        let user = try JSONSerialization.data(withJSONObject: ["type": "user", "text": "跨越边界"])
        try AtomicFile.write(lines([try row(["input_tokens": 1]), usage, user]), to: file(scratch))
        for chunk in [1, 7, 23, 64 * 1024] {
            XCTAssertEqual(TranscriptUsageReader(paths: scratch.paths, chunkBytes: chunk).contextTokens(cliSessionID: id), 100_006)
        }
    }

    func testLineLongerThanSixteenMiBStopsWithoutUsingEarlierUsage() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        let older = try row(["input_tokens": 200_000])
        var data = older
        data.append(10)
        data.append(Data(repeating: 32, count: TranscriptUsageReader.maximumLineBytes + 1))
        data.append(10)
        try AtomicFile.write(data, to: file(scratch))
        XCTAssertNil(TranscriptUsageReader(paths: scratch.paths).contextTokens(cliSessionID: id))
        // An answer newer than the huge line needs no read of that older line.
        data.append(try row(["input_tokens": 100_000]))
        try AtomicFile.write(data, to: file(scratch))
        XCTAssertEqual(TranscriptUsageReader(paths: scratch.paths).contextTokens(cliSessionID: id), 100_000)
    }

    func testSixtyFourMiBScanBudgetDoesNotReachAnOlderAnswer() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        let path = file(scratch)
        try AtomicFile.write(lines([try row(["input_tokens": 100_000])]), to: path)
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var block = Data(repeating: 32, count: 64 * 1024 - 3)
        block.append(contentsOf: [123, 125, 10])
        for _ in 0..<(TranscriptUsageReader.maximumScanBytes / block.count) { try handle.write(contentsOf: block) }
        XCTAssertNil(TranscriptUsageReader(paths: scratch.paths).contextTokens(cliSessionID: id))
    }

    func testProjectAndTranscriptSymlinksAreFollowedAndUnreadablePathsGiveNoHint() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        let projects = scratch.paths.claudeCLIHome.appending(path: "projects")
        let project = scratch.root.appending(path: "linked-project")
        let transcript = scratch.root.appending(path: "linked-transcript.jsonl")
        try AtomicFile.write(lines([try row(["input_tokens": 123_456])]), to: transcript)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: projects.appending(path: "project"), withDestinationURL: project)
        try FileManager.default.createSymbolicLink(at: project.appending(path: id + ".jsonl"), withDestinationURL: transcript)
        let reader = TranscriptUsageReader(paths: scratch.paths)
        XCTAssertEqual(reader.contextTokens(cliSessionID: id), 123_456)
        XCTAssertNil(reader.contextTokens(cliSessionID: "../outside"))
        try FileManager.default.removeItem(at: transcript)
        XCTAssertNil(reader.contextTokens(cliSessionID: id))
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: false)
        XCTAssertNil(reader.contextTokens(cliSessionID: id))
    }
}
