import Foundation

struct DestinationSelection: Equatable {
    let id: String
    let name: String
}

final class DestinationPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DestinationSelection? {
        guard
            let id = defaults.string(
                forKey: AppConfiguration.destinationIDDefaultsKey
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
            let name = defaults.string(
                forKey: AppConfiguration.destinationNameDefaultsKey
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty,
            !name.isEmpty
        else {
            return nil
        }

        return DestinationSelection(id: id, name: name)
    }

    func save(_ selection: DestinationSelection) {
        defaults.set(
            selection.id,
            forKey: AppConfiguration.destinationIDDefaultsKey
        )
        defaults.set(
            selection.name,
            forKey: AppConfiguration.destinationNameDefaultsKey
        )
    }
}
