import SwiftUI

/// The playback-rate control for the full player's secondary cluster (Task 7) — a single
/// `.buttonStyle(.glass)` Menu trigger showing the current rate (e.g. "1.5×"), NOT a new glass
/// surface. The caller places it inside the shared secondary `GlassEffectContainer` alongside the
/// sleep-timer/bookmark controls (`FullPlayerView.secondaryControls`), so it reads as one member of
/// the transport/control chrome per the UI mandate — never glass-on-glass.
///
/// Selecting an option calls `PlayerModel.setRate`, which routes through `AppState.setPlaybackRate`:
/// the rate applies to the live `PlaybackController` immediately AND persists as this (connection,
/// item)'s per-book preference (the `v3` `cachedItemPref` table) — so the SAME book resumes at it
/// next time it's opened, while a DIFFERENT book is unaffected and falls back to the global default
/// rate setting (`AppState`'s `colophon.defaultRate`).
struct SpeedControl: View {
    var model: PlayerModel

    /// 0.25 steps across the full 0.5×–3.0× range, merged with the plan's named common presets
    /// (1.2× isn't on the 0.25 grid, so it's added explicitly) — deduplicated and sorted so the
    /// menu reads as one clean ascending list rather than two separate sections.
    static let options: [Double] = {
        let steps = stride(from: 0.5, through: 3.0, by: 0.25).map { $0 }
        let presets: [Double] = [1.0, 1.2, 1.5, 1.75, 2.0]
        return Array(Set(steps + presets)).sorted()
    }()

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.self) { option in
                Button {
                    model.setRate(option)
                } label: {
                    if Self.isCurrent(option, model.rate) {
                        Label(Self.label(for: option), systemImage: "checkmark")
                    } else {
                        Text(Self.label(for: option))
                    }
                }
            }
        } label: {
            Text(Self.label(for: model.rate))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 34)
        }
        .buttonStyle(.glass)
        .fontDesign(.default)
        .accessibilityLabel("Playback Speed")
        .accessibilityValue(Self.label(for: model.rate))
    }

    private static func isCurrent(_ option: Double, _ rate: Double) -> Bool {
        abs(option - rate) < 0.001
    }

    /// "1×" for whole numbers, "1.5×"/"1.2×" for one decimal place, "1.25×"/"2.75×" for the 0.25
    /// steps that need two — never a spurious trailing zero (e.g. never "1.50×").
    static func label(for rate: Double) -> String {
        let hundredths = (rate * 100).rounded()
        if hundredths.truncatingRemainder(dividingBy: 100) == 0 {
            return String(format: "%.0f×", hundredths / 100)
        }
        if hundredths.truncatingRemainder(dividingBy: 10) == 0 {
            return String(format: "%.1f×", hundredths / 100)
        }
        return String(format: "%.2f×", hundredths / 100)
    }
}
