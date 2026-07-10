import SwiftUI
import WidgetKit
import ColophonShared

/// The widget extension's `@main` entry point. Real widgets (continue-listening, Live Activity,
/// Control Center) arrive in M2b Tasks 2–4; this Task-1 scaffold ships ONE placeholder widget so the
/// extension target builds, links `ColophonShared`, and loads in the widget gallery.
@main
struct ColophonWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
    }
}
