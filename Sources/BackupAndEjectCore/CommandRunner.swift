import Foundation
import Darwin

public struct CommandResult: Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, output: String) {
        self.init(
            exitCode: exitCode,
            standardOutput: output,
            standardError: ""
        )
    }

    public init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var output: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public protocol CommandRunning {
    func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) throws -> CommandResult
}

public extension CommandRunning {
    func run(
        _ executable: String,
        arguments: [String]
    ) throws -> CommandResult {
        try run(executable, arguments: arguments, timeout: nil)
    }
}

public enum CommandRunnerError: LocalizedError {
    case executableNotFound(String)
    case launchFailed(executable: String, underlying: Error)
    case timedOut(executable: String, timeout: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "The required system tool was not found at \(path)."
        case .launchFailed(let executable, let underlying):
            return "Could not run \(executable): \(underlying.localizedDescription)"
        case .timedOut(let executable, let timeout):
            return "\(executable) did not respond within \(Int(timeout.rounded())) seconds."
        }
    }
}

private final class CommandOutputBox {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    func appendStandardOutput(_ data: Data) {
        lock.lock()
        standardOutput.append(data)
        lock.unlock()
    }

    func appendStandardError(_ data: Data) {
        lock.lock()
        standardError.append(data)
        lock.unlock()
    }

    func strings() -> (standardOutput: String, standardError: String) {
        lock.lock()
        let standardOutput = self.standardOutput
        let standardError = self.standardError
        lock.unlock()

        return (
            Self.clean(standardOutput),
            Self.clean(standardError)
        )
    }

    private static func clean(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class CommandPipeReader {
    private let fileHandle: FileHandle
    private let receive: (Data) -> Void
    private let didFinish: () -> Void
    private let lock = NSLock()
    private var finished = false

    init(
        fileHandle: FileHandle,
        receive: @escaping (Data) -> Void,
        didFinish: @escaping () -> Void
    ) {
        self.fileHandle = fileHandle
        self.receive = receive
        self.didFinish = didFinish
    }

    func start() {
        fileHandle.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
    }

    func stop() {
        finishIfNeeded()
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            finishIfNeeded()
            return
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        receive(data)
        lock.unlock()
    }

    private func finishIfNeeded() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        fileHandle.readabilityHandler = nil
        didFinish()
    }
}

final class CommandOutputCollector {
    private let outputBox = CommandOutputBox()
    private let completion = DispatchGroup()
    private let standardOutputReader: CommandPipeReader
    private let standardErrorReader: CommandPipeReader

    init(
        standardOutputPipe: Pipe,
        standardErrorPipe: Pipe
    ) {
        completion.enter()
        completion.enter()

        let completion = self.completion
        let outputBox = self.outputBox
        standardOutputReader = CommandPipeReader(
            fileHandle: standardOutputPipe.fileHandleForReading,
            receive: { outputBox.appendStandardOutput($0) },
            didFinish: { completion.leave() }
        )
        standardErrorReader = CommandPipeReader(
            fileHandle: standardErrorPipe.fileHandleForReading,
            receive: { outputBox.appendStandardError($0) },
            didFinish: { completion.leave() }
        )
    }

    func start() {
        standardOutputReader.start()
        standardErrorReader.start()
    }

    func finish(
        timeout: TimeInterval
    ) -> (standardOutput: String, standardError: String) {
        if completion.wait(
            timeout: .now() + max(timeout, 0.01)
        ) == .timedOut {
            stop()
        }
        return outputBox.strings()
    }

    func stop() {
        standardOutputReader.stop()
        standardErrorReader.stop()
    }
}

public final class SystemCommandRunner: CommandRunning {
    private static let terminationGracePeriod: TimeInterval = 2
    private static let forcedTerminationGracePeriod: TimeInterval = 0.25
    private static let outputDrainTimeout: TimeInterval = 1

    public init() {}

    public func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandRunnerError.executableNotFound(executable)
        }

        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let outputCollector = CommandOutputCollector(
            standardOutputPipe: standardOutputPipe,
            standardErrorPipe: standardErrorPipe
        )
        let completion = timeout.map { _ in DispatchSemaphore(value: 0) }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        if let completion {
            process.terminationHandler = { _ in
                completion.signal()
            }
        }
        outputCollector.start()

        do {
            try process.run()
        } catch {
            outputCollector.stop()
            throw CommandRunnerError.launchFailed(
                executable: executable,
                underlying: error
            )
        }

        if let timeout, let completion {
            if completion.wait(
                timeout: .now() + max(timeout, 0.01)
            ) == .timedOut {
                process.terminate()

                if completion.wait(
                    timeout: .now() + Self.terminationGracePeriod
                ) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = completion.wait(
                        timeout: .now()
                            + Self.forcedTerminationGracePeriod
                    )
                }

                outputCollector.stop()
                throw CommandRunnerError.timedOut(
                    executable: executable,
                    timeout: timeout
                )
            }
        } else {
            process.waitUntilExit()
        }

        let output = outputCollector.finish(
            timeout: Self.outputDrainTimeout
        )

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: output.standardOutput,
            standardError: output.standardError
        )
    }
}
