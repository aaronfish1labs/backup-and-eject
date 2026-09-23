import Foundation
import BackupAndEjectCore

private struct RecordedCommand {
    let executable: String
    let arguments: [String]
}

private enum WorkflowTestScenario {
    case success
    case backupFailure
    case ejectFailure
    case progressReporting
}

private final class FakeCommandRunner: CommandRunning {
    private let scenario: WorkflowTestScenario
    private let settings: BackupSettings
    private let mountPoint: String
    private let lock = NSLock()

    private var mounted = true
    private var backupInProgress = false
    private var calls: [RecordedCommand] = []

    init(
        scenario: WorkflowTestScenario,
        settings: BackupSettings,
        mountPoint: String
    ) {
        self.scenario = scenario
        self.settings = settings
        self.mountPoint = mountPoint
    }

    var recordedCalls: [RecordedCommand] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) throws -> CommandResult {
        lock.lock()
        calls.append(
            RecordedCommand(
                executable: executable,
                arguments: arguments
            )
        )
        lock.unlock()

        if executable == settings.tmutilPath {
            switch arguments.first {
            case "destinationinfo":
                return CommandResult(
                    exitCode: 0,
                    output: try destinationInfoOutput()
                )
            case "status":
                if isBackupInProgress {
                    return CommandResult(
                        exitCode: 0,
                        output: """
                        Backup session status:
                        {
                            BackupPhase = Copying;
                            FractionOfProgressBar = "0.5";
                            Progress = {
                                bytes = 4000000000;
                                totalBytes = 8000000000;
                            };
                            DestinationID = "\(settings.targetDestinationID)";
                            Running = 1;
                        }
                        """
                    )
                }

                return CommandResult(
                    exitCode: 0,
                    output: """
                    Backup session status:
                    {
                        Running = 0;
                    }
                    """
                )
            case "startbackup":
                if scenario == .backupFailure {
                    return CommandResult(
                        exitCode: 9,
                        output: "Simulated backup failure"
                    )
                }

                if scenario == .progressReporting {
                    setBackupInProgress(true)
                    Thread.sleep(forTimeInterval: 1.25)
                    setBackupInProgress(false)
                }

                return CommandResult(exitCode: 0, output: "")
            default:
                return CommandResult(
                    exitCode: 98,
                    output: "Unexpected tmutil command"
                )
            }
        }

        if executable == settings.diskutilPath {
            if scenario == .ejectFailure {
                return CommandResult(
                    exitCode: 16,
                    output: "Simulated safe-eject failure"
                )
            }

            setMounted(false)
            return CommandResult(
                exitCode: 0,
                output: "Disk ejected"
            )
        }

        return CommandResult(
            exitCode: 99,
            output: "Unexpected executable"
        )
    }

    private func destinationInfoOutput() throws -> String {
        var destination: [String: Any] = [
            "ID": settings.targetDestinationID,
            "Name": settings.targetName,
            "Kind": "Local"
        ]

        if isMounted {
            destination["MountPoint"] = mountPoint
        }

        return try xmlString(
            [
                "Destinations": [destination]
            ]
        )
    }

    private var isMounted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mounted
    }

    private func setMounted(_ mounted: Bool) {
        lock.lock()
        self.mounted = mounted
        lock.unlock()
    }

    private var isBackupInProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return backupInProgress
    }

    private func setBackupInProgress(_ isInProgress: Bool) {
        lock.lock()
        backupInProgress = isInProgress
        lock.unlock()
    }

    private func xmlString(_ propertyList: Any) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        return String(decoding: data, as: UTF8.self)
    }
}

func runWorkflowSelfTest() -> Int32 {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "BackupAndEjectWorkflowSelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
    let mount = root.appendingPathComponent(
        "Test Backup Disk",
        isDirectory: true
    )

    do {
        try FileManager.default.createDirectory(
            at: mount,
            withIntermediateDirectories: true
        )
    } catch {
        fputs(
            "WORKFLOW SELF-TEST FAILED: could not create test folders\n",
            stderr
        )
        return 1
    }

    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let settings = BackupSettings(
        targetName: "Test Backup Disk",
        targetDestinationID: "TEST-DESTINATION-ID",
        waitForDiskTimeout: 1,
        waitForUnmountTimeout: 1,
        waitForIdleTimeout: 1,
        quickCommandTimeout: 1,
        destinationInfoCommandTimeout: 1,
        statusCommandTimeout: 1,
        tmutilPath: "/test/tmutil",
        diskutilPath: "/test/diskutil"
    )

    guard
        verifySuccessfulWorkflow(settings: settings, mountPoint: mount.path),
        verifyBackupFailureDoesNotEject(
            settings: settings,
            mountPoint: mount.path
        ),
        verifyEjectFailureIsReported(
            settings: settings,
            mountPoint: mount.path
        ),
        verifyProgressIsReported(
            settings: settings,
            mountPoint: mount.path
        ),
        verifyEjectOnlyWorkflow(
            settings: settings,
            mountPoint: mount.path
        ),
        verifyEjectOnlyFailureIsReported(
            settings: settings,
            mountPoint: mount.path
        )
    else {
        return 1
    }

    print(
        "WORKFLOW SELF-TEST PASSED: exact-destination backup, eject-only, live progress, failure handling, and non-force ejection are correct"
    )
    return 0
}

private func verifySuccessfulWorkflow(
    settings: BackupSettings,
    mountPoint: String
) -> Bool {
    let result = runScenario(
        .success,
        settings: settings,
        mountPoint: mountPoint
    )

    guard case .success? = result.completion else {
        return workflowFailure("successful workflow did not complete")
    }

    let startArguments = [
        "startbackup",
        "--auto",
        "--block",
        "--destination",
        settings.targetDestinationID
    ]
    let ejectArguments = ["eject", mountPoint]

    guard
        let startIndex = result.calls.firstIndex(where: {
            $0.executable == settings.tmutilPath
                && $0.arguments == startArguments
        }),
        let ejectIndex = result.calls.firstIndex(where: {
            $0.executable == settings.diskutilPath
                && $0.arguments == ejectArguments
        }),
        startIndex < ejectIndex
    else {
        return workflowFailure(
            "the exact destination was not backed up before eject"
        )
    }

    guard !result.calls.contains(where: {
        $0.arguments.contains("force")
    }) else {
        return workflowFailure("a force-eject argument was used")
    }

    return true
}

private func verifyBackupFailureDoesNotEject(
    settings: BackupSettings,
    mountPoint: String
) -> Bool {
    let result = runScenario(
        .backupFailure,
        settings: settings,
        mountPoint: mountPoint
    )

    guard case .failure(_, let stage)? = result.completion,
          stage == .duringBackup else {
        return workflowFailure(
            "a failed backup was not reported as incomplete"
        )
    }

    guard !result.calls.contains(where: {
        $0.executable == settings.diskutilPath
    }) else {
        return workflowFailure("the disk was ejected after a failed backup")
    }

    return true
}

private func verifyEjectFailureIsReported(
    settings: BackupSettings,
    mountPoint: String
) -> Bool {
    let result = runScenario(
        .ejectFailure,
        settings: settings,
        mountPoint: mountPoint
    )

    guard case .failure(_, let stage)? = result.completion,
          stage == .afterBackup else {
        return workflowFailure(
            "an eject failure did not preserve the successful backup result"
        )
    }

    guard !result.calls.contains(where: {
        $0.arguments.contains("force")
    }) else {
        return workflowFailure(
            "the eject failure attempted a force eject"
        )
    }

    return true
}

private func verifyProgressIsReported(
    settings: BackupSettings,
    mountPoint: String
) -> Bool {
    let runner = FakeCommandRunner(
        scenario: .progressReporting,
        settings: settings,
        mountPoint: mountPoint
    )
    let controller = BackupController(
        runner: runner,
        settings: settings,
        fileExists: { _ in true },
        sleep: { _ in }
    )

    var completion: BackupCompletion?
    var reportedHalfwayProgress = false

    controller.onProgressChange = { progress in
        if progress?.fractionCompleted == 0.5 {
            reportedHalfwayProgress = true
        }
    }
    controller.onCompletion = {
        completion = $0
    }
    controller.startBackup()

    let deadline = Date().addingTimeInterval(4)
    while completion == nil, Date() < deadline {
        _ = RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.01)
        )
    }

    guard case .success? = completion else {
        return workflowFailure(
            "progress-reporting workflow did not complete"
        )
    }

    guard reportedHalfwayProgress else {
        return workflowFailure(
            "no progress update was reported while the backup was running"
        )
    }

    return true
}

private func verifyEjectOnlyWorkflow(
    settings: BackupSettings,
    mountPoint: String
) -> Bool {
    let result = runEjectScenario(
        .success,
        settings: settings,
        mountPoint: mountPoint
    )

    guard case .ejected? = result.completion else {
        return workflowFailure(
            "the eject-only workflow did not report a safe ejection"
        )
    }

    let ejectArguments = ["eject", mountPoint]

    guard result.calls.contains(where: {
        $0.executable == settings.diskutilPath
            && $0.arguments == ejectArguments
    }) else {
        return workflowFailure(
            "the eject-only workflow did not target the exact mounted path"
        )
    }

    guard !result.calls.contains(where: {
        $0.arguments.first == "startbackup"
            || $0.arguments.contains("force")
    }) else {
        return workflowFailure(
            "the eject-only workflow started a backup or used force"
        )
    }

    return true
}

private func verifyEjectOnlyFailureIsReported(
    settings: BackupSettings,
    mountPoint: String
) -> Bool {
    let result = runEjectScenario(
        .ejectFailure,
        settings: settings,
        mountPoint: mountPoint
    )

    guard case .ejectionFailure? = result.completion else {
        return workflowFailure(
            "an eject-only failure was not reported correctly"
        )
    }

    guard !result.calls.contains(where: {
        $0.arguments.contains("force")
    }) else {
        return workflowFailure(
            "the eject-only failure attempted a force eject"
        )
    }

    return true
}

private func runScenario(
    _ scenario: WorkflowTestScenario,
    settings: BackupSettings,
    mountPoint: String
) -> (
    completion: BackupCompletion?,
    calls: [RecordedCommand]
) {
    let runner = FakeCommandRunner(
        scenario: scenario,
        settings: settings,
        mountPoint: mountPoint
    )
    let controller = BackupController(
        runner: runner,
        settings: settings,
        fileExists: { _ in true },
        sleep: { _ in }
    )

    var completion: BackupCompletion?
    controller.onCompletion = {
        completion = $0
    }
    controller.startBackup()

    let deadline = Date().addingTimeInterval(3)
    while completion == nil, Date() < deadline {
        _ = RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.01)
        )
    }

    return (completion, runner.recordedCalls)
}

private func runEjectScenario(
    _ scenario: WorkflowTestScenario,
    settings: BackupSettings,
    mountPoint: String
) -> (
    completion: BackupCompletion?,
    calls: [RecordedCommand]
) {
    let runner = FakeCommandRunner(
        scenario: scenario,
        settings: settings,
        mountPoint: mountPoint
    )
    let controller = BackupController(
        runner: runner,
        settings: settings,
        fileExists: { _ in true },
        sleep: { _ in }
    )

    var completion: BackupCompletion?
    controller.onCompletion = {
        completion = $0
    }
    controller.startEjectOnly()

    let deadline = Date().addingTimeInterval(3)
    while completion == nil, Date() < deadline {
        _ = RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.01)
        )
    }

    return (completion, runner.recordedCalls)
}

private func workflowFailure(_ message: String) -> Bool {
    fputs("WORKFLOW SELF-TEST FAILED: \(message)\n", stderr)
    return false
}
