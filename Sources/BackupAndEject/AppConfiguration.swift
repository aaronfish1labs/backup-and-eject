import Foundation

enum AppConfiguration {
    static let appName = "Backup & Eject"
    static let bundleIdentifier = "com.aaronfish1labs.backupandeject"
    static let waitForDiskTimeout: TimeInterval = 120
    static let waitForUnmountTimeout: TimeInterval = 20

    static let tmutilPath = "/usr/bin/tmutil"
    static let diskutilPath = "/usr/sbin/diskutil"

    static let safetyCheckDefaultsKey = "WarnWhenAIAgentsAreRunning"
    static let coverageNoticeAcknowledgedDefaultsKey =
        "HasAcknowledgedTimeMachineCoverageNoticeV1"
    static let destinationNameDefaultsKey = "SelectedDestinationName"
    static let destinationIDDefaultsKey = "SelectedDestinationID"
    static let lastSuccessfulBackupDefaultsKeyPrefix = "LastSuccessfulBackup"

    static func backupSettings(
        for selection: DestinationSelection
    ) -> BackupSettings {
        BackupSettings(
            targetName: selection.name,
            targetDestinationID: selection.id,
            waitForDiskTimeout: waitForDiskTimeout,
            waitForUnmountTimeout: waitForUnmountTimeout,
            tmutilPath: tmutilPath,
            diskutilPath: diskutilPath
        )
    }

    static func lastSuccessfulBackupKey(
        for destinationID: String
    ) -> String {
        "\(lastSuccessfulBackupDefaultsKeyPrefix).\(destinationID)"
    }
}
