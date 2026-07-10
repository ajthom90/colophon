import Foundation

/// The App Group the app and its extensions (Widgets / Live Activity / Control Center) share.
///
/// Automatic code signing provisions app groups with no Apple approval needed (unlike CarPlay), so
/// this is added to both `App/Colophon.entitlements` and `Widgets/ColophonWidgets.entitlements`.
///
/// SECURITY: the container behind this group carries ONLY display snapshots (titles, ids, progress,
/// small cover thumbnails). It NEVER holds tokens or credentials — those stay device-local in the
/// Keychain. `SharedStore` enforces this by construction (it exposes no token surface).
public enum ColophonAppGroup {
    public static let identifier = "group.com.andrewthom.colophon"
}
