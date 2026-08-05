import XCTest
@testable import BackupAndEjectCore

final class CommandRunnerTests: XCTestCase {
    func testKeepsStandardErrorOutOfParserInput() throws {
        let result = try SystemCommandRunner().run(
            "/bin/sh",
            arguments: [
                "-c",
                "printf '<plist></plist>'; printf 'warning' >&2"
            ],
            timeout: 2
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "<plist></plist>")
        XCTAssertEqual(result.standardError, "warning")
        XCTAssertEqual(result.output, "<plist></plist>\nwarning")
    }

    func testTimesOutAQuickCommand() {
        XCTAssertThrowsError(
            try SystemCommandRunner().run(
                "/bin/sleep",
                arguments: ["2"],
                timeout: 0.05
            )
        ) { error in
            guard case CommandRunnerError.timedOut = error else {
                return XCTFail("Expected a timeout, got \(error)")
            }
        }
    }

    func testOutputCollectionStopsWhenPipeWriterDoesNotClose() throws {
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let collector = CommandOutputCollector(
            standardOutputPipe: standardOutputPipe,
            standardErrorPipe: standardErrorPipe
        )
        collector.start()

        try standardOutputPipe.fileHandleForWriting.write(
            contentsOf: Data("partial output".utf8)
        )
        try standardOutputPipe.fileHandleForWriting.close()
        let startedAt = Date()
        let output = collector.finish(timeout: 0.05)

        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1,
            "Output collection must not wait indefinitely for EOF"
        )
        XCTAssertEqual(output.standardOutput, "partial output")
        XCTAssertEqual(output.standardError, "")

        try standardErrorPipe.fileHandleForWriting.close()
    }
}
