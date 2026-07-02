import AVFoundation
import Foundation
import Observation

/// Opt-in audio tweaks. Everything defaults OFF so normal playback is untouched.
/// - ReplayGain + preamp: applied via `AVPlayer.volume` (attenuation-accurate;
///   boost is capped at 1.0 — the safe, tap-free path).
/// - Crossfade: handled by `PlaybackEngine` with a second player.
/// - EQ: a multiband peaking EQ applied through an `MTAudioProcessingTap` on the
///   item's audio mix. Only attached when enabled, so a tap bug can't affect
///   default playback.
@Observable
@MainActor
final class AudioEnhancements {
    private let defaults: UserDefaults
    private enum Keys {
        static let replayGain = "audio.replayGain.enabled"
        static let replayGainAlbumMode = "audio.replayGain.albumMode"
        static let preamp = "audio.preampDB"
        static let eqEnabled = "audio.eq.enabled"
        static let eqBands = "audio.eq.bands"
        static let crossfade = "audio.crossfadeSeconds"
        static let gapless = "audio.gapless.enabled"
    }

    /// Centre frequencies for the EQ bands (Hz). `nonisolated` so the EQ tap's
    /// real-time (nonisolated) callbacks can read it.
    nonisolated static let eqFrequencies: [Double] = [60, 230, 910, 3600, 14000]

    var replayGainEnabled: Bool { didSet { defaults.set(replayGainEnabled, forKey: Keys.replayGain) } }
    /// Album-gain mode: prefer the album ReplayGain tag over the per-track tag, so a
    /// record's tracks keep their relative loudness (the audiophile-correct choice
    /// for listening to a whole album). Falls back to track gain when no album tag.
    var replayGainAlbumMode: Bool { didSet { defaults.set(replayGainAlbumMode, forKey: Keys.replayGainAlbumMode) } }
    /// Manual preamp in dB (−12…+12). Also used as the EQ make-up/preamp.
    var preampDB: Double { didSet { defaults.set(preampDB, forKey: Keys.preamp) } }
    var eqEnabled: Bool { didSet { defaults.set(eqEnabled, forKey: Keys.eqEnabled) } }
    /// Per-band gains in dB (−12…+12), one per `eqFrequencies` entry.
    var eqBandsDB: [Double] { didSet { defaults.set(eqBandsDB, forKey: Keys.eqBands) } }
    /// Crossfade duration in seconds (0 = off / hard cut).
    var crossfadeSeconds: Double { didSet { defaults.set(crossfadeSeconds, forKey: Keys.crossfade) } }
    /// Gapless playback: preload the next track so it transitions with no gap.
    /// On by default. Only the next track when it's already local/cached is
    /// preloaded, so it never adds streaming contention.
    var gaplessEnabled: Bool { didSet { defaults.set(gaplessEnabled, forKey: Keys.gapless) } }

    var isActive: Bool { replayGainEnabled || eqEnabled || abs(preampDB) > 0.01 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        replayGainEnabled = defaults.bool(forKey: Keys.replayGain)
        replayGainAlbumMode = defaults.bool(forKey: Keys.replayGainAlbumMode)
        preampDB = defaults.double(forKey: Keys.preamp)
        eqEnabled = defaults.bool(forKey: Keys.eqEnabled)
        if let saved = defaults.array(forKey: Keys.eqBands) as? [Double], saved.count == Self.eqFrequencies.count {
            eqBandsDB = saved
        } else {
            eqBandsDB = Array(repeating: 0, count: Self.eqFrequencies.count)
        }
        crossfadeSeconds = defaults.double(forKey: Keys.crossfade)
        // Default ON (no stored value yet → true).
        gaplessEnabled = defaults.object(forKey: Keys.gapless) == nil ? true : defaults.bool(forKey: Keys.gapless)
    }

    /// dB → linear amplitude. `nonisolated` (pure) for the real-time tap.
    nonisolated static func linear(fromDB db: Double) -> Float { Float(pow(10.0, db / 20.0)) }

    /// Parse a ReplayGain value (e.g. "-6.48 dB") from an AVAsset's metadata
    /// (TXXX:replaygain_*_gain / Vorbis REPLAYGAIN_*_GAIN). In album mode the album
    /// tag is preferred (falling back to track gain), otherwise the track tag is
    /// preferred (falling back to album gain).
    static func replayGainDB(from metadata: [AVMetadataItem], preferAlbum: Bool = false) async -> Double? {
        let primary = preferAlbum ? "replaygain_album_gain" : "replaygain_track_gain"
        let fallback = preferAlbum ? "replaygain_track_gain" : "replaygain_album_gain"
        if let db = await gainValue(for: primary, in: metadata) { return db }
        return await gainValue(for: fallback, in: metadata)
    }

    private static func gainValue(for tag: String, in metadata: [AVMetadataItem]) async -> Double? {
        for item in metadata {
            let key = (item.identifier?.rawValue ?? item.key?.description ?? "").lowercased()
            guard key.contains(tag) else { continue }
            if let value = try? await item.load(.stringValue), let db = parseGainString(value) {
                return db
            }
        }
        return nil
    }

    static func parseGainString(_ raw: String) -> Double? {
        let token = raw.lowercased().replacingOccurrences(of: "db", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(token)
    }
}
