import SwiftUI
#if DEBUG
import AVFoundation
import BetterStreamingDomain
import Darwin
import LibraryIndexer
import RemoteFileSystem
import SMBRemote
#endif

@main
struct BetterStreamingApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if DevicePlaybackProbeView.isEnabled {
                DevicePlaybackProbeView()
                    .tint(DesignTokens.brandPrimary)
            } else {
                LaunchRootView()
                    .tint(DesignTokens.brandPrimary)
            }
            #else
            LaunchRootView()
                .tint(DesignTokens.brandPrimary)
            #endif
        }
    }
}

private struct LaunchRootView: View {
    @State private var model: AppModel?

    var body: some View {
        Group {
            if let model {
                RootTabView()
                    .environment(model)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(DesignTokens.brandPrimary)
                    ProgressView()
                        .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .appScreenBackground()
                .task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard model == nil else { return }
                    model = AppModel()
                }
            }
        }
    }
}

#if DEBUG
private struct DevicePlaybackProbeView: View {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--betterstreaming-playback-probe")
    }

    @State private var status = "Starting playback probe..."

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(DesignTokens.brandPrimary)
            Text(status)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignTokens.textPrimary)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appScreenBackground()
        .task {
            let exitCode = await DevicePlaybackProbe().run { message in
                status = message
            }
            fflush(stdout)
            fflush(stderr)
            exit(exitCode)
        }
    }
}

@MainActor
private final class DevicePlaybackProbe {
    private let player = AVPlayer()
    private let streamingService = RemoteStreamingService()
    private let streamCacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("BetterStreamingProbeRanges", isDirectory: true)

    func run(update: @escaping @MainActor (String) -> Void) async -> Int32 {
        print("BETTERSTREAMING_PROBE start")
        do {
            try configureAudioSession()
            try FileManager.default.createDirectory(at: streamCacheDir, withIntermediateDirectories: true)
            guard let source = ProbeSourceEnvironment.current else {
                throw ProbeError.noSources
            }

            update("Finding sample files...")
            let client = SMBRemoteClient(
                configuration: SMBConnectionConfiguration(
                    host: source.host,
                    port: source.port,
                    share: source.share,
                    username: source.username
                ),
                authentication: .password(username: source.username, password: source.password)
            )

            let connection = await client.testConnection()
            print("BETTERSTREAMING_PROBE connection=\(connection.state.rawValue)")
            guard connection.state == .online else {
                throw connection.failure ?? ProbeError.connectionFailed
            }

            let candidates = try await findCandidates(client: client, rootPath: source.rootPath, targetExtensions: source.targetExtensions)
            print("BETTERSTREAMING_PROBE candidates=\(candidates.map(\.label).joined(separator: ","))")
            guard !candidates.isEmpty else {
                throw ProbeError.noTracks
            }

            var passed = 0
            for candidate in candidates {
                update("Testing \(candidate.label)...")
                let result = await test(candidate, client: client)
                print(result.logLine)
                if result.passed { passed += 1 }
            }

            let missing = missingLabels(in: candidates)
            if !missing.isEmpty {
                print("BETTERSTREAMING_PROBE missing=\(missing.joined(separator: ","))")
            }

            guard passed == candidates.count else {
                throw ProbeError.playbackFailed
            }

            print("BETTERSTREAMING_PROBE pass tested=\(candidates.map(\.label).joined(separator: ","))")
            update("Playback probe passed")
            return EXIT_SUCCESS
        } catch {
            player.pause()
            print("BETTERSTREAMING_PROBE fail reason=\(String(describing: error))")
            update("Playback probe failed")
            return EXIT_FAILURE
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    private func findCandidates(
        client: SMBRemoteClient,
        rootPath: String,
        targetExtensions: [String]
    ) async throws -> [RemoteProbeCandidate] {
        let classifier = MediaFileClassifier()
        let filter = LibraryScanFilter()
        var foundByExtension: [String: RemoteProbeCandidate] = [:]
        var pending: [RemotePath] = [RemotePath(displayPath: rootPath)]
        var visited = Set<String>()
        var listedDirectories = 0

        while let dir = pending.first,
              listedDirectories < 240,
              foundByExtension.count < targetExtensions.count {
            pending.removeFirst()
            guard visited.insert(dir.normalizedPath).inserted else { continue }
            listedDirectories += 1
            let entries = try await client.list(dir)
                .filter { filter.shouldIndex($0) }
                .sortedDeterministically()

            for entry in entries where entry.kind == .file {
                let ext = (entry.name as NSString).pathExtension.lowercased()
                guard targetExtensions.contains(ext),
                      foundByExtension[ext] == nil,
                      classifier.classify(entry) != nil else {
                    continue
                }
                let metadata = try await client.stat(entry.path)
                foundByExtension[ext] = RemoteProbeCandidate(label: ext, entry: entry, metadata: metadata)
            }

            for entry in entries where entry.kind == .directory {
                if pending.count < 800 {
                    pending.append(entry.path)
                }
            }
        }

        let ordered = targetExtensions.compactMap { foundByExtension[$0] }
        print("BETTERSTREAMING_PROBE listedDirectories=\(listedDirectories)")
        return ordered
    }

    private func missingLabels(in candidates: [RemoteProbeCandidate]) -> [String] {
        let labels = Set(candidates.map(\.label))
        var missing: [String] = []
        for ext in ["mp3", "m4a", "flac"] where !labels.contains(ext) {
            missing.append(ext)
        }
        if labels.isDisjoint(with: ["mp4", "mkv", "mov"]) {
            missing.append("video")
        }
        return missing
    }

    private func test(_ candidate: RemoteProbeCandidate, client: SMBRemoteClient) async -> ProbeResult {
        let start = Date()
        let probeKey = Self.stableHash(candidate.entry.path.normalizedPath)
        let item = streamingService.playerItem(
            client: client,
            path: candidate.entry.path,
            metadata: candidate.metadata,
            fallbackExtension: candidate.label,
            partialCacheURL: streamCacheDir.appendingPathComponent(probeKey + ".part"),
            completeCacheURL: streamCacheDir.appendingPathComponent(probeKey + ".complete")
        )

        player.replaceCurrentItem(with: item)
        player.play()

        let started = await wait(timeout: 20) {
            item.status == .readyToPlay
                && (self.player.timeControlStatus == .playing || self.player.currentTime().seconds > 0.05)
        }
        let latency = Date().timeIntervalSince(start)
        guard started else {
            let status = item.status == .failed ? "item_failed" : "start_timeout"
            let diagnostics = await diagnostics(for: item)
            return ProbeResult(label: candidate.label, passed: false, detail: "\(status) latency=\(Self.format(latency)) \(diagnostics)")
        }

        let seekOK = await seekIfPossible(item)
        player.pause()
        player.replaceCurrentItem(with: nil)
        return ProbeResult(
            label: candidate.label,
            passed: true,
            detail: "latency=\(Self.format(latency)) seek=\(seekOK ? "ok" : "skipped")"
        )
    }

    private func seekIfPossible(_ item: AVPlayerItem) async -> Bool {
        let duration = (try? await item.asset.load(.duration).seconds) ?? item.duration.seconds
        guard duration.isFinite, duration > 20 else { return false }
        let target = min(max(duration * 0.1, 8), 30)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
        return await wait(timeout: 8) {
            abs(self.player.currentTime().seconds - target) < 4
        }
    }

    private func wait(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    private func diagnostics(for item: AVPlayerItem) async -> String {
        var parts: [String] = [
            "itemStatus=\(item.status.rawValue)",
            "timeControl=\(player.timeControlStatus.rawValue)",
            "reason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")"
        ]
        if let error = item.error {
            parts.append("itemError=\(error.localizedDescription)")
        }
        if let event = item.errorLog()?.events.last {
            parts.append("errorLog=\(event.errorStatusCode):\(event.errorComment ?? "none")")
        }
        if let playable = try? await item.asset.load(.isPlayable) {
            parts.append("assetPlayable=\(playable)")
        }
        if let readable = try? await item.asset.load(.isReadable) {
            parts.append("assetReadable=\(readable)")
        }
        return parts.joined(separator: " ")
    }

    private static func format(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

private struct RemoteProbeCandidate {
    var label: String
    var entry: RemoteEntry
    var metadata: RemoteMetadata
}

private struct ProbeResult {
    var label: String
    var passed: Bool
    var detail: String

    var logLine: String {
        "BETTERSTREAMING_PROBE item label=\(label) result=\(passed ? "pass" : "fail") \(detail)"
    }
}

private enum ProbeError: Error {
    case noSources
    case noTracks
    case connectionFailed
    case playbackFailed
}

private struct ProbeSourceEnvironment {
    var host: String
    var port: Int
    var share: String
    var rootPath: String
    var username: String
    var password: String
    var targetExtensions: [String]

    static var current: ProbeSourceEnvironment? {
        let env = ProcessInfo.processInfo.environment
        guard let host = clean(env["BETTERSTREAMING_PROBE_SMB_HOST"]),
              let share = clean(env["BETTERSTREAMING_PROBE_SMB_SHARE"]),
              let username = clean(env["BETTERSTREAMING_PROBE_SMB_USERNAME"]),
              let password = env["BETTERSTREAMING_PROBE_SMB_PASSWORD"],
              !password.isEmpty else {
            return nil
        }
        return ProbeSourceEnvironment(
            host: host,
            port: Int(env["BETTERSTREAMING_PROBE_SMB_PORT"] ?? "") ?? SourceProtocol.smb.defaultPort,
            share: share,
            rootPath: clean(env["BETTERSTREAMING_PROBE_SMB_ROOT"]) ?? "/",
            username: username,
            password: password,
            targetExtensions: clean(env["BETTERSTREAMING_PROBE_FORMATS"])?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
                ?? ["mp3", "m4a", "flac", "mp4", "mkv", "mov"]
        )
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
