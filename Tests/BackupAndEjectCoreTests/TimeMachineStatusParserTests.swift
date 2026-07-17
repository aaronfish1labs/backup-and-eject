import XCTest
@testable import BackupAndEjectCore

final class TimeMachineStatusParserTests: XCTestCase {
    func testDetectsRunningBackup() {
        let output = """
        Backup session status:
        {
            BackupPhase = Copying;
            FractionOfProgressBar = "0.375";
            Progress = {
                bytes = 3000000000;
                files = 1200;
                totalBytes = 8000000000;
                totalFiles = 4000;
            };
            ClientID = "com.apple.backupd";
            Running = 1;
        }
        """

        XCTAssertTrue(TimeMachineStatusParser.isBackupRunning(output))

        let status = TimeMachineStatusParser.parse(output)
        XCTAssertEqual(status.phase, "Copying")
        XCTAssertEqual(status.fractionCompleted, 0.375)
        XCTAssertEqual(status.copiedBytes, 3_000_000_000)
        XCTAssertEqual(status.totalBytes, 8_000_000_000)
        XCTAssertEqual(status.copiedFiles, 1_200)
        XCTAssertEqual(status.totalFiles, 4_000)
    }

    func testDetectsIdleBackup() {
        let output = """
        Backup session status:
        {
            ClientID = "com.apple.backupd";
            Running = 0;
        }
        """

        XCTAssertFalse(TimeMachineStatusParser.isBackupRunning(output))
    }

    func testCalculatesProgressFromBytesWhenFractionIsMissing() {
        let output = """
        Backup session status:
        {
            BackupPhase = Copying;
            Progress = {
                bytes = 250;
                totalBytes = 1000;
            };
            Running = 1;
        }
        """

        let status = TimeMachineStatusParser.parse(output)

        XCTAssertEqual(status.fractionCompleted, 0.25)
    }

    func testPreparationCanBeIndeterminate() {
        let output = """
        Backup session status:
        {
            BackupPhase = FindingChanges;
            Progress = {
                files = 17425;
            };
            Running = 1;
        }
        """

        let status = TimeMachineStatusParser.parse(output)

        XCTAssertEqual(status.phase, "FindingChanges")
        XCTAssertNil(status.fractionCompleted)
        XCTAssertEqual(status.copiedFiles, 17_425)
    }
}
