import SwiftUI

struct PlayerBarView: View {
    @Environment(AppState.self) private var app
    private let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        let playback = app.playback
        if playback.totalDuration > 0 {
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(playback.title).font(.headline).lineLimit(1)
                        Text(playback.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { playback.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { playback.togglePlayPause() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    }
                    Button { playback.skip(15) } label: { Image(systemName: "goforward.15") }
                    Menu(String(format: "%.2g×", playback.rate)) {
                        ForEach(rates, id: \.self) { rate in
                            Button(String(format: "%.2g×", rate)) { playback.setRate(rate) }
                        }
                    }
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    Text(timeString(playback.globalTime)).monospacedDigit().font(.caption)
                    Slider(
                        value: Binding(
                            get: { playback.globalTime },
                            set: { playback.seek(toGlobal: $0) }),
                        in: 0...max(playback.totalDuration, 1))
                    Text(timeString(playback.totalDuration)).monospacedDigit().font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .fontDesign(.serif)
            .padding(12)
            .background(.bar)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
