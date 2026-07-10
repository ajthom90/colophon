#if DEBUG && os(macOS)
import SwiftUI
import Foundation

/// Cross-file handoff for "time from window-open request to first rendered content".
/// `ColophonApp`'s auto-opener stamps `windowOpenRequestedAt` right before calling
/// `openWindow(id:)`; `PerfSpikeView` reads it when its first cell appears.
///
/// Gotcha this design has to survive: if the previous process was killed with the
/// perf-spike window open, macOS state restoration re-creates that window at launch
/// BEFORE the auto-opener's `.task` runs — so `windowOpenRequestedAt` is still nil when
/// the first cell appears. `processLaunch` (stamped in `ColophonApp.init()`) is the
/// fallback origin for that path, and the measurement log line labels which origin was
/// used so a restored-window measurement can never masquerade as an open-window one.
enum PerfSpikeClock {
    static var processLaunch: Date?
    static var windowOpenRequestedAt: Date?
}

/// Coarse frame-gap instrumentation: schedules a 120Hz `Timer` on the main run loop
/// (`.common` mode, so it keeps firing during scroll/tracking loops) and measures the
/// *actual* elapsed time between consecutive fires. When the main thread is busy doing
/// layout/render work, the timer fires late — the gap between "expected" (~8.3ms) and
/// "actual" reveals the hitch. This is deliberately coarse (no CVDisplayLink/CADisplayLink
/// tie-in to the real display refresh) — see the spike doc's "what this can't tell us" section.
final class FrameGapMonitor {
    private var timer: Timer?
    private var lastTick: CFAbsoluteTime?
    private(set) var maxGapMS: Double = 0
    private(set) var totalGapMS: Double = 0
    private(set) var sampleCount: Int = 0
    private(set) var hitchCount: Int = 0  // gaps > 33ms (~sub-30fps)

    var meanGapMS: Double { sampleCount > 0 ? totalGapMS / Double(sampleCount) : 0 }

    func start() {
        stop()
        lastTick = nil
        maxGapMS = 0
        totalGapMS = 0
        sampleCount = 0
        hitchCount = 0
        // The block-based Timer initializer's callback type is `@Sendable`, so the closure
        // literal is nonisolated by default even though this timer is added to `RunLoop.main`
        // in `.common` mode and therefore always fires on the main thread. `assumeIsolated`
        // is the documented bridge for exactly this case (a callback the compiler can't
        // annotate `@MainActor` but is known to run on the main actor's thread) — it asserts
        // that fact at runtime rather than silently trusting it, with no change in when/where
        // `tick()` actually runs.
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let gapMS = (now - last) * 1000
        sampleCount += 1
        totalGapMS += gapMS
        if gapMS > maxGapMS { maxGapMS = gapMS }
        if gapMS > 33 { hitchCount += 1 }
    }
}

private func perfLog(_ message: String) {
    print(message)
    fflush(stdout)
}

private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

/// Synthetic 10k-item grid to probe LazyVGrid scroll performance on macOS.
struct PerfSpikeView: View {
    struct Cell: Identifiable { let id: Int }
    let cells = (0..<10_000).map(Cell.init)
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    @State private var monitor = FrameGapMonitor()
    @State private var firstContentRecorded = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(cells) { cell in
                        VStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LinearGradient(
                                    colors: [.blue.opacity(Double(cell.id % 10) / 10 + 0.05), .purple],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .aspectRatio(1, contentMode: .fit)
                            Text("Synthetic Book \(cell.id)").font(.headline).lineLimit(1)
                            Text("Author \(cell.id % 500)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .id(cell.id)
                        .onAppear { recordFirstContentIfNeeded(cellID: cell.id) }
                    }
                }
                .padding()
            }
            .navigationTitle("Perf Spike — 10k items")
            .onAppear {
                guard ProcessInfo.processInfo.environment["COLOPHON_PERF_AUTOSCROLL"] == "1" else { return }
                runAutoSweep(proxy: proxy)
            }
        }
    }

    private func recordFirstContentIfNeeded(cellID: Int) {
        guard cellID == 0, !firstContentRecorded else { return }
        firstContentRecorded = true
        let now = Date()
        if let requested = PerfSpikeClock.windowOpenRequestedAt {
            let elapsedMS = now.timeIntervalSince(requested) * 1000
            perfLog("[PerfSpike] time_to_first_content_ms=\(fmt(elapsedMS)) origin=open_window_request")
        } else if let launch = PerfSpikeClock.processLaunch {
            let elapsedMS = now.timeIntervalSince(launch) * 1000
            perfLog("[PerfSpike] time_to_first_content_ms=\(fmt(elapsedMS)) origin=process_launch "
                    + "(window existed before auto-opener ran — likely state restoration; "
                    + "NOT comparable to origin=open_window_request)")
        } else {
            perfLog("[PerfSpike] time_to_first_content_ms=unmeasured (no launch timestamp; window opened manually)")
        }
    }

    /// Runs `COLOPHON_PERF_SWEEP_COUNT` (default 2) top→bottom→top passes, each ~20s
    /// (40 steps down + 40 steps up, 250ms per step), instrumenting frame gaps per pass.
    /// Sweep 1 is "cold" (first layout pass over every cell), sweep 2+ is "warm" (cells'
    /// view state/layout already computed once in this process).
    private func runAutoSweep(proxy: ScrollViewProxy) {
        let env = ProcessInfo.processInfo.environment
        let requestedCount = Int(env["COLOPHON_PERF_SWEEP_COUNT"] ?? "") ?? 2
        let sweepCount = max(1, requestedCount)
        Task {
            for i in 1...sweepCount {
                let phase = i == 1 ? "cold" : "warm"
                monitor.start()
                perfLog("[PerfSpike] sweep=\(i)/\(sweepCount) phase=\(phase) starting")
                let sweepStart = Date()
                await scrollSweep(proxy: proxy, from: 0, to: cells.count - 1, steps: 40)
                await scrollSweep(proxy: proxy, from: cells.count - 1, to: 0, steps: 40)
                monitor.stop()
                let elapsedS = Date().timeIntervalSince(sweepStart)
                perfLog("[PerfSpike] sweep=\(i)/\(sweepCount) phase=\(phase) duration_s=\(fmt(elapsedS)) " +
                        "max_gap_ms=\(fmt(monitor.maxGapMS)) mean_gap_ms=\(fmt(monitor.meanGapMS)) " +
                        "samples=\(monitor.sampleCount) hitches_gt_33ms=\(monitor.hitchCount)")
            }
            perfLog("[PerfSpike] ALL_SWEEPS_COMPLETE")
        }
    }

    private func scrollSweep(proxy: ScrollViewProxy, from: Int, to: Int, steps: Int) async {
        let range = to - from
        for step in 0...steps {
            let index = from + Int(Double(range) * Double(step) / Double(steps))
            withAnimation(.linear(duration: 0.25)) {
                proxy.scrollTo(index, anchor: .top)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
#endif
