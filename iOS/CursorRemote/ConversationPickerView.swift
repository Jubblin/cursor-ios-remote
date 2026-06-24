import SwiftUI

struct ConversationPickerView: View {
    @EnvironmentObject private var client: BridgeClient
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agent session")
                    .font(.headline)
                Spacer()
                if client.isLoadingCatalog {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await client.loadAgents() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!client.isConnected)
            }

            if client.agents.isEmpty {
                Text("Load agent conversations from your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Load agents") {
                    Task { await client.loadAgents() }
                }
                .disabled(!client.isConnected)
            } else {
                Picker("Agent", selection: agentBinding) {
                    Text("Select agent session").tag(String?.none)
                    ForEach(client.agents) { agent in
                        Text(agentPickerLabel(agent))
                            .tag(Optional(agent.id))
                    }
                }
                .pickerStyle(.menu)

                if let selected = currentAgent {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(selected.projectName, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Last used \(selected.lastUsedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Button("Open on Mac") {
                        guard let agentId = settings.settings.selectedAgentId else { return }
                        Task { await client.selectAgent(agentId: agentId) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(settings.settings.selectedAgentId == nil)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            if client.agents.isEmpty, client.isConnected {
                Task { await client.loadAgents() }
            }
        }
    }

    private func agentPickerLabel(_ agent: AgentConversation) -> String {
        let when = agent.lastUsedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(agent.name) · \(agent.projectName) · \(when)"
    }

    private var currentAgent: AgentConversation? {
        guard let id = settings.settings.selectedAgentId else { return nil }
        return client.agents.first { $0.id == id }
    }

    private var agentBinding: Binding<String?> {
        Binding(
            get: { settings.settings.selectedAgentId },
            set: { settings.settings.selectedAgentId = $0 }
        )
    }
}
