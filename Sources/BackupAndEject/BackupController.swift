import Foundation
import BackupAndEjectCore

struct BackupSettings {
    let targetName: String
    let targetDestinationID: String
    let waitForDiskTimeout: TimeInterval
    let waitForUnmountTimeout: TimeInterval
    let tmutilPath: String
    let diskutilPath: String
}

enum BackupState {
    case idle(String)
    case waiting(String)
    case checking(String)
    case backingUp(String)
    case ejecting(String)
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .idle(let message),
             .waiting(let message),
             .checking(let message),
             .backingUp(let message),
             .ejecting(let message),
             .success(let message),
             .failure(let message):
            return message
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "externaldrive.fill"
        case .waiting:
            return "externaldrive.badge.questionmark"
        case .checking:
            return "checkmark.shield"
        case .backingUp:
            return "clock.arrow.circlepath"
        case .ejecting:
            return "eject.fill"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    var isBusy: Bool {
        switch self {
        case .waiting, .checking, .backingUp, .ejecting:
            return true
        case .idle, .success, .failure:
            return false
        }
    }
}

enum BackupCompletion {
    case success(Date)
    case ejected(Date)
    case simulation
    case failure(message: String, backupCompleted: Bool)
    case ejectionFailure(message: String)
}

private final class BackupCommandOutcomeBox {
    private let lock = NSLock()
    private var outcome: Result<CommandResult, Error>?

    func store(_ outcome: Result<CommandResult, Error>) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
    }

    func result() throws -> CommandResult {
        lock.lock()
        let outcome = self.outcome
        lock.unlock()

        guard let outcome else {
            throw BackupWorkflowError.commandFailed(
                step: "The Time Machine backup",
                details: "The backup process ended without returning a result."
            )
        }

        return try outcome.get()
    }
}

private enum BackupWorkflowError: LocalizedError {
    case destinationLookupFailed(String)
    case targetNotConfigured(String)
    case targetIdentityChanged(String)
    case targetNotMounted(String)
    case timedOutWaitingForDisk(name: String, timeout: TimeInterval)
    case anotherBackupRunning
    case commandFailed(step: String, details: String)
    case backupStillRunning(String)
    case ejectionFailed(name: String, details: String)
    case diskStillMounted(String)

    var errorDescription: String? {
        switch self {
        case .destinationLookupFailed(let details):
            return "The app could not read Time Machine’s configured disks. \(details)"
        case .targetNotConfigured(let name):
            return "\(name) is no longer configured as a Time Machine destination. The disk was not touched."
        case .targetIdentityChanged(let name):
            return "A disk called \(name) is configured, but its identity has changed. For safety, the app refused to use it."
        case .targetNotMounted(let name):
            return "\(name) is not mounted. It may already be safely ejected."
        case .timedOutWaitingForDisk(let name, let timeout):
            return "\(name) did not become available within \(Self.durationDescription(timeout)). Check its power and cable, then try again."
        case .anotherBackupRunning:
            return "Time Machine is already running another backup. Nothing was ejected; wait for it to finish and try again."
        case .commandFailed(let step, let details):
            return "\(step) failed. \(details)"
        case .backupStillRunning(let name):
            return "Time Machine still reports that the backup is running, so \(name) was deliberately left connected."
        case .ejectionFailed(let name, let details):
            return "macOS could not safely eject \(name). Leave it powered on and try ejecting it from Finder. \(details)"
        case .diskStillMounted(let name):
            return "macOS reported an eject, but \(name) still appears mounted. Leave it powered on and eject it from Finder."
        }
    }

    private static func durationDescription(
        _ timeout: TimeInterval
    ) -> String {
        let roundedSeconds = max(Int(timeout.rounded()), 1)
        if roundedSeconds.isMultiple(of: 60) {
            let minutes = roundedSeconds / 60
            return minutes == 1 ? "one minute" : "\(minutes) minutes"
        }
        return roundedSeconds == 1
            ? "one second"
            : "\(roundedSeconds) seconds"
    }
}

final class BackupController {
    var onStateChange: ((BackupState) -> Void)?
    var onProgressChange: ((TimeMachineBackupStatus?) -> Void)?
    var onCompletion: ((BackupCompletion) -> Void)?

    private(set) var isBusy = false

    private let runner: CommandRunning
    private let settings: BackupSettings
    private let fileExists: (String) -> Bool
    private let sleep: (TimeInterval) -> Void
    private let workQueue = DispatchQueue(
        label: "com.aaronfish1labs.backupandeject.backup",
        qos: .userInitiated
    )
    private let backupCommandQueue = DispatchQueue(
        label: "com.aaronfish1labs.backupandeject.backup-command",
        qos: .userInitiated
    )

    private var activityToken: NSObjectProtocol?

    init(
        runner: CommandRunning = SystemCommandRunner(),
        settings: BackupSettings,
        fileExists: @escaping (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        sleep: @escaping (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        }
    ) {
        self.runner = runner
        self.settings = settings
        self.fileExists = fileExists
        self.sleep = sleep
    }

    func startBackup() {
        precondition(Thread.isMainThread)
        guard !isBusy else { return }

        isBusy = true
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled
            ],
            reason: "Completing and safely ejecting a Time Machine backup"
        )
        emitProgress(nil)
        emit(.waiting("Waiting for \(settings.targetName)…"))

        workQueue.async { [weak self] in
            self?.performBackup()
        }
    }

    func startEjectOnly() {
        precondition(Thread.isMainThread)
        guard !isBusy else { return }

        isBusy = true
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled
            ],
            reason: "Safely ejecting the external Time Machine disk"
        )
        emitProgress(nil)
        emit(
            .checking(
                "Checking \(settings.targetName) before ejection…"
            )
        )

        workQueue.async { [weak self] in
            self?.performEjectOnly()
        }
    }

    func startSimulation() {
        precondition(Thread.isMainThread)
        guard !isBusy else { return }

        isBusy = true
        emitProgress(nil)
        emit(
            .waiting(
                "Safety test: finding \(settings.targetName)…"
            )
        )

        workQueue.async { [weak self] in
            guard let self else { return }

            self.sleep(0.7)
            self.emit(.checking("Safety test: checking the destination…"))
            self.sleep(0.7)
            self.emit(.backingUp("Safety test: simulating a backup…"))
            for fraction in [0.12, 0.38, 0.67, 1.0] {
                self.emitProgress(
                    TimeMachineBackupStatus(
                        isRunning: true,
                        phase: "Copying",
                        fractionCompleted: fraction,
                        copiedBytes: Int64(fraction * 8_000_000_000),
                        totalBytes: 8_000_000_000,
                        copiedFiles: Int64(fraction * 4_000),
                        totalFiles: 4_000
                    )
                )
                self.sleep(0.35)
            }
            self.emit(.ejecting("Safety test: simulating a safe eject…"))
            self.sleep(0.8)

            self.finish(
                state: .success("Safety test passed — no disk was touched"),
                completion: .simulation
            )
        }
    }

    private func performBackup() {
        var backupCompleted = false

        do {
            let mountedDestination = try waitForMountedTarget()

            emit(
                .checking(
                    "Checking Time Machine and \(settings.targetName)…"
                )
            )
            try ensureTimeMachineIsIdle()

            emit(.backingUp("Preparing the Time Machine backup…"))
            let backupResult = try runBackupWithMonitoring(
                destinationID: mountedDestination.id
            )

            guard backupResult.exitCode == 0 else {
                throw BackupWorkflowError.commandFailed(
                    step: "The Time Machine backup",
                    details: usefulDetails(
                        backupResult.output,
                        fallback: "Time Machine returned error \(backupResult.exitCode)."
                    )
                )
            }

            backupCompleted = true
            emitProgress(
                TimeMachineBackupStatus(
                    isRunning: false,
                    phase: "Finished",
                    fractionCompleted: 1,
                    copiedBytes: nil,
                    totalBytes: nil,
                    copiedFiles: nil,
                    totalFiles: nil
                )
            )
            try waitUntilTimeMachineIsIdle()

            emit(
                .ejecting(
                    "Backup complete — safely ejecting \(settings.targetName)…"
                )
            )
            sleep(2)

            guard let latestMountPoint = try targetDestination().mountPoint else {
                finishSuccessfulBackup()
                return
            }

            try ejectTarget(at: latestMountPoint)
            finishSuccessfulBackup()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription

            finish(
                state: .failure(message),
                completion: .failure(
                    message: message,
                    backupCompleted: backupCompleted
                )
            )
        }
    }

    private func performEjectOnly() {
        do {
            let destination = try targetDestination()

            guard
                let mountPoint = destination.mountPoint,
                fileExists(mountPoint)
            else {
                throw BackupWorkflowError.targetNotMounted(
                    settings.targetName
                )
            }

            try ensureTimeMachineIsIdle()
            emit(
                .ejecting(
                    "Safely ejecting \(settings.targetName)…"
                )
            )
            try ejectTarget(at: mountPoint)
            finishSuccessfulEjection()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription

            finish(
                state: .failure(message),
                completion: .ejectionFailure(message: message)
            )
        }
    }

    private func finishSuccessfulBackup() {
        let completionDate = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        finish(
            state: .success(
                "\(settings.targetName) safely ejected at \(formatter.string(from: completionDate))"
            ),
            completion: .success(completionDate)
        )
    }

    private func finishSuccessfulEjection() {
        let completionDate = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        finish(
            state: .success(
                "\(settings.targetName) safely ejected at \(formatter.string(from: completionDate))"
            ),
            completion: .ejected(completionDate)
        )
    }

    private func ejectTarget(at mountPoint: String) throws {
        let ejectResult = try runner.run(
            settings.diskutilPath,
            arguments: ["eject", mountPoint]
        )

        guard ejectResult.exitCode == 0 else {
            throw BackupWorkflowError.ejectionFailed(
                name: settings.targetName,
                details: usefulDetails(
                    ejectResult.output,
                    fallback: "macOS returned error \(ejectResult.exitCode)."
                )
            )
        }

        try waitUntilTargetIsUnmounted()
    }

    private func waitForMountedTarget() throws -> TimeMachineDestination {
        let deadline = Date().addingTimeInterval(
            settings.waitForDiskTimeout
        )

        while Date() < deadline {
            let destination = try targetDestination()

            if
                let mountPoint = destination.mountPoint,
                fileExists(mountPoint)
            {
                return destination
            }

            sleep(2)
        }

        throw BackupWorkflowError.timedOutWaitingForDisk(
            name: settings.targetName,
            timeout: settings.waitForDiskTimeout
        )
    }

    private func runBackupWithMonitoring(
        destinationID: String
    ) throws -> CommandResult {
        let group = DispatchGroup()
        let outcomeBox = BackupCommandOutcomeBox()
        let runner = self.runner
        let settings = self.settings

        group.enter()
        backupCommandQueue.async {
            let outcome = Result {
                try runner.run(
                    settings.tmutilPath,
                    arguments: [
                        "startbackup",
                        "--auto",
                        "--block",
                        "--destination",
                        destinationID
                    ]
                )
            }
            outcomeBox.store(outcome)
            group.leave()
        }

        while group.wait(timeout: .now() + 1) == .timedOut {
            reportCurrentBackupProgress()
        }

        return try outcomeBox.result()
    }

    private func reportCurrentBackupProgress() {
        guard
            let result = try? runner.run(
                settings.tmutilPath,
                arguments: ["status"]
            ),
            result.exitCode == 0
        else {
            return
        }

        let status = TimeMachineStatusParser.parse(result.output)
        guard status.isRunning else { return }

        emitProgress(status)
        emit(.backingUp(stageMessage(for: status.phase)))
    }

    private func stageMessage(for phase: String?) -> String {
        let normalizedPhase = phase?.lowercased() ?? ""

        if normalizedPhase.contains("copy") {
            return "Backing up to \(settings.targetName)…"
        }

        if
            normalizedPhase.contains("finish")
                || normalizedPhase.contains("thin")
                || normalizedPhase.contains("clean")
        {
            return "Finishing the Time Machine backup…"
        }

        return "Preparing the Time Machine backup…"
    }

    private func targetDestination() throws -> TimeMachineDestination {
        let destinations = try configuredDestinations()

        if let destination = destinations.first(where: {
            $0.id == settings.targetDestinationID
        }) {
            return destination
        }

        if destinations.contains(where: {
            $0.normalizedName.caseInsensitiveCompare(
                settings.targetName
            ) == .orderedSame
        }) {
            throw BackupWorkflowError.targetIdentityChanged(
                settings.targetName
            )
        }

        throw BackupWorkflowError.targetNotConfigured(
            settings.targetName
        )
    }

    private func configuredDestinations() throws -> [TimeMachineDestination] {
        let result = try runner.run(
            settings.tmutilPath,
            arguments: ["destinationinfo", "-X"]
        )

        guard result.exitCode == 0 else {
            throw BackupWorkflowError.destinationLookupFailed(
                usefulDetails(
                    result.output,
                    fallback: "Time Machine returned error \(result.exitCode)."
                )
            )
        }

        do {
            return try TimeMachineDestinationParser.parse(result.output)
        } catch {
            throw BackupWorkflowError.destinationLookupFailed(
                error.localizedDescription
            )
        }
    }

    private func ensureTimeMachineIsIdle() throws {
        if try isTimeMachineRunning() {
            throw BackupWorkflowError.anotherBackupRunning
        }
    }

    private func waitUntilTimeMachineIsIdle() throws {
        let deadline = Date().addingTimeInterval(30)

        while Date() < deadline {
            if try !isTimeMachineRunning() {
                return
            }
            sleep(2)
        }

        throw BackupWorkflowError.backupStillRunning(
            settings.targetName
        )
    }

    private func isTimeMachineRunning() throws -> Bool {
        let result = try runner.run(
            settings.tmutilPath,
            arguments: ["status"]
        )

        guard result.exitCode == 0 else {
            throw BackupWorkflowError.commandFailed(
                step: "The Time Machine status check",
                details: usefulDetails(
                    result.output,
                    fallback: "Time Machine returned error \(result.exitCode)."
                )
            )
        }

        return TimeMachineStatusParser.isBackupRunning(result.output)
    }

    private func waitUntilTargetIsUnmounted() throws {
        let deadline = Date().addingTimeInterval(
            settings.waitForUnmountTimeout
        )

        while Date() < deadline {
            let destinations = try configuredDestinations()

            if let target = destinations.first(where: {
                $0.id == settings.targetDestinationID
            }) {
                if target.mountPoint == nil {
                    return
                }
            } else {
                return
            }

            sleep(1)
        }

        throw BackupWorkflowError.diskStillMounted(
            settings.targetName
        )
    }

    private func usefulDetails(_ output: String, fallback: String) -> String {
        let cleaned = output
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return fallback }
        return String(cleaned.prefix(500))
    }

    private func emit(_ state: BackupState) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    private func emitProgress(_ progress: TimeMachineBackupStatus?) {
        DispatchQueue.main.async { [weak self] in
            self?.onProgressChange?(progress)
        }
    }

    private func finish(
        state: BackupState,
        completion: BackupCompletion
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let activityToken = self.activityToken {
                ProcessInfo.processInfo.endActivity(activityToken)
                self.activityToken = nil
            }

            self.isBusy = false
            self.onStateChange?(state)
            self.onCompletion?(completion)
        }
    }
}
