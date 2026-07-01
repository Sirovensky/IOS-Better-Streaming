import BetterStreamingDomain
import BetterStreamingSources
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// First-run setup: welcome → connect a source → key settings. Matches the docs'
/// principle that setup starts from a Library shell's "Add Source", not a bare
/// protocol picker. Reuses the real SMB connection tester from Core.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var proto: SourceProtocol = .smb
    @State private var host = ""
    @State private var port = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var rootPath = "/"
    @State private var showFolderPicker = false
    @State private var testState: TestState = .idle
    @State private var isTesting = false
    @State private var showLocalImporter = false

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
        .sheet(isPresented: $showFolderPicker) {
            RemoteFolderPicker(
                proto: proto,
                host: host.trimmed,
                port: Int(port.trimmed) ?? proto.defaultPort,
                share: share.trimmed,
                username: username.trimmed.isEmpty ? nil : username.trimmed,
                domain: domain.trimmed.isEmpty ? nil : domain.trimmed,
                password: password.isEmpty ? nil : password
            ) { selected in
                rootPath = selected
            }
            .environment(model)
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

            Button {
                showLocalImporter = true
            } label: {
                Label("Use music on this device", systemImage: "iphone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryActionButtonStyle())

            // An escape hatch so a first-run user whose server is unreachable (and who
            // has no local music) isn't trapped in the modal — the app's empty states
            // guide them to add a source later.
            Button("Skip for now") { model.completeOnboarding() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

            Spacer(minLength: 12)
        }
        .fileImporter(isPresented: $showLocalImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.addLocalSource(name: url.lastPathComponent, folderURL: url)
                dismiss()
            }
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
                ForEach(SourceProtocol.servers) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: proto) { _, _ in testState = .idle }

            VStack(spacing: 12) {
                field("Host or IP", text: $host, icon: "network")
                field("Port (default \(proto.defaultPort))", text: $port, icon: "number", keyboard: .numberPad)
                field(proto.pathFieldLabel, text: $share, icon: "folder")
                field("Username (optional)", text: $username, icon: "person")
                secureField("Password (optional)", text: $password)
                if proto == .smb {
                    field("Domain / workgroup (optional)", text: $domain, icon: "building.2")
                }
            }
            .padding(14)
            .surfaceCard(fill: DesignTokens.surfaceCard)

            if !portValid {
                Text("Enter a port between 1 and 65535.")
                    .font(.caption).foregroundStyle(DesignTokens.error)
            }

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
                .disabled(isTesting || host.trimmed.isEmpty || share.trimmed.isEmpty || !portValid)
            } else {
                Text("\(proto.rawValue) connects when you add it; your library appears after the first scan.")
                    .font(.caption).foregroundStyle(DesignTokens.textSecondary)
            }

            if proto.hasAdapter {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(DesignTokens.brandPrimary)
                    Text(rootPath == "/" ? "Whole share" : rootPath)
                        .font(.caption).foregroundStyle(DesignTokens.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Browse…") { showFolderPicker = true }
                        .font(.caption.weight(.semibold)).foregroundStyle(DesignTokens.brandPrimary)
                        .disabled(host.trimmed.isEmpty || share.trimmed.isEmpty)
                }
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
            .disabled(step == 1 && (host.trimmed.isEmpty || share.trimmed.isEmpty || !portValid))
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
                port: Int(port.trimmed) ?? proto.defaultPort,
                share: share.trimmed,
                username: username.trimmed.isEmpty ? nil : username.trimmed,
                password: password.isEmpty ? nil : password,
                domain: domain.trimmed.isEmpty ? nil : domain.trimmed,
                rootPath: rootPath
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
                endpoint: SourceEndpoint(hostDisplayName: trimmedHost, port: Int(port.trimmed), shareName: trimmedShare),
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

    /// Port must be blank (→ protocol default) or a valid 1...65535.
    private var portValid: Bool {
        let t = port.trimmed
        if t.isEmpty { return true }
        guard let n = Int(t) else { return false }
        return (1...65535).contains(n)
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
