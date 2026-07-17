import AppKit
import BackupAndEjectCore

final class BackupStatusPanelController: NSWindowController {
    private var targetName: String?
    private let statusImageView = NSImageView()
    private let titleLabel = NSTextField(
        labelWithString: AppConfiguration.appName
    )
    private let stageLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let percentageLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    // Roughly half the screen footprint of the original 390 × 205 panel,
    // while preserving enough room for readable two-line status messages.
    private let panelSize = NSSize(width: 300, height: 142)

    init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        super.init(window: panel)

        configureContent()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionIfVisible),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setTargetName(_ name: String?) {
        targetName = name?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    func update(
        state: BackupState,
        progress: TimeMachineBackupStatus?
    ) {
        precondition(Thread.isMainThread)

        stageLabel.stringValue = state.message
        stageLabel.toolTip = state.message
        updateIcon(symbolName: state.symbolName)

        switch state {
        case .idle:
            setStoppedProgress()
            if let targetName {
                detailLabel.stringValue = """
                Turn on \(targetName), then start from the menu bar.
                """
            } else {
                detailLabel.stringValue = """
                Choose a Time Machine backup disk from the menu bar.
                """
            }
        case .waiting:
            setIndeterminateProgress()
            detailLabel.stringValue = """
            Looking for \(targetDisplayName). Keep the drive powered on.
            """
            show()
        case .checking:
            setIndeterminateProgress()
            detailLabel.stringValue = """
            Checking Time Machine and the selected destination.
            """
            show()
        case .backingUp:
            updateBackupProgress(progress)
            show()
        case .ejecting:
            setIndeterminateProgress()
            detailLabel.stringValue = "Do not switch off the drive until ejection finishes."
            show()
        case .success:
            setDeterminateProgress(1)
            if state.message.localizedCaseInsensitiveContains("safety test") {
                detailLabel.stringValue = """
                Display test passed. No disk was touched.
                """
            } else {
                detailLabel.stringValue = """
                \(targetDisplayName) is safely ejected. You can switch it off.
                """
            }
            show()
        case .failure:
            setStoppedProgress()
            stageLabel.stringValue = "Backup needs attention"
            detailLabel.stringValue = firstSentence(of: state.message)
            show()
        }
    }

    func show() {
        precondition(Thread.isMainThread)
        positionAtBottomRight()
        window?.orderFrontRegardless()
    }

    @objc func hide() {
        window?.orderOut(nil)
    }

    private func configureContent() {
        guard let panel = window as? NSPanel else { return }

        let backgroundView = NSVisualEffectView()
        backgroundView.material = .popover
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 13
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderWidth = 1
        backgroundView.layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.45)
            .cgColor
        panel.contentView = backgroundView

        let contentViews = [
            statusImageView,
            titleLabel,
            stageLabel,
            detailLabel,
            progressIndicator,
            percentageLabel,
            closeButton
        ]
        contentViews.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            backgroundView.addSubview($0)
        }

        statusImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 17,
            weight: .medium
        )
        statusImageView.contentTintColor = .controlAccentColor

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        stageLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        stageLabel.textColor = .labelColor
        stageLabel.maximumNumberOfLines = 2
        stageLabel.lineBreakMode = .byWordWrapping
        stageLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        detailLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1

        percentageLabel.font = .monospacedDigitSystemFont(
            ofSize: 10.5,
            weight: .semibold
        )
        percentageLabel.textColor = .secondaryLabelColor
        percentageLabel.alignment = .right

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Hide backup status"
        )
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(hide)
        closeButton.toolTip = "Hide status window"

        NSLayoutConstraint.activate([
            statusImageView.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor,
                constant: 12
            ),
            statusImageView.topAnchor.constraint(
                equalTo: backgroundView.topAnchor,
                constant: 12
            ),
            statusImageView.widthAnchor.constraint(equalToConstant: 22),
            statusImageView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(
                equalTo: statusImageView.trailingAnchor,
                constant: 8
            ),
            titleLabel.centerYAnchor.constraint(
                equalTo: statusImageView.centerYAnchor
            ),

            closeButton.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor,
                constant: -9
            ),
            closeButton.centerYAnchor.constraint(
                equalTo: statusImageView.centerYAnchor
            ),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor,
                constant: -8
            ),

            stageLabel.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor,
                constant: 12
            ),
            stageLabel.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor,
                constant: -12
            ),
            stageLabel.topAnchor.constraint(
                equalTo: statusImageView.bottomAnchor,
                constant: 7
            ),

            progressIndicator.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor,
                constant: 12
            ),
            progressIndicator.trailingAnchor.constraint(
                equalTo: percentageLabel.leadingAnchor,
                constant: -7
            ),
            progressIndicator.topAnchor.constraint(
                equalTo: stageLabel.bottomAnchor,
                constant: 9
            ),
            progressIndicator.heightAnchor.constraint(equalToConstant: 6),

            percentageLabel.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor,
                constant: -12
            ),
            percentageLabel.centerYAnchor.constraint(
                equalTo: progressIndicator.centerYAnchor
            ),
            percentageLabel.widthAnchor.constraint(equalToConstant: 38),

            detailLabel.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor,
                constant: 12
            ),
            detailLabel.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor,
                constant: -12
            ),
            detailLabel.topAnchor.constraint(
                equalTo: progressIndicator.bottomAnchor,
                constant: 8
            ),
            detailLabel.bottomAnchor.constraint(
                lessThanOrEqualTo: backgroundView.bottomAnchor,
                constant: -10
            )
        ])

        updateIcon(symbolName: "externaldrive.fill")
        setStoppedProgress()
    }

    private func updateIcon(symbolName: String) {
        statusImageView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: stageLabel.stringValue
        )

        switch symbolName {
        case "checkmark.circle.fill":
            statusImageView.contentTintColor = .systemGreen
        case "exclamationmark.triangle.fill":
            statusImageView.contentTintColor = .systemRed
        default:
            statusImageView.contentTintColor = .controlAccentColor
        }
    }

    private func updateBackupProgress(
        _ progress: TimeMachineBackupStatus?
    ) {
        guard let progress else {
            setIndeterminateProgress()
            detailLabel.stringValue = """
            Time Machine is calculating what needs to be copied.
            """
            return
        }

        if let fraction = progress.fractionCompleted {
            setDeterminateProgress(fraction)
        } else {
            setIndeterminateProgress()
        }

        if
            let copiedBytes = progress.copiedBytes,
            let totalBytes = progress.totalBytes,
            totalBytes > 0
        {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            detailLabel.stringValue = """
            \(formatter.string(fromByteCount: copiedBytes)) of \(formatter.string(fromByteCount: totalBytes)) copied
            """
            return
        }

        if
            let copiedFiles = progress.copiedFiles,
            let totalFiles = progress.totalFiles,
            totalFiles > 0
        {
            detailLabel.stringValue = """
            \(formatted(copiedFiles)) of \(formatted(totalFiles)) items copied
            """
            return
        }

        if let copiedFiles = progress.copiedFiles {
            detailLabel.stringValue = """
            \(formatted(copiedFiles)) items found so far
            """
            return
        }

        let phase = progress.phase?.lowercased() ?? ""
        if
            phase.contains("finish")
                || phase.contains("thin")
                || phase.contains("clean")
        {
            detailLabel.stringValue = """
            Time Machine is finishing and checking the backup.
            """
        } else if phase.contains("copy") {
            detailLabel.stringValue = "Time Machine is copying your files."
        } else {
            detailLabel.stringValue = """
            Time Machine is calculating what needs to be copied.
            """
        }
    }

    private func setIndeterminateProgress() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        percentageLabel.stringValue = ""
    }

    private func setDeterminateProgress(_ fraction: Double) {
        let clampedFraction = min(max(fraction, 0), 1)
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = clampedFraction
        percentageLabel.stringValue = """
        \(Int((clampedFraction * 100).rounded()))%
        """
    }

    private func setStoppedProgress() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = 0
        percentageLabel.stringValue = ""
    }

    private var targetDisplayName: String {
        targetName ?? "your backup disk"
    }

    private func formatted(_ value: Int64) -> String {
        NumberFormatter.localizedString(
            from: NSNumber(value: value),
            number: .decimal
        )
    }

    private func firstSentence(of message: String) -> String {
        guard let sentenceEnd = message.firstIndex(of: ".") else {
            return message
        }
        return String(message[...sentenceEnd])
    }

    private func positionAtBottomRight() {
        guard
            let window,
            let screen = NSScreen.screens.first(where: {
                $0.frame.contains(NSEvent.mouseLocation)
            }) ?? NSScreen.main ?? NSScreen.screens.first
        else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.maxX - window.frame.width - 12,
            y: visibleFrame.minY + 12
        )
        window.setFrameOrigin(origin)
    }

    @objc private func repositionIfVisible() {
        guard window?.isVisible == true else { return }
        positionAtBottomRight()
    }
}
