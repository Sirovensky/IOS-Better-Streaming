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
        static let preamp = "audio.preampDB"
        static let eqEnabled = "audio.eq.enabled"
        static let eqBands = "audio.eq.bands"
        static let crossfade = "audio.crossfadeSeconds"
    }

    /// Centre frequencies for the EQ bands (Hz).
    static let eqFrequencies: [Double] = [60, 230, 910, 3600, 14000]

    var replayGainEnabled: Bool { didSet { defaults.set(replayGainEnabled, forKey: Keys.replayGain) } }
    /// Manual preamp in dB (−12…+12). Also used as the EQ make-up/preamp.
    var preampDB: Double { didSet { defaults.set(preampDB, forKey: Keys.preamp) } }
    var eqEnabled: Bool { didSet { defaults.set(eqEnabled, forKey: Keys.eqEnabled) } }
    /// Per-band gains in dB (−12…+12), one per `eqFrequencies` entry.
    var eqBandsDB: [Double] { didSet { defaults.set(eqBandsDB, forKey: Keys.eqBands) } }
    /// Crossfade duration in seconds (0 = off / hard cut).
    var crossfadeSeconds: Double { didSet { defaults.set(crossfadeSeconds, forKey: Keys.crossfade) } }

    var isActive: Bool { replayGainEnabled || eqEnabled || abs(preampDB) > 0.01 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        replayGainEnabled = defaults.bool(forKey: Keys.replayGain)
        preampDB = defaults.double(forKey: Keys.preamp)
        eqEnabled = defaults.bool(forKey: Keys.eqEnabled)
        if let saved = defaults.array(forKey: Keys.eqBands) as? [Double], saved.count == Self.eqFrequencies.count {
            eqBandsDB = saved
        } else {
            eqBandsDB = Array(repeating: 0, count: Self.eqFrequencies.count)
        }
        crossfadeSeconds = defaults.double(forKey: Keys.crossfade)
    }

    /// dB → linear amplitude.
    static func linear(fromDB db: Double) -> Float { Float(pow(10.0, db / 20.0)) }

    /// Parse a ReplayGain track-gain value (e.g. "-6.48 dB") from an AVAsset's
    /// metadata (TXXX:replaygain_track_gain / Vorbis REPLAYGAIN_TRACK_GAIN).
    static func replayGainDB(from metadata: [AVMetadataItem]) async -> Double? {
        for item in metadata {
            let key = (item.identifier?.rawValue ?? item.key?.description ?? "").lowercased()
            guard key.contains("replaygain_track_gain") || key.contains("replaygain_album_gain") else { continue }
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
