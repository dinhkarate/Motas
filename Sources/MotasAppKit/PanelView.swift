import MotasCore
import SwiftUI

public struct PanelView: View {
    @ObservedObject public var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero
            if model.snapshot.providers.isEmpty, model.snapshot.proxies.isEmpty,
                !model.isDemoMode
            {
                emptyState
            } else {
                sourcesSection
            }
            Divider()
            footer
            if let error = model.lastRefreshError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(MotasTheme.panelPadding)
        .frame(width: MotasTheme.panelWidth)
    }

    private var hero: some View {
        let tightest = StatusPresentation.tightestWindow(
            providers: model.snapshot.providers,
            proxies: model.snapshot.proxies
        )
        return HStack(spacing: 12) {
            if let tightest {
                QuotaRing(fraction: tightest.remainingFraction)
            } else {
                Image(systemName: model.snapshot.readiness.state.symbolName)
                    .font(.system(size: 26))
                    .foregroundStyle(model.snapshot.readiness.state.tint)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle().fill(model.snapshot.readiness.state.tint.opacity(0.15))
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.snapshot.readiness.title)
                        .font(.headline)
                    if model.isDemoMode {
                        Text("DEMO")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                }
                Text(model.snapshot.readiness.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let tightest {
                    Text(
                        "\(tightest.name) · \(StatusPresentation.resetLabel(for: tightest.resetsAt, now: Date()) ?? "no reset time")"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: MotasTheme.tileSpacing) {
            Text("SOURCES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.snapshot.providers) { provider in
                Tile {
                    providerTile(provider)
                }
            }
            ForEach(model.snapshot.proxies) { proxy in
                Tile {
                    proxyTile(proxy)
                }
            }
        }
    }

    private func providerTile(_ provider: ProviderStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(provider.health.tint)
                    .frame(width: 7, height: 7)
                Text(provider.name)
                    .font(.system(.body, weight: .medium))
                Spacer()
                Text(provider.health.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(provider.quotaWindows.filter(\.isEnforced)) { window in
                QuotaBar(window: window)
            }
            if let remediation = StatusPresentation.remediation(
                health: provider.health,
                quality: provider.observation.quality
            ) {
                Label(remediation, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func proxyTile(_ proxy: ProxyStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(proxy.health.tint)
                    .frame(width: 7, height: 7)
                Text(proxy.name)
                    .font(.system(.body, weight: .medium))
                Spacer()
                Text(proxy.endpointLabel ?? proxy.health.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(proxySubtitle(proxy))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(proxy.quotaWindows.filter(\.isEnforced)) { window in
                QuotaBar(window: window)
            }
            if !proxy.accounts.isEmpty {
                DisclosureGroup("Accounts") {
                    ForEach(proxy.accounts) { account in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(account.health.tint)
                                .frame(width: 6, height: 6)
                            Text(account.label)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            ForEach(account.quotaWindows.filter(\.isEnforced)) { window in
                                if let fraction = window.remainingFraction {
                                    Text(
                                        "\(Int((fraction * 100).rounded()))% · \(window.name)"
                                    )
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .font(.caption)
            }
            if proxy.quotaWindows.isEmpty, !proxy.accounts.isEmpty {
                Text("Quota not exposed by this proxy build.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let remediation = StatusPresentation.remediation(
                health: proxy.health,
                quality: proxy.observation.quality
            ) {
                Label(remediation, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func proxySubtitle(_ proxy: ProxyStatus) -> String {
        var clauses: [String] = []
        if !proxy.accounts.isEmpty {
            let usable = proxy.accounts.filter { $0.health == .healthy }.count
            clauses.append("\(usable) of \(proxy.accounts.count) accounts")
        }
        if let tier = proxy.route?.activeTier, tier != .unknown {
            clauses.append("\(tier.displayName) tier")
        }
        return clauses.joined(separator: " · ")
    }

    private var emptyState: some View {
        Tile {
            VStack(alignment: .leading, spacing: 6) {
                Text("No source connected")
                    .font(.headline)
                Text("Point Motas at CLIProxyAPI or 9Router to see live quota.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsLink {
                    Text("Open Settings")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(
                "Updated \(StatusPresentation.relativeAge(of: model.snapshot.capturedAt, now: Date()))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                PanelIconButton(systemName: "arrow.clockwise", help: "Refresh") {
                    Task { await model.refresh(trigger: .manual) }
                }
                .keyboardShortcut("r")
            }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Settings")
            PanelIconButton(systemName: "power", help: "Quit Motas") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

private struct PanelIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.10 : 0)))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

extension ReadinessState {
    public var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .fallback: "arrow.triangle.branch"
        case .blocked: "xmark.octagon.fill"
        case .proxyDown: "network.slash"
        case .unknown: "questionmark.circle.fill"
        }
    }

    public var tint: Color {
        switch self {
        case .ready: .green
        case .caution: .orange
        case .fallback: .blue
        case .blocked, .proxyDown: .red
        case .unknown: .secondary
        }
    }
}

extension OperationalHealth {
    public var displayName: String {
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

    public var tint: Color {
        switch self {
        case .healthy: .green
        case .degraded: .orange
        case .exhausted, .unreachable: .red
        case .unauthorized, .unsupported, .unknown: .secondary
        }
    }
}

extension RouteTier {
    public var displayName: String {
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
