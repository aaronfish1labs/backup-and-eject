import AppKit
import BackupAndEjectCore
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject {
    private var controller: BackupController?
    private let statusPanelController = BackupStatusPanelController()
    private let defaults = UserDefaults.standard
    private lazy var destinationPreferences = DestinationPreferences(
        defaults: defaults
    )
    private let destinationProvider = TimeMachineDestinationProvider()

    private var selectedDestination: DestinationSelection?
    private var currentState = BackupState.idle(
        "Choose a backup disk"
    )
    private var currentProgress: TimeMachineBackupStatus?
    private var pendingTermination = false

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var backupMenuItem: NSMenuItem!
    private var ejectMenuItem: NSMenuItem!
    private var cancelMenuItem: NSMenuItem!
    private var testMenuItem: NSMenuItem!
    private var showStatusMenuItem: NSMenuItem!
    private var safetyMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!
    private var chooseDiskMenuItem: NSMenuItem!
    private var quitMenuItem: NSMenuItem!

    override init() {
        super.init()
        defaults.register(defaults: [
            AppConfiguration.safetyCheckDefaultsKey: true
        ])
    }
}

extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination(
            "\(AppConfiguration.appName) keeps its menu-bar control available"
        )
        UNUserNotificationCenter.current().delegate = self

        configureMenuBar()

        if let selection = destinationPreferences.load() {
            install(selection)
            DispatchQueue.main.async { [weak self] in
                _ = self?.presentTimeMachineCoverageNoticeIfNeeded()
            }
        } else {
            applyUnconfiguredState()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.presentTimeMachineCoverageNoticeIfNeeded() {
                    self.loadDestinationsAndPresentPicker()
                }
            }
        }

        if CommandLine.arguments.contains("--run-safety-test") {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.4
            ) { [weak self] in
                self?.controller?.startSimulation()
            }
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard controller?.isBusy == true else {
            return .terminateNow
        }

        guard
            currentState.isCancellable,
            controller?.canCancel == true
        else {
            showAlert(
                title: "Safe ejection is in progress",
                message: "\(AppConfiguration.appName) must stay open until macOS finishes the current ejection."
            )
            return .terminateCancel
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cancel the current operation and quit?"
        alert.informativeText = """
        Backup & Eject will ask Time Machine to stop if necessary. The disk will remain connected and will not be ejected.
        """
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Cancel Operation and Quit")

        guard alert.runModal() == .alertSecondButtonReturn else {
            return .terminateCancel
        }

        guard controller?.cancelCurrentOperation() == true else {
            return .terminateCancel
        }

        pendingTermination = true
        return .terminateLater
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginMenuItem()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

private extension AppDelegate {
    func configureController(_ controller: BackupController) {
        controller.onStateChange = { [weak self] state in
            self?.apply(state)
        }

        controller.onProgressChange = { [weak self] progress in
            guard let self else { return }
            self.currentProgress = progress
            self.statusPanelController.update(
                state: self.currentState,
                progress: progress
            )
        }

        controller.onCompletion = { [weak self] completion in
            self?.handle(completion)
        }
    }

    func install(_ selection: DestinationSelection) {
        let controller = BackupController(
            settings: AppConfiguration.backupSettings(for: selection)
        )
        configureController(controller)

        selectedDestination = selection
        self.controller = controller
        currentProgress = nil
        statusPanelController.setTargetName(selection.name)
        updateDestinationMenuTitles()
        apply(.idle(initialStatusMessage(for: selection)))
    }

    func applyUnconfiguredState() {
        selectedDestination = nil
        controller = nil
        currentProgress = nil
        statusPanelController.setTargetName(nil)
        updateDestinationMenuTitles()
        apply(.idle("Choose a backup disk"))
    }

    func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusMenuItem = NSMenuItem(
            title: currentState.message,
            action: nil,
            keyEquivalent: ""
        )
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        backupMenuItem = NSMenuItem(
            title: "Choose a Backup Disk First",
            action: #selector(startBackup),
            keyEquivalent: "b"
        )
        backupMenuItem.target = self
        menu.addItem(backupMenuItem)

        ejectMenuItem = NSMenuItem(
            title: "Eject Backup Disk",
            action: #selector(ejectDisk),
            keyEquivalent: "e"
        )
        ejectMenuItem.target = self
        ejectMenuItem.image = NSImage(
            systemSymbolName: "eject",
            accessibilityDescription: "Eject backup disk"
        )
        menu.addItem(ejectMenuItem)

        cancelMenuItem = NSMenuItem(
            title: "Cancel Current Operation",
            action: #selector(cancelCurrentOperation),
            keyEquivalent: "."
        )
        cancelMenuItem.target = self
        cancelMenuItem.isHidden = true
        cancelMenuItem.isEnabled = false
        menu.addItem(cancelMenuItem)

        menu.addItem(.separator())

        showStatusMenuItem = NSMenuItem(
            title: "Show Backup Status",
            action: #selector(showBackupStatus),
            keyEquivalent: ""
        )
        showStatusMenuItem.target = self
        menu.addItem(showStatusMenuItem)

        testMenuItem = NSMenuItem(
            title: "Run Safety Test…",
            action: #selector(runSafetyTest),
            keyEquivalent: ""
        )
        testMenuItem.target = self
        menu.addItem(testMenuItem)

        menu.addItem(.separator())

        safetyMenuItem = NSMenuItem(
            title: "Warn if AI Apps Are Open",
            action: #selector(toggleAgentSafetyCheck),
            keyEquivalent: ""
        )
        safetyMenuItem.target = self
        safetyMenuItem.state = agentSafetyCheckEnabled ? .on : .off
        menu.addItem(safetyMenuItem)

        launchAtLoginMenuItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)
        updateLaunchAtLoginMenuItem()

        chooseDiskMenuItem = NSMenuItem(
            title: "Choose Backup Disk…",
            action: #selector(chooseBackupDisk),
            keyEquivalent: ""
        )
        chooseDiskMenuItem.target = self
        menu.addItem(chooseDiskMenuItem)

        let settingsItem = NSMenuItem(
            title: "Open Time Machine Settings…",
            action: #selector(openTimeMachineSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "About \(AppConfiguration.appName)",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        quitMenuItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
        statusItem.button?.toolTip = AppConfiguration.appName
        setStatusIcon(
            symbolName: "externaldrive.fill",
            accessibilityDescription: "\(AppConfiguration.appName) is ready"
        )
    }

    func updateDestinationMenuTitles() {
        guard
            backupMenuItem != nil,
            ejectMenuItem != nil
        else {
            return
        }

        guard let selection = selectedDestination else {
            backupMenuItem.title = "Choose a Backup Disk First"
            ejectMenuItem.title = "Eject Backup Disk"
            ejectMenuItem.image = NSImage(
                systemSymbolName: "eject",
                accessibilityDescription: "Eject backup disk"
            )
            return
        }

        backupMenuItem.title = "Back Up to \(selection.name) & Eject"
        ejectMenuItem.title = "Eject \(selection.name)"
        ejectMenuItem.image = NSImage(
            systemSymbolName: "eject",
            accessibilityDescription: "Eject \(selection.name)"
        )
    }

    func initialStatusMessage(
        for selection: DestinationSelection
    ) -> String {
        let key = AppConfiguration.lastSuccessfulBackupKey(
            for: selection.id
        )

        guard let date = defaults.object(forKey: key) as? Date else {
            return "Ready for \(selection.name)"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Last safe backup: \(formatter.string(from: date))"
    }

    func apply(_ state: BackupState) {
        currentState = state
        statusMenuItem.title = state.message

        let isConfigured = selectedDestination != nil
        let isAvailable = !state.isBusy
        backupMenuItem.isEnabled = isConfigured && isAvailable
        ejectMenuItem.isEnabled = isConfigured && isAvailable
        testMenuItem.isEnabled = isConfigured && isAvailable
        chooseDiskMenuItem.isEnabled = isAvailable
        safetyMenuItem.isEnabled = isAvailable
        launchAtLoginMenuItem.isEnabled = isAvailable
        cancelMenuItem.isHidden = !state.isBusy
        cancelMenuItem.isEnabled =
            state.isCancellable && controller?.canCancel == true
        quitMenuItem.isEnabled = isAvailable || state.isCancellable

        setStatusIcon(
            symbolName: state.symbolName,
            accessibilityDescription: state.message
        )
        statusItem.button?.toolTip = state.message
        statusPanelController.update(
            state: state,
            progress: currentProgress
        )
    }

    func handle(_ completion: BackupCompletion) {
        let targetName = selectedDestination?.name ?? "The backup disk"

        switch completion {
        case .success(let date):
            if let destinationID = selectedDestination?.id {
                defaults.set(
                    date,
                    forKey: AppConfiguration.lastSuccessfulBackupKey(
                        for: destinationID
                    )
                )
            }
            sendNotification(
                identifier: "backup-success-\(date.timeIntervalSince1970)",
                title: "\(targetName) is safe to switch off",
                body: "The Time Machine backup completed and the disk was safely ejected."
            )
        case .alreadyUnmounted(let date):
            if let destinationID = selectedDestination?.id {
                defaults.set(
                    date,
                    forKey: AppConfiguration.lastSuccessfulBackupKey(
                        for: destinationID
                    )
                )
            }
            sendNotification(
                identifier: "backup-unmounted-\(date.timeIntervalSince1970)",
                title: "\(targetName) is safe to switch off",
                body: "The Time Machine backup completed and the disk was already unmounted."
            )
        case .ejected(let date):
            sendNotification(
                identifier: "ejection-success-\(date.timeIntervalSince1970)",
                title: "\(targetName) is safe to switch off",
                body: "The disk was safely ejected. No backup was started."
            )
        case .cancelled:
            break
        case .simulation:
            sendNotification(
                identifier: "safety-test-\(Date().timeIntervalSince1970)",
                title: "Safety test passed",
                body: "Notifications work. No backup was started and no disk was touched."
            )
        case .failure(let message, let stage):
            let title: String
            switch stage {
            case .beforeBackup:
                title = "The backup could not start"
            case .duringBackup:
                title = "The backup did not complete"
            case .afterBackup:
                title = "Backup completed, but \(targetName) is still connected"
            }

            sendNotification(
                identifier: "backup-failure-\(Date().timeIntervalSince1970)",
                title: title,
                body: message,
                fallbackToAlert: false
            )
            NSSound.beep()
            showAlert(title: title, message: message)
        case .ejectionFailure(let message):
            let title = "\(targetName) could not be ejected"
            sendNotification(
                identifier: "ejection-failure-\(Date().timeIntervalSince1970)",
                title: title,
                body: message,
                fallbackToAlert: false
            )
            NSSound.beep()
            showAlert(title: title, message: message)
        }

        if pendingTermination {
            pendingTermination = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    @objc func startBackup() {
        guard
            let controller,
            !controller.isBusy
        else {
            return
        }

        if agentSafetyCheckEnabled {
            let runningAgents = runningAIAgentNames()

            if !runningAgents.isEmpty {
                NSApp.activate(ignoringOtherApps: true)

                let targetName = selectedDestination?.name
                    ?? "the backup disk"
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "An AI app is still open"
                alert.informativeText = """
                \(runningAgents.joined(separator: ", ")) appears to be running.

                For the strongest offline protection, close it before connecting or backing up to \(targetName).
                """
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Back Up Anyway")

                guard alert.runModal() == .alertSecondButtonReturn else {
                    return
                }
            }
        }

        requestNotificationPermission()
        controller.startBackup()
    }

    @objc func ejectDisk() {
        guard
            let controller,
            !controller.isBusy
        else {
            return
        }

        requestNotificationPermission()
        controller.startEjectOnly()
    }

    @objc func cancelCurrentOperation() {
        _ = controller?.cancelCurrentOperation()
    }

    @objc func runSafetyTest() {
        guard
            let controller,
            !controller.isBusy
        else {
            return
        }

        requestNotificationPermission()
        controller.startSimulation()
    }

    @objc func showBackupStatus() {
        statusPanelController.update(
            state: currentState,
            progress: currentProgress
        )
        statusPanelController.show()
    }

    @objc func chooseBackupDisk() {
        guard controller?.isBusy != true else { return }
        loadDestinationsAndPresentPicker()
    }

    func loadDestinationsAndPresentPicker() {
        statusMenuItem.title = "Reading Time Machine backup disks…"
        chooseDiskMenuItem.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let result = Result {
                try self.destinationProvider
                    .configuredLocalDestinations()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                self.statusMenuItem.title = self.currentState.message
                self.chooseDiskMenuItem.isEnabled = true

                switch result {
                case .success(let destinations):
                    self.presentDestinationPicker(destinations)
                case .failure(let error):
                    self.showAlert(
                        title: "Could not read Time Machine disks",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    func presentDestinationPicker(
        _ destinations: [TimeMachineDestination]
    ) {
        guard !destinations.isEmpty else {
            showNoLocalDestinationAlert()
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Choose your backup disk"
        alert.informativeText = """
        Choose the directly attached Time Machine disk that \(AppConfiguration.appName) may back up to and safely eject.

        The app stores the exact Time Machine destination identity, so it will refuse a different disk that merely has the same name.
        """

        let accessoryView = NSView(
            frame: NSRect(x: 0, y: 0, width: 370, height: 32)
        )
        let popUpButton = NSPopUpButton(
            frame: accessoryView.bounds.insetBy(dx: 0, dy: 2),
            pullsDown: false
        )
        popUpButton.autoresizingMask = [.width]
        accessoryView.addSubview(popUpButton)

        for destination in destinations {
            let connectionState = destination.mountPoint == nil
                ? "not connected"
                : "connected"
            popUpButton.addItem(
                withTitle: "\(destination.normalizedName) — \(connectionState)"
            )
        }

        if
            let selectedID = selectedDestination?.id,
            let selectedIndex = destinations.firstIndex(where: {
                $0.id == selectedID
            })
        {
            popUpButton.selectItem(at: selectedIndex)
        }

        alert.accessoryView = accessoryView
        alert.addButton(withTitle: "Use This Disk")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let selectedIndex = popUpButton.indexOfSelectedItem
        guard destinations.indices.contains(selectedIndex) else {
            return
        }

        let destination = destinations[selectedIndex]
        let selection = DestinationSelection(
            id: destination.id,
            name: destination.normalizedName
        )
        destinationPreferences.save(selection)
        install(selection)
    }

    func showNoLocalDestinationAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No local Time Machine backup disk was found"
        alert.informativeText = """
        First add a directly attached disk in Time Machine Settings. Then return to the menu-bar icon and choose “Choose Backup Disk…”.

        Network Time Machine destinations are not supported because this app is designed to safely eject a physical disk.
        """
        alert.addButton(withTitle: "Open Time Machine Settings")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            openTimeMachineSettings()
        }
    }

    func presentTimeMachineCoverageNoticeIfNeeded() -> Bool {
        guard !defaults.bool(
            forKey: AppConfiguration.coverageNoticeAcknowledgedDefaultsKey
        ) else {
            return true
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Check what Time Machine will protect"
        alert.informativeText = """
        Backup & Eject follows your existing Time Machine settings, including exclusions.

        Before relying on this backup, open Time Machine → Options and make sure every important folder and volume is included.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Open Time Machine Settings")

        let response = alert.runModal()
        defaults.set(
            true,
            forKey: AppConfiguration.coverageNoticeAcknowledgedDefaultsKey
        )

        if response == .alertSecondButtonReturn {
            openTimeMachineSettings()
            return false
        }

        return true
    }

    @objc func toggleAgentSafetyCheck() {
        let newValue = !agentSafetyCheckEnabled
        defaults.set(
            newValue,
            forKey: AppConfiguration.safetyCheckDefaultsKey
        )
        safetyMenuItem.state = newValue ? .on : .off
    }

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp

        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        } catch {
            showAlert(
                title: "Could not change Launch at Login",
                message: error.localizedDescription
            )
        }

        updateLaunchAtLoginMenuItem()
    }

    @objc func openTimeMachineSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc func showAbout() {
        showAlert(
            title: AppConfiguration.appName,
            message: """
            A one-click controller for a directly attached Time Machine backup disk.

            It starts a manual backup to the exact destination you selected, waits for Time Machine to finish, and then asks macOS to eject the disk normally. It never force-ejects.

            \(AppConfiguration.appName) is an independent utility and is not affiliated with Apple.
            """
        )
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    var agentSafetyCheckEnabled: Bool {
        defaults.bool(forKey: AppConfiguration.safetyCheckDefaultsKey)
    }

    func runningAIAgentNames() -> [String] {
        let keywords = ["chatgpt", "claude", "codex"]

        let names = NSWorkspace.shared.runningApplications.compactMap {
            application -> String? in
            guard application.processIdentifier
                    != ProcessInfo.processInfo.processIdentifier
            else {
                return nil
            }

            guard let name = application.localizedName else {
                return nil
            }

            let lowercaseName = name.lowercased()
            return keywords.contains(where: lowercaseName.contains)
                ? name
                : nil
        }

        return Array(Set(names)).sorted()
    }

    func updateLaunchAtLoginMenuItem() {
        guard launchAtLoginMenuItem != nil else { return }

        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .on
        case .requiresApproval:
            launchAtLoginMenuItem.title = "Launch at Login (Approval Needed)"
            launchAtLoginMenuItem.state = .mixed
        case .notRegistered, .notFound:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .off
        @unknown default:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .off
        }
    }

    func setStatusIcon(
        symbolName: String,
        accessibilityDescription: String
    ) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: .regular
        )
        let image = (
            NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: accessibilityDescription
            )
            ?? NSImage(
                systemSymbolName: "externaldrive.fill",
                accessibilityDescription: accessibilityDescription
            )
        )?.withSymbolConfiguration(configuration)

        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    func sendNotification(
        identifier: String,
        title: String,
        body: String,
        fallbackToAlert: Bool = true
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request) { error in
                    if error != nil, fallbackToAlert {
                        self?.showNotificationFallback(
                            title: title,
                            body: body
                        )
                    }
                }
            case .notDetermined:
                center.requestAuthorization(
                    options: [.alert, .sound]
                ) { granted, _ in
                    if granted {
                        center.add(request)
                    } else if fallbackToAlert {
                        self?.showNotificationFallback(
                            title: title,
                            body: body
                        )
                    }
                }
            case .denied:
                if fallbackToAlert {
                    self?.showNotificationFallback(
                        title: title,
                        body: body
                    )
                }
            @unknown default:
                if fallbackToAlert {
                    self?.showNotificationFallback(
                        title: title,
                        body: body
                    )
                }
            }
        }
    }

    func showNotificationFallback(title: String, body: String) {
        DispatchQueue.main.async { [weak self] in
            self?.showAlert(title: title, message: body)
        }
    }

    func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
