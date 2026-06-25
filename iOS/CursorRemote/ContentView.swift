import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var client: BridgeClient
    @EnvironmentObject private var settings: SettingsStore
    @State private var prompt = ""
    @State private var showSettings = false
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ConversationPickerView()
                    statusCard
                    if client.status?.state == .awaitingApproval {
                        approvalButtons
                    }
                    if let message = client.lastActionMessage, client.status?.state != .awaitingApproval {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = client.lastError, client.status?.state != .awaitingApproval {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
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
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isPromptFocused = false }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                promptSection
                    .padding()
                    .background(.bar)
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
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Button(role: .destructive) {
                    Task { await client.reject() }
                } label: {
                    Label("Reject", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(client.isPerformingAction || !client.isConnected)

                Button {
                    Task { await client.approve() }
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(client.isPerformingAction || !client.isConnected)
            }

            if client.isPerformingAction {
                ProgressView("Sending to Mac…")
                    .font(.caption)
            }

            if let message = client.lastActionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let error = client.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Follow-up prompt")
                .font(.headline)
            TextField("Steer the agent…", text: $prompt)
                .textFieldStyle(.roundedBorder)
                .focused($isPromptFocused)
                .submitLabel(.send)
                .onSubmit(sendPrompt)
            Button("Send", action: sendPrompt)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !client.isConnected)
        }
    }

    private func sendPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        isPromptFocused = false
        Task { await client.sendPrompt(text) }
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
    @State private var showScanner = false
    @State private var pairingMessage: String?

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
                    if QRScannerView.isAvailable {
                        Button {
                            pairingMessage = nil
                            showScanner = true
                        } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        }
                    }

                    Text("Or paste pairing JSON from the Mac menu bar app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("{\"hostname\":\"...\",\"port\":8742,\"token\":\"...\"}", text: $pairingPaste, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .textInputAutocapitalization(.never)
                    Button("Import") {
                        if settings.importPairingJSON(pairingPaste) {
                            pairingMessage = "Pairing imported"
                            pairingPaste = ""
                        } else {
                            pairingMessage = "Invalid pairing JSON"
                        }
                    }

                    if let pairingMessage {
                        Text(pairingMessage)
                            .font(.caption)
                            .foregroundStyle(pairingMessage.contains("Invalid") ? .red : .green)
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
            .sheet(isPresented: $showScanner) {
                QRScannerSheet(
                    onCode: { code in
                        if settings.importPairingJSON(code) {
                            pairingMessage = "Pairing imported from QR code"
                            showScanner = false
                        } else {
                            pairingMessage = "QR code is not valid pairing data"
                        }
                    },
                    onCancel: { showScanner = false }
                )
            }
        }
    }
}

private struct QRScannerSheet: View {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView(onCode: onCode)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("Point at the QR code in Cursor Bridge on your Mac")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
            }
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
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
