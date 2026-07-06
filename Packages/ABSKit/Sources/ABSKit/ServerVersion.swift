import Foundation

public struct ServerVersion: Comparable, Sendable, Equatable {
    public let major: Int, minor: Int, patch: Int

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }

    public static func < (l: ServerVersion, r: ServerVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}

public enum ABSKit {
    /// First server release with the JWT access/refresh flow — the spec's support floor.
    public static let minimumServerVersion = ServerVersion("2.26.0")!
}
