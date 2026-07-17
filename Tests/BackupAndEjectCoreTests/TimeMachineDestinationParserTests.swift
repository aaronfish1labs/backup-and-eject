import XCTest
@testable import BackupAndEjectCore

final class TimeMachineDestinationParserTests: XCTestCase {
    func testParsesMountedAndDisconnectedDestinations() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Destinations</key>
            <array>
                <dict>
                    <key>ID</key>
                    <string>EXTERNAL-ID</string>
                    <key>Name</key>
                    <string>Archive Drive </string>
                    <key>Kind</key>
                    <string>Local</string>
                    <key>MountPoint</key>
                    <string>/Volumes/Archive Drive </string>
                </dict>
                <dict>
                    <key>ID</key>
                    <string>DOCK-ID</string>
                    <key>Name</key>
                    <string>Time Machine</string>
                    <key>Kind</key>
                    <string>Local</string>
                    <key>MountPoint</key>
                    <string>/Volumes/Time Machine</string>
                </dict>
            </array>
        </dict>
        </plist>
        """

        let destinations = try TimeMachineDestinationParser.parse(plist)

        XCTAssertEqual(destinations.count, 2)
        XCTAssertEqual(destinations[0].id, "EXTERNAL-ID")
        XCTAssertEqual(destinations[0].normalizedName, "Archive Drive")
        XCTAssertEqual(
            destinations[0].mountPoint,
            "/Volumes/Archive Drive "
        )
        XCTAssertEqual(destinations[1].mountPoint, "/Volumes/Time Machine")
    }

    func testIgnoresIncompleteDestinationEntries() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Destinations</key>
            <array>
                <dict>
                    <key>Name</key>
                    <string>Missing ID</string>
                </dict>
                <dict>
                    <key>ID</key>
                    <string>VALID-ID</string>
                    <key>Name</key>
                    <string>Archive Drive</string>
                </dict>
            </array>
        </dict>
        </plist>
        """

        let destinations = try TimeMachineDestinationParser.parse(plist)

        XCTAssertEqual(
            destinations,
            [
                TimeMachineDestination(
                    id: "VALID-ID",
                    name: "Archive Drive",
                    kind: nil,
                    mountPoint: nil
                )
            ]
        )
    }
}
