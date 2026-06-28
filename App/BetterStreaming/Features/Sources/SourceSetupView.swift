import SwiftUI
import BetterStreamingSources

struct SourceSetupView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var step: SetupStep = .chooseSource
    @State private var selectedDiscovery = "Manual SMB"
    @State private var host = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var workgroup = ""
    @State private var showAdvanced = false
    @State private var rootPath = ""
    @State private var testState: ConnectionTestState = .notRun
    @State private var isTesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SetupProgressRail(step: step)

                stepContent

                HStack(spacing: 10) {
                    Button {
                        step = step.previous
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(step == .chooseSource)

                    Button {
                        advance()
                    } label: {
                        Label(step == .startLibrary ? "Add Source" : "Next", systemImage: step == .startLibrary ? "externaldrive.badge.plus" : "chevron.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(step == .startLibrary && !canAddSource)
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 24)
        }
        .appScreenBackground()
        .navigationTitle("Add SMB Source")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .chooseSource:
            ChooseSourceStep(selectedDiscovery: $selectedDiscovery)
        case .connect:
            ConnectStep(
                host: $host,
                share: $share,
                username: $username,
                password: $password,
                workgroup: $workgroup,
                showAdvanced: $showAdvanced
            )
        case .test:
            TestStep(host: host, share: share, state: testState, isTesting: isTesting, action: testConnection)
        case .chooseRoots:
            ChooseRootsStep(rootPath: $rootPath)
        case .startLibrary:
            StartLibraryStep(host: host, share: share, rootPath: rootPath, testState: testState)
        }
    }

    private var canAddSource: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func advance() {
        guard step != .startLibrary else {
            environment.addSMBSource(
                host: host,
                share: share,
                username: username,
                rootPath: rootPath,
                isOnline: testState.isOnline
            )
            dismiss()
            return
        }

        step = step.next
    }

    private func testConnection() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedShare.isEmpty else {
            testState = .failure("Host and share are required.")
            return
        }

        isTesting = true
        testState = .notRun
        Task {
            let draft = SourceDraft(
                protocolKind: .smb,
                displayName: trimmedShare,
                endpoint: SourceEndpoint(hostDisplayName: trimmedHost, shareName: trimmedShare),
                username: username.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                domain: workgroup.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
}

private enum ConnectionTestState: Equatable {
    case notRun
    case success
    case failure(String)

    var isOnline: Bool {
        if case .success = self { return true }
        return false
    }
}

private enum SetupStep: String, CaseIterable, Identifiable {
    case chooseSource = "Choose"
    case connect = "Connect"
    case test = "Test"
    case chooseRoots = "Roots"
    case startLibrary = "Start"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chooseSource: "Choose Source"
        case .connect: "Connect"
        case .test: "Test"
        case .chooseRoots: "Choose Roots"
        case .startLibrary: "Start Library"
        }
    }

    var next: SetupStep {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index < all.index(before: all.endIndex) else {
            return self
        }
        return all[all.index(after: index)]
    }

    var previous: SetupStep {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > all.startIndex else {
            return self
        }
        return all[all.index(before: index)]
    }
}

private struct SetupProgressRail: View {
    var step: SetupStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(DesignTokens.textPrimary)

            HStack(spacing: 6) {
                ForEach(SetupStep.allCases) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule()
                            .fill(fill(for: item))
                            .frame(height: 4)
                        Text(item.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item == step ? DesignTokens.textPrimary : DesignTokens.textTertiary)
                    }
                }
            }
        }
    }

    private func fill(for item: SetupStep) -> Color {
        guard let itemIndex = SetupStep.allCases.firstIndex(of: item),
              let stepIndex = SetupStep.allCases.firstIndex(of: step)
        else { return DesignTokens.surfaceRaised }

        if itemIndex < stepIndex { return DesignTokens.connectionTeal }
        if itemIndex == stepIndex { return DesignTokens.brandPrimary }
        return DesignTokens.surfaceRaised
    }
}

private struct ChooseSourceStep: View {
    @Binding var selectedDiscovery: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manual SMB is enabled now. Real network discovery will be added later and must not show placeholder servers.")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)

            SetupOptionCard(
                title: "Manual SMB",
                subtitle: "Host, share, username, password, optional domain",
                systemImage: "server.rack",
                isSelected: selectedDiscovery == "Manual SMB",
                action: { selectedDiscovery = "Manual SMB" }
            )

            SetupOptionCard(
                title: "Network discovery",
                subtitle: "Disabled until real Bonjour/NetBIOS discovery is implemented",
                systemImage: "network",
                isSelected: false,
                isDisabled: true,
                action: {}
            )
        }
    }
}

private struct ConnectStep: View {
    @Binding var host: String
    @Binding var share: String
    @Binding var username: String
    @Binding var password: String
    @Binding var workgroup: String
    @Binding var showAdvanced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Credentials stay in Keychain on this device. Local Network permission lets Better Streaming find and connect to your NAS.")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)

            VStack(spacing: 12) {
                SetupTextField(title: "Host or IP", text: $host, systemImage: "network")
                SetupTextField(title: "Share", text: $share, systemImage: "folder")
                SetupTextField(title: "Username", text: $username, systemImage: "person")
                SetupSecureField(title: "Password", text: $password)

                DisclosureGroup(isExpanded: $showAdvanced) {
                    SetupTextField(title: "Domain or workgroup", text: $workgroup, systemImage: "building.2")
                } label: {
                    Text("More connection options")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                }
            }
            .padding(14)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }
}

private struct TestStep: View {
    var host: String
    var share: String
    var state: ConnectionTestState
    var isTesting: Bool
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Runs a real SMB login and share listing using the values you entered. No sample result is shown before the network call succeeds.")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)

            switch state {
            case .notRun:
                TestResultRow(label: "Connection", value: "Not tested", systemImage: "circle", tint: DesignTokens.textTertiary)
            case .success:
                TestResultRow(label: "Connection", value: "Online", systemImage: "checkmark.circle.fill", tint: DesignTokens.connectionTeal)
            case .failure(let message):
                TestResultRow(label: "Connection", value: message, systemImage: "exclamationmark.triangle.fill", tint: DesignTokens.error)
            }

            Button(action: action) {
                Label(isTesting ? "Testing..." : "Test Connection", systemImage: "network")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(isTesting || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct ChooseRootsStep: View {
    @Binding var rootPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter the folder path inside the SMB share to scan first. Leave it blank to scan the share root.")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)

            SetupTextField(title: "Root folder path", text: $rootPath, systemImage: "folder")
        }
    }
}

private struct StartLibraryStep: View {
    var host: String
    var share: String
    var rootPath: String
    var testState: ConnectionTestState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MediaArtwork(symbol: "folder.badge.plus", status: testState.isOnline ? .cached : .remoteOnly, size: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add source")
                        .font(.headline)
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text("This will add the SMB source to the local app state. Scanning and playback wiring are the next implementation step.")
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                TestResultRow(label: "Host", value: host.isEmpty ? "Required" : host, systemImage: "network", tint: host.isEmpty ? DesignTokens.error : DesignTokens.connectionTeal)
                TestResultRow(label: "Share", value: share.isEmpty ? "Required" : share, systemImage: "folder", tint: share.isEmpty ? DesignTokens.error : DesignTokens.connectionTeal)
                TestResultRow(label: "Root", value: rootPath.isEmpty ? "Share root" : rootPath, systemImage: "folder.badge.plus", tint: DesignTokens.brandPrimary)
                Text("No tracks, folders, albums, downloads, or playback rows are fabricated.")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .padding(14)
            .surfaceCard(fill: DesignTokens.surfaceRaised)
        }
        .padding(14)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }
}

private struct SetupOptionCard: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var isSelected: Bool
    var isDisabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(isSelected ? DesignTokens.brandPrimary : .clear)
                    .frame(width: 3)
                    .clipShape(Capsule())

                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(isDisabled ? DesignTokens.textTertiary : DesignTokens.brandPrimary)
                    .frame(width: 38, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isDisabled ? DesignTokens.textTertiary : DesignTokens.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignTokens.brandPrimary)
                }
            }
            .padding(12)
            .background(
                (isSelected ? DesignTokens.brandPrimary.opacity(0.08) : DesignTokens.surfaceCard),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct SetupTextField: View {
    var title: String
    @Binding var text: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 24)
            TextField(title, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(DesignTokens.textPrimary)
        }
        .padding(12)
        .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SetupSecureField: View {
    var title: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key")
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 24)
            SecureField(title, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(DesignTokens.textPrimary)
        }
        .padding(12)
        .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TestResultRow: View {
    var label: String
    var value: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            Spacer()
        }
        .padding(12)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }
}

private struct RootToggle: View {
    var title: String
    var path: String
    var kind: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(DesignTokens.textTertiary)
                StatusPill(label: kind, systemImage: "tag", tint: DesignTokens.connectionTeal)
                    .fixedSize()
            }
        }
        .toggleStyle(.switch)
        .tint(DesignTokens.brandPrimary)
        .padding(12)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#Preview {
    NavigationStack {
        SourceSetupView()
            .environmentObject(AppEnvironment())
    }
}
