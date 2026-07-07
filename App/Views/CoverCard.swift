import SwiftUI
import LibraryCache

/// One book card in a home shelf — an OPAQUE content card (never glass): the item's cover, a
/// serif title (2-line clamp), the author (1-line secondary), and a subtle progress affordance
/// shown ONLY when the item has in-progress `CachedProgress` (0 < fraction < 1, not finished):
/// a thin determinate bar hugging the cover's bottom edge (the Apple Books "currently listening"
/// idiom) plus a small tinted percentage pill. Progress is JOINED from `CachedProgress`
/// (`me()`/socket), NOT the shelf entity — shelf entities carry no progress (verified live). The
/// duration for the fraction comes from the shelf entity's `media.duration` (progress rows store
/// `currentTime`, not duration). Tapping starts playback of the item (so the shelf is functional
/// and the mini-bar/transport lights up); item detail is M1c-b.
struct CoverCard: View {
    @Environment(AppState.self) private var app
    let itemID: String
    let updatedAt: Int?
    let title: String
    let author: String?
    /// From the shelf entity's `media.duration` — needed to turn a `currentTime` into a fraction.
    let duration: Double?
    /// Joined from the cache (nil when the server reports no progress for this item).
    let progress: CachedProgress?

    static let width: CGFloat = 150

    /// The listened fraction, but ONLY when it's a meaningful in-progress value (0 < f < 1 and not
    /// finished) — otherwise nil so no bar/pill renders on an untouched or completed item.
    private var fraction: Double? {
        guard let progress, !progress.isFinished,
              let duration, duration > 0 else { return nil }
        let f = progress.currentTime / duration
        guard f > 0, f < 1 else { return nil }
        return f
    }

    var body: some View {
        Button {
            Task { await app.startPlayback(itemID: itemID) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CachedCoverView(itemID: itemID, updatedAt: updatedAt)
                    .frame(width: Self.width, height: Self.width)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottom) {
                        if let fraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .tint(.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 8)
                        }
                    }

                // Serif comes from the app-wide `.fontDesign` (root typeface toggle) — per the
                // ColophonApp convention, per-view `.fontDesign(.serif)` is NOT reintroduced here.
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                if let author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.tint))
                        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent listened")
                }
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

/// An author entity card in the "Newest Authors" shelf — an avatar circle (initials placeholder;
/// real author artwork via `/api/authors/:id/image` is Task 9's authors browse) plus the name.
/// Not tappable-to-play (there's nothing to play); author detail is Task 9.
struct AuthorCard: View {
    let name: String

    static let width: CGFloat = 110

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(.quaternary)
                .frame(width: 90, height: 90)
                .overlay {
                    Text(initials)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .overlay {
                    if initials.isEmpty {
                        Image(systemName: "person.fill")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }

            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: Self.width)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}

/// A podcast-episode shelf entity card — STUBBED for M1c-a. Renders the podcast cover + the recent
/// episode's title with a "Podcast" caption; real per-episode cards (playback, per-episode
/// progress, download) land in M1c-c. Deliberately not tappable-to-play yet. The seeded dev stack
/// has no podcast library, so this path is source-verified, not live-exercised, this milestone.
struct EpisodeStubCard: View {
    let itemID: String
    let title: String

    static let width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedCoverView(itemID: itemID, updatedAt: nil)
                .frame(width: Self.width, height: Self.width)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)

            Text("Podcast · M1c-c")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: Self.width, alignment: .leading)
    }
}
