import SwiftUI
import MotasCore

struct StatusPopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            readinessHeader

            if !model.snapshot.providers.isEmpty {
                section("Providers") {
                    ForEach(model.snapshot.providers) { provider in
                        ProviderRow(provider: provider, now: Date())
                    }
                }
            }

            if !model.snapshot.proxies.isEmpty {
                section("Proxies") {
                    ForEach(model.snapshot.proxies) { proxy in
                        ProxyRow(proxy: proxy)
                    }
                }
            }

            Divider()

            HStack {
                Label(
                    "Updated \(StatusPresentation.relativeAge(of: model.snapshot.capturedAt, now: Date()))",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await model.refresh() }
                } label: {
                    Label(
                        model.isRefreshing ? "Refreshing" : "Refresh",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(model.isRefreshing)
                .keyboardShortcut("r")

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }

            if let error = model.lastRefreshError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var readinessHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.snapshot.readiness.state.symbolName)
                .font(.title2)
                .foregroundStyle(model.snapshot.readiness.state.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.snapshot.readiness.title)
                    .font(.headline)
                Text(model.snapshot.readiness.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderStatus
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            SourceHealthDot(health: provider.health)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                if let window = provider.quotaWindows
                    .filter(\.isEnforced)
                    .compactMap({ window -> (QuotaWindow, Double)? in
                        guard let value = window.remainingFraction else { return nil }
                        return (window, value)
                    })
                    .min(by: { $0.1 < $1.1 })
                {
                    Text(quotaDetail(window: window.0, remaining: window.1))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(StatusPresentation.qualityLabel(provider.observation.quality))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = provider.observation.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let remediation = StatusPresentation.remediation(
                    health: provider.health,
                    quality: provider.observation.quality
                ) {
                    Text(remediation)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(provider.health.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func quotaDetail(window: QuotaWindow, remaining: Double) -> String {
        let quality = StatusPresentation.qualityLabel(provider.observation.quality)
        let qualityPrefix = provider.observation.quality == .fresh ? "" : "\(quality) · "
        let percentage = "\(qualityPrefix)\(Int((remaining * 100).rounded()))% left · \(window.name)"
        guard let reset = StatusPresentation.resetLabel(for: window.resetsAt, now: now) else {
            return percentage
        }
        return "\(percentage) · \(reset)"
    }
}

private struct ProxyRow: View {
    let proxy: ProxyStatus

    var body: some View {
        HStack(spacing: 10) {
            SourceHealthDot(health: proxy.health)
            VStack(alignment: .leading, spacing: 2) {
                Text(proxy.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = proxy.observation.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let remediation = StatusPresentation.remediation(
                    health: proxy.health,
                    quality: proxy.observation.quality
                ) {
                    Text(remediation)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(proxy.health.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        if let tier = proxy.route?.activeTier, tier != .unknown {
            return "\(tier.displayName) tier · \(proxy.accounts.count) accounts"
        }
        return proxy.endpointLabel ?? proxy.observation.quality.displayName
    }
}

private struct SourceHealthDot: View {
    let health: OperationalHealth

    var body: some View {
        Circle()
            .fill(health.tint)
            .frame(width: 8, height: 8)
    }
}

extension ReadinessState {
    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .fallback: "arrow.triangle.branch"
        case .blocked: "xmark.octagon.fill"
        case .proxyDown: "network.slash"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .caution: .orange
        case .fallback: .blue
        case .blocked, .proxyDown: .red
        case .unknown: .secondary
        }
    }
}

private extension OperationalHealth {
    var displayName: String {
        switch self {
        case .healthy: "Healthy"
        case .degraded: "Degraded"
        case .exhausted: "Exhausted"
        case .unreachable: "Unreachable"
        case .unauthorized: "Unauthorized"
        case .unsupported: "Unsupported"
        case .unknown: "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: .green
        case .degraded: .orange
        case .exhausted, .unreachable: .red
        case .unauthorized, .unsupported, .unknown: .secondary
        }
    }
}

private extension DataQuality {
    var displayName: String {
        switch self {
        case .fresh: "Fresh"
        case .stale: "Stale"
        case .partial: "Partial"
        case .unavailable: "Unavailable"
        }
    }
}

private extension RouteTier {
    var displayName: String {
        switch self {
        case .primary: "Primary"
        case .subscription: "Subscription"
        case .economical: "Economical"
        case .free: "Free"
        case .custom: "Custom"
        case .unknown: "Unknown"
        }
    }
}
