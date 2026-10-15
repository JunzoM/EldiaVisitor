import SwiftUI

// MARK: - ホーム（7カテゴリと検索）

struct ManualHomeView: View {
    @Environment(ManualStore.self) private var manual
    @State private var query = ""
    @State private var voice = VoiceSearch()
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: sizeClass == .regular ? 4 : 2)
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let err = manual.lastError {
                    NoticeBanner(text: err, symbol: "wifi.exclamationmark")
                }
                searchBar
                voiceStatus
                if isSearching {
                    ManualSearchResultsView(result: manual.search(query))
                } else {
                    categories
                    if let run = manual.run, !run.finished, let card = manual.card(run.cardID) {
                        ResumeBanner(card: card)
                    }
                }
            }
            .padding(20)
        }
        .background(Palette.ground)
        .navigationTitle("フロントマニュアル")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await manual.load() }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            searchField
            VoiceSearchButton(voice: voice)
        }
        .onAppear { voice.onText = { query = $0 } }
        .onDisappear { voice.stopAll() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.sub)
            TextField("言葉で探す（例：お釣り）", text: $query)
                .font(.title3)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.sub)
                }
                .accessibilityLabel("検索を消す")
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var voiceStatus: some View {
        if voice.listening {
            Label("聞いています…話し終わったらボタンを離してください", systemImage: "waveform")
                .font(.headline)
                .foregroundStyle(Palette.sunday)
                .symbolEffect(.variableColor.iterative, isActive: true)
        } else if let err = voice.error {
            Text(err).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.sunday)
        }
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("何について調べますか？")
                .font(.system(size: 26, weight: .heavy))
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(ManualCategory.allCases) { c in
                    NavigationLink(value: ManualRoute.category(c)) {
                        CategoryTile(category: c, count: manual.cards(in: c).count)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 音声検索ボタン（押している間だけ聞き取り、離すと止めて検索する）

struct VoiceSearchButton: View {
    let voice: VoiceSearch

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: voice.listening ? "waveform" : "mic.fill")
            Text(voice.listening ? "離すと検索" : "押して話す")
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
        .background(voice.listening ? Palette.sunday : Palette.teal, in: RoundedRectangle(cornerRadius: 14))
        .scaleEffect(voice.listening ? 1.06 : 1)
        .animation(.easeOut(duration: 0.15), value: voice.listening)
        .fixedSize()
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onLongPressGesture(minimumDuration: 600, maximumDistance: 120, perform: {
            voice.release()
        }, onPressingChanged: { down in
            if down { voice.press() } else { voice.release() }
        })
        .sensoryFeedback(.start, trigger: voice.listening) { _, now in now }
        .sensoryFeedback(.stop, trigger: voice.listening) { old, now in old && !now }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("押して話す")
        .accessibilityHint("押している間だけ聞き取り、離すと検索します")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 検索結果

struct ManualSearchResultsView: View {
    let result: ManualSearch.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !result.keywords.isEmpty { keywordChips }
            if result.hits.isEmpty {
                Text("見つかりません。別の言葉で探すか、上のカテゴリから選んでください")
                    .font(.title3).foregroundStyle(Palette.sub)
                    .padding(.top, 8)
            } else {
                if !result.full.isEmpty {
                    if result.keywords.count > 1 { sectionTitle("すべての言葉に当てはまる") }
                    hitList(result.full)
                }
                if !result.partial.isEmpty {
                    sectionTitle(result.full.isEmpty ? "近いもの（一部の言葉に当てはまる）" : "ほかの候補（一部の言葉に当てはまる）")
                        .padding(.top, result.full.isEmpty ? 0 : 8)
                    hitList(result.partial)
                }
            }
        }
    }

    private var keywordChips: some View {
        HStack(spacing: 8) {
            Text("探した言葉").font(.subheadline.weight(.bold)).foregroundStyle(Palette.sub)
            ForEach(result.keywords, id: \.self) { k in
                Text(k)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Palette.teal)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Palette.tealSoft, in: Capsule())
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(Palette.ink2)
    }

    private func hitList(_ hits: [ManualSearch.Hit]) -> some View {
        VStack(spacing: 10) {
            ForEach(hits) { h in
                NavigationLink(value: ManualRoute.card(h.card.id)) {
                    CardRow(card: h.card, showCategory: true)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 続きから見る

private struct ResumeBanner: View {
    let card: ManualCard

    var body: some View {
        NavigationLink(value: ManualRoute.card(card.id)) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.forward.circle.fill")
                    .font(.title)
                    .foregroundStyle(Palette.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("続きから見る").font(.footnote.weight(.bold)).foregroundStyle(Palette.sub)
                    Text(card.title).font(.title3.weight(.bold)).foregroundStyle(Color.primary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Palette.sub)
            }
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}
