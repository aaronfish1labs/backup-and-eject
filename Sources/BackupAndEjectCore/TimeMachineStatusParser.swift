import Foundation

public struct TimeMachineBackupStatus: Equatable {
    public let isRunning: Bool
    public let phase: String?
    public let fractionCompleted: Double?
    public let copiedBytes: Int64?
    public let totalBytes: Int64?
    public let copiedFiles: Int64?
    public let totalFiles: Int64?
    public let destinationID: String?

    public init(
        isRunning: Bool,
        phase: String?,
        fractionCompleted: Double?,
        copiedBytes: Int64?,
        totalBytes: Int64?,
        copiedFiles: Int64?,
        totalFiles: Int64?,
        destinationID: String? = nil
    ) {
        self.isRunning = isRunning
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.copiedBytes = copiedBytes
        self.totalBytes = totalBytes
        self.copiedFiles = copiedFiles
        self.totalFiles = totalFiles
        self.destinationID = destinationID
    }
}

public enum TimeMachineStatusParser {
    public static func isBackupRunning(_ output: String) -> Bool {
        parse(output).isRunning
    }

    public static func parse(_ output: String) -> TimeMachineBackupStatus {
        let copiedBytes = integerValue(for: "bytes", in: output)
        let totalBytes = integerValue(for: "totalBytes", in: output)
        let copiedFiles = integerValue(for: "files", in: output)
        let totalFiles = integerValue(for: "totalFiles", in: output)

        var fractionCompleted = doubleValue(
            for: "FractionOfProgressBar",
            in: output
        )

        if
            fractionCompleted == nil,
            let copiedBytes,
            let totalBytes,
            totalBytes > 0
        {
            fractionCompleted = Double(copiedBytes) / Double(totalBytes)
        }

        if let fractionCompleted {
            guard fractionCompleted.isFinite else {
                return status(
                    output: output,
                    fractionCompleted: nil,
                    copiedBytes: copiedBytes,
                    totalBytes: totalBytes,
                    copiedFiles: copiedFiles,
                    totalFiles: totalFiles
                )
            }
        }

        return status(
            output: output,
            fractionCompleted: fractionCompleted.map {
                min(max($0, 0), 1)
            },
            copiedBytes: copiedBytes,
            totalBytes: totalBytes,
            copiedFiles: copiedFiles,
            totalFiles: totalFiles
        )
    }

    private static func status(
        output: String,
        fractionCompleted: Double?,
        copiedBytes: Int64?,
        totalBytes: Int64?,
        copiedFiles: Int64?,
        totalFiles: Int64?
    ) -> TimeMachineBackupStatus {
        TimeMachineBackupStatus(
            isRunning: integerValue(for: "Running", in: output) == 1,
            phase: stringValue(for: "BackupPhase", in: output),
            fractionCompleted: fractionCompleted,
            copiedBytes: copiedBytes,
            totalBytes: totalBytes,
            copiedFiles: copiedFiles,
            totalFiles: totalFiles,
            destinationID: stringValue(
                for: "DestinationID",
                in: output
            )
        )
    }

    private static func stringValue(
        for key: String,
        in output: String
    ) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"(?m)^\s*\#(escapedKey)\s*=\s*(?:"([^"]*)"|([^;\r\n]+))\s*;"#

        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
            )
        else {
            return nil
        }

        for rangeIndex in 1..<match.numberOfRanges {
            let range = match.range(at: rangeIndex)
            guard
                range.location != NSNotFound,
                let swiftRange = Range(range, in: output)
            else {
                continue
            }

            let value = output[swiftRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private static func integerValue(
        for key: String,
        in output: String
    ) -> Int64? {
        guard let value = stringValue(for: key, in: output) else {
            return nil
        }
        return Int64(value)
    }

    private static func doubleValue(
        for key: String,
        in output: String
    ) -> Double? {
        guard let value = stringValue(for: key, in: output) else {
            return nil
        }
        return Double(value)
    }
}
