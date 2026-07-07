import SwiftUI

/// Slim top overlay shown when a background refresh fails but the cache still has items to
/// display — the screen stays usable, so this just informs and offers a retry instead of
/// replacing the whole view with `ContentUnavailableView` (that path stays reserved for a
/// genuinely empty cache, in `LibraryItemsView`).
struct RefreshBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text(message).lineLimit(1)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
                .fontWeight(.semibold)
        }
        .font(.footnote)
        .fontDesign(.serif)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar, in: Capsule())
        .shadow(radius: 2)
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
