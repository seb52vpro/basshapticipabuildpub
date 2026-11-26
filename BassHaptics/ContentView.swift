import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = PlayerModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImporter = false
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.15), Color.black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    header
                    songCard
                    if model.phase == .ready {
                        playerCard
                        tuningCard
                    }
                    if !model.hapticsSupported {
                        unsupportedNote
                    }
                }
                .padding(20)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.load(from: url) }
            case .failure(let error):
                if (error as NSError).code != CocoaError.userCancelled.rawValue {
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .alert("Couldn't load song", isPresented: errorBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: scenePhase) { _, newPhase in
            // iOS doesn't allow third-party haptics in the background.
            if newPhase == .background { model.pause() }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.path")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.blue, .orange],
                                                startPoint: .leading, endPoint: .trailing))
            Text("Bass Haptics")
                .font(.system(.title, design: .rounded).weight(.bold))
            Text("Feel the low end of your music")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var songCard: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .empty:
                Text("Pick an MP3 and the app will turn its bass into haptics.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            case .analyzing:
                VStack(spacing: 10) {
                    Text(model.songName)
                        .font(.headline)
                        .lineLimit(1)
                    ProgressView(value: model.progress)
                    Text("Analysing bass… \(Int(model.progress * 100))%")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .ready:
                VStack(spacing: 4) {
                    Text(model.songName)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("Haptic map ready · \(timeString(model.duration))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                BassMapView(bars: model.bars,
                            progress: model.duration > 0 ? model.currentTime / model.duration : 0)
                    .frame(height: 110)
                Text("Height = bass loudness (intensity). Colour = bass pitch: blue ≈ 25–30 Hz (lowest sharpness), orange ≈ 100–120 Hz (highest).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showImporter = true
            } label: {
                Label(model.phase == .empty ? "Choose a song" : "Choose another song",
                      systemImage: "music.note.list")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.phase == .analyzing)
        }
        .card()
    }

    private var playerCard: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Slider(value: sliderBinding,
                       in: 0...max(model.duration, 0.1),
                       onEditingChanged: { editing in
                    if editing {
                        scrubValue = model.currentTime
                        scrubbing = true
                    } else {
                        model.seek(to: scrubValue)
                        scrubbing = false
                    }
                })
                HStack {
                    Text(timeString(shownTime))
                    Spacer()
                    Text("-" + timeString(max(model.duration - shownTime, 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(
                        Circle().fill(LinearGradient(colors: [.blue, .purple],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                stat("Bass", model.isPlaying ? "\(Int(model.live.frequency.rounded())) Hz" : "–")
                stat("Sharpness", model.isPlaying ? String(format: "%.2f", model.live.sharpness) : "–")
                stat("Intensity", model.isPlaying ? String(format: "%.2f", model.live.intensity) : "–")
            }
        }
        .card()
    }

    private var tuningCard: some View {
        DisclosureGroup("Tuning") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Intensity boost")
                        Spacer()
                        Text("\(Int(model.boost * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.boost, in: 0...1)
                    Text("Higher keeps the vibration strong even when the bass is quieter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Haptic delay")
                        Spacer()
                        Text("\(Int(model.delayMs)) ms")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.delayMs, in: -150...300, step: 5)
                    Text("Raise it if you feel the beat before you hear it (Bluetooth headphones), lower it if you feel it late.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 12)
        }
        .card()
    }

    private var unsupportedNote: some View {
        Label("This device doesn't support Core Haptics, so you'll only hear the song. Run the app on an iPhone.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Helpers

    private var shownTime: Double {
        scrubbing ? scrubValue : model.currentTime
    }

    private var sliderBinding: Binding<Double> {
        Binding(get: { shownTime }, set: { scrubValue = $0 })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

// MARK: - Bass map

/// One bar per slice of the song: height = loudness, colour = sharpness (blue -> orange).
struct BassMapView: View {
    let bars: [BassAnalysis.Bar]
    let progress: Double

    var body: some View {
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            let slot = size.width / CGFloat(bars.count)
            let barWidth = max(1, slot * 0.7)
            for (i, bar) in bars.enumerated() {
                let h = max(3, CGFloat(bar.level) * size.height)
                let rect = CGRect(x: CGFloat(i) * slot + (slot - barWidth) / 2,
                                  y: (size.height - h) / 2,
                                  width: barWidth,
                                  height: h)
                let color = Color(hue: 0.60 - 0.52 * Double(bar.sharpness),
                                  saturation: 0.75, brightness: 1.0)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(color.opacity(0.9)))
            }
            let x = size.width * CGFloat(min(max(progress, 0), 1))
            context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)),
                         with: .color(.white))
        }
    }
}

// MARK: - Small utilities

private extension View {
    func card() -> some View {
        self
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private func timeString(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}
