import Foundation
import AVFoundation
import Accelerate

// MARK: - Result

/// Bass features for a whole song, sampled every `hop` seconds.
struct BassAnalysis: Sendable {
    struct Bar: Sendable {
        let level: Float
        let sharpness: Float
    }

    let hop: Double
    let duration: Double
    /// 0...1 – how loud the bass (20–150 Hz) is, relative to the loud parts of this song.
    let level: [Float]
    /// Dominant bass frequency in Hz.
    let frequency: [Float]
    /// 0...1 – frequency mapped to haptic sharpness (<= 30 Hz -> 0, >= 100 Hz -> 1).
    let sharpness: [Float]

    /// Linearly interpolated values at `time` (seconds).
    func sample(at time: Double) -> (level: Float, frequency: Float, sharpness: Float) {
        guard level.count > 1, time.isFinite else { return (0, 0, 0) }
        let pos = max(0, time) / hop
        let i0 = min(Int(pos), level.count - 1)
        let i1 = min(i0 + 1, level.count - 1)
        let f = Float(min(max(pos - Double(i0), 0), 1))
        return (level[i0] + (level[i1] - level[i0]) * f,
                frequency[i0] + (frequency[i1] - frequency[i0]) * f,
                sharpness[i0] + (sharpness[i1] - sharpness[i0]) * f)
    }

    /// Condensed overview (peak of each bucket) for drawing.
    func bars(count: Int) -> [Bar] {
        let n = level.count
        guard n > 0, count > 0 else { return [] }
        var result: [Bar] = []
        result.reserveCapacity(count)
        for b in 0..<count {
            let start = min(b * n / count, n - 1)
            let end = min(n, max(start + 1, (b + 1) * n / count))
            var peak: Float = -1
            var sharp: Float = 0
            for i in start..<end where level[i] > peak {
                peak = level[i]
                sharp = sharpness[i]
            }
            result.append(Bar(level: max(peak, 0), sharpness: sharp))
        }
        return result
    }
}

// MARK: - Analyzer

enum BassAnalyzer {
    enum AnalysisError: LocalizedError {
        case unreadable(String)
        case tooShort

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason): return "This audio file couldn't be read. \(reason)"
            case .tooShort: return "This audio file is too short to analyse."
            }
        }
    }

    // MARK: Tunables

    /// Audio is low-passed and reduced to roughly this sample rate before analysis.
    static let analysisRate = 3000.0
    static let antiAliasCutoff = 800.0
    static let antiAliasQ: [Double] = [0.5098, 0.6013, 0.8999, 2.5629]   // 8th-order Butterworth
    /// The "bass" band.
    static let bandLow = 20.0
    static let bandHigh = 150.0
    static let lowpassQ: [Double] = [0.5412, 1.3066]                    // 4th-order Butterworth
    static let highpassQ = 0.70710678
    /// Frequency-estimator resolution.
    static let binSpacing = 3.0
    static let frameLength = 512
    /// One analysis frame every 10 ms.
    static let hopSeconds = 0.010
    static let levelWindowSeconds = 0.040
    /// Bass quieter than this many dB below the song's loud bass counts as silence.
    static let levelRangeDB = 30.0
    static let releaseSeconds = 0.060
    /// Sharpness is 0 at or below this frequency ...
    static let sharpnessLowHz = 30.0
    /// ... and 1 at or above this one (log-frequency in between).
    static let sharpnessHighHz = 100.0

    // MARK: Entry point

    /// Blocking – call from a background queue. `progress` receives 0...1.
    static func analyze(url: URL, progress: (Double) -> Void) throws -> BassAnalysis {
        let decoded = try readDecimated(url: url, progress: progress)
        let rate = decoded.rate
        let x = decoded.samples
        guard x.count > Int(rate) / 4 else { throw AnalysisError.tooShort }

        // 1. Keep only the bass band (about 20-150 Hz).
        var stages: [Biquad] = [Biquad.highpass(cutoff: bandLow, rate: rate, q: highpassQ)]
        for q in lowpassQ { stages.append(Biquad.lowpass(cutoff: bandHigh, rate: rate, q: q)) }
        var bandpass = Cascade(stages: stages)
        var y = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count { y[i] = Float(bandpass.process(Double(x[i]))) }

        let hopSamples = max(1, Int((rate * hopSeconds).rounded()))
        let hop = Double(hopSamples) / rate
        let frames = y.count / hopSamples + 1

        // 2. Loudness: RMS of the bass band over a short sliding window.
        var cumulative = [Double](repeating: 0, count: y.count + 1)
        for i in 0..<y.count {
            let v = Double(y[i])
            cumulative[i + 1] = cumulative[i] + v * v
        }
        let window = max(2, Int((rate * levelWindowSeconds).rounded()))
        var rms = [Float](repeating: 0, count: frames)
        for m in 0..<frames {
            let centre = m * hopSamples
            let a = max(0, centre - window / 2)
            let b = min(y.count, centre + window / 2)
            if b > a {
                let meanSquare = max(0, (cumulative[b] - cumulative[a]) / Double(b - a))
                rms[m] = Float(meanSquare.squareRoot())
            }
        }

        // 3. Dominant bass frequency: Hann-windowed DFT of the bass band, per frame.
        //    The frequency is the centre of gravity of the (squared) power spectrum, which
        //    follows the strongest bass note smoothly instead of jumping between harmonics.
        var binFrequencies: [Double] = []
        var f = bandLow
        while f <= bandHigh + 0.001 {
            binFrequencies.append(f)
            f += binSpacing
        }
        let bins = binFrequencies.count
        let L = frameLength

        let cosTable = UnsafeMutablePointer<Float>.allocate(capacity: bins * L)
        let sinTable = UnsafeMutablePointer<Float>.allocate(capacity: bins * L)
        let frame = UnsafeMutablePointer<Float>.allocate(capacity: L)
        cosTable.initialize(repeating: 0, count: bins * L)
        sinTable.initialize(repeating: 0, count: bins * L)
        frame.initialize(repeating: 0, count: L)
        defer {
            cosTable.deallocate()
            sinTable.deallocate()
            frame.deallocate()
        }
        for k in 0..<bins {
            let omega = 2.0 * Double.pi * binFrequencies[k] / rate
            for n in 0..<L {
                let hann = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(n) / Double(L))
                cosTable[k * L + n] = Float(hann * cos(omega * Double(n)))
                sinTable[k * L + n] = Float(hann * sin(omega * Double(n)))
            }
        }

        var centroid = [Float](repeating: Float(bandLow), count: frames)
        var lastValid = Float(bandLow)
        for m in 0..<frames {
            let start = m * hopSamples - L / 2
            for n in 0..<L {
                let idx = start + n
                frame[n] = (idx >= 0 && idx < y.count) ? y[idx] : 0
            }
            var numerator = 0.0
            var denominator = 0.0
            for k in 0..<bins {
                var re: Float = 0
                var im: Float = 0
                vDSP_dotpr(frame, 1, cosTable + k * L, 1, &re, vDSP_Length(L))
                vDSP_dotpr(frame, 1, sinTable + k * L, 1, &im, vDSP_Length(L))
                let power = Double(re) * Double(re) + Double(im) * Double(im)
                let weight = power * power
                numerator += binFrequencies[k] * weight
                denominator += weight
            }
            if denominator > 1e-20 { lastValid = Float(numerator / denominator) }
            centroid[m] = lastValid
            if m % 500 == 0 { progress(0.35 + 0.65 * Double(m) / Double(frames)) }
        }

        // 4. Loudness in dB relative to the song's loud bass, 0...1, with a short release
        //    so the vibration doesn't flutter between beats.
        let audible = rms.filter { $0 > 1e-9 }.sorted()
        var level = [Float](repeating: 0, count: frames)
        if !audible.isEmpty {
            let reference = Double(audible[min(audible.count - 1, Int(Double(audible.count) * 0.98))])
            if reference > 1e-7 {
                let release = exp(-hop / releaseSeconds)
                var previous = 0.0
                for m in 0..<frames {
                    let ratio = max(Double(rms[m]) / reference, 1e-6)
                    let db = 20.0 * log10(ratio)
                    let norm = min(max((db + levelRangeDB) / levelRangeDB, 0), 1)
                    let value = max(norm, previous * release)
                    level[m] = Float(value)
                    previous = value
                }
            }
        }

        // 5. Smooth the frequency (louder frames count more) and map it to sharpness.
        let lowLog = log(sharpnessLowHz)
        let highLog = log(sharpnessHighHz)
        var frequency = [Float](repeating: 0, count: frames)
        var sharpness = [Float](repeating: 0, count: frames)
        for m in 0..<frames {
            var num: Float = 0
            var den: Float = 0
            for j in max(0, m - 3)...min(frames - 1, m + 3) {
                let w = level[j] + 0.001
                num += w * centroid[j]
                den += w
            }
            let hz = num / den
            frequency[m] = hz
            let s = (log(max(Double(hz), 1.0)) - lowLog) / (highLog - lowLog)
            sharpness[m] = Float(min(max(s, 0), 1))
        }

        progress(1)
        return BassAnalysis(hop: hop, duration: decoded.duration,
                            level: level, frequency: frequency, sharpness: sharpness)
    }

    // MARK: Decoding

    /// Decodes any audio file AVFoundation can read (MP3, M4A, WAV, ...) to mono and
    /// reduces it to about `analysisRate` Hz. Reports 0...0.35 of the total progress.
    private static func readDecimated(url: URL, progress: (Double) -> Void) throws
        -> (samples: [Float], rate: Double, duration: Double) {

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AnalysisError.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let total = file.length
        guard total > 0, channels > 0, sampleRate > 0 else { throw AnalysisError.tooShort }

        let decimation = max(1, Int((sampleRate / analysisRate).rounded()))
        let outRate = sampleRate / Double(decimation)

        var stages: [Biquad] = []
        for q in antiAliasQ {
            stages.append(Biquad.lowpass(cutoff: antiAliasCutoff, rate: sampleRate, q: q))
        }
        var antiAlias = Cascade(stages: stages)

        let chunk: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AnalysisError.unreadable("Not enough memory.")
        }

        var out: [Float] = []
        out.reserveCapacity(Int(total) / decimation + 16)
        var phase = 0
        var lastReported = 0.0
        let scale = 1.0 / Double(channels)

        while file.framePosition < total {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var mono = 0.0
                for c in 0..<channels { mono += Double(data[c][i]) }
                let filtered = antiAlias.process(mono * scale)
                phase += 1
                if phase == decimation {
                    phase = 0
                    out.append(Float(filtered))
                }
            }
            let done = Double(file.framePosition) / Double(total)
            if done - lastReported >= 0.01 {
                lastReported = done
                progress(0.35 * done)
            }
        }
        return (out, outRate, Double(total) / sampleRate)
    }
}

// MARK: - Filters (RBJ biquads, Butterworth cascades)

fileprivate struct Biquad {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
    var z1 = 0.0
    var z2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func lowpass(cutoff: Double, rate: Double, q: Double) -> Biquad {
        let w0 = 2.0 * Double.pi * cutoff / rate
        let c = cos(w0)
        let alpha = sin(w0) / (2.0 * q)
        let a0 = 1.0 + alpha
        return Biquad(b0: (1.0 - c) / 2.0 / a0, b1: (1.0 - c) / a0, b2: (1.0 - c) / 2.0 / a0,
                      a1: -2.0 * c / a0, a2: (1.0 - alpha) / a0)
    }

    static func highpass(cutoff: Double, rate: Double, q: Double) -> Biquad {
        let w0 = 2.0 * Double.pi * cutoff / rate
        let c = cos(w0)
        let alpha = sin(w0) / (2.0 * q)
        let a0 = 1.0 + alpha
        return Biquad(b0: (1.0 + c) / 2.0 / a0, b1: -(1.0 + c) / a0, b2: (1.0 + c) / 2.0 / a0,
                      a1: -2.0 * c / a0, a2: (1.0 - alpha) / a0)
    }
}

fileprivate struct Cascade {
    var stages: [Biquad]

    mutating func process(_ x: Double) -> Double {
        var v = x
        for i in 0..<stages.count { v = stages[i].process(v) }
        return v
    }
}
