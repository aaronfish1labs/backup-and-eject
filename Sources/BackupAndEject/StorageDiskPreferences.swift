import Foundation

final class StorageDiskPreferences {
    static let idKey = "SelectedStorageVolumeUUID"
    static let nameKey = "SelectedStorageVolumeName"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> StorageDiskSelection? {
        guard let id = defaults.string(forKey: Self.idKey), UUID(uuidString: id) != nil,
              let name = defaults.string(forKey: Self.nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return StorageDiskSelection(id: id, name: name)
    }

    func save(_ selection: StorageDiskSelection) {
        defaults.set(selection.id, forKey: Self.idKey)
        defaults.set(selection.name, forKey: Self.nameKey)
    }
}
