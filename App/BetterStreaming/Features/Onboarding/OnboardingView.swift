import BetterStreamingSources
import SwiftUI

/// First-run setup: welcome → connect a source → key settings. Matches the docs'
/// principle that setup starts from a Library shell's "Add Source", not a bare
/// protocol picker. Reuses the real SMB connection tester from Core.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var proto: SourceProtocol = .smb
    @State private var host = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var testState: TestState = .idle
    @State private var isTesting = false

    private enum TestState: Equatable {
        case idle, success, failure(String)
        var isOnline: Bool { if case .success = self { return true }; return false }
    }

    var body: some View {
        ZStack {
            DesignTokens.surfaceCanvas.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch step {
                        case 0: welcome
                        case 1: connect
                        default: settings
                        }
                    }
                    .padding(24)
                }
                footer
            }
        }
    }

    // MARK: Step 0 — welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 24)
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 56))
                .foregroundStyle(DesignTokens.brandPrimary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your music.\nYour server.")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text("Stream and download your own library straight from your NAS or home server. Nothing leaves your network.")
                    .font(.body)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                valueRow("lock.shield", "Private by design", "No cloud account. Your files stay yours.")
                valueRow("folder.fill", "Folder-first", "Play any folder before a full scan finishes.")
                valueRow("arrow.down.circle", "Offline ready", "Keep your most-played music on device.")
            }
            .padding(.top, 8)
            Spacer(minLength: 12)
        }
    }

    private func valueRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(DesignTokens.brandPrimary).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                Text(detail).font(.caption).foregroundStyle(DesignTokens.textSecondary)
            }
        }
    }

    // MARK: Step 1 — connect

    private var connect: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("Connect your library", "Credentials stay in the Keychain on this device.")

            Picker("Protocol", selection: $proto) {
                ForEach(SourceProtocol.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: proto) { _, _ in testState = .idle }

            VStack(spacing: 12) {
                field("Host or IP", text: $host, icon: "network")
                field(proto.pathFieldLabel, text: $share, icon: "folder")
                field("Username (optional)", text: $username, icon: "person")
                secureField("Password (optional)", text: $password)
                if proto == .smb {
                    field("Domain / workgroup (optional)", text: $domain, icon: "building.2")
                }
            }
            .padding(14)
            .surfaceCard(fill: DesignTokens.surfaceCard)

            if proto.hasConnectionTest {
                switch testState {
                case .idle:
                    EmptyView()
                case .success:
                    StatusPill(label: "Connected", systemImage: "checkmark.circle.fill", tint: DesignTokens.success)
                case .failure(let message):
                    Text(message).font(.caption).foregroundStyle(DesignTokens.error)
                }

                Button(action: testConnection) {
                    Label(isTesting ? "Testing…" : "Test connection", systemImage: "network")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(isTesting || host.trimmed.isEmpty || share.trimmed.isEmpty)
            } else if proto.hasAdapter {
                Text("\(proto.rawValue) connects when you add it; your library appears after the first scan.")
                    .font(.caption).foregroundStyle(DesignTokens.textSecondary)
            } else {
                Text("\(proto.rawValue) support is coming soon — you can still save it now.")
                    .font(.caption).foregroundStyle(DesignTokens.textSecondary)
            }

            Text("Local Network access lets Better Streaming find and connect to your server.")
                .font(.caption2).foregroundStyle(DesignTokens.textTertiary)
        }
    }

    // MARK: Step 2 — settings

    private var settings: some View {
        @Bindable var autoCache = model.autoCache

        return VStack(alignment: .leading, spacing: 16) {
            stepTitle("Stay ready offline", "Better Streaming can keep the music you play most ready without the source.")

            VStack(spacing: 0) {
                Toggle(isOn: $autoCache.isEnabled) {
                    Text("Auto-cache my most-played music").font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)
                Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                HStack {
                    Text("Maximum storage").font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                    Spacer()
                    Picker("", selection: $autoCache.budgetBytes) {
                        ForEach(AutoCacheController.budgetPresets, id: \.self) {
                            Text(AutoCacheController.byteLabel($0)).tag($0)
                        }
                    }
                    .labelsHidden().tint(DesignTokens.brandPrimary)
                }
                .padding(12)
                Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                Toggle(isOn: $autoCache.wifiOnly) {
                    Text("Wi-Fi only").font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)
            }
            .surfaceCard(fill: DesignTokens.surfaceCard)

            Text("You can change all of this later in Settings.")
                .font(.caption2).foregroundStyle(DesignTokens.textTertiary)
        }
    }

    // MARK: Footer controls

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button { withAnimation { step -= 1 } } label: {
                    Label("Back", systemImage: "chevron.left").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }
            Button(action: primaryAction) {
                Label(primaryTitle, systemImage: step == 2 ? "play.fill" : "chevron.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(step == 1 && (host.trimmed.isEmpty || share.trimmed.isEmpty))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var primaryTitle: String {
        switch step {
        case 0: "Get started"
        case 1: "Continue"
        default: "Start listening"
        }
    }

    private func primaryAction() {
        switch step {
        case 0, 1:
            withAnimation { step += 1 }
        default:
            model.addSource(
                name: share.trimmed,
                proto: proto,
                host: host.trimmed,
                port: proto.defaultPort,
                share: share.trimmed,
                username: username.trimmed.isEmpty ? nil : username.trimmed,
                password: password.isEmpty ? nil : password,
                domain: domain.trimmed.isEmpty ? nil : domain.trimmed
            )
            dismiss()
        }
    }

    private func testConnection() {
        guard proto == .smb else { return }
        let trimmedHost = host.trimmed
        let trimmedShare = share.trimmed
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

    // MARK: Small UI helpers

    private func stepTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.weight(.bold)).foregroundStyle(DesignTokens.textPrimary)
            Text(detail).font(.subheadline).foregroundStyle(DesignTokens.textSecondary)
        }
    }

    private func field(_ title: String, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(DesignTokens.textTertiary).frame(width: 24)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(DesignTokens.textPrimary)
        }
        .padding(12)
        .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key").foregroundStyle(DesignTokens.textTertiary).frame(width: 24)
            SecureField(title, text: text)
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
