import SwiftUI

/// The sleep-timer control for the full player's secondary cluster — a single `.buttonStyle(.glass)`
/// Menu trigger (a moon glyph, plus the live countdown when armed), NOT a new glass surface. The
/// caller places it inside the shared secondary `GlassEffectContainer` alongside the other Task 5–8
/// controls, so it reads as one member of the transport/control chrome (per the UI mandate).
///
/// Tapping opens a native `Menu` of presets + End of Chapter + (when armed) Add Time / Off. The
/// countdown label is opaque text (`.monospacedDigit()`, SF via `.fontDesign(.default)`), rendered
/// over the glass button — never its own glass chip.
struct SleepTimerView: View {
    /// The shared, `AppState`-owned timer (survives the player being dismissed).
    let timer: SleepTimer
    /// Whether End of Chapter is offerable — the player passes `!chapters.isEmpty`.
    var hasChapters: Bool

    var body: some View {
        Menu {
            menuContent
        } label: {
            label
        }
        .buttonStyle(.glass)
        .fontDesign(.default)
        .accessibilityLabel("Sleep Timer")
        .accessibilityValue(timer.remainingLabel.map { "\($0) remaining" } ?? "Off")
    }

    // MARK: - Trigger label (opaque content over the glass button)

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: timer.isArmed ? "moon.zzz.fill" : "moon.zzz")
            if let countdown = timer.remainingLabel {
                Text(countdown)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private var menuContent: some View {
        if timer.isArmed {
            Section {
                Menu {
                    Button("5 minutes") { timer.addTime(minutes: 5) }
                    Button("15 minutes") { timer.addTime(minutes: 15) }
                    Button("30 minutes") { timer.addTime(minutes: 30) }
                } label: {
                    Label("Add Time", systemImage: "plus.circle")
                }
                Button(role: .destructive) { timer.turnOff() } label: {
                    Label("Turn Off", systemImage: "xmark.circle")
                }
            }
        }

        Section("Sleep After") {
            ForEach(SleepTimer.presetMinutes, id: \.self) { minutes in
                Button {
                    timer.arm(.preset(minutes: minutes))
                } label: {
                    if timer.activePresetMinutes == minutes {
                        Label("\(minutes) minutes", systemImage: "checkmark")
                    } else {
                        Text("\(minutes) minutes")
                    }
                }
            }
            Button {
                timer.arm(.endOfChapter)
            } label: {
                if timer.isEndOfChapter {
                    Label("End of Chapter", systemImage: "checkmark")
                } else {
                    Label("End of Chapter", systemImage: "book")
                }
            }
            .disabled(!hasChapters)
        }
    }
}
