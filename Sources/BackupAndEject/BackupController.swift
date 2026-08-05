import Foundation
import BackupAndEjectCore

struct BackupSettings {
    let targetName: String
    let targetDestinationID: String
    let waitForDiskTimeout: TimeInterval
    let waitForUnmountTimeout: TimeInterval
    let waitForIdleTimeout: TimeInterval
    let quickCommandTimeout: TimeInterval
    let destinationInfoCommandTimeout: TimeInterval
    let statusCommandTimeout: TimeInterval
    let tmutilPath: String
    let diskutilPath: String
}

enum BackupState {
    case idle(String)
    case waiting(String)
    case checking(String)
    case backingUp(String)
    case ejecting(String)
    case canceling(String)
    case cancelled(String)
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .idle(let message),
             .waiting(let message),
             .checking(let message),
             .backingUp(let message),
             .ejecting(let message),
             .canceling(let message),
             .cancelled(let message),
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
        case .canceling:
            return "stop.circle"
        case .cancelled:
            return "xmark.circle"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    var isBusy: Bool {
        switch self {
        case .waiting, .checking, .backingUp, .ejecting, .canceling:
            return true
        case .idle, .cancelled, .success, .failure:
            return false
        }
    }

    var isCancellable: Bool {
        switch self {
        case .waiting, .checking, .backingUp:
            return true
        case .idle, .ejecting, .canceling, .cancelled, .success, .failure:
            return false
        }
    }
}

enum BackupFailureStage: Equatable {
    case beforeBackup
    case duringBackup
    case afterBackup
}

enum BackupCompletion {
    case success(Date)
    case alreadyUnmounted(Date)
    case ejected(Date)
    case cancelled(String)
    case simulation
    case failure(message: String, stage: BackupFailureStage)
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

private final class CancellationGate {
    private enum Phase {
        case idle
        case cancellable
        case backingUp
        case ejecting
    }

    private let lock = NSLock()
    private var phase = Phase.idle
    private var cancellationRequested = false
    private var stopCommandIssued = false

    func begin() {
        lock.lock()
        phase = .cancellable
        cancellationRequested = false
        stopCommandIssued = false
        lock.unlock()
    }

    func beginBackup() {
        lock.lock()
        phase = .backingUp
        lock.unlock()
    }

    func returnToCancellablePhase() {
        lock.lock()
        if phase == .backingUp {
            phase = .cancellable
        }
        lock.unlock()
    }

    func beginEjectIfNotCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !cancellationRequested else {
            return false
        }

        phase = .ejecting
        return true
    }

    func finish() {
        lock.lock()
        phase = .idle
        cancellationRequested = false
        stopCommandIssued = false
        lock.unlock()
    }

    func requestCancellation() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard phase == .cancellable || phase == .backingUp else {
            return false
        }

        cancellationRequested = true
        return true
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    var canCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase == .cancellable || phase == .backingUp
    }

    func shouldIssueStopCommand() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard
            phase == .backingUp,
            cancellationRequested,
            !stopCommandIssued
        else {
            return false
        }

        stopCommandIssued = true
        return true
    }
}

private enum BackupWorkflowError: LocalizedError {
    case cancelled
    case destinationLookupFailed(String)
    case targetNotConfigured(String)
    case targetIdentityChanged(String)
    case targetNotMounted(String)
    case timedOutWaitingForDisk(name: String, timeout: TimeInterval)
    case selectedDestinationBackupRunning(String)
    case anotherBackupRunning(destinationKnown: Bool)
    case commandFailed(step: String, details: String)
    case destinationQueryUnresponsive(String)
    case timeMachineUnresponsive(String)
    case diskAccessLost(String)
    case backupStillRunning(String)
    case ejectionFailed(name: String, details: String)
    case diskStillMounted(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The operation was cancelled. No disk was ejected."
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
        case .selectedDestinationBackupRunning(let name):
            return "Time Machine is currently backing up to \(name). Nothing was ejected; wait for it to finish and try again."
        case .anotherBackupRunning(let destinationKnown):
            if destinationKnown {
                return "Time Machine is backing up to a different disk. Nothing was ejected; wait for it to finish and try again."
            }
            return "Time Machine is already running a backup, but macOS did not identify its destination. Nothing was ejected; wait for it to finish and try again."
        case .commandFailed(let step, let details):
            return "\(step) failed. \(details)"
        case .destinationQueryUnresponsive(let name):
            return "macOS stopped responding while locating \(name). The app did not eject it. A disk can remain powered when its USB data connection or hub resets; wait for it to reappear before trying again."
        case .timeMachineUnresponsive(let name):
            return "macOS stopped responding while checking Time Machine for \(name). The disk was deliberately left connected and was not ejected. Keep it connected, then try the backup again."
        case .diskAccessLost(let name):
            return "macOS lost access to \(name) before the backup and safe ejection finished. Nothing was ejected. The disk may still have power if its USB data connection or hub reset."
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
    private let cancellationGate = CancellationGate()

    private var activityToken: NSObjectProtocol?

    var canCancel: Bool {
        cancellationGate.canCancel
    }

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
        cancellationGate.begin()
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
        cancellationGate.begin()
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
        cancellationGate.begin()
        emitProgress(nil)
        emit(
            .waiting(
                "Safety test: finding \(settings.targetName)…"
            )
        )

        workQueue.async { [weak self] in
            guard let self else { return }

            self.sleep(0.7)
            guard !self.finishIfCancelled() else { return }
            self.emit(.checking("Safety test: checking the destination…"))
            self.sleep(0.7)
            guard !self.finishIfCancelled() else { return }
            self.emit(.backingUp("Safety test: simulating a backup…"))
            for fraction in [0.12, 0.38, 0.67, 1.0] {
                guard !self.finishIfCancelled() else { return }
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
            guard self.cancellationGate.beginEjectIfNotCancelled() else {
                self.finishCancelled()
                return
            }
            self.emit(.ejecting("Safety test: simulating a safe eject…"))
            self.sleep(0.8)

            self.finish(
                state: .success("Safety test passed — no disk was touched"),
                completion: .simulation
            )
        }
    }

    @discardableResult
    func cancelCurrentOperation() -> Bool {
        precondition(Thread.isMainThread)
        guard isBusy, cancellationGate.requestCancellation() else {
            return false
        }

        emit(
            .canceling(
                "Cancelling — \(settings.targetName) will not be ejected…"
            )
        )
        return true
    }

    private func performBackup() {
        var failureStage = BackupFailureStage.beforeBackup
        var originalMountPoint: String?

        do {
            let mountedDestination = try waitForMountedTarget()
            originalMountPoint = mountedDestination.mountPoint

            emit(
                .checking(
                    "Checking Time Machine and \(settings.targetName)…"
                )
            )
            try waitForSelectedDestinationToBecomeIdle()
            try checkCancellation()

            emit(.backingUp("Preparing the Time Machine backup…"))
            cancellationGate.beginBackup()
            failureStage = .duringBackup
            let backupResult = try runVerifiedBackup(
                destinationID: mountedDestination.id
            )
            try checkCancellation()

            guard backupResult.exitCode == 0 else {
                throw BackupWorkflowError.commandFailed(
                    step: "The Time Machine backup",
                    details: usefulDetails(
                        backupResult.output,
                        fallback: "Time Machine returned error \(backupResult.exitCode)."
                    )
                )
            }

            failureStage = .afterBackup
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
            guard cancellationGate.beginEjectIfNotCancelled() else {
                throw BackupWorkflowError.cancelled
            }
            emit(
                .ejecting(
                    "Backup complete — safely ejecting \(settings.targetName)…"
                )
            )
            sleep(2)

            let latestDestination = try targetDestination()
            guard
                let latestMountPoint = latestDestination.mountPoint,
                fileExists(latestMountPoint)
            else {
                if
                    let originalMountPoint,
                    fileExists(originalMountPoint)
                {
                    throw BackupWorkflowError.diskStillMounted(
                        settings.targetName
                    )
                }

                finishSuccessfulBackup(alreadyUnmounted: true)
                return
            }

            try ejectTarget(at: latestMountPoint)
            finishSuccessfulBackup(alreadyUnmounted: false)
        } catch BackupWorkflowError.cancelled {
            finishCancelled()
        } catch {
            let message: String
            if
                failureStage != .afterBackup,
                let originalMountPoint,
                !fileExists(originalMountPoint)
            {
                message = BackupWorkflowError.diskAccessLost(
                    settings.targetName
                ).errorDescription ?? error.localizedDescription
            } else {
                message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }

            finish(
                state: .failure(message),
                completion: .failure(
                    message: message,
                    stage: failureStage
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
            guard cancellationGate.beginEjectIfNotCancelled() else {
                throw BackupWorkflowError.cancelled
            }
            emit(
                .ejecting(
                    "Safely ejecting \(settings.targetName)…"
                )
            )
            try ejectTarget(at: mountPoint)
            finishSuccessfulEjection()
        } catch BackupWorkflowError.cancelled {
            finishCancelled()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription

            finish(
                state: .failure(message),
                completion: .ejectionFailure(message: message)
            )
        }
    }

    private func finishSuccessfulBackup(alreadyUnmounted: Bool) {
        let completionDate = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        if alreadyUnmounted {
            finish(
                state: .success(
                    "Backup complete — \(settings.targetName) is already unmounted"
                ),
                completion: .alreadyUnmounted(completionDate)
            )
            return
        }

        finish(
            state: .success(
                "\(settings.targetName) safely ejected at \(formatter.string(from: completionDate))"
            ),
            completion: .success(completionDate)
        )
    }

    private func finishCancelled() {
        let message = "Cancelled — no disk was ejected"
        finish(
            state: .cancelled(message),
            completion: .cancelled(message)
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
            arguments: ["eject", mountPoint],
            timeout: settings.quickCommandTimeout
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
            try checkCancellation()
            let destination = try targetDestination()

            if
                let mountPoint = destination.mountPoint,
                fileExists(mountPoint)
            {
                return destination
            }

            sleep(5)
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
            if cancellationGate.shouldIssueStopCommand() {
                _ = try? runner.run(
                    settings.tmutilPath,
                    arguments: ["stopbackup"],
                    timeout: settings.quickCommandTimeout
                )
            }
            reportCurrentBackupProgress()
        }

        try checkCancellation()
        return try outcomeBox.result()
    }

    private func runVerifiedBackup(
        destinationID: String
    ) throws -> CommandResult {
        let firstResult = try runBackupWithMonitoring(
            destinationID: destinationID
        )
        guard firstResult.exitCode != 0 else {
            return firstResult
        }

        let status = try currentTimeMachineStatus()
        guard
            status.isRunning,
            status.destinationID == settings.targetDestinationID
        else {
            return firstResult
        }

        cancellationGate.returnToCancellablePhase()
        try waitForSelectedDestinationToBecomeIdle(
            startingWith: status
        )
        try checkCancellation()

        emit(.backingUp("Starting the verified Time Machine backup…"))
        cancellationGate.beginBackup()
        return try runBackupWithMonitoring(
            destinationID: destinationID
        )
    }

    private func reportCurrentBackupProgress() {
        guard
            let status = try? currentTimeMachineStatus(
                retryOnTimeout: false
            ),
            status.isRunning
        else {
            return
        }

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
        var finalResult: CommandResult?

        for attempt in 0..<2 {
            do {
                finalResult = try runner.run(
                    settings.tmutilPath,
                    arguments: ["destinationinfo", "-X"],
                    timeout: settings.destinationInfoCommandTimeout
                )
                break
            } catch let error as CommandRunnerError {
                guard case .timedOut = error else {
                    throw error
                }

                guard attempt == 0 else {
                    throw BackupWorkflowError.destinationQueryUnresponsive(
                        settings.targetName
                    )
                }

                emit(
                    .waiting(
                        "macOS briefly lost contact with \(settings.targetName) — retrying safely…"
                    )
                )
                try checkCancellation()
                sleep(1)
            }
        }

        guard let result = finalResult else {
            throw BackupWorkflowError.destinationQueryUnresponsive(
                settings.targetName
            )
        }

        guard result.exitCode == 0 else {
            throw BackupWorkflowError.destinationLookupFailed(
                usefulDetails(
                    result.output,
                    fallback: "Time Machine returned error \(result.exitCode)."
                )
            )
        }

        do {
            return try TimeMachineDestinationParser.parse(
                result.standardOutput
            )
        } catch {
            throw BackupWorkflowError.destinationLookupFailed(
                error.localizedDescription
            )
        }
    }

    private func ensureTimeMachineIsIdle() throws {
        let status = try currentTimeMachineStatus()
        if status.isRunning {
            if status.destinationID == settings.targetDestinationID {
                throw BackupWorkflowError.selectedDestinationBackupRunning(
                    settings.targetName
                )
            }
            throw BackupWorkflowError.anotherBackupRunning(
                destinationKnown: status.destinationID != nil
            )
        }
    }

    private func waitForSelectedDestinationToBecomeIdle(
        startingWith initialStatus: TimeMachineBackupStatus? = nil
    ) throws {
        var status = try initialStatus ?? currentTimeMachineStatus()
        guard status.isRunning else { return }

        guard
            let runningDestinationID = status.destinationID
        else {
            throw BackupWorkflowError.anotherBackupRunning(
                destinationKnown: false
            )
        }

        guard runningDestinationID == settings.targetDestinationID else {
            throw BackupWorkflowError.anotherBackupRunning(
                destinationKnown: true
            )
        }

        emit(
            .backingUp(
                "Waiting for the existing backup to \(settings.targetName)…"
            )
        )

        while status.isRunning {
            try checkCancellation()

            guard status.destinationID == settings.targetDestinationID else {
                throw BackupWorkflowError.anotherBackupRunning(
                    destinationKnown: status.destinationID != nil
                )
            }

            emitProgress(status)
            sleep(2)
            status = try currentTimeMachineStatus()
        }

        emit(
            .checking(
                "Existing backup finished — starting a verified final backup…"
            )
        )
    }

    private func waitUntilTimeMachineIsIdle() throws {
        let deadline = Date().addingTimeInterval(
            settings.waitForIdleTimeout
        )

        while Date() < deadline {
            try checkCancellation()
            if try !currentTimeMachineStatus().isRunning {
                return
            }
            sleep(2)
        }

        throw BackupWorkflowError.backupStillRunning(
            settings.targetName
        )
    }

    private func currentTimeMachineStatus(
        retryOnTimeout: Bool = true
    ) throws -> TimeMachineBackupStatus {
        let attemptCount = retryOnTimeout ? 2 : 1

        for attempt in 0..<attemptCount {
            do {
                let result = try runner.run(
                    settings.tmutilPath,
                    arguments: ["status"],
                    timeout: settings.statusCommandTimeout
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

                return TimeMachineStatusParser.parse(
                    result.standardOutput
                )
            } catch let error as CommandRunnerError {
                guard case .timedOut = error else {
                    throw error
                }

                guard attempt + 1 < attemptCount else {
                    throw BackupWorkflowError.timeMachineUnresponsive(
                        settings.targetName
                    )
                }

                emit(
                    .checking(
                        "Time Machine is slow to respond — retrying safely…"
                    )
                )
                try checkCancellation()
                sleep(1)
            }
        }

        throw BackupWorkflowError.timeMachineUnresponsive(
            settings.targetName
        )
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

    private func checkCancellation() throws {
        if cancellationGate.isCancellationRequested {
            throw BackupWorkflowError.cancelled
        }
    }

    private func finishIfCancelled() -> Bool {
        guard cancellationGate.isCancellationRequested else {
            return false
        }
        finishCancelled()
        return true
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

            self.cancellationGate.finish()
            self.isBusy = false
            self.onStateChange?(state)
            self.onCompletion?(completion)
        }
    }
}
