import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var shareConfig: SharedSourceConfig?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if model.sources.isEmpty {
                    NavigationLink { SourceSetupView() } label: {
                        AppEmptyState(
                            title: "No sources yet",
                            detail: "Add an SMB, WebDAV, FTP, or SFTP server to start building your library.",
                            systemImage: "externaldrive.badge.plus"
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(model.sources) { source in
                        sourceCard(source)
                    }
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SourceSetupView() } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $shareConfig) { config in
            SourceShareView(shared: config)
        }
    }

    private func sourceCard(_ source: LibrarySource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: source.proto.glyph)
                    .font(.title3)
                    .foregroundStyle(DesignTokens.brandPrimary)
                    .frame(width: 44, height: 44)
                    .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.headline).foregroundStyle(DesignTokens.textPrimary).lineLimit(1)
                    Text(source.detail).font(.caption).foregroundStyle(DesignTokens.textSecondary).lineLimit(1)
                }
                Spacer()
                SourceHealthPill(health: source.health)
            }

            HStack {
                metric("\(source.trackCount)", "songs")
                Divider().frame(height: 28).overlay(DesignTokens.borderSubtle.opacity(0.1))
                metric("\(source.folderCount)", "folders")
                Divider().frame(height: 28).overlay(DesignTokens.borderSubtle.opacity(0.1))
                metric(source.sizeLabel, "on server")
            }

            HStack {
                Text(source.lastScanLabel).font(.caption).foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                Button {
                    Task { await model.rescan(source.id) }
                } label: {
                    Label("Rescan", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .disabled(model.isScanning)
                Menu {
                    Button("Rescan", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.rescan(source.id) }
                    }
                    if let config = model.exportableSource(source.id) {
                        Button("Share configuration", systemImage: "square.and.arrow.up") {
                            shareConfig = config
                        }
                    }
                    Button("Remove source", systemImage: "trash", role: .destructive) {
                        model.removeSource(source.id)
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(DesignTokens.textSecondary).frame(width: 30, height: 30)
                }
            }
        }
        .padding(14)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(DesignTokens.textPrimary)
            Text(label).font(.caption2).foregroundStyle(DesignTokens.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Share a source's connection config to another device via a QR code or a
/// `.bettersource` file. The password is never included — the other device
/// re-enters it on import (see SourceSetupView's "Import from file").
struct SourceShareView: View {
    @Environment(\.dismiss) private var dismiss
    let shared: SharedSourceConfig

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Text("Scan this on another device, or share the file. Your password is never included — you'll re-enter it on the other device.")
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if let qr = Self.qrImage(for: shared) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260)
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityLabel("QR code for \(shared.name)")
                    }

                    VStack(spacing: 4) {
                        Text(shared.name).font(.headline).foregroundStyle(DesignTokens.textPrimary)
                        Text("\(shared.proto) · \(shared.host)")
                            .font(.caption).foregroundStyle(DesignTokens.textSecondary)
                    }

                    if let file = Self.exportFile(for: shared) {
                        ShareLink(item: file) {
                            Label("Share File", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    }
                }
                .padding(DesignTokens.phonePadding)
            }
            .appScreenBackground()
            .navigationTitle("Share Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    static func qrImage(for shared: SharedSourceConfig) -> UIImage? {
        guard let data = try? JSONEncoder().encode(shared) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Write the config to a temp `.bettersource` JSON file for ShareLink.
    static func exportFile(for shared: SharedSourceConfig) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(shared) else { return nil }
        let safeName = shared.name.isEmpty ? "source" : shared.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).bettersource")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
