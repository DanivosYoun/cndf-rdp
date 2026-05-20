import AppKit
import RDPClientCore

protocol ConnectionBarViewDelegate: AnyObject {
    func connectionBarDidRequestConnect(
        _ view: ConnectionBarView,
        host: String,
        port: UInt16,
        username: String,
        password: String,
        domain: String
    )
    func connectionBarDidRequestDisconnect(_ view: ConnectionBarView)
}

final class ConnectionBarView: NSView {
    weak var delegate: ConnectionBarViewDelegate?

    private let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "3389")
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let domainField = NSTextField(string: "")
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
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        hostField.placeholderString = "Host"
        portField.placeholderString = "Port"
        usernameField.placeholderString = "Username"
        passwordField.placeholderString = "Password"
        domainField.placeholderString = "Domain"
        statusLabel.lineBreakMode = .byTruncatingTail

        connectButton.target = self
        connectButton.action = #selector(connect)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect)
        disconnectButton.isEnabled = false

        let stack = NSStackView(views: [
            hostField,
            portField,
            usernameField,
            passwordField,
            domainField,
            connectButton,
            disconnectButton,
            statusLabel
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        hostField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        portField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        usernameField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        passwordField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        domainField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    @objc private func connect() {
        delegate?.connectionBarDidRequestConnect(
            self,
            host: hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            port: UInt16(portField.stringValue) ?? 3389,
            username: usernameField.stringValue,
            password: passwordField.stringValue,
            domain: domainField.stringValue
        )
    }

    @objc private func disconnect() {
        delegate?.connectionBarDidRequestDisconnect(self)
    }
}
