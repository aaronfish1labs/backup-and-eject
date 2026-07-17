import Foundation

public struct TimeMachineDestination: Equatable {
    public let id: String
    public let name: String
    public let kind: String?
    public let mountPoint: String?

    public init(
        id: String,
        name: String,
        kind: String?,
        mountPoint: String?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.mountPoint = mountPoint
    }

    public var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum DestinationParserError: LocalizedError {
    case invalidTopLevel
    case missingDestinations

    public var errorDescription: String? {
        switch self {
        case .invalidTopLevel:
            return "Time Machine returned an unreadable destination list."
        case .missingDestinations:
            return "Time Machine did not return any configured destinations."
        }
    }
}

public enum TimeMachineDestinationParser {
    public static func parse(_ data: Data) throws -> [TimeMachineDestination] {
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )

        guard let dictionary = propertyList as? [String: Any] else {
            throw DestinationParserError.invalidTopLevel
        }

        guard let rawDestinations = dictionary["Destinations"] as? [[String: Any]] else {
            throw DestinationParserError.missingDestinations
        }

        return rawDestinations.compactMap { raw in
            guard
                let id = raw["ID"] as? String,
                let name = raw["Name"] as? String
            else {
                return nil
            }

            // A volume name can legally end in a space. Preserve the exact
            // mount path returned by Time Machine so filesystem checks and
            // ejection address the real volume.
            let mountPoint = raw["MountPoint"] as? String

            return TimeMachineDestination(
                id: id,
                name: name,
                kind: raw["Kind"] as? String,
                mountPoint: mountPoint?.isEmpty == true ? nil : mountPoint
            )
        }
    }

    public static func parse(_ string: String) throws -> [TimeMachineDestination] {
        try parse(Data(string.utf8))
    }
}
