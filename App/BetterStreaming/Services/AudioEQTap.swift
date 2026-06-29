import Accelerate
import AVFoundation
import MediaToolbox

/// Builds an `AVAudioMix` that applies a multiband peaking EQ to an
/// `AVPlayerItem` via an `MTAudioProcessingTap`. Only used when the EQ is turned
/// on; default playback never attaches a tap. Defensive throughout: any
/// unexpected audio format or allocation failure makes the tap a pass-through
/// (audio untouched) rather than corrupting samples or crashing.
enum AudioEQTap {
    /// `bandsDB` is one gain per `AudioEnhancements.eqFrequencies`; `preampDB` is
    /// an overall make-up gain. Returns nil if a tap can't be created (caller
    /// then plays without EQ).
    static func makeAudioMix(bandsDB: [Double], preampDB: Double) -> AVAudioMix? {
        let context = EQContext(
            frequencies: AudioEnhancements.eqFrequencies,
            bandsDB: bandsDB,
            preampLinear: AudioEnhancements.linear(fromDB: preampDB)
        )

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            `init`: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        guard status == noErr, let tap else {
            // Creation failed → balance the retain we handed to clientInfo.
            Unmanaged<EQContext>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }

        let params = AVMutableAudioMixInputParameters()
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

/// Per-tap state: biquad coefficient setup (shared across channels) + per-channel
/// delay buffers that vDSP_biquad threads across callbacks.
private final class EQContext {
    let frequencies: [Double]
    let bandsDB: [Double]
    let preampLinear: Float

    var sampleRate: Double = 44_100
    var channelCount: Int = 0
    var isFloat = false
    var setup: vDSP_biquad_Setup?
    var delays: [[Float]] = []   // one [2*sections+2] buffer per channel
    var sections: Int = 0

    init(frequencies: [Double], bandsDB: [Double], preampLinear: Float) {
        self.frequencies = frequencies
        self.bandsDB = bandsDB
        self.preampLinear = preampLinear
    }

    /// Build the biquad cascade for the current sample rate.
    func buildSetup() {
        teardownSetup()
        var coeffs: [Double] = []
        let n = min(frequencies.count, bandsDB.count)
        for i in 0..<n where abs(bandsDB[i]) > 0.01 {
            coeffs.append(contentsOf: Self.peakingCoefficients(freq: frequencies[i], gainDB: bandsDB[i], q: 1.0, sampleRate: sampleRate))
        }
        sections = coeffs.count / 5
        guard sections > 0 else { setup = nil; return }
        setup = coeffs.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(sections))
        }
        // 2*sections + 2 delay values per channel.
        delays = Array(repeating: Array(repeating: 0, count: 2 * sections + 2), count: max(channelCount, 1))
    }

    func teardownSetup() {
        if let setup { vDSP_biquad_DestroySetup(setup) }
        setup = nil
        delays = []
        sections = 0
    }

    /// RBJ peaking-EQ biquad, normalized (a0 = 1): returns [b0,b1,b2,a1,a2].
    static func peakingCoefficients(freq: Double, gainDB: Double, q: Double, sampleRate: Double) -> [Double] {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let b0 = 1 + alpha * A
        let b1 = -2 * cosw
        let b2 = 1 - alpha * A
        let a0 = 1 + alpha / A
        let a1 = -2 * cosw
        let a2 = 1 - alpha / A
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
}

// MARK: - Tap callbacks (C function pointers — must not capture context)

private func tapInit(tap: MTAudioProcessingTap, clientInfo: UnsafeMutableRawPointer?, tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    // Move the retained context into tap storage (released in finalize).
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<EQContext>.fromOpaque(storage).release()
}

private func tapPrepare(tap: MTAudioProcessingTap, maxFrames: CMItemCount, processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    let context = Unmanaged<EQContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let asbd = processingFormat.pointee
    context.sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
    context.channelCount = Int(asbd.mChannelsPerFrame)
    // Only the canonical non-interleaved Float32 case is processed; anything else
    // passes through untouched.
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    context.isFloat = isFloat && nonInterleaved && asbd.mBitsPerChannel == 32
    if context.isFloat { context.buildSetup() }
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    let context = Unmanaged<EQContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.teardownSetup()
}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }

    let context = Unmanaged<EQContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let frames = vDSP_Length(numberFramesOut.pointee)
    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)

    // Apply preamp (cheap, always safe) then the biquad cascade per channel.
    for (index, buffer) in buffers.enumerated() {
        guard let raw = buffer.mData else { continue }
        let samples = raw.assumingMemoryBound(to: Float.self)
        if context.preampLinear != 1 {
            var gain = context.preampLinear
            vDSP_vsmul(samples, 1, &gain, samples, 1, frames)
        }
        if context.isFloat, let setup = context.setup, context.sections > 0, index < context.delays.count {
            context.delays[index].withUnsafeMutableBufferPointer { delay in
                vDSP_biquad(setup, delay.baseAddress!, samples, 1, samples, 1, frames)
            }
        }
    }
}
