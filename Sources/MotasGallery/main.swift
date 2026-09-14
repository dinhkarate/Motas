import AppKit
import MotasAppKit
import MotasCore
import SwiftUI

/// Render harness: `swift run MotasGallery <outputDir>` writes light/dark
/// panel PNGs for every MockData scenario plus a synthetic proxy-accounts
/// snapshot, and menu-bar icon variants. `--icon <path.png>` writes the
/// 1024x1024 app icon. Materials do not rasterize under ImageRenderer, so
/// panels render over an explicit backdrop.
@main
struct MotasGallery {
    @MainActor
    static func main() {
        let args = CommandLine.arguments.dropFirst().filter { $0 != "--" }
        if args.first == "--icon", args.count >= 2 {
            writeIcon(to: String(args[1]))
            return
        }
        guard let outputDir = args.first else {
            fputs("usage: MotasGallery <outputDir> | MotasGallery --icon <path.png>\n", stderr)
            exit(2)
        }
        runGallery(outputDir: outputDir)
    }

    @MainActor
    static func runGallery(outputDir: String) {
        let now = Date()
        let proxyAccounts = ProxyStatus(
            id: "cliproxyapi-local",
            name: "CLIProxyAPI",
            role: .primary,
            health: .healthy,
            observation: Observation(
                checkedAt: now,
                lastSuccessfulAt: now,
                quality: .fresh,
                message: "2 of 2 accounts available · quota from 1 provider windows."
            ),
            isRequiredRoute: true,
            route: RouteStatus(
                activeTier: .custom,
                primaryAvailable: true,
                fallbackAvailable: true,
                description: "Account routing is managed by CLIProxyAPI."
            ),
            accounts: [
                ProxyAccountStatus(
                    id: "a1",
                    label: "work@ · Pro",
                    provider: "claude",
                    health: .healthy,
                    quotaWindows: [
                        QuotaWindow(
                            id: "cliproxyapi/a1/claude/5-hour",
                            name: "Claude · 5-hour",
                            unit: .percentage,
                            remainingFraction: 0.62,
                            resetsAt: now.addingTimeInterval(3600),
                            isEnforced: true
                        )
                    ]
                ),
                ProxyAccountStatus(
                    id: "a2",
                    label: "personal@",
                    provider: "claude",
                    health: .healthy,
                    quotaWindows: [
                        QuotaWindow(
                            id: "cliproxyapi/a2/claude/5-hour",
                            name: "Claude · 5-hour",
                            unit: .percentage,
                            remainingFraction: 0.11,
                            resetsAt: now.addingTimeInterval(3600),
                            isEnforced: true
                        )
                    ]
                ),
            ],
            quotaWindows: [
                QuotaWindow(
                    id: "cliproxyapi/route/claude-5-hour",
                    name: "Claude · 5-hour",
                    unit: .percentage,
                    remainingFraction: 0.62,
                    resetsAt: now.addingTimeInterval(3600),
                    isEnforced: true
                )
            ],
            endpointLabel: "localhost:8317"
        )
        let scenarios: [(String, StatusSnapshot)] = [
            ("ready", MockData.readySnapshot(at: now)),
            ("caution", MockData.cautionSnapshot(at: now)),
            ("fallback", MockData.fallbackSnapshot(at: now)),
            ("proxy-down", MockData.proxyDownSnapshot(at: now)),
            ("unknown", MockData.unknownSnapshot(at: now)),
            (
                "proxy-accounts",
                StatusSnapshot(
                    capturedAt: now,
                    readiness: ReadinessAssessment(
                        state: .ready,
                        title: "Ready to build",
                        explanation: "All monitored routes report quota.",
                        evaluatedAt: now
                    ),
                    providers: [],
                    proxies: [proxyAccounts]
                )
            ),
        ]
        try? FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true)
        for (name, snapshot) in scenarios {
            for dark in [false, true] {
                let model = AppModel(previewSnapshot: snapshot)
                let view = PanelView(model: model)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(dark ? Color(white: 0.13) : Color(white: 0.96))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let nsImage = renderer.nsImage {
                    let suffix = dark ? "dark" : "light"
                    let path = (outputDir as NSString)
                        .appendingPathComponent("\(name)-\(suffix).png")
                    writePNG(nsImage, to: path)
                }
            }
        }
        for state in [ReadinessState.ready, .caution, .fallback, .proxyDown] as [ReadinessState] {
            for dark in [false, true] {
                let fraction: Double? =
                    switch state {
                    case .ready: 0.62
                    case .caution: 0.13
                    case .fallback: 0.45
                    case .proxyDown: nil
                    case .blocked: 0.0
                    case .unknown: nil
                    }
                let image = MenuBarIcon.image(
                    fraction: fraction,
                    state: state,
                    showsPercentage: true,
                    tintWhenLow: true
                )
                let suffix = dark ? "dark" : "light"
                let path = (outputDir as NSString)
                    .appendingPathComponent("menubar-\(state.rawValue)-\(suffix).png")
                writePNG(image, to: path)
            }
        }
        print("gallery written to \(outputDir)")
    }

    @MainActor
    static func writeIcon(to path: String) {
        let size: CGFloat = 1024
        let icon = ZStack {
            LinearGradient(
                colors: [Color(hex: 0x2B7CFF), Color(hex: 0x0A4CD1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            QuotaRing(
                fraction: 0.72, diameter: size * 0.52, lineWidth: size * 0.055, showsLabel: false,
                tint: .white
            )
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 224, style: .continuous))
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let nsImage = renderer.nsImage else {
            fputs("icon render failed\n", stderr)
            exit(1)
        }
        writePNG(nsImage, to: path)
        print("icon written to \(path)")
    }

    static func writePNG(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        else {
            fputs("png encode failed for \(path)\n", stderr)
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
