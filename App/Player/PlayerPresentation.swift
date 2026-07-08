import SwiftUI

/// The per-platform presentation seam for `FullPlayerView` — the single place the UI MANDATE's
/// "presented natively per platform, NOT a shared layout" rule is expressed:
///
///   • **iPhone** (`PhoneShell`, compact width) — an edge-to-edge `.fullScreenCover` (a native
///     slide-up), so the player's immersive `backgroundExtensionEffect` backdrop reaches the safe
///     area. This IS the HIG-idiomatic now-playing presentation (Apple Music / Podcasts).
///   • **iPad** (`SplitShell`, regular width) — a large detented `.sheet` on the detail column
///     (`.presentationDetents([.large])`), NOT a full-window takeover.
///   • **Mac** (`SplitShell`, macOS) — a dedicated `Window(id:)` scene (see `PlayerWindowScene`),
///     opened via `@Environment(\.openWindow)` from the transport bar's expand affordance. A
///     window, not a sheet — the Mac-native choice the mandate calls for.
///
/// **Morph note (recorded deviation):** a mini-bar → full **zoom morph**
/// (`matchedTransitionSource(id:in:)` + `.navigationTransition(.zoom(sourceID:in:))`) was
/// implemented and *compiled* clean against the 26 SDK, but when the presented content is this
/// immersive `ZStack` player (a `.backgroundExtensionEffect()` backdrop under `.ignoresSafeArea()`),
/// the zoom transition's residual transform pushed the top dismiss-bar (the chevron-down Close
/// button) off-screen — verified live via idb (a11y frame `x = -172`, and absent from the render),
/// while swipe-down still dismissed. Rather than ship a full player whose Close affordance is
/// unreachable, this reverts to the standard slide-up `fullScreenCover` — which is the idiomatic
/// now-playing presentation anyway. The `@Namespace` plumbing was removed with it.
///
/// The window's scene identifier is declared here as the single source of truth shared by the
/// scene declaration (`ColophonApp`) and its opener (`SplitShell`).

/// The dedicated Mac player Window's scene id — referenced by both the `Window(id:)` scene in
/// `ColophonApp` and the `openWindow(id:)` call in `SplitShell`'s transport expand affordance.
enum PlayerWindowScene {
    static let id = "player"
}

extension View {
    /// iPhone (compact) full-player presentation: an edge-to-edge `fullScreenCover` hosting
    /// `FullPlayerView` (see the morph note above for why this is a standard slide-up, not a zoom
    /// morph). On macOS this is a no-op passthrough — `PhoneShell` is never rendered there
    /// (`RootShell` routes the Mac to `SplitShell`), but the file still compiles for the macOS
    /// target.
    @ViewBuilder
    func iPhonePlayerCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) { FullPlayerView() }
        #else
        self
        #endif
    }

    /// iPad (regular width) full-player presentation: a large detented `.sheet` on the detail
    /// column — the iPad-native surface (NOT a full-window takeover). On macOS this is a no-op
    /// passthrough: the Mac uses the dedicated `Window` (`PlayerWindowScene`) instead.
    @ViewBuilder
    func iPadPlayerSheet(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        sheet(isPresented: isPresented) {
            FullPlayerView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        #else
        self
        #endif
    }
}
