import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var client: BridgeClient
    @EnvironmentObject private var settings: SettingsStore
    @State private var prompt = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ConversationPickerView()
                statusCard
                if client.status?.state == .awaitingApproval {
                    approvalButtons
                }
                promptSection
                if let message = client.lastActionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = client.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Cursor Remote")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionBadge
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await client.refreshStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var statusCard: some View {
        Group {
            if let status = client.status {
                VStack(spacing: 8) {
                    Image(systemName: status.state.symbolName)
                        .font(.system(size: 44))
                        .foregroundStyle(status.state == .awaitingApproval ? .orange : .blue)
                    Text(status.state.displayName)
                        .font(.title2.bold())
                    if let detail = status.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Text(status.cursorRunning ? "Cursor running" : "Cursor not running")
                        .font(.caption)
                        .foregroundStyle(status.cursorRunning ? .green : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else {
                ContentUnavailableView(
                    "Not connected",
                    systemImage: "wifi.slash",
                    description: Text("Configure your Mac bridge in Settings")
                )
            }
        }
    }

    private var approvalButtons: some View {
        HStack(spacing: 16) {
            Button(role: .destructive) {
                Task { await client.reject() }
            } label: {
                Label("Reject", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button {
                Task { await client.approve() }
            } label: {
                Label("Approve", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Follow-up prompt")
                .font(.headline)
            TextField("Steer the agent…", text: $prompt, axis: .vertical)
                .lineLimit(3 ... 6)
                .textFieldStyle(.roundedBorder)
            Button("Send") {
                let text = prompt
                prompt = ""
                Task { await client.sendPrompt(text) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !client.isConnected)
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(client.isConnected ? "Live" : "Offline")
                .font(.caption)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var pairingPaste = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac bridge") {
                    TextField("Hostname (LAN or Tailscale)", text: $settings.settings.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper("Port: \(settings.settings.port)", value: $settings.settings.port, in: 1024 ... 65535)
                    SecureField("Auth token", text: $settings.settings.token)
                    Toggle("Use HTTPS", isOn: $settings.settings.useHTTPS)
                }

                Section("Quick pair") {
                    Text("Paste pairing JSON from the Mac menu bar app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("{\"hostname\":\"...\",\"port\":8742,\"token\":\"...\"}", text: $pairingPaste, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .textInputAutocapitalization(.never)
                    Button("Import") {
                        settings.importPairingJSON(pairingPaste)
                        pairingPaste = ""
                    }
                }

                Section("Away from home") {
                    Text(
                        "Use your Mac's Tailscale MagicDNS name (e.g. macbook.tailnet.ts.net). Ensure Tailscale is running on both devices."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BridgeClient(settings: .default))
        .environmentObject(SettingsStore())
        .environmentObject(NotificationManager())
}
