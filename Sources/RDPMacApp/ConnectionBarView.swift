import AppKit
import RDPClientCore

protocol ConnectionBarViewDelegate: AnyObject {
    func connectionBarDidRequestConnect(_ view: ConnectionBarView, options: RDPConnectionOptions)
    func connectionBarDidRequestDisconnect(_ view: ConnectionBarView)
}

final class ConnectionBarView: NSView {
    weak var delegate: ConnectionBarViewDelegate?

    private let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "3389")
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let domainField = NSTextField(string: "")
    private let folderMountButton = NSButton(checkboxWithTitle: "Local folder", target: nil, action: nil)
    private let folderPathField = NSTextField(string: "")
    private let folderNameField = NSTextField(string: "RemoteShare")
    private let audioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nativeResolutionButton = NSButton(checkboxWithTitle: "Retina", target: nil, action: nil)
    private let colorDepthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let forcedSizeField = NSTextField(string: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Disconnected")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    func setConnected(_ connected: Bool) {
        connectButton.isEnabled = !connected
        disconnectButton.isEnabled = connected
        statusLabel.stringValue = connected ? "Connected" : "Disconnected"
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func applyExternalCredentials(_ options: RDPConnectionOptions) {
        hostField.stringValue = options.host
        portField.stringValue = String(options.port)
        usernameField.stringValue = options.username ?? ""
        passwordField.stringValue = options.password ?? ""
        domainField.stringValue = options.domain ?? ""
        folderMountButton.state = options.redirectedFolderPath == nil ? .off : .on
        folderPathField.stringValue = options.redirectedFolderPath ?? ""
        folderNameField.stringValue = options.redirectedFolderName ?? "RemoteShare"
        audioPopup.selectItem(at: Int(options.audioPlaybackMode.rawValue))
        nativeResolutionButton.state = options.preferDeviceNativeResolution ? .on : .off
        colorDepthPopup.selectItem(withTitle: "\(options.colorDepth.rawValue)-bit")
        if let forcedDesktopSize = options.forcedDesktopSize {
            forcedSizeField.stringValue = "\(Int(forcedDesktopSize.width))x\(Int(forcedDesktopSize.height))"
        } else {
            forcedSizeField.stringValue = ""
        }
        updateFolderFields()
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        hostField.placeholderString = "Host"
        portField.placeholderString = "Port"
        usernameField.placeholderString = "Username"
        passwordField.placeholderString = "Password"
        domainField.placeholderString = "Domain"
        folderPathField.placeholderString = "Local folder path"
        folderNameField.placeholderString = "Share name"
        statusLabel.lineBreakMode = .byTruncatingTail
        folderMountButton.target = self
        folderMountButton.action = #selector(updateFolderFields)
        folderMountButton.state = .off
        folderMountButton.setButtonType(.switch)
        audioPopup.addItems(withTitles: ["Audio off", "Play local", "Play remote"])
        audioPopup.selectItem(at: 0)
        nativeResolutionButton.state = .on
        nativeResolutionButton.setButtonType(.switch)
        colorDepthPopup.addItems(withTitles: ["32-bit", "24-bit", "16-bit"])
        colorDepthPopup.selectItem(at: 0)
        forcedSizeField.placeholderString = "WxH"

        connectButton.target = self
        connectButton.action = #selector(connect)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect)
        disconnectButton.isEnabled = false

        let primaryStack = NSStackView(views: [
            hostField,
            portField,
            usernameField,
            passwordField,
            domainField,
            connectButton,
            disconnectButton,
            statusLabel
        ])
        primaryStack.orientation = .horizontal
        primaryStack.alignment = .centerY
        primaryStack.spacing = 8

        let optionsStack = NSStackView(views: [
            audioPopup,
            nativeResolutionButton,
            colorDepthPopup,
            forcedSizeField,
            folderMountButton,
            folderNameField,
            folderPathField
        ])
        optionsStack.orientation = .horizontal
        optionsStack.alignment = .centerY
        optionsStack.spacing = 8

        let stack = NSStackView(views: [primaryStack, optionsStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        hostField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        portField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        usernameField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        passwordField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        domainField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        audioPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true
        nativeResolutionButton.widthAnchor.constraint(equalToConstant: 76).isActive = true
        colorDepthPopup.widthAnchor.constraint(equalToConstant: 86).isActive = true
        forcedSizeField.widthAnchor.constraint(equalToConstant: 94).isActive = true
        folderNameField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        folderPathField.widthAnchor.constraint(equalToConstant: 280).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        updateFolderFields()
    }

    @objc private func connect() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderPath = folderPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = folderNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldMountFolder = folderMountButton.state == .on && !folderPath.isEmpty

        delegate?.connectionBarDidRequestConnect(
            self,
            options: RDPConnectionOptions(
                host: host,
                port: UInt16(portField.stringValue) ?? 3389,
                username: nilIfEmpty(usernameField.stringValue),
                password: nilIfEmpty(passwordField.stringValue),
                domain: nilIfEmpty(domainField.stringValue),
                redirectedFolderPath: shouldMountFolder ? folderPath : nil,
                redirectedFolderName: nilIfEmpty(folderName),
                audioPlaybackMode: selectedAudioPlaybackMode(),
                preferDeviceNativeResolution: nativeResolutionButton.state == .on,
                colorDepth: selectedColorDepth(),
                forcedDesktopSize: parsedForcedDesktopSize()
            )
        )
    }

    @objc private func disconnect() {
        delegate?.connectionBarDidRequestDisconnect(self)
    }

    @objc private func updateFolderFields() {
        let enabled = folderMountButton.state == .on
        folderPathField.isEnabled = enabled
        folderNameField.isEnabled = enabled
    }

    private func selectedAudioPlaybackMode() -> RDPAudioPlaybackMode {
        switch audioPopup.indexOfSelectedItem {
        case 1:
            return .playLocally
        case 2:
            return .playOnRemote
        default:
            return .disabled
        }
    }

    private func selectedColorDepth() -> RDPColorDepth {
        switch colorDepthPopup.indexOfSelectedItem {
        case 1:
            return .depth24
        case 2:
            return .depth16
        default:
            return .depth32
        }
    }

    private func parsedForcedDesktopSize() -> CGSize? {
        let value = forcedSizeField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "×", with: "x")
        guard !value.isEmpty else {
            return nil
        }
        let parts = value
            .split(separator: "x", maxSplits: 1)
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            return nil
        }
        return CGSize(width: parts[0], height: parts[1])
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
