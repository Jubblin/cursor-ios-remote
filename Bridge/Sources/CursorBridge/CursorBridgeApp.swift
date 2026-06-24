import AppKit
import ApplicationServices
import SwiftUI

@main
struct CursorBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Cursor Bridge", systemImage: "iphone.and.arrow.forward") {
            MenuBarView()
                .environmentObject(appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

final class BridgeController: ObservableObject {
    @Published var isRunning = false
    @Published var port: Int
    @Published var token: String
    @Published var lastStatus: SessionStatus?
    @Published var errorMessage: String?

    private var server: BridgeServer?
    private var refreshTimer: Timer?

    init() {
        port = Int(ProcessInfo.processInfo.environment["CURSOR_BRIDGE_PORT"] ?? "8742") ?? 8742
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
        do {
            try server.start()
            DispatchQueue.main.async {
                self.server = server
                self.isRunning = true
                self.startStatusRefresh()
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
                self.isRunning = false
            }
        }
    }

    func stop() {
        server?.stop()
        DispatchQueue.main.async {
            self.server = nil
            self.isRunning = false
            self.refreshTimer?.invalidate()
            self.refreshTimer = nil
        }
    }

    private func startStatusRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let status = CursorAutomation().detectSessionStatus()
            DispatchQueue.main.async {
                self.lastStatus = status
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
        try? token.data(using: .utf8)?.write(to: url)
        return token
    }

    static func tokenFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor-bridge/token.txt")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = BridgeController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
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

            if let status = controller.lastStatus {
                Label(status.state.rawValue, systemImage: icon(for: status.state))
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Port: \(controller.port)")
            Text("Token: \(controller.token.prefix(8))…")
                .textSelection(.enabled)
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
                let info = """
                {"hostname":"\(Hostname.local() ?? "your-mac.tailnet-name.ts.net")","port":\(controller.port),"token":"\(controller.token)"}
                """
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info, forType: .string)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func icon(for state: AgentSessionState) -> String {
        switch state {
        case .awaitingApproval: return "hand.raised.fill"
        case .running: return "bolt.fill"
        case .idle: return "moon.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}
