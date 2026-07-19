import BackupAndEjectCore
import Foundation

enum DestinationLookupError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let details):
            return "Time Machine’s configured backup disks could not be read. \(details)"
        }
    }
}

struct TimeMachineDestinationProvider {
    private let runner: CommandRunning
    private let tmutilPath: String

    init(
        runner: CommandRunning = SystemCommandRunner(),
        tmutilPath: String = AppConfiguration.tmutilPath
    ) {
        self.runner = runner
        self.tmutilPath = tmutilPath
    }

    func configuredLocalDestinations() throws -> [TimeMachineDestination] {
        let result = try runner.run(
            tmutilPath,
            arguments: ["destinationinfo", "-X"],
            timeout: AppConfiguration.quickCommandTimeout
        )

        guard result.exitCode == 0 else {
            let details = result.output.isEmpty
                ? "Time Machine returned error \(result.exitCode)."
                : result.output
            throw DestinationLookupError.commandFailed(details)
        }

        return try TimeMachineDestinationParser.parse(
            result.standardOutput
        )
            .filter { destination in
                guard let kind = destination.kind else {
                    return true
                }
                return kind.caseInsensitiveCompare("Local") == .orderedSame
            }
            .sorted {
                $0.normalizedName.localizedCaseInsensitiveCompare(
                    $1.normalizedName
                ) == .orderedAscending
            }
    }
}
