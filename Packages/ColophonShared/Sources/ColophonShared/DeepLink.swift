import Foundation

/// The `colophon://` deep links the app's companion surfaces (widgets, Live Activity, Control
/// Center, Siri/Spotlight) use to route back into the running app. Built here so BOTH the app (which
/// parses them in `onOpenURL`) and the extensions (which build them for `widgetURL`/`Link`) agree on
/// one grammar:
///   - `colophon://item/<id>`            → open a book / podcast detail
///   - `colophon://item/<id>?episode=<e>`→ open a specific episode
///   - `colophon://resume`               → resume the last / continue-listening item
public enum ColophonDeepLink: Equatable, Sendable {
    case item(id: String, episodeID: String?)
    case resume

    public static let scheme = "colophon"

    private enum Host: String {
        case item
        case resume
    }

    private static let episodeQueryName = "episode"

    /// The URL representation. Non-optional: every case produces a valid `colophon://` URL.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case let .item(id, episodeID):
            components.host = Host.item.rawValue
            components.path = "/" + id
            if let episodeID, !episodeID.isEmpty {
                components.queryItems = [URLQueryItem(name: Self.episodeQueryName, value: episodeID)]
            }
        case .resume:
            components.host = Host.resume.rawValue
        }
        // Safe to force-unwrap: scheme + host (+ percent-encoded path/query) always compose a URL.
        return components.url!
    }

    /// Parse a `colophon://` URL back into a deep link, or `nil` when it isn't one we recognize.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host.flatMap(Host.init(rawValue:)) else {
            return nil
        }
        switch host {
        case .resume:
            self = .resume
        case .item:
            // `url.path` is already percent-decoded; drop the single leading slash.
            let id = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            guard !id.isEmpty else { return nil }
            let episodeID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == Self.episodeQueryName }?
                .value
            self = .item(id: id, episodeID: (episodeID?.isEmpty == false) ? episodeID : nil)
        }
    }
}
