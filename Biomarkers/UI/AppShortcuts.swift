import SwiftUI

/// Quick-launch buttons that open the companion apps (Oura, Garmin Connect,
/// Renpho). Tries the app's URL scheme; if it isn't installed, falls back to
/// its App Store page. Badges are stylized brand marks, not official logos.
struct AppShortcuts: View {
    @Environment(\.openURL) private var openURL

    private struct Provider {
        let name: String
        let scheme: String
        let appStore: String
        let badge: AnyView
        let tint: Color
    }

    private var providers: [Provider] {
        [
            Provider(name: "Oura", scheme: "oura://",
                     appStore: "https://apps.apple.com/app/id1043837948",
                     badge: AnyView(OuraMark()), tint: Color(hex: 0x6C5CE7)),
            Provider(name: "Garmin", scheme: "gcm://",
                     appStore: "https://apps.apple.com/app/id583446403",
                     badge: AnyView(GarminMark()), tint: Color(hex: 0x007CC3)),
            Provider(name: "Renpho", scheme: "renpho://",
                     appStore: "https://apps.apple.com/app/id1522571121",
                     badge: AnyView(RenphoMark()), tint: Color(hex: 0x00B3A4)),
        ]
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(providers, id: \.name) { p in
                Button { open(p) } label: {
                    VStack(spacing: 6) {
                        p.badge.frame(width: 30, height: 30)
                        HStack(spacing: 3) {
                            Text(p.name).font(.subheadline.weight(.semibold))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(p.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
    }

    private func open(_ p: Provider) {
        guard let url = URL(string: p.scheme) else { return }
        openURL(url) { accepted in
            if !accepted, let store = URL(string: p.appStore) { openURL(store) }
        }
    }
}

// MARK: - Stylized brand marks

private struct OuraMark: View {
    var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0x1B1B2F))
            Circle().stroke(Color.white, lineWidth: 2.4).padding(6)
        }
    }
}

private struct GarminMark: View {
    var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0x007CC3))
            Image(systemName: "triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct RenphoMark: View {
    var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0x00B3A4))
            Text("R").font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
