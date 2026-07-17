import Foundation

public struct CommandResult: Equatable {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public protocol CommandRunning {
    func run(_ executable: String, arguments: [String]) throws -> CommandResult
}

public enum CommandRunnerError: LocalizedError {
    case executableNotFound(String)
    case launchFailed(executable: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "The required system tool was not found at \(path)."
        case .launchFailed(let executable, let underlying):
            return "Could not run \(executable): \(underlying.localizedDescription)"
        }
    }
}

public final class SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandRunnerError.executableNotFound(executable)
        }

        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(
                executable: executable,
                underlying: error
            )
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CommandResult(
            exitCode: process.terminationStatus,
            output: output
        )
    }
}
