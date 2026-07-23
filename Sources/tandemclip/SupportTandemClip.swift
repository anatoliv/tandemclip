import SwiftUI
import Foundation

// MARK: - Donation links

/// Tip-jar destinations shown in Settings → General. TandemClip is free and MIT-licensed;
/// these let people who want to support the project pick whichever platform they prefer.
///
/// To turn a button on, set its handle (leave `nil` to hide the button). GitHub Sponsors is the
/// natural fit for an open-source project; the others are here so users aren't forced onto one
/// service. Keep these in sync with `.github/FUNDING.yml`.
enum TandemSupportLinks {
    /// github.com/sponsors/<handle>
    static let gitHubSponsorsHandle: String? = "anatoliv"
    /// ko-fi.com/<handle>
    static let koFiHandle: String? = "anatolivishnyakov"
    /// paypal.me/<handle>
    static let payPalHandle: String? = "anatolivishnyakov"

    /// Where users vote on what to build next — open issues labelled `roadmap`, sorted by 👍
    /// reactions. The label filter keeps bug reports out so the page is purely candidate features.
    static let roadmapURL = URL(string: "https://github.com/anatoliv/tandemclip/issues?q=is%3Aissue+is%3Aopen+label%3Aroadmap+sort%3Areactions-%2B1-desc")!

    struct Option: Identifiable {
        let id: String
        let title: String       // full label for buttons (Settings)
        let shortTitle: String  // compact label for the About window's text row
        let symbol: String
        let url: URL
    }

    /// Only the platforms you've configured a handle for, in a stable display order.
    static var options: [Option] {
        var out: [Option] = []
        if let h = gitHubSponsorsHandle, let url = URL(string: "https://github.com/sponsors/\(h)") {
            out.append(.init(id: "github", title: "GitHub Sponsors", shortTitle: "Sponsor", symbol: "heart.fill", url: url))
        }
        if let h = koFiHandle, let url = URL(string: "https://ko-fi.com/\(h)") {
            out.append(.init(id: "kofi", title: "Ko-fi", shortTitle: "Ko-fi", symbol: "cup.and.saucer.fill", url: url))
        }
        if let h = payPalHandle, let url = URL(string: "https://paypal.me/\(h)") {
            out.append(.init(id: "paypal", title: "PayPal", shortTitle: "PayPal", symbol: "dollarsign.circle.fill", url: url))
        }
        return out
    }

    /// A compact "Sponsor · Ko-fi · PayPal" run of links for tight surfaces (the About window),
    /// each platform linked. Only configured platforms appear.
    static var compactLinks: AttributedString {
        var out = AttributedString()
        for (index, option) in options.enumerated() {
            if index > 0 { out += AttributedString("  ·  ") }
            var chip = AttributedString(option.shortTitle)
            chip.link = option.url
            out += chip
        }
        return out
    }
}

// MARK: - Supporters (remote, opt-in recognition)

/// One name to thank in Settings. `url` is optional — when present the name links out. Recognition
/// is opt-in: people appear here only after they ask to be listed.
struct TandemSupporter: Decodable, Identifiable, Hashable {
    let name: String
    let url: URL?
    var id: String { name }
}

private struct TandemSupporterList: Decodable {
    let version: Int?
    let supporters: [TandemSupporter]
}

/// Loads the "Thanks to our supporters" list from `tandemclip.com/supporters.json` so names can be
/// added by redeploying the site — no app release required. The last good copy is cached in
/// Application Support, so the list paints instantly and survives offline; a background refresh
/// keeps it current. If the fetch fails and there's no cache, the section simply hides.
final class TandemSupportersStore: ObservableObject {
    @Published private(set) var supporters: [TandemSupporter] = []

    private var loaded = false
    private let remoteURL: URL
    private let cacheURL: URL

    init(remoteURL: URL = URL(string: "https://tandemclip.com/supporters.json")!) {
        self.remoteURL = remoteURL
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TandemClip", isDirectory: true)
        cacheURL = dir.appendingPathComponent("supporters.json")
    }

    /// Paints the cached list, then refreshes from the site. Safe to call from `.task` on every
    /// appearance — the cache read happens once.
    @MainActor
    func loadIfNeeded() async {
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: cacheURL),
               let list = try? JSONDecoder().decode(TandemSupporterList.self, from: data) {
                supporters = list.supporters
            }
        }
        await refresh()
    }

    @MainActor
    private func refresh() async {
        do {
            var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.setValue("TandemClip (macOS; Support)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) { return }
            let list = try JSONDecoder().decode(TandemSupporterList.self, from: data)
            supporters = list.supporters
            try? data.write(to: cacheURL, options: .atomic) // best-effort cache
        } catch {
            // Offline or no list yet — keep whatever the cache gave us; the section hides if empty.
        }
    }
}

// MARK: - Settings section

/// "Support TandemClip" — the tip-jar buttons plus an opt-in supporter thank-you list. Drops into
/// the grouped `Form` of the General settings tab. TandemClip stays free and MIT under all of this;
/// tips fund sustainability, and the list is recognition, not a paywall.
struct SupportTandemClipSection: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var store = TandemSupportersStore()

    private let options = TandemSupportLinks.options

    var body: some View {
        Section {
            Text("TandemClip is free and open source. If it earns a place in your workflow, a one-time tip helps keep it maintained — entirely optional, and it never unlocks anything.")
                .font(.callout).foregroundStyle(.secondary)

            if !options.isEmpty {
                // All donation buttons on one row, sharing width equally.
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        Button {
                            openURL(option.url)
                        } label: {
                            Label(option.title, systemImage: option.symbol)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .help("Opens \(option.url.host ?? option.title) in your browser")
                    }
                }
                .buttonStyle(.bordered)
                .padding(.vertical, 2)
            }

            Link(destination: TandemSupportLinks.roadmapURL) {
                Label("Vote on what's next", systemImage: "arrow.up.heart")
                    .font(.callout)
            }

            if !store.supporters.isEmpty {
                Divider()
                Text("Thanks to our supporters")
                    .font(.callout.weight(.semibold))
                TandemSupportersFlow(supporters: store.supporters)
            }
        } header: {
            Text("Support TandemClip")
        }
        .task { await store.loadIfNeeded() }
    }
}

/// Supporter names as a soft, wrapping run. Names with a `url` link out; the rest are plain text.
private struct TandemSupportersFlow: View {
    let supporters: [TandemSupporter]

    var body: some View {
        Text(attributed)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for (index, supporter) in supporters.enumerated() {
            if index > 0 { out += AttributedString("  ·  ") }
            var chip = AttributedString(supporter.name)
            if let url = supporter.url { chip.link = url }
            out += chip
        }
        return out
    }
}
