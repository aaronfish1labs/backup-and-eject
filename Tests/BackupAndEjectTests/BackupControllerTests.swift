import XCTest
@testable import BackupAndEject
import BackupAndEjectCore

final class BackupControllerTests: XCTestCase {
    func testWaitsForExistingBackupToSelectedDestinationThenRunsVerifiedBackup() {
        let harness = WorkflowHarness(
            existingBackupDestinationID: "TARGET-ID",
            existingBackupPolls: 2
        )

        let completion = harness.runBackup()

        guard case .success? = completion else {
            return XCTFail("Expected a successful backup and eject")
        }
        XCTAssertEqual(harness.runner.startBackupCount, 1)
        XCTAssertEqual(harness.runner.ejectCount, 1)
        XCTAssertTrue(
            harness.runner.calls
                .filter { $0.arguments.first != "startbackup" }
                .allSatisfy { $0.timeout == 0.25 }
        )
        XCTAssertNil(
            harness.runner.calls.first {
                $0.arguments.first == "startbackup"
            }?.timeout
        )
    }

    func testRetriesOneTransientStatusTimeoutThenCompletesSafely() {
        let harness = WorkflowHarness(statusTimeoutsRemaining: 1)

        let completion = harness.runBackup()

        guard case .success? = completion else {
            return XCTFail("Expected the retry to recover")
        }
        XCTAssertGreaterThanOrEqual(harness.runner.statusCount, 2)
        XCTAssertEqual(harness.runner.startBackupCount, 1)
        XCTAssertEqual(harness.runner.ejectCount, 1)
    }

    func testRetriesOneTransientDestinationTimeoutThenCompletesSafely() {
        let harness = WorkflowHarness(
            destinationInfoTimeoutsRemaining: 1
        )

        let completion = harness.runBackup()

        guard case .success? = completion else {
            return XCTFail("Expected the destination retry to recover")
        }
        XCTAssertGreaterThanOrEqual(
            harness.runner.destinationInfoCount,
            2
        )
        XCTAssertEqual(harness.runner.startBackupCount, 1)
        XCTAssertEqual(harness.runner.ejectCount, 1)
    }

    func testPersistentDestinationTimeoutExplainsUSBResetAndDoesNotStartBackup() {
        let harness = WorkflowHarness(
            destinationInfoTimeoutsRemaining: 2
        )

        let completion = harness.runBackup()

        guard case .failure(let message, let stage)? = completion else {
            return XCTFail("Expected a safe destination-query failure")
        }
        XCTAssertEqual(stage, .beforeBackup)
        XCTAssertTrue(message.contains("USB data connection or hub resets"))
        XCTAssertTrue(message.contains("did not eject"))
        XCTAssertEqual(harness.runner.destinationInfoCount, 2)
        XCTAssertEqual(harness.runner.startBackupCount, 0)
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testPersistentStatusTimeoutLeavesDiskConnected() {
        let harness = WorkflowHarness(statusTimeoutsRemaining: 2)

        let completion = harness.runBackup()

        guard case .failure(let message, let stage)? = completion else {
            return XCTFail("Expected a safe failure")
        }
        XCTAssertEqual(stage, .beforeBackup)
        XCTAssertTrue(message.contains("macOS stopped responding"))
        XCTAssertEqual(harness.runner.statusCount, 2)
        XCTAssertEqual(harness.runner.startBackupCount, 0)
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testUnexpectedDisconnectReplacesGenericTimeoutMessage() {
        let harness = WorkflowHarness(
            statusTimeoutsRemaining: 2,
            disconnectWhenStatusTimesOut: true
        )

        let completion = harness.runBackup()

        guard case .failure(let message, let stage)? = completion else {
            return XCTFail("Expected a disconnect failure")
        }
        XCTAssertEqual(stage, .beforeBackup)
        XCTAssertTrue(message.contains("macOS lost access"))
        XCTAssertFalse(message.contains("did not respond"))
        XCTAssertEqual(harness.runner.startBackupCount, 0)
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testRefusesRunningBackupToDifferentDestination() {
        let harness = WorkflowHarness(
            existingBackupDestinationID: "OTHER-ID",
            existingBackupPolls: 1
        )

        let completion = harness.runBackup()

        guard case .failure(_, let stage)? = completion else {
            return XCTFail("Expected a safe refusal")
        }
        XCTAssertEqual(stage, .beforeBackup)
        XCTAssertEqual(harness.runner.startBackupCount, 0)
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testRefusesRunningBackupWhenDestinationIsMissing() {
        let harness = WorkflowHarness(
            existingBackupDestinationID: nil,
            existingBackupPolls: 1
        )

        let completion = harness.runBackup()

        guard case .failure(let message, let stage)? = completion else {
            return XCTFail("Expected a conservative refusal")
        }
        XCTAssertEqual(stage, .beforeBackup)
        XCTAssertTrue(message.contains("did not identify its destination"))
        XCTAssertEqual(harness.runner.startBackupCount, 0)
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testRetriesOnceWhenAutomaticBackupWinsStartRace() {
        let harness = WorkflowHarness(
            failFirstStartWithSameDestinationBackup: true
        )

        let completion = harness.runBackup()

        guard case .success? = completion else {
            return XCTFail("Expected retry to complete safely")
        }
        XCTAssertEqual(harness.runner.startBackupCount, 2)
        XCTAssertEqual(harness.runner.ejectCount, 1)
    }

    func testRefusesSameNamedDiskWithChangedIdentity() {
        let harness = WorkflowHarness(reportedDestinationID: "CHANGED-ID")

        let completion = harness.runBackup()

        guard case .failure(let message, let stage)? = completion else {
            return XCTFail("Expected an identity-change failure")
        }
        XCTAssertEqual(stage, .beforeBackup)
        XCTAssertTrue(message.contains("identity has changed"))
        XCTAssertEqual(harness.runner.startBackupCount, 0)
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testCancellationWhileWaitingLeavesDiskUntouched() {
        let harness = WorkflowHarness(initiallyMounted: false)

        harness.controller.startBackup()
        XCTAssertTrue(harness.controller.cancelCurrentOperation())
        let completion = harness.waitForCompletion()

        guard case .cancelled? = completion else {
            return XCTFail("Expected cancellation")
        }
        XCTAssertEqual(harness.runner.startBackupCount, 0)
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testCancellationDuringBackupStopsTimeMachineAndDoesNotEject() {
        let harness = WorkflowHarness(blockStartBackupUntilStopped: true)

        harness.controller.startBackup()
        let startDeadline = Date().addingTimeInterval(1)
        while
            harness.runner.startBackupCount == 0,
            Date() < startDeadline
        {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }

        XCTAssertEqual(harness.runner.startBackupCount, 1)
        XCTAssertTrue(harness.controller.cancelCurrentOperation())
        let completion = harness.waitForCompletion(timeout: 3)

        guard case .cancelled? = completion else {
            return XCTFail("Expected active-backup cancellation")
        }
        XCTAssertEqual(harness.runner.stopBackupCount, 1)
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testDoesNotClaimEjectionWhenMountPathStillExists() {
        let harness = WorkflowHarness(
            reportUnmountedAfterBackup: true,
            originalMountPathExistsAfterBackup: true
        )

        let completion = harness.runBackup()

        guard case .failure(_, let stage)? = completion else {
            return XCTFail("Expected a post-backup mount verification failure")
        }
        XCTAssertEqual(stage, .afterBackup)
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testReportsAlreadyUnmountedOnlyWhenMountPathIsGone() {
        let harness = WorkflowHarness(
            reportUnmountedAfterBackup: true,
            originalMountPathExistsAfterBackup: false
        )

        let completion = harness.runBackup()

        guard case .alreadyUnmounted? = completion else {
            return XCTFail("Expected an already-unmounted success")
        }
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testIdleTimeoutAfterSuccessfulBackupLeavesDiskConnected() {
        let harness = WorkflowHarness(remainRunningAfterBackup: true)

        let completion = harness.runBackup()

        guard case .failure(_, let stage)? = completion else {
            return XCTFail("Expected an idle timeout")
        }
        XCTAssertEqual(stage, .afterBackup)
        XCTAssertEqual(harness.runner.ejectCount, 0)
    }

    func testDestinationProviderParsesOnlyStandardOutput() throws {
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "Destinations": [
                    [
                        "ID": "TARGET-ID",
                        "Name": "Test Backup Disk",
                        "Kind": "Local"
                    ]
                ]
            ],
            format: .xml,
            options: 0
        )
        let runner = StaticResultRunner(
            result: CommandResult(
                exitCode: 0,
                standardOutput: String(decoding: plistData, as: UTF8.self),
                standardError: "tmutil warning"
            )
        )

        let destinations = try TimeMachineDestinationProvider(
            runner: runner,
            tmutilPath: "/test/tmutil"
        ).configuredLocalDestinations()

        XCTAssertEqual(destinations.map(\.id), ["TARGET-ID"])
    }
}

private struct RecordedCommand {
    let arguments: [String]
    let timeout: TimeInterval?
}

private final class TestCommandRunner: CommandRunning {
    let targetID = "TARGET-ID"
    let targetName = "Test Backup Disk"
    let mountPoint = "/Volumes/Test Backup Disk"

    private let lock = NSLock()
    private var existingBackupDestinationID: String?
    private var existingBackupPolls: Int
    private let reportedDestinationID: String
    private let initiallyMounted: Bool
    private let reportUnmountedAfterBackup: Bool
    private let blockStartBackupUntilStopped: Bool
    private let failFirstStartWithSameDestinationBackup: Bool
    private let remainRunningAfterBackup: Bool
    private let disconnectWhenStatusTimesOut: Bool
    private let stopSemaphore = DispatchSemaphore(value: 0)

    private var destinationInfoTimeoutsRemaining: Int
    private var statusTimeoutsRemaining: Int
    private var recordedDestinationInfoCount = 0
    private var recordedStatusCount = 0
    private var disconnected = false
    private var recordedCalls: [RecordedCommand] = []
    private var recordedStartBackupCount = 0
    private var recordedStopBackupCount = 0
    private var recordedEjectCount = 0
    private var hasCompletedBackup = false
    private var ejected = false

    var calls: [RecordedCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    var startBackupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedStartBackupCount
    }

    var stopBackupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedStopBackupCount
    }

    var ejectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedEjectCount
    }

    var statusCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedStatusCount
    }

    var destinationInfoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedDestinationInfoCount
    }

    init(
        existingBackupDestinationID: String?,
        existingBackupPolls: Int,
        reportedDestinationID: String,
        initiallyMounted: Bool,
        reportUnmountedAfterBackup: Bool,
        blockStartBackupUntilStopped: Bool,
        failFirstStartWithSameDestinationBackup: Bool,
        remainRunningAfterBackup: Bool,
        destinationInfoTimeoutsRemaining: Int,
        statusTimeoutsRemaining: Int,
        disconnectWhenStatusTimesOut: Bool
    ) {
        self.existingBackupDestinationID = existingBackupDestinationID
        self.existingBackupPolls = existingBackupPolls
        self.reportedDestinationID = reportedDestinationID
        self.initiallyMounted = initiallyMounted
        self.reportUnmountedAfterBackup = reportUnmountedAfterBackup
        self.blockStartBackupUntilStopped = blockStartBackupUntilStopped
        self.failFirstStartWithSameDestinationBackup =
            failFirstStartWithSameDestinationBackup
        self.remainRunningAfterBackup = remainRunningAfterBackup
        self.destinationInfoTimeoutsRemaining =
            destinationInfoTimeoutsRemaining
        self.statusTimeoutsRemaining = statusTimeoutsRemaining
        self.disconnectWhenStatusTimesOut =
            disconnectWhenStatusTimesOut
    }

    func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) throws -> CommandResult {
        lock.lock()
        recordedCalls.append(
            RecordedCommand(arguments: arguments, timeout: timeout)
        )
        lock.unlock()

        switch arguments.first {
        case "destinationinfo":
            lock.lock()
            recordedDestinationInfoCount += 1
            let shouldTimeOut = destinationInfoTimeoutsRemaining > 0
            if shouldTimeOut {
                destinationInfoTimeoutsRemaining -= 1
            }
            lock.unlock()

            if shouldTimeOut {
                throw CommandRunnerError.timedOut(
                    executable: executable,
                    timeout: timeout ?? 0
                )
            }
            return CommandResult(
                exitCode: 0,
                output: try destinationInfo()
            )
        case "status":
            lock.lock()
            recordedStatusCount += 1
            let shouldTimeOut = statusTimeoutsRemaining > 0
            if shouldTimeOut {
                statusTimeoutsRemaining -= 1
                if disconnectWhenStatusTimesOut {
                    disconnected = true
                }
            }
            lock.unlock()

            if shouldTimeOut {
                throw CommandRunnerError.timedOut(
                    executable: executable,
                    timeout: timeout ?? 0
                )
            }
            return CommandResult(
                exitCode: 0,
                output: statusOutput()
            )
        case "startbackup":
            lock.lock()
            recordedStartBackupCount += 1
            let currentStartCount = recordedStartBackupCount

            if
                failFirstStartWithSameDestinationBackup,
                currentStartCount == 1
            {
                existingBackupDestinationID = targetID
                existingBackupPolls = 1
                lock.unlock()
                return CommandResult(
                    exitCode: 1,
                    output: "Another backup started first"
                )
            }
            lock.unlock()

            if blockStartBackupUntilStopped {
                _ = stopSemaphore.wait(timeout: .now() + 3)
                return CommandResult(
                    exitCode: 1,
                    output: "Backup stopped"
                )
            }

            lock.lock()
            hasCompletedBackup = true
            lock.unlock()
            return CommandResult(exitCode: 0, output: "")
        case "stopbackup":
            lock.lock()
            recordedStopBackupCount += 1
            existingBackupPolls = 0
            lock.unlock()
            stopSemaphore.signal()
            return CommandResult(exitCode: 0, output: "")
        case "eject":
            lock.lock()
            recordedEjectCount += 1
            ejected = true
            lock.unlock()
            return CommandResult(exitCode: 0, output: "Disk ejected")
        default:
            return CommandResult(exitCode: 99, output: "Unexpected command")
        }
    }

    func mountPathExists(
        originalMountPathExistsAfterBackup: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if ejected {
            return false
        }
        if disconnected {
            return false
        }
        if hasCompletedBackup, reportUnmountedAfterBackup {
            return originalMountPathExistsAfterBackup
        }
        return initiallyMounted
    }

    private func statusOutput() -> String {
        lock.lock()
        defer { lock.unlock() }

        if hasCompletedBackup, remainRunningAfterBackup {
            return """
            Backup session status:
            {
                BackupPhase = Thinning;
                DestinationID = "\(targetID)";
                Running = 1;
            }
            """
        }

        guard existingBackupPolls > 0 else {
            return """
            Backup session status:
            {
                Running = 0;
            }
            """
        }

        existingBackupPolls -= 1
        let destinationLine = existingBackupDestinationID.map {
            "DestinationID = \"\($0)\";"
        } ?? ""

        return """
        Backup session status:
        {
            BackupPhase = Copying;
            \(destinationLine)
            Running = 1;
        }
        """
    }

    private func destinationInfo() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        var destination: [String: Any] = [
            "ID": reportedDestinationID,
            "Name": targetName,
            "Kind": "Local"
        ]
        if initiallyMounted,
           !ejected,
           !(hasCompletedBackup && reportUnmountedAfterBackup)
        {
            destination["MountPoint"] = mountPoint
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Destinations": [destination]],
            format: .xml,
            options: 0
        )
        return String(decoding: data, as: UTF8.self)
    }
}

private final class WorkflowHarness {
    let runner: TestCommandRunner
    let controller: BackupController
    private var completion: BackupCompletion?

    init(
        existingBackupDestinationID: String? = nil,
        existingBackupPolls: Int = 0,
        reportedDestinationID: String = "TARGET-ID",
        initiallyMounted: Bool = true,
        reportUnmountedAfterBackup: Bool = false,
        originalMountPathExistsAfterBackup: Bool = false,
        blockStartBackupUntilStopped: Bool = false,
        failFirstStartWithSameDestinationBackup: Bool = false,
        remainRunningAfterBackup: Bool = false,
        destinationInfoTimeoutsRemaining: Int = 0,
        statusTimeoutsRemaining: Int = 0,
        disconnectWhenStatusTimesOut: Bool = false
    ) {
        runner = TestCommandRunner(
            existingBackupDestinationID: existingBackupDestinationID,
            existingBackupPolls: existingBackupPolls,
            reportedDestinationID: reportedDestinationID,
            initiallyMounted: initiallyMounted,
            reportUnmountedAfterBackup: reportUnmountedAfterBackup,
            blockStartBackupUntilStopped: blockStartBackupUntilStopped,
            failFirstStartWithSameDestinationBackup:
                failFirstStartWithSameDestinationBackup,
            remainRunningAfterBackup: remainRunningAfterBackup,
            destinationInfoTimeoutsRemaining:
                destinationInfoTimeoutsRemaining,
            statusTimeoutsRemaining: statusTimeoutsRemaining,
            disconnectWhenStatusTimesOut:
                disconnectWhenStatusTimesOut
        )

        let runner = self.runner
        controller = BackupController(
            runner: runner,
            settings: BackupSettings(
                targetName: runner.targetName,
                targetDestinationID: runner.targetID,
                waitForDiskTimeout: 0.25,
                waitForUnmountTimeout: 0.25,
                waitForIdleTimeout: 0.25,
                quickCommandTimeout: 0.25,
                destinationInfoCommandTimeout: 0.25,
                statusCommandTimeout: 0.25,
                tmutilPath: "/test/tmutil",
                diskutilPath: "/test/diskutil"
            ),
            fileExists: { _ in
                runner.mountPathExists(
                    originalMountPathExistsAfterBackup:
                        originalMountPathExistsAfterBackup
                )
            },
            sleep: { _ in
                Thread.sleep(forTimeInterval: 0.005)
            }
        )
        controller.onCompletion = { [weak self] in
            self?.completion = $0
        }
    }

    func runBackup() -> BackupCompletion? {
        controller.startBackup()
        return waitForCompletion()
    }

    func waitForCompletion(
        timeout: TimeInterval = 2
    ) -> BackupCompletion? {
        let deadline = Date().addingTimeInterval(timeout)
        while completion == nil, Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        return completion
    }
}

private struct StaticResultRunner: CommandRunning {
    let result: CommandResult

    func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) throws -> CommandResult {
        result
    }
}
