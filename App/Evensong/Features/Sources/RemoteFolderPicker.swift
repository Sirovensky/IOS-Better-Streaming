import SwiftUI

/// Live folder browser used during source setup: after host+credentials, walk
/// the share with `RemoteFileSystemClient.list` and tap a folder to set the scan
/// root (e.g. share "Media" -> subfolder "Music"). Protocol-neutral.
struct RemoteFolderPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let proto: SourceProtocol
    let host: String
    let port: Int?
    let share: String
    let username: String?
    let domain: String?
    let password: String?
    var onSelect: (String) -> Void

    @State private var path = "/"
    @State private var folders: [RemoteFolder] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if path != "/" {
                        Button {
                            path = Self.parent(of: path)
                        } label: {
                            Label("Up", systemImage: "arrow.up.left")
                        }
                    }
                    if isLoading {
                        HStack { ProgressView(); Text("Loading…").foregroundStyle(DesignTokens.textSecondary) }
                    } else if let error {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(DesignTokens.error)
                            Button("Try again") { Task { await load() } }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DesignTokens.brandPrimary)
                        }
                    } else if folders.isEmpty {
                        Text("No sub-folders here.").foregroundStyle(DesignTokens.textSecondary)
                    } else {
                        ForEach(folders) { folder in
                            Button {
                                path = folder.path
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill").foregroundStyle(DesignTokens.brandPrimary)
                                    Text(folder.name).foregroundStyle(DesignTokens.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(DesignTokens.textTertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(path == "/" ? "\(share)" : path)
                        .font(.caption.monospaced())
                }
            }
            .navigationTitle("Choose folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Scan here") {
                        onSelect(path)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(isLoading || error != nil)
                }
            }
            .task(id: path) { await load() }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        let result = await model.browseFolders(
            proto: proto, host: host, port: port, share: share,
            username: username, domain: domain, password: password, path: path
        )
        isLoading = false
        switch result {
        case .success(let list):
            folders = list
        case .failure(let err):
            folders = []
            error = err.message
        }
    }

    private static func parent(of path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).dropLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }
}
