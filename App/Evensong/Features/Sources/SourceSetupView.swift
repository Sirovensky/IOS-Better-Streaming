import EvensongDomain
import EvensongSources
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var rootPath = "/"
    @State private var showFolderPicker = false
    @State private var testState: TestState = .idle
    @State private var isTesting = false
    @State private var localFolderURL: URL?
    @State private var localName = ""
    @State private var showLocalImporter = false
    @State private var showConfigImporter = false
    @State private var importError: String?

    private enum TestState: Equatable {
        case idle, success, failure(String)
        var isOnline: Bool { if case .success = self { return true }; return false }
    }

    private var canAdd: Bool {
        if proto == .local { return localFolderURL != nil }
        return !host.trimmed.isEmpty && !path.trimmed.isEmpty && portValid
    }

    /// Port must be blank (→ protocol default) or a valid 1...65535. Guards the FTP
    /// UInt16-overflow crash and an out-of-range custom port before Add/Test.
    private var portValid: Bool {
        let t = port.trimmed
        if t.isEmpty { return true }
        guard let n = Int(t) else { return false }
        return (1...65535).contains(n)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { showConfigImporter = true } label: {
                    Label("Import from a shared file", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                if let importError {
                    Text(importError).font(.caption).foregroundStyle(DesignTokens.error)
                }
                protocolPicker
                if proto == .local {
                    localForm
                } else {
                    connectionForm
                    folderRow
                    testRow
                }
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
        // Success tick only when a Test connection actually comes back online.
        .sensoryFeedback(.success, trigger: testState.isOnline) { _, online in online }
        .fileImporter(isPresented: $showLocalImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                localFolderURL = url
                if localName.isEmpty { localName = url.lastPathComponent }
            }
        }
        .fileImporter(
            isPresented: $showConfigImporter,
            allowedContentTypes: [UTType(filenameExtension: "bettersource") ?? .json, .json]
        ) { result in
            if case .success(let url) = result { importConfig(from: url) }
        }
        .sheet(isPresented: $showFolderPicker) {
            RemoteFolderPicker(
                proto: proto,
                host: host.trimmed,
                port: Int(port.trimmed),
                share: path.trimmed,
                username: username.trimmed.isEmpty ? nil : username.trimmed,
                domain: domain.trimmed.isEmpty ? nil : domain.trimmed,
                password: password.isEmpty ? nil : password
            ) { selected in
                rootPath = selected
            }
            .environment(model)
        }
    }

    @ViewBuilder
    private var folderRow: some View {
        if proto.hasAdapter {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Folder to scan")
                HStack(spacing: 12) {
                    Image(systemName: "folder").foregroundStyle(DesignTokens.brandPrimary).frame(width: 24)
                    Text(rootPath == "/" ? "Whole share" : rootPath)
                        .font(.subheadline).foregroundStyle(DesignTokens.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Browse…") { showFolderPicker = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.brandPrimary)
                        .disabled(!canAdd)
                }
                .padding(12)
                .surfaceCard(fill: DesignTokens.surfaceCard)
                Text("Pick the folder that holds your music (e.g. a “Music” sub-folder) for a faster, focused scan.")
                    .font(.caption2).foregroundStyle(DesignTokens.textTertiary)
            }
        }
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
                                Text(item.rawValue).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(DesignTokens.textPrimary)
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
            if !portValid {
                Text("Enter a port between 1 and 65535.")
                    .font(.caption).foregroundStyle(DesignTokens.error)
            }
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
        } else {
            Text("\(proto.rawValue) connects when you add it — your library appears after the first scan.")
                .font(.caption).foregroundStyle(DesignTokens.textSecondary)
        }
    }

    private var localForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "On-device music")
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "textformat").foregroundStyle(DesignTokens.textTertiary).frame(width: 24)
                    TextField("Name (optional)", text: $localName).foregroundStyle(DesignTokens.textPrimary)
                }
                .padding(12)
                .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button { showLocalImporter = true } label: {
                    Label(localFolderURL?.lastPathComponent ?? "Choose music folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }
            .padding(14)
            .surfaceCard(fill: DesignTokens.surfaceCard)

            Text("Pick a folder from Files, iCloud Drive, or this device. Music plays straight from there — no download.")
                .font(.caption2).foregroundStyle(DesignTokens.textTertiary)
        }
    }

    private func addSource() {
        if proto == .local {
            if let url = localFolderURL { model.addLocalSource(name: localName, folderURL: url) }
            dismiss()
            return
        }
        model.addSource(
            name: path.trimmed,
            proto: proto,
            host: host.trimmed,
            port: Int(port.trimmed) ?? proto.defaultPort,
            share: path.trimmed,
            username: username.trimmed.isEmpty ? nil : username.trimmed,
            password: password.isEmpty ? nil : password,
            domain: domain.trimmed.isEmpty ? nil : domain.trimmed,
            rootPath: rootPath
        )
        dismiss()
    }

    /// Decode a `.bettersource` file and prefill the form (password left blank —
    /// it's never shared). The user reviews, enters the password, and adds.
    private func importConfig(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let shared = try? JSONDecoder().decode(SharedSourceConfig.self, from: data),
              let importedProto = SourceProtocol(rawValue: shared.proto) else {
            importError = "Couldn't read that file. It may not be a valid source export."
            return
        }
        importError = nil
        proto = importedProto
        host = shared.host
        port = String(shared.port)
        path = shared.share
        username = shared.username ?? ""
        domain = shared.domain ?? ""
        rootPath = shared.rootPath
        password = ""
        testState = .idle
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
