import SwiftUI

/// The "Support the app" tip jar (M2c Task 2) — a native, state-driven view bound to a `TipStore`.
/// Reached from `SettingsView`'s "Support" section on every platform (see that file's doc comment
/// for the per-platform navigation contexts this relies on).
///
/// Renders every `TipStore.State` case:
/// - `.idle`/`.loading` → a centered `ProgressView` (idle is momentary — `load()` runs from
///   `.task`, so it's folded into the same spinner rather than a separate blank state).
/// - `.loadFailed` → a native `ContentUnavailableView` with a Retry button that calls `load()` again.
/// - `.loaded`/`.purchasing`/`.pending`/`.purchaseFailed` → the warm blurb + all 3 tiers as buttons
///   (`displayName` + `displayPrice` — StoreKit-localized, NEVER hardcoded). `.purchasing(id)`
///   disables every tier and swaps the tapped one's price for a spinner; `.pending` adds a gentle
///   Ask-to-Buy note above the tiers; `.purchaseFailed` adds a non-blocking inline error above the
///   STILL-tappable tiers (retry is just tapping a tier again).
/// - `.thankYou` → a heartfelt full-bleed confirmation (a big heart + "Thank You So Much!").
///
/// Tips are CONSUMABLE and unlock NOTHING (Global Constraint): this view never reads or writes an
/// `@AppStorage`/`UserDefaults` key — the only thing that changes is `TipStore.state`, and
/// `.thankYou` is purely transient. Tips can repeat, so the thank-you includes a "Tip Again"
/// button; `dismissedThankYou` is local, ephemeral view state (never persisted) that flips the
/// confirmation back to the tier list without altering `TipStore` at all, and is reset the moment
/// a NEW purchase starts (`tierButton(for:)`) so a second tip always shows its own fresh thank-you
/// rather than one still "dismissed" from an earlier tip. `userCancelled` needs no handling here —
/// `TipStore.purchase` already returns silently to `.loaded` with no thanks and no error.
///
/// No dark patterns: all 3 tiers render identically (no pre-selected "recommended", no size bias,
/// no nagging) — one plain, equally-weighted button per tier, exactly the HIG mandate.
struct TipJarView: View {
    @State private var store = TipStore()
    @State private var dismissedThankYou = false

    private var showingThankYou: Bool {
        store.state == .thankYou && !dismissedThankYou
    }

    var body: some View {
        Group {
            if showingThankYou {
                thankYouView
            } else {
                switch store.state {
                case .idle, .loading:
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loadFailed(let message):
                    loadFailedView(message)
                case .loaded, .purchasing, .pending, .thankYou, .purchaseFailed:
                    tiersView
                }
            }
        }
        .navigationTitle("Support the App")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
        .task { await store.load() }
    }

    // MARK: - Loading / error

    private func loadFailedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Load Tips", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await store.load() } }
        }
    }

    // MARK: - Tiers

    private var tiersView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Colophon is free and always will be. If it's brought you good listening, you can leave a tip to support development — thank you either way.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .purchaseFailed(let message) = store.state {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                if case .pending = store.state {
                    Label(
                        "Waiting for approval — this tip may need a parent or organizer to confirm it (Ask to Buy).",
                        systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    ForEach(store.products) { product in
                        tierButton(for: product)
                    }
                }
            }
            .padding()
        }
    }

    private var purchasingID: String? {
        if case .purchasing(let id) = store.state { return id }
        return nil
    }

    private func tierButton(for product: TipProduct) -> some View {
        let isPurchasingThis = purchasingID == product.id
        let tiersDisabled = purchasingID != nil

        return Button {
            // A fresh tip always gets its own fresh thank-you, even if an earlier one was
            // "dismissed" back to the tiers — see the doc comment above.
            dismissedThankYou = false
            Task { await store.purchase(product.id) }
        } label: {
            HStack {
                Text(product.displayName)
                    .font(.headline)
                Spacer()
                if isPurchasingThis {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    // StoreKit-localized — NEVER a hardcoded literal like "$1.99".
                    Text(product.displayPrice)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(tiersDisabled)
    }

    // MARK: - Thank you

    private var thankYouView: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.pink)
            Text("Thank You So Much!")
                .font(.title2.weight(.semibold))
            Text("Your support genuinely helps keep Colophon going. It doesn't unlock anything — it's just a thank-you.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Tip Again") { dismissedThankYou = true }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
    }
}
