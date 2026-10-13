import XCTest
@testable import BackupAndEject
import BackupAndEjectCore

final class StorageDiskServiceTests: XCTestCase {
    private let volumeID = "9AB0243A-02D6-4BBA-8454-75F55F818A6C"
    private let otherID = "11111111-2222-3333-4444-555555555555"
    private let mountPoint = "/Volumes/Test Storage"

    func testSelectsOnlyExactPathUsingBoundedInfoAndStandardOutput() throws {
        let response = try plist(volume(), warning: "A harmless warning")
        let runner = StorageCommandRunner([.success(response)])

        let selection = try StorageDiskService(runner: runner).selection(atPath: mountPoint)

        XCTAssertEqual(selection, StorageDiskSelection(id: volumeID, name: "Test Storage"))
        XCTAssertEqual(runner.calls, [
            StorageCommandCall(arguments: ["info", "-plist", mountPoint], timeout: 10)
        ])
    }

    func testInvalidPathsAreRefusedWithoutAnyDiskQuery() {
        for path in ["/", "/Volumes", "/Volumes/", "/Volumes/Test Storage/folder",
                     "/Volumes/../System", "/Volumes/..", "/tmp/Storage"] {
            let runner = StorageCommandRunner([])
            XCTAssertThrowsError(try StorageDiskService(runner: runner).selection(atPath: path))
            XCTAssertTrue(runner.calls.isEmpty, path)
        }
    }

    func testRefusesAPathDifferentFromReportedMountRoot() throws {
        let runner = StorageCommandRunner([.success(try plist(volume()))])

        XCTAssertThrowsError(
            try StorageDiskService(runner: runner).selection(atPath: "/Volumes/Other Storage")
        )
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testRefusesMissingMalformedAndUnsafeRequiredProperties() throws {
        let variants: [[String: Any]] = [
            ["VolumeUUID": "not-a-uuid"], ["VolumeName": "  "],
            ["Internal": true], ["Internal": 0], ["Ejectable": false],
            ["Ejectable": "true"], ["Mounted": false], ["Mounted": 1],
            ["MountPoint": ""], ["MountPoint": "/System/Volumes/Data"]
        ]
        for updates in variants {
            var info = volume()
            info.merge(updates) { _, updated in updated }
            let runner = StorageCommandRunner([.success(try plist(info))])
            XCTAssertThrowsError(try StorageDiskService(runner: runner).selection(atPath: mountPoint))
            XCTAssertEqual(runner.calls.count, 1)
        }
        for missingKey in ["VolumeUUID", "VolumeName", "Internal", "Ejectable", "MountPoint"] {
            var info = volume()
            info.removeValue(forKey: missingKey)
            let runner = StorageCommandRunner([.success(try plist(info))])
            XCTAssertThrowsError(try StorageDiskService(runner: runner).selection(atPath: mountPoint))
            XCTAssertEqual(runner.calls.count, 1)
        }
    }

    func testRefusesBackupAndSystemRolesWithoutEjection() throws {
        for key in ["APFSVolumeRole", "APFSVolumeRoles", "Roles"] {
            for role in ["Backup", "System", "Data", "Preboot", "Recovery", "VM"] {
                var info = volume()
                info[key] = [role]
                let runner = StorageCommandRunner([.success(try plist(info))])
                XCTAssertThrowsError(try StorageDiskService(runner: runner).eject(selection()))
                XCTAssertEqual(runner.calls.map(\.arguments.first), ["info"])
            }
        }
        var info = volume()
        info["APFSVolumeRole"] = " backup "
        let runner = StorageCommandRunner([.success(try plist(info))])
        XCTAssertThrowsError(try StorageDiskService(runner: runner).selection(atPath: mountPoint))
    }

    func testRefusesMalformedRoleField() throws {
        var info = volume()
        info["APFSVolumeRole"] = [42]
        let runner = StorageCommandRunner([.success(try plist(info))])

        XCTAssertThrowsError(try StorageDiskService(runner: runner).selection(atPath: mountPoint))
    }

    func testAllowsExplicitNoRole() throws {
        var info = volume()
        info["APFSVolumeRole"] = [] as [String]
        let runner = StorageCommandRunner([.success(try plist(info))])

        XCTAssertEqual(try StorageDiskService(runner: runner).selection(atPath: mountPoint), selection())
    }

    func testRefusesMalformedPlistEvenIfStderrContainsValidInfo() throws {
        let valid = try plist(volume()).standardOutput
        let runner = StorageCommandRunner([.success(CommandResult(
            exitCode: 0, standardOutput: "invalid", standardError: valid
        ))])

        XCTAssertThrowsError(try StorageDiskService(runner: runner).selection(atPath: mountPoint))
    }

    func testRefusesUnavailableSelectionAndDoesNotTreatItAsEjected() {
        let runner = StorageCommandRunner([.success(CommandResult(exitCode: 1, output: "Not found"))])

        XCTAssertThrowsError(try StorageDiskService(runner: runner).eject(selection()))
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testRejectsInvalidSavedUUIDWithoutAnyQuery() {
        let runner = StorageCommandRunner([])

        XCTAssertThrowsError(try StorageDiskService(runner: runner).eject(
            StorageDiskSelection(id: "disk2", name: "Test Storage")
        ))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testRefusesIdentityMismatchBeforeEjecting() throws {
        var info = volume()
        info["VolumeUUID"] = otherID
        let runner = StorageCommandRunner([.success(try plist(info))])

        XCTAssertThrowsError(try StorageDiskService(runner: runner).eject(selection()))
        XCTAssertEqual(runner.calls.map(\.arguments.first), ["info"])
    }

    func testEjectUsesUUIDAfterDiskIdentifierChangesAndVerifiesAbsence() throws {
        var info = volume()
        info["DeviceIdentifier"] = "disk99s7"
        let runner = StorageCommandRunner([
            .success(try plist(info)),
            .success(CommandResult(exitCode: 0, output: "Ejected")),
            .success(CommandResult(exitCode: 1, output: "Not found"))
        ])

        try StorageDiskService(runner: runner).eject(selection())

        XCTAssertEqual(runner.calls, [
            StorageCommandCall(arguments: ["info", "-plist", volumeID], timeout: 10),
            StorageCommandCall(arguments: ["eject", volumeID], timeout: 30),
            StorageCommandCall(arguments: ["info", "-plist", volumeID], timeout: 10)
        ])
    }

    func testAcceptsVerifiedUnmountedVolume() throws {
        var unmounted = volume()
        unmounted.removeValue(forKey: "MountPoint")
        unmounted["Mounted"] = false
        let runner = try ejectRunner(after: plist(unmounted))

        XCTAssertNoThrow(try StorageDiskService(runner: runner).eject(selection()))
    }

    func testAcceptsMacOSUnmountedAPFSResultWithoutMountedFlag() throws {
        // diskutil info -plist reports an empty MountPoint without a Mounted
        // key for an ejected APFS volume that remains visible to diskutil.
        for mountPointValue in [nil, ""] as [String?] {
            var unmounted = volume()
            unmounted.removeValue(forKey: "Mounted")
            unmounted["MountPoint"] = mountPointValue
            let runner = try ejectRunner(after: plist(unmounted))

            XCTAssertNoThrow(try StorageDiskService(runner: runner).eject(selection()))
            XCTAssertEqual(runner.calls.map(\.arguments.first), ["info", "eject", "info"])
        }
    }

    func testRefusesMountedOrAmbiguousPostEjectInformation() throws {
        var unmountedWithPath = volume()
        unmountedWithPath["Mounted"] = false
        var mountedWithoutPath = volume()
        mountedWithoutPath.removeValue(forKey: "MountPoint")
        var missingMountedFlagWithPath = volume()
        missingMountedFlagWithPath.removeValue(forKey: "Mounted")
        var invalidMountedFlag = volume()
        invalidMountedFlag.removeValue(forKey: "MountPoint")
        invalidMountedFlag["Mounted"] = "false"
        var malformedMountPoint = volume()
        malformedMountPoint.removeValue(forKey: "Mounted")
        malformedMountPoint["MountPoint"] = false
        var differentVolume = volume()
        differentVolume["VolumeUUID"] = otherID
        for info in [volume(), unmountedWithPath, mountedWithoutPath,
                     missingMountedFlagWithPath, invalidMountedFlag,
                     malformedMountPoint, differentVolume] {
            let runner = try ejectRunner(after: plist(info))
            XCTAssertThrowsError(try StorageDiskService(runner: runner).eject(selection()))
            XCTAssertEqual(runner.calls.count, 3)
        }
        let malformed = try ejectRunner(after: CommandResult(exitCode: 0, output: "invalid"))
        XCTAssertThrowsError(try StorageDiskService(runner: malformed).eject(selection())) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not confirm ejection"))
            XCTAssertFalse(error.localizedDescription.contains("did not eject"))
        }
    }

    func testIncompletePostEjectMetadataDoesNotProveEjection() throws {
        for missingKey in ["VolumeName", "Internal", "Ejectable"] {
            var unmounted = volume()
            unmounted.removeValue(forKey: "MountPoint")
            unmounted.removeValue(forKey: missingKey)
            unmounted["Mounted"] = false
            let runner = try ejectRunner(after: plist(unmounted))

            XCTAssertThrowsError(try StorageDiskService(runner: runner).eject(selection()))
            XCTAssertEqual(runner.calls.count, 3)
        }
    }

    func testEjectFailureDoesNotForceRetryOrRunPostCheck() throws {
        let runner = StorageCommandRunner([
            .success(try plist(volume())),
            .success(CommandResult(exitCode: 1, output: "Busy"))
        ])

        XCTAssertThrowsError(try StorageDiskService(runner: runner).eject(selection()))
        XCTAssertEqual(runner.calls.map(\.arguments.first), ["info", "eject"])
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("force") })
    }

    func testTimeoutsFailConservativelyAtEachStage() throws {
        let timeout = CommandRunnerError.timedOut(executable: "/usr/sbin/diskutil", timeout: 10)
        let sequences: [[Result<CommandResult, Error>]] = [
            [.failure(timeout)],
            [.success(try plist(volume())), .failure(timeout)],
            [.success(try plist(volume())),
             .success(CommandResult(exitCode: 0, output: "Ejected")), .failure(timeout)]
        ]
        for sequence in sequences {
            let runner = StorageCommandRunner(sequence)
            XCTAssertThrowsError(try StorageDiskService(runner: runner).eject(selection())) { error in
                XCTAssertLessThan(error.localizedDescription.count, 250)
            }
            XCTAssertEqual(runner.calls.count, sequence.count)
        }
    }

    private func selection() -> StorageDiskSelection {
        StorageDiskSelection(id: volumeID, name: "Test Storage")
    }

    private func volume() -> [String: Any] {
        ["VolumeUUID": volumeID, "VolumeName": "Test Storage", "Internal": false,
         "Ejectable": true, "Mounted": true, "MountPoint": mountPoint]
    }

    private func plist(_ value: [String: Any], warning: String = "") throws -> CommandResult {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        return CommandResult(exitCode: 0, standardOutput: String(decoding: data, as: UTF8.self),
                             standardError: warning)
    }

    private func ejectRunner(after response: CommandResult) throws -> StorageCommandRunner {
        StorageCommandRunner([.success(try plist(volume())),
                              .success(CommandResult(exitCode: 0, output: "Ejected")),
                              .success(response)])
    }
}

private struct StorageCommandCall: Equatable {
    let arguments: [String]
    let timeout: TimeInterval?
}

private final class StorageCommandRunner: CommandRunning {
    private var responses: [Result<CommandResult, Error>]
    private(set) var calls: [StorageCommandCall] = []

    init(_ responses: [Result<CommandResult, Error>]) {
        self.responses = responses
    }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval?) throws -> CommandResult {
        XCTAssertEqual(executable, "/usr/sbin/diskutil")
        calls.append(StorageCommandCall(arguments: arguments, timeout: timeout))
        guard !responses.isEmpty else {
            XCTFail("Unexpected command: \(arguments)")
            throw StorageDiskError.unavailable
        }
        return try responses.removeFirst().get()
    }
}
