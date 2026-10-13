import Foundation
import CoreFoundation
import BackupAndEjectCore

struct StorageDiskSelection: Equatable {
    let id: String
    let name: String
}

enum StorageDiskError: LocalizedError {
    case invalidPath
    case invalidIdentity
    case unavailable
    case malformedInformation
    case unsafeVolume
    case notMounted
    case identityChanged
    case queryTimedOut
    case ejectFailed
    case ejectTimedOut
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Select the root of an external storage volume mounted in /Volumes."
        case .invalidIdentity:
            return "The saved storage volume identity is invalid. Select the storage volume again."
        case .unavailable:
            return "macOS could not read the selected storage volume. Reconnect it and select it again."
        case .malformedInformation:
            return "macOS returned incomplete or invalid storage volume information. The app did not eject it."
        case .unsafeVolume:
            return "The selected volume must be external and ejectable, and cannot have a backup or system role."
        case .notMounted:
            return "The selected storage volume is not mounted at its volume root. Reconnect it and select it again."
        case .identityChanged:
            return "The storage volume identity has changed. The app did not eject it. Select the volume again."
        case .queryTimedOut:
            return "macOS did not respond to the storage volume check within 10 seconds. Ejection could not be confirmed."
        case .ejectFailed:
            return "macOS could not eject the storage volume. Close files on it and try again; the app did not force ejection."
        case .ejectTimedOut:
            return "macOS did not finish ejecting the storage volume within 30 seconds. Leave it connected until ejection is confirmed."
        case .verificationFailed:
            return "The storage volume still appears mounted, or macOS could not confirm ejection. Leave it connected and try again."
        }
    }
}

/// Queries and ejects only the explicitly selected storage volume.
final class StorageDiskService {
    private let runner: CommandRunning
    private let diskutilPath = "/usr/sbin/diskutil"

    init(runner: CommandRunning = SystemCommandRunner()) {
        self.runner = runner
    }

    func selection(atPath path: String) throws -> StorageDiskSelection {
        guard Self.isVolumeRoot(path) else {
            throw StorageDiskError.invalidPath
        }
        let result = try info(path)
        guard result.exitCode == 0 else {
            throw StorageDiskError.unavailable
        }
        let volume = try parse(result)
        try validateMountedStorage(volume)
        guard volume["MountPoint"] as? String == path else {
            throw StorageDiskError.notMounted
        }
        return try selection(from: volume)
    }

    func eject(_ selection: StorageDiskSelection) throws {
        guard let expectedID = UUID(uuidString: selection.id) else {
            throw StorageDiskError.invalidIdentity
        }
        let before = try info(expectedID.uuidString)
        guard before.exitCode == 0 else {
            throw StorageDiskError.unavailable
        }
        let volume = try parse(before)
        let current = try self.selection(from: volume)
        guard UUID(uuidString: current.id) == expectedID else {
            throw StorageDiskError.identityChanged
        }
        try validateMountedStorage(volume)

        let result: CommandResult
        do {
            result = try runner.run(
                diskutilPath,
                arguments: ["eject", expectedID.uuidString],
                timeout: 30
            )
        } catch let error as CommandRunnerError {
            if case .timedOut = error {
                throw StorageDiskError.ejectTimedOut
            }
            throw StorageDiskError.ejectFailed
        } catch {
            throw StorageDiskError.ejectFailed
        }
        guard result.exitCode == 0 else {
            throw StorageDiskError.ejectFailed
        }

        // Only after successful ejection may a failed targeted lookup mean absent.
        do {
            let after = try info(expectedID.uuidString)
            guard after.exitCode == 0 else { return }
            let remaining = try parse(after)
            let remainingSelection = try self.selection(from: remaining)
            try validateExternalStorage(remaining)
            guard UUID(uuidString: remainingSelection.id) == expectedID,
                  // diskutil's APFS plist can omit Mounted after ejection.
                  // A present flag must still explicitly say false.
                  remaining["Mounted"] == nil || Self.boolean(remaining["Mounted"]) == false,
                  remaining["MountPoint"] == nil
                    || (remaining["MountPoint"] as? String) == ""
            else {
                throw StorageDiskError.verificationFailed
            }
        } catch {
            throw StorageDiskError.verificationFailed
        }
    }

    private func info(_ target: String) throws -> CommandResult {
        do {
            return try runner.run(
                diskutilPath,
                arguments: ["info", "-plist", target],
                timeout: 10
            )
        } catch let error as CommandRunnerError {
            if case .timedOut = error {
                throw StorageDiskError.queryTimedOut
            }
            throw StorageDiskError.unavailable
        } catch {
            throw StorageDiskError.unavailable
        }
    }

    private func parse(_ result: CommandResult) throws -> [String: Any] {
        guard let data = result.standardOutput.data(using: .utf8),
              let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let volume = value as? [String: Any]
        else {
            throw StorageDiskError.malformedInformation
        }
        return volume
    }

    private func selection(from volume: [String: Any]) throws -> StorageDiskSelection {
        guard let rawID = volume["VolumeUUID"] as? String,
              let id = UUID(uuidString: rawID),
              let name = volume["VolumeName"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw StorageDiskError.malformedInformation
        }
        return StorageDiskSelection(id: id.uuidString, name: name)
    }

    private func validateMountedStorage(_ volume: [String: Any]) throws {
        try validateExternalStorage(volume)
        guard let mountPoint = volume["MountPoint"] as? String,
              Self.isVolumeRoot(mountPoint)
        else {
            throw StorageDiskError.notMounted
        }
        if let mounted = volume["Mounted"], Self.boolean(mounted) != true {
            throw StorageDiskError.notMounted
        }
    }

    private func validateExternalStorage(_ volume: [String: Any]) throws {
        guard Self.boolean(volume["Internal"]) == false,
              Self.boolean(volume["Ejectable"]) == true
        else {
            throw StorageDiskError.unsafeVolume
        }
        let forbiddenRoles: Set<String> = [
            "backup", "system", "data", "preboot", "recovery", "vm"
        ]
        for key in ["APFSVolumeRole", "APFSVolumeRoles", "Roles"] {
            guard let value = volume[key] else { continue }
            let roles: [String]
            if let values = value as? [String] {
                roles = values
            } else if let role = value as? String {
                roles = [role]
            } else {
                throw StorageDiskError.malformedInformation
            }
            guard roles.allSatisfy({
                !forbiddenRoles.contains(
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            }) else {
                throw StorageDiskError.unsafeVolume
            }
        }
    }

    private static func isVolumeRoot(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 3
            && components[0].isEmpty
            && components[1] == "Volumes"
            && !components[2].isEmpty
            && components[2] != "."
            && components[2] != ".."
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }
}
