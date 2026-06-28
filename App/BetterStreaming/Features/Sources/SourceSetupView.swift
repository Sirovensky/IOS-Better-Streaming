import BetterStreamingSources
import SwiftUI
import UIKit

/// Add a music source. Protocol-aware (SMB / WebDAV / FTP / SFTP). The library
/// model is protocol-neutral; only SMB has a live connection test today, the
/// others save and connect when their adapter lands.
struct SourceSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var proto: SourceProtocol = .smb
    @State private var host = ""
    @State private var port = ""
    @State private var path = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var testState: TestState = .idle
    @State private var isTesting = false

    private enum TestState: Equatable {
        case idle, success, failure(String)
        var isOnline: Bool { if case .success = self { return true }; return false }
    }

    private var canAdd: Bool { !host.trimmed.isEmpty && !path.trimmed.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                protocolPicker
                connectionForm
                testRow
                Button { addSource() } label: {
                    Label("Add source", systemImage: "externaldrive.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!canAdd)
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Add Source")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var protocolPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Protocol")
            VStack(spacing: 0) {
                ForEach(SourceProtocol.allCases) { item in
                    Button {
                        proto = item
                        testState = .idle
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.glyph).font(.title3)
                                .foregroundStyle(DesignTokens.brandPrimary).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.rawValue).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(DesignTokens.textPrimary)
                                    if !item.hasAdapter {
                                        Text("soon").font(.caption2.weight(.bold))
                                            .foregroundStyle(DesignTokens.warning)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(DesignTokens.warning.opacity(0.16), in: Capsule())
                                    }
                                }
                                Text(item.subtitle).font(.caption).foregroundStyle(DesignTokens.textSecondary)
                            }
                            Spacer()
                            if proto == item {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(DesignTokens.brandPrimary)
                            }
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if item != SourceProtocol.allCases.last {
                        Divider().overlay(DesignTokens.borderSubtle.opacity(0.08)).padding(.leading, 54)
                    }
                }
            }
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Connection")
            VStack(spacing: 12) {
                field("Host or IP", text: $host, icon: "network")
                field("Port (default \(proto.defaultPort))", text: $port, icon: "number", keyboard: .numberPad)
                field(proto.pathFieldLabel, text: $path, icon: "folder")
                field("Username (optional)", text: $username, icon: "person")
                secureField("Password (optional)")
                if proto == .smb {
                    field("Domain / workgroup (optional)", text: $domain, icon: "building.2")
                }
            }
            .padding(14)
            .surfaceCard(fill: DesignTokens.surfaceCard)
            Text("Credentials are stored in the Keychain on this device only.")
                .font(.caption2).foregroundStyle(DesignTokens.textTertiary)
        }
    }

    @ViewBuilder
    private var testRow: some View {
        if proto.hasConnectionTest {
            VStack(alignment: .leading, spacing: 8) {
                switch testState {
                case .idle: EmptyView()
                case .success:
                    StatusPill(label: "Connected", systemImage: "checkmark.circle.fill", tint: DesignTokens.success)
                case .failure(let message):
                    Text(message).font(.caption).foregroundStyle(DesignTokens.error)
                }
                Button { testConnection() } label: {
                    Label(isTesting ? "Testing…" : "Test connection", systemImage: "network").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(isTesting || !canAdd)
            }
        } else if proto.hasAdapter {
            Text("\(proto.rawValue) connects when you add it — your library appears after the first scan.")
                .font(.caption).foregroundStyle(DesignTokens.textSecondary)
        } else {
            Text("\(proto.rawValue) support is coming soon. You can save it now; it’ll stay pending until the adapter ships.")
                .font(.caption).foregroundStyle(DesignTokens.textSecondary)
        }
    }

    private func addSource() {
        model.addSource(
            name: path.trimmed,
            proto: proto,
            host: host.trimmed,
            port: Int(port.trimmed) ?? proto.defaultPort,
            share: path.trimmed,
            username: username.trimmed.isEmpty ? nil : username.trimmed,
            password: password.isEmpty ? nil : password,
            domain: domain.trimmed.isEmpty ? nil : domain.trimmed
        )
        dismiss()
    }

    private func testConnection() {
        guard proto == .smb else { return }
        let trimmedHost = host.trimmed
        let trimmedShare = path.trimmed
        guard !trimmedHost.isEmpty, !trimmedShare.isEmpty else { return }
        isTesting = true
        testState = .idle
        Task {
            let draft = SourceDraft(
                protocolKind: .smb,
                displayName: trimmedShare,
                endpoint: SourceEndpoint(hostDisplayName: trimmedHost, shareName: trimmedShare),
                username: username.trimmed.isEmpty ? nil : username.trimmed,
                domain: domain.trimmed.isEmpty ? nil : domain.trimmed
            )
            let credential = password.isEmpty ? nil : CredentialSecret(password: password)
            let result = await SMBSourceConnectionTester().testConnection(draft, credential: credential)
            await MainActor.run {
                isTesting = false
                if result.state == .online {
                    testState = .success
                } else {
                    testState = .failure(result.userMessage ?? result.failure?.userMessage ?? "Connection failed.")
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, icon: String, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(DesignTokens.textTertiary).frame(width: 24)
            TextField(title, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(DesignTokens.textPrimary)
        }
        .padding(12)
        .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func secureField(_ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key").foregroundStyle(DesignTokens.textTertiary).frame(width: 24)
            SecureField(title, text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(DesignTokens.textPrimary)
        }
        .padding(12)
        .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
