import Foundation

public enum FlexibleDate {
    /// Parses ISO8601 with and without fractional seconds, and numeric epoch
    /// seconds or milliseconds supplied as a string. Returns nil otherwise.
    ///
    /// Numeric discrimination: value `< 1e12` is seconds, otherwise
    /// milliseconds. Never invents a reset time — nil in, nil out.
    public static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let numeric = Double(raw) {
            if numeric < 1e12 {
                return Date(timeIntervalSince1970: numeric)
            }
            return Date(timeIntervalSince1970: numeric / 1000)
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
