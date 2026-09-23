import XCTest
import Darwin
@testable import BackupAndEjectCore

final class CommandRunnerTests: XCTestCase {
    func testRetriesBadFileDescriptorLaunchWithFreshProcess() throws {
        var launches = 0
        let runner = SystemCommandRunner { process in
            launches += 1
            if launches == 1 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF))
            }
            try process.run()
        }

        let result = try runner.run(
            "/bin/echo",
            arguments: ["recovered"],
            timeout: 2
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "recovered")
        XCTAssertEqual(launches, 2)
    }

    func testDoesNotRetryOtherLaunchFailures() {
        var launches = 0
        let runner = SystemCommandRunner { _ in
            launches += 1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }

        XCTAssertThrowsError(
            try runner.run("/bin/echo", arguments: [], timeout: 2)
        )
        XCTAssertEqual(launches, 1)
    }

    func testBoundsBadFileDescriptorLaunchRetries() {
        var launches = 0
        let runner = SystemCommandRunner { _ in
            launches += 1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF))
        }

        XCTAssertThrowsError(
            try runner.run("/bin/echo", arguments: [], timeout: 2)
        )
        XCTAssertEqual(launches, 3)
    }

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
