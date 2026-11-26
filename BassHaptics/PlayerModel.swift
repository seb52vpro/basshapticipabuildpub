import Foundation
import AVFoundation
import CoreHaptics
import Combine
import UIKit

// MARK: - Haptics

/// Keeps one long continuous haptic event running and steers its intensity and sharpness
/// in real time with Core Haptics dynamic parameters
/// (intensity control is a multiplier, sharpness control is added to the event's sharpness).
final class HapticDriver {
    let isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var engineRunning = false
    private var playerRunning = false
    private var lastIntensity: Float = -1
    private var lastSharpness: Float = -1

    /// Starts the engine and the carrier event (silent until the first update). Safe to repeat.
    @discardableResult
    func start() -> Bool {
        guard isSupported else { return false }
        do {
            let engine = try runningEngine()
            if !playerRunning {
                let newPlayer = try makePlayer(on: engine)
                try newPlayer.start(atTime: CHHapticTimeImmediate)
                player = newPlayer
                playerRunning = true
                send(intensity: 0, sharpness: 0)   // never start at full strength
            }
            return true
        } catch {
            return false
        }
    }

    func update(intensity: Float, sharpness: Float) {
        guard isSupported else { return }
        if !playerRunning && !start() { return }
        if intensity <= 0 {
            if lastIntensity > 0 { send(intensity: 0, sharpness: sharpness) }
            return
        }
        if abs(intensity - lastIntensity) < 0.01 && abs(sharpness - lastSharpness) < 0.01 { return }
        send(intensity: intensity, sharpness: sharpness)
    }

    func stop() {
        guard playerRunning else { return }
        send(intensity: 0, sharpness: 0)
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        playerRunning = false
        lastIntensity = -1
        lastSharpness = -1
    }

    // MARK: Internals

    private func runningEngine() throws -> CHHapticEngine {
        let e: CHHapticEngine
        if let existing = engine {
            e = existing
        } else {
            e = try CHHapticEngine()
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = false
            e.stoppedHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.markStopped() }
            }
            e.resetHandler = { [weak self] in
                DispatchQueue.main.async { self?.markStopped() }
            }
            engine = e
        }
        if !engineRunning {
            try e.start()
            engineRunning = true
        }
        return e
    }

    private func makePlayer(on engine: CHHapticEngine) throws -> CHHapticAdvancedPatternPlayer {
        // One continuous event at full strength; the dynamic parameters scale it down.
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.0)
            ],
            relativeTime: 0,
            duration: 30)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let newPlayer = try engine.makeAdvancedPlayer(with: pattern)
        newPlayer.loopEnabled = true
        return newPlayer
    }

    private func send(intensity: Float, sharpness: Float) {
        guard let player = player else { return }
        let parameters = [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                     value: min(max(intensity, 0), 1), relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                     value: min(max(sharpness, 0), 1), relativeTime: 0)
        ]
        do {
            try player.sendParameters(parameters, atTime: CHHapticTimeImmediate)
            lastIntensity = intensity
            lastSharpness = sharpness
        } catch {
            // If the engine stopped, the next update() restarts it.
        }
    }

    private func markStopped() {
        engineRunning = false
        playerRunning = false
        player = nil
    }
}

// MARK: - Model

struct LiveReadout {
    var frequency: Float = 0
    var sharpness: Float = 0
    var intensity: Float = 0
}

final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Phase { case empty, analyzing, ready }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var progress = 0.0
    @Published private(set) var songName = ""
    @Published private(set) var duration = 0.0
    @Published private(set) var currentTime = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var bars: [BassAnalysis.Bar] = []
    @Published private(set) var live = LiveReadout()
    @Published var errorMessage: String?

    /// 0...1 – pushes the vibration strength up (higher floor, gentler curve).
    @Published var boost: Double = UserDefaults.standard.object(forKey: "boost") as? Double ?? 0.6 {
        didSet { UserDefaults.standard.set(boost, forKey: "boost") }
    }
    /// Milliseconds. Positive = feel the haptics later, negative = earlier.
    @Published var delayMs: Double = UserDefaults.standard.object(forKey: "delayMs") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(delayMs, forKey: "delayMs") }
    }

    let hapticsSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private let haptics = HapticDriver()
    private var audio: AVAudioPlayer?
    private var analysis: BassAnalysis?
    private var displayLink: CADisplayLink?
    private var loadToken = UUID()
    private var tickCount = 0
    private var stalledTicks = 0
    private var outputLatency: TimeInterval = 0

    // MARK: Loading

    func load(from pickedURL: URL) {
        pause()
        audio?.stop()
        audio = nil
        analysis = nil
        bars = []
        duration = 0
        currentTime = 0
        errorMessage = nil
        songName = pickedURL.deletingPathExtension().lastPathComponent
        progress = 0
        phase = .analyzing

        let token = UUID()
        loadToken = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let didAccess = pickedURL.startAccessingSecurityScopedResource()
            defer { if didAccess { pickedURL.stopAccessingSecurityScopedResource() } }
            do {
                let local = try PlayerModel.copyToTemporaryFolder(pickedURL)
                let result = try BassAnalyzer.analyze(url: local) { fraction in
                    DispatchQueue.main.async {
                        guard let model = self, model.loadToken == token else { return }
                        model.progress = fraction
                    }
                }
                DispatchQueue.main.async {
                    self?.finishLoading(token: token, file: local, analysis: result)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.failLoading(token: token, error: error)
                }
            }
        }
    }

    private func finishLoading(token: UUID, file: URL, analysis result: BassAnalysis) {
        guard token == loadToken else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: file)
            player.delegate = self
            player.prepareToPlay()
            audio = player
            analysis = result
            duration = player.duration
            bars = result.bars(count: 160)
            currentTime = 0
            progress = 1
            phase = .ready
        } catch {
            failLoading(token: token, error: error)
        }
    }

    private func failLoading(token: UUID, error: Error) {
        guard token == loadToken else { return }
        phase = .empty
        songName = ""
        errorMessage = error.localizedDescription
    }

    /// The picker hands us a security-scoped URL (possibly an iCloud file that isn't
    /// downloaded yet), so copy it into the app's temp folder first.
    private static func copyToTemporaryFolder(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("song", isDirectory: true)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [],
                                                         error: &coordinationError) { readable in
            do { try fm.copyItem(at: readable, to: destination) } catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        return destination
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let audio = audio, analysis != nil, !isPlaying else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            errorMessage = "Couldn't start audio: \(error.localizedDescription)"
            return
        }
        outputLatency = session.outputLatency
        if audio.currentTime >= audio.duration - 0.05 { audio.currentTime = 0 }
        haptics.start()
        guard audio.play() else {
            haptics.stop()
            errorMessage = "Couldn't start playback."
            return
        }
        isPlaying = true
        tickCount = 0
        stalledTicks = 0
        startDisplayLink()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func pause() {
        audio?.pause()
        stopDisplayLink()
        haptics.stop()
        if let audio = audio { currentTime = audio.currentTime }
        if isPlaying { isPlaying = false }
        live = LiveReadout()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func seek(to time: Double) {
        guard let audio = audio else { return }
        let target = min(max(time, 0), max(audio.duration - 0.05, 0))
        audio.currentTime = target
        currentTime = target
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pause()
            self.audio?.currentTime = 0
            self.currentTime = 0
        }
    }

    // MARK: Haptic sync loop (runs once per screen refresh while playing)

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let audio = audio, let analysis = analysis else { return }

        if !audio.isPlaying {                       // finished, or interrupted by a call etc.
            haptics.update(intensity: 0, sharpness: 0)
            stalledTicks += 1
            if stalledTicks > 5 { pause() }
            return
        }
        stalledTicks = 0

        let time = audio.currentTime
        if tickCount % 30 == 0 { outputLatency = AVAudioSession.sharedInstance().outputLatency }
        tickCount += 1

        // What you hear right now was rendered `outputLatency` seconds ago.
        let heard = time - outputLatency - delayMs / 1000.0
        let sample = analysis.sample(at: heard)
        let intensity = PlayerModel.intensity(level: sample.level, boost: Float(boost))
        haptics.update(intensity: intensity, sharpness: sample.sharpness)

        if tickCount % 4 == 0 {                     // refresh the UI ~15x per second
            currentTime = time
            live = LiveReadout(frequency: sample.frequency,
                               sharpness: sample.sharpness,
                               intensity: intensity)
        }
    }

    /// Bass loudness (0...1) -> haptic intensity (0...1).
    /// Deliberately biased upward so the vibration stays strong; true silence stays silent.
    static func intensity(level x: Float, boost: Float) -> Float {
        let gate: Float = 0.03
        guard x > gate else { return 0 }
        let fadeIn = min(1, (x - gate) / 0.08)
        let smooth = fadeIn * fadeIn * (3 - 2 * fadeIn)
        let floorValue: Float = 0.30 + 0.35 * boost          // 0.30 ... 0.65
        let gamma = Double(0.9 - 0.5 * boost)                 // 0.9 ... 0.4 (lower = louder mid levels)
        let n = Double((x - gate) / (1 - gate))
        let shaped = floorValue + (1 - floorValue) * Float(pow(n, gamma))
        return min(1, max(0, smooth * shaped))
    }
}
