import Foundation

public struct ClaudeCodeConfiguration: Sendable, Equatable {
    public let statusFileURL: URL
    public let role: SourceRole
    public let maximumAge: TimeInterval

    public init(
        statusFileURL: URL,
        role: SourceRole = .primary,
        maximumAge: TimeInterval = 30 * 60
    ) {
        self.statusFileURL = statusFileURL
        self.role = role
        self.maximumAge = maximumAge
    }
}

public struct ClaudeCodeConnector: StatusConnector {
    public let id = "claude-code"
    public let displayName = "Claude Code"

    private let configuration: ClaudeCodeConfiguration
    private let now: @Sendable () -> Date

    public init(
        configuration: ClaudeCodeConfiguration,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.now = now
    }

    public func refresh() async -> ConnectorResult {
        let checkedAt = now()

        guard FileManager.default.fileExists(atPath: configuration.statusFileURL.path) else {
            return .provider(
                status(
                    health: .unsupported,
                    quality: .unavailable,
                    checkedAt: checkedAt,
                    message: "Enable the Motas Claude Code status-line capture to monitor subscription quota."
                )
            )
        }

        do {
            let data = try Data(contentsOf: configuration.statusFileURL)
            let payload = try Self.decoder.decode(StatusPayload.self, from: data)
            let windows = quotaWindows(from: payload.rateLimits)

            guard !windows.isEmpty else {
                return .provider(
                    status(
                        health: .unsupported,
                        quality: .unavailable,
                        checkedAt: checkedAt,
                        lastSuccessfulAt: payload.capturedAt,
                        message: "Claude Code did not expose subscription rate-limit windows."
                    )
                )
            }

            let age = checkedAt.timeIntervalSince(payload.capturedAt)
            let isStale = age < -60 || age > configuration.maximumAge
            let health: OperationalHealth = !isStale && windows.contains {
                $0.isEnforced && $0.remainingFraction == 0
            } ? .exhausted : .healthy
            let quality: DataQuality
            if isStale {
                quality = .stale
            } else if windows.count < 2 {
                quality = .partial
            } else {
                quality = .fresh
            }

            return .provider(
                status(
                    health: health,
                    quality: quality,
                    checkedAt: checkedAt,
                    lastSuccessfulAt: payload.capturedAt,
                    message: isStale
                        ? "Claude Code quota data is stale. Start or resume a Claude Code session to refresh it."
                        : "Quota captured locally from Claude Code's status line.",
                    quotaWindows: windows
                )
            )
        } catch {
            return .provider(
                status(
                    health: .unknown,
                    quality: .unavailable,
                    checkedAt: checkedAt,
                    message: "Claude Code quota data could not be decoded."
                )
            )
        }
    }
}

private extension ClaudeCodeConnector {
    struct StatusPayload: Decodable {
        let capturedAt: Date
        let rateLimits: RateLimits

        enum CodingKeys: String, CodingKey {
            case capturedAt = "captured_at"
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let fiveHour: RateLimitWindow?
        let sevenDay: RateLimitWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    struct RateLimitWindow: Decodable {
        let usedPercentage: Double?
        let resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: value)
                ?? ISO8601DateFormatter().date(from: value)
            {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 date or Unix timestamp."
            )
        }
        return decoder
    }()

    func quotaWindows(from rateLimits: RateLimits) -> [QuotaWindow] {
        [
            quotaWindow(
                id: "claude-code-five-hour",
                name: "5-hour",
                source: rateLimits.fiveHour
            ),
            quotaWindow(
                id: "claude-code-seven-day",
                name: "Weekly",
                source: rateLimits.sevenDay
            ),
        ].compactMap { $0 }
    }

    func quotaWindow(
        id: String,
        name: String,
        source: RateLimitWindow?
    ) -> QuotaWindow? {
        guard let usedPercentage = source?.usedPercentage else { return nil }
        let clampedUsed = min(max(usedPercentage, 0), 100)
        return QuotaWindow(
            id: id,
            name: name,
            unit: .percentage,
            used: clampedUsed,
            limit: 100,
            remainingFraction: 1 - (clampedUsed / 100),
            resetsAt: source?.resetsAt
        )
    }

    func status(
        health: OperationalHealth,
        quality: DataQuality,
        checkedAt: Date,
        lastSuccessfulAt: Date? = nil,
        message: String,
        quotaWindows: [QuotaWindow] = []
    ) -> ProviderStatus {
        ProviderStatus(
            id: "claude-code-local",
            name: "Claude Code",
            role: configuration.role,
            health: health,
            observation: Observation(
                checkedAt: checkedAt,
                lastSuccessfulAt: lastSuccessfulAt,
                quality: quality,
                message: message
            ),
            quotaWindows: quotaWindows,
            detail: "Local subscription rate-limit snapshot"
        )
    }
}
