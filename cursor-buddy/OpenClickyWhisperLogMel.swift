//
//  OpenClickyWhisperLogMel.swift
//  cursor-buddy
//
//  Whisper log-mel front-end, in Accelerate. Feeds smart-turn-v3, which
//  wants [80 mel bins x 800 frames] from 8 s of 16 kHz mono audio.
//
//  The ONNX half of end-of-turn detection is trivial — the app already
//  runs ORT for the intent classifier. This file is the actual work: if
//  the mel features are subtly wrong the model still returns confident
//  numbers, they are just meaningless. Every step below has a specific
//  wrong-looking-but-plausible alternative, and each one is called out.
//
//  Verified numerically against parlor's Python reference
//  (`compute_whisper_log_mel_features`) rather than by inspection — see
//  scripts/verify-logmel.sh.
//
//  Reference: docs/parlor-integration-research/04-smart-turn-port-plan.md
//

import Accelerate
import Foundation

enum OpenClickyWhisperLogMel {

    static let sampleRate = 16_000
    static let nFFT = 400
    static let hopLength = 160
    static let melBins = 80
    /// Frames the model expects. The STFT produces 801; the last is dropped.
    static let frames = 800
    /// 8 s at 16 kHz.
    static let expectedSamples = 128_000

    private static let nBins = nFFT / 2 + 1     // 201

    // MARK: - Precomputed

    /// PERIODIC Hann — `np.hanning(401)[:-1]`, i.e. `0.5 - 0.5cos(2πn/400)`.
    ///
    /// `vDSP_hann_window(..., vDSP_HANN_DENORM)` produces the SYMMETRIC
    /// variant, which is a different window and silently shifts every bin.
    /// Built explicitly for that reason.
    private static let hann: [Float] = (0..<nFFT).map {
        0.5 - 0.5 * cos(2.0 * Float.pi * Float($0) / Float(nFFT))
    }

    /// Slaney-scale mel filterbank, [80][201], row-major.
    private static let filterbank: [Float] = buildSlaneyFilterbank()

    /// Twiddle factors for a direct 400-point DFT, [bin][sample].
    ///
    /// Neither Accelerate route works here, and the port plan is wrong about
    /// this — checked empirically (`vDSP_DFT_zop_CreateSetup` returns nil for
    /// 400, 800 and 1200; it accepts 320, 480, 512, 640, so the rule is
    /// f·2^n with f in {1,3,5,15}, not "factors into 2/3/5"). And zero-
    /// padding to a 512-point transform is genuinely different: it changes
    /// the bin centres, so the mel projection would sample the wrong
    /// frequencies.
    ///
    /// So: compute the 201 needed bins directly. O(201·400) per frame is
    /// ~80k multiply-adds, and `cblas_sgemv` does it as two matrix-vector
    /// products. Measured fast enough — see the timing in the verifier.
    private static let dftReal: [Float] = {
        var table = [Float](repeating: 0, count: nBins * nFFT)
        for bin in 0..<nBins {
            for n in 0..<nFFT {
                table[bin * nFFT + n] = cos(-2.0 * Float.pi * Float(bin) * Float(n) / Float(nFFT))
            }
        }
        return table
    }()

    private static let dftImag: [Float] = {
        var table = [Float](repeating: 0, count: nBins * nFFT)
        for bin in 0..<nBins {
            for n in 0..<nFFT {
                table[bin * nFFT + n] = sin(-2.0 * Float.pi * Float(bin) * Float(n) / Float(nFFT))
            }
        }
        return table
    }()

    // MARK: - Public

    /// Compute features for exactly `expectedSamples` of mono float audio in
    /// [-1, 1]. Returns 80*800 floats, mel-major (bin 0's 800 frames first),
    /// which is the layout the ONNX input wants.
    ///
    /// Returns nil on the wrong sample count rather than padding: silently
    /// accepting a short buffer would make the model judge a window that is
    /// mostly zeros, and answer confidently about it.
    static func features(from samples: [Float]) -> [Float]? {
        guard samples.count == expectedSamples else { return nil }

        // Zero-mean, unit-variance the WAVEFORM first.
        //
        // `transformers`' do_normalize=True, and the port plan omits it
        // entirely — which cost a debugging cycle: without it every output
        // value is off by a uniform ~0.21, because the whole spectrogram
        // shifts and the global max used for the dynamic-range clamp shifts
        // with it. A constant offset across all 80x800 values looks like a
        // scaling bug in the final chain, not a missing step at the very
        // start.
        var normalized = samples
        var mean: Float = 0
        vDSP_meanv(normalized, 1, &mean, vDSP_Length(normalized.count))
        var negativeMean = -mean
        vDSP_vsadd(normalized, 1, &negativeMean, &normalized, 1, vDSP_Length(normalized.count))

        // Population variance (divide by N), matching numpy's `var()`.
        // Bessel's correction would be a different number.
        var sumOfSquares: Float = 0
        vDSP_svesq(normalized, 1, &sumOfSquares, vDSP_Length(normalized.count))
        let variance = sumOfSquares / Float(normalized.count)
        var inverseStdDev = 1.0 / sqrt(variance + 1e-7)
        vDSP_vsmul(normalized, 1, &inverseStdDev, &normalized, 1, vDSP_Length(normalized.count))

        let samples = normalized

        // Reflect padding, 200 each side. NOT symmetric padding: reflect
        // gives padded[199] == x[1] and padded[200] == x[0], symmetric would
        // give padded[199] == x[0]. An off-by-one here shifts every frame.
        let pad = nFFT / 2
        var padded = [Float](repeating: 0, count: samples.count + 2 * pad)
        for i in 0..<pad {
            // Left wing counts DOWN into the signal: padded[0] = x[200],
            // padded[199] = x[1], padded[200] = x[0].
            padded[i] = samples[pad - i]
            // Right wing mirrors about the LAST sample and reads forward
            // from there: padded[len-200] = x[n-2], ... padded[len-1] =
            // x[n-201]. Writing it as `padded[len-1-i] = x[n-2-i]` produces
            // the same 200 values in the opposite order — which still has
            // the correct min, max and mean, so only the final frame's
            // spectrum differs and 79913 of 80000 outputs still match.
            padded[pad + samples.count + i] = samples[samples.count - 2 - i]
        }
        padded.replaceSubrange(pad..<(pad + samples.count), with: samples)

        // STFT over ALL 801 windows.
        //
        // The reference computes 801 and then slices `log_spec[:, :-1]`.
        // Computing only the first 800 is NOT the same: the mel projection
        // and the log are per-element so they do not care, but everything
        // after depends on frame 800 existing — and, more subtly, the frame
        // at index 799 is only correct if the buffer was framed the same
        // way. Compute all 801, drop the last at the end.
        let totalFrames = (padded.count - nFFT) / hopLength + 1
        var power = [Float](repeating: 0, count: nBins * totalFrames)

        var windowed = [Float](repeating: 0, count: nFFT)
        var realOut = [Float](repeating: 0, count: nBins)
        var imagOut = [Float](repeating: 0, count: nBins)

        for frame in 0..<totalFrames {
            let start = frame * hopLength
            padded.withUnsafeBufferPointer { buffer in
                vDSP_vmul(buffer.baseAddress! + start, 1, hann, 1, &windowed, 1, vDSP_Length(nFFT))
            }

            // Real input, so Re{X} = cos-table · x and Im{X} = sin-table · x.
            dftReal.withUnsafeBufferPointer { re in
                cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(nBins), Int32(nFFT),
                            1.0, re.baseAddress, Int32(nFFT), windowed, 1, 0.0, &realOut, 1)
            }
            dftImag.withUnsafeBufferPointer { im in
                cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(nBins), Int32(nFFT),
                            1.0, im.baseAddress, Int32(nFFT), windowed, 1, 0.0, &imagOut, 1)
            }

            // |X|^2 as re² + im². Not `vDSP_zvabs` then square — that is a
            // sqrt followed by a squaring, which costs precision for nothing.
            for bin in 0..<nBins {
                let re = realOut[bin], im = imagOut[bin]
                power[bin * totalFrames + frame] = re * re + im * im
            }
        }

        // Mel projection: [80 x 201] · [201 x 801].
        var wide = [Float](repeating: 0, count: melBins * totalFrames)
        filterbank.withUnsafeBufferPointer { fb in
            power.withUnsafeBufferPointer { pw in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                            Int32(melBins), Int32(totalFrames), Int32(nBins),
                            1.0, fb.baseAddress, Int32(nBins),
                            pw.baseAddress, Int32(totalFrames),
                            0.0, &wide, Int32(totalFrames))
            }
        }

        // log10(max(x, 1e-10)) on all 801, then drop the trailing frame —
        // in that order. The global max below must be taken over the 800
        // that survive, not the 801 computed.
        var floorFirst: Float = 1e-10
        vDSP_vthr(wide, 1, &floorFirst, &wide, 1, vDSP_Length(wide.count))
        var wideCount = Int32(wide.count)
        vvlog10f(&wide, wide, &wideCount)

        var mel = [Float](repeating: 0, count: melBins * frames)
        for bin in 0..<melBins {
            let source = bin * totalFrames
            let destination = bin * frames
            for frame in 0..<frames {
                mel[destination + frame] = wide[source + frame]
            }
        }

        // Dynamic-range clamp against the GLOBAL maximum over all 80x800 —
        // not a per-frame maximum. Using a per-frame max would normalise
        // each column independently and destroy the loudness contour the
        // model reads.
        var globalMax: Float = 0
        vDSP_maxv(mel, 1, &globalMax, vDSP_Length(mel.count))
        var floorLevel = globalMax - 8.0
        vDSP_vthr(mel, 1, &floorLevel, &mel, 1, vDSP_Length(mel.count))

        // (x + 4) / 4
        var offset: Float = 4.0
        var scale: Float = 0.25
        vDSP_vsadd(mel, 1, &offset, &mel, 1, vDSP_Length(mel.count))
        vDSP_vsmul(mel, 1, &scale, &mel, 1, vDSP_Length(mel.count))

        return mel
    }

    // MARK: - Filterbank

    private static func hertzToMelSlaney(_ hz: Float) -> Float {
        let minLogHertz: Float = 1000.0
        let minLogMel: Float = 15.0
        let logstep: Float = 27.0 / log(6.4)
        if hz >= minLogHertz {
            return minLogMel + log(hz / minLogHertz) * logstep
        }
        return 3.0 * hz / 200.0
    }

    private static func melToHertzSlaney(_ mel: Float) -> Float {
        let minLogHertz: Float = 1000.0
        let minLogMel: Float = 15.0
        let logstep: Float = log(6.4) / 27.0
        if mel >= minLogMel {
            return minLogHertz * exp(logstep * (mel - minLogMel))
        }
        return 200.0 * mel / 3.0
    }

    /// Slaney-normalised triangular filterbank, matching
    /// `transformers.audio_utils.mel_filter_bank(norm="slaney")`.
    private static func buildSlaneyFilterbank() -> [Float] {
        let fftFreqs = (0..<nBins).map { Float($0) * Float(sampleRate) / Float(nFFT) }

        let melMin = hertzToMelSlaney(0)
        let melMax = hertzToMelSlaney(Float(sampleRate) / 2)
        let melPoints = (0...(melBins + 1)).map {
            melMin + (melMax - melMin) * Float($0) / Float(melBins + 1)
        }
        let filterFreqs = melPoints.map(melToHertzSlaney)

        var bank = [Float](repeating: 0, count: melBins * nBins)
        for m in 0..<melBins {
            let left = filterFreqs[m], centre = filterFreqs[m + 1], right = filterFreqs[m + 2]
            // Slaney normalisation: each filter has unit AREA, not unit peak.
            // Dropping this leaves high-frequency bins far too loud.
            let enorm = 2.0 / (right - left)
            for (bin, freq) in fftFreqs.enumerated() {
                let rising = (freq - left) / (centre - left)
                let falling = (right - freq) / (right - centre)
                let value = max(0, min(rising, falling))
                bank[m * nBins + bin] = value * enorm
            }
        }
        return bank
    }
}
