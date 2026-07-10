import SwiftUI
import WidgetKit
import ColophonShared

/// The widget extension's `@main` entry point. `ContinueListeningWidget` (M2b Task 2) replaces the
/// Task-1 placeholder; the Live Activity + Control Center widgets (Tasks 3–4) join this bundle as
/// they land.
@main
struct ColophonWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ContinueListeningWidget()
    }
}
