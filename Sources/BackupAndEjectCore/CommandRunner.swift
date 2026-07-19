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

    func storeStandardOutput(_ data: Data) {
        lock.lock()
        standardOutput = data
        lock.unlock()
    }

    func storeStandardError(_ data: Data) {
        lock.lock()
        standardError = data
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

public final class SystemCommandRunner: CommandRunning {
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
        let outputBox = CommandOutputBox()
        let readGroup = DispatchGroup()
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

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(
                executable: executable,
                underlying: error
            )
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.storeStandardOutput(
                standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
            )
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.storeStandardError(
                standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
            )
            readGroup.leave()
        }

        if let timeout, let completion {
            if completion.wait(
                timeout: .now() + max(timeout, 0.01)
            ) == .timedOut {
                process.terminate()

                if completion.wait(timeout: .now() + 2) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }

                readGroup.wait()
                throw CommandRunnerError.timedOut(
                    executable: executable,
                    timeout: timeout
                )
            }
        } else {
            process.waitUntilExit()
        }

        readGroup.wait()
        let output = outputBox.strings()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: output.standardOutput,
            standardError: output.standardError
        )
    }
}
