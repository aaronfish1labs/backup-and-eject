import AppKit
import XCTest
@testable import BackupAndEject

final class BackupStatusPanelControllerTests: XCTestCase {
    @MainActor
    func testStatusPanelUsesNormalWindowLevel() {
        let controller = BackupStatusPanelController()
        guard let panel = controller.window as? NSPanel else {
            return XCTFail("Expected the status window to be an NSPanel")
        }

        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    @MainActor
    func testRepeatedShowDoesNotRepositionVisiblePanel() {
        let controller = BackupStatusPanelController()
        guard let panel = controller.window as? NSPanel else {
            return XCTFail("Expected the status window to be an NSPanel")
        }
        defer { controller.hide() }

        controller.show()
        let movedOrigin = NSPoint(x: 40, y: 40)
        panel.setFrameOrigin(movedOrigin)

        controller.show()

        XCTAssertEqual(panel.frame.origin, movedOrigin)
    }
}
