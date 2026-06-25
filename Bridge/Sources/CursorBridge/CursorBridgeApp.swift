import AppKit
import ApplicationServices
import SwiftUI

@main
struct CursorBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.controller)
        } label: {
            Image(nsImage: BridgeIcons.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}

private enum BridgeIcons {
    static var menuBarImage: NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: "Cursor Bridge")!
        fallback.isTemplate = true
        return fallback
    }
}

final class BridgeController: ObservableObject {
    @Published var isRunning = false
    @Published var port: Int
    @Published var token: String
    @Published var lastStatus: SessionStatus?
    @Published var errorMessage: String?
    @Published private(set) var pairingQRImage: NSImage?

    private var server: BridgeServer?

    init() {
        port = Int(ProcessInfo.processInfo.environment["CURSOR_BRIDGE_PORT"] ?? "8742") ?? 8742
        Self.secureTokenFile()
        token = BridgeController.loadOrCreateToken()
    }

    func toggleServer() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        errorMessage = nil
        let server = BridgeServer(port: port, authToken: token)
        server.onStatusUpdate = { [weak self] status in
            DispatchQueue.main.async {
                self?.lastStatus = status
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try server.start()
                DispatchQueue.main.async {
                    self.server = server
                    self.isRunning = true
                    self.lastStatus = server.currentStatus
                    self.refreshPairingQR()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isRunning = false
                }
            }
        }
    }

    func stop() {
        server?.stop()
        DispatchQueue.main.async {
            self.server = nil
            self.isRunning = false
            self.pairingQRImage = nil
        }
    }

    func pairingJSON() -> String {
        PairingPayload.current(
            hostname: Hostname.local(),
            port: port,
            token: token
        )
    }

    private func refreshPairingQR() {
        let json = pairingJSON()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = QRCodeImage.make(from: json)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pairingQRImage = image
                if image == nil {
                    print("[Bridge] Could not generate pairing QR code (\(json.count) bytes)")
                }
            }
        }
    }

    private static func loadOrCreateToken() -> String {
        let url = tokenFileURL()
        if let data = try? Data(contentsOf: url),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        let token = UUID().uuidString
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? token.data(using: .utf8)?.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
        return token
    }

    static func secureTokenFile() {
        let url = tokenFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    static func tokenFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor-bridge/token.txt")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = BridgeController()

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()
        controller.start()
    }

    func applicationWillTerminate(_: Notification) {
        controller.stop()
    }

    private func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var controller: BridgeController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(controller.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(controller.isRunning ? "Bridge running" : "Bridge stopped")
                    .font(.headline)
            }

            if controller.isRunning {
                pairingSection
            }

            if let status = controller.lastStatus {
                Label(status.state.rawValue, systemImage: icon(for: status.state))
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Text("Port: \(controller.port)")
            if controller.token.isEmpty {
                Text("Token: not set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Token: ••••\(controller.token.suffix(4))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Use Tailscale hostname when away from home")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            Button(controller.isRunning ? "Stop Bridge" : "Start Bridge") {
                controller.toggleServer()
            }

            Button("Copy pairing JSON") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controller.pairingJSON(), forType: .string)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private var pairingSection: some View {
        VStack(spacing: 8) {
            Text("Scan to pair iPhone")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let qrImage = controller.pairingQRImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 160, height: 160)
                    .accessibilityLabel("Pairing QR code")
            } else {
                Text("QR unavailable — use Copy pairing JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func icon(for state: AgentSessionState) -> String {
        switch state {
        case .awaitingApproval: "hand.raised.fill"
        case .running: "bolt.fill"
        case .idle: "moon.fill"
        case .error: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}
