import SwiftUI

/// 記録画面。
/// - iPad：横幅が広いときは2店舗を左右に並べ、上のバーにアカウント・マニュアル・分析
/// - iPhone 縦：店舗を切り替えて1店舗ずつ。左上の丸いボタンにアカウント・分析・マニュアルをまとめる
/// - iPhone 横：1店舗ずつ。右のドックで店舗の切り替えと、アカウント・分析・マニュアル
struct RecordView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(LogStore.self) private var logs
    @Environment(ManualStore.self) private var manual
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showManual = false
    @State private var showAnalysis = false
    @State private var drafts: [StoreID: Draft] = [.modern: Draft(), .luxury: Draft()]
    @State private var selected: StoreID = .modern
    @State private var confirmLogout = false
    @State private var landscape = false

    private let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    private var isWide: Bool { !isPhone && sizeClass == .regular }
    /// iPad 横向き：時計を上のバーに移し、ボタンを低くして1画面に収める
    private var compact: Bool { isWide && landscape }

    var body: some View {
        NavigationStack {
            Group {
                if isPhone {
                    if landscape { phoneLandscape } else { phonePortrait }
                } else {
                    padLayout
                }
            }
            .background(Palette.ground)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { landscape = g.size.width > g.size.height }
                        .onChange(of: g.size) { _, size in landscape = size.width > size.height }
                }
            )
            .navigationDestination(isPresented: $showAnalysis) { AnalysisView() }
            .fullScreenCover(isPresented: $showManual, onDismiss: { manual.endEditing() }) {
                ManualRootView()
            }
            .confirmationDialog("ログアウトしますか？", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("ログアウト", role: .destructive) {
                    logs.stop()
                    auth.signOut()
                }
            } message: {
                Text(logs.pending.isEmpty ? "" : "未送信の記録 \(logs.pending.count)件 は端末に残り、次回ログイン後に送信されます。")
            }
        }
    }

    private var actions: AppActions {
        AppActions(analysis: { showAnalysis = true },
                   manual: { showManual = true },
                   logout: { confirmLogout = true })
    }

    // MARK: iPhone 縦

    private var phonePortrait: some View {
        ScrollView {
            VStack(spacing: 16) {
                ClockHeader(large: false)
                SyncErrorBanner()
                Picker("店舗", selection: $selected) {
                    ForEach(StoreID.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                StorePanel(store: selected, draft: binding(selected), wide: false)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await logs.syncNow() }
        // 左上の丸いボタン（押すとアカウント・分析・マニュアルが開く）
        .overlay(alignment: .topLeading) {
            ActionCluster(actions: actions)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: iPhone 横

    private var phoneLandscape: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    CompactClock()
                        .frame(maxWidth: .infinity)
                    SyncErrorBanner()
                    StorePanel(store: selected, draft: binding(selected), wide: false, compact: true, sideBySide: true)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }
            .refreshable { await logs.syncNow() }
            SideDock(selected: $selected, actions: actions)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: iPad

    private var padLayout: some View {
        ScrollView {
            VStack(spacing: compact ? 10 : 16) {
                if !compact { ClockHeader(large: isWide) }
                SyncErrorBanner()
                if isWide {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(StoreID.allCases) { s in
                            StorePanel(store: s, draft: binding(s), wide: true, compact: compact)
                        }
                    }
                } else {
                    Picker("店舗", selection: $selected) {
                        ForEach(StoreID.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.large)
                    StorePanel(store: selected, draft: binding(selected), wide: false)
                }
            }
            .padding(.horizontal, isWide ? 20 : 16)
            .padding(.top, compact ? 6 : 0)
            .padding(.bottom, 24)
        }
        .refreshable { await logs.syncNow() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if compact { CompactClock() }
            }
            ToolbarItem(placement: .topBarLeading) {
                AccountMenu { confirmLogout = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showManual = true
                } label: {
                    // ツールバーは Label だとアイコンだけになるので、文字を必ず出す自前の見た目にする
                    HStack(spacing: 6) {
                        Image(systemName: "book.pages")
                        Text(manual.run.map { $0.finished ? "フロントマニュアル" : "フロントマニュアル（続き）" } ?? "フロントマニュアル")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Palette.teal, in: Capsule())
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("フロントマニュアルを開く")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAnalysis = true
                } label: {
                    Label("分析", systemImage: "chart.bar.xaxis")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private func binding(_ s: StoreID) -> Binding<Draft> {
        Binding(get: { drafts[s] ?? Draft() }, set: { drafts[s] = $0 })
    }
}

/// 記録画面から開く先（分析・マニュアル・ログアウト確認）
struct AppActions {
    let analysis: () -> Void
    let manual: () -> Void
    let logout: () -> Void
}

// MARK: - 上部の小さな部品
// 同期のたびに変わる値（エラー・最終同期時刻・未送信）は、それを使う部品の中だけで読む。
// こうすると10秒ごとの同期で記録画面全体が描き直されない。

/// 通信エラー・未送信の表示
struct SyncErrorBanner: View {
    @Environment(LogStore.self) private var logs
    var body: some View {
        if let err = logs.lastError {
            Label(err, systemImage: "exclamationmark.icloud")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.warnInk)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Palette.warnFill, in: Capsule())
        }
    }
}

/// 左上のアカウントメニュー（メール・最終同期・ログアウト）
struct AccountMenu: View {
    @Environment(AuthManager.self) private var auth
    @Environment(LogStore.self) private var logs
    let onLogout: () -> Void

    var body: some View {
        Menu {
            Text(auth.email)
            if let t = logs.lastSync {
                Text("最終同期 \(JST.hms.string(from: t))")
            }
            Button("ログアウト", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                onLogout()
            }
        } label: {
            Image(systemName: logs.pending.isEmpty ? "person.crop.circle" : "icloud.slash")
        }
    }
}

// MARK: - 時計（中央）

struct ClockHeader: View {
    var large: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 4) {
                Text(JST.hms.string(from: ctx.date))
                    .font(.system(size: large ? 60 : 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(JST.dateLong.string(from: ctx.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.sub)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }
}

/// iPad 横向き用：上のバーに1行で表示する時計
struct CompactClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(JST.hms.string(from: ctx.date))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(JST.dateLong.string(from: ctx.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.sub)
            }
        }
    }
}


// MARK: - 店舗ごとの入力パネル

/// 画面の向き・幅で変わる寸法をまとめたもの
struct PanelMetrics {
    let wide: Bool
    let compact: Bool
    /// iPhone 横向き：人数ボタンを左、客層・記録ボタンを右に並べる
    var sideBySide: Bool = false
    /// 客層のチップを1行に並べる（iPad 横向きだけ。iPhone 横向きは幅が足りないので折り返す）
    var segmentsInOneRow: Bool { compact && !sideBySide }

    /// 人数ボタンの高さ
    var cellHeight: CGFloat { compact ? 38 : (wide ? 56 : 48) }
    /// 年代の見出しの文字の大きさと幅
    var ageFontSize: CGFloat { compact ? 22 : (wide ? 26 : 21) }
    var labelWidth: CGFloat { compact ? 86 : (wide ? 96 : 78) }
    var genderHeaderHeight: CGFloat { compact ? 30 : 36 }
    var segmentChipHeight: CGFloat { compact ? 34 : 38 }
    var actionHeight: CGFloat { compact ? 40 : 46 }
    var historyRowHeight: CGFloat { compact ? 44 : 52 }
    var cardPadding: CGFloat { compact ? 10 : 14 }
    var sectionSpacing: CGFloat { compact ? 6 : 8 }
}

struct StorePanel: View {
    let store: StoreID
    @Binding var draft: Draft
    let wide: Bool
    var compact: Bool = false
    var sideBySide: Bool = false
    @Environment(LogStore.self) private var logs
    @State private var deleting: DisplayLog?

    private var metrics: PanelMetrics { PanelMetrics(wide: wide, compact: compact, sideBySide: sideBySide) }

    var body: some View {
        VStack(spacing: compact ? 10 : 12) {
            StoreInputCard(store: store, draft: $draft, wide: wide, metrics: metrics)
            StoreHistoryCard(store: store, metrics: metrics) { deleting = $0 }
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.increase, trigger: draft.total)
        .confirmationDialog("この記録を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { item in
            Button("削除", role: .destructive) {
                Task { await logs.delete(item) }
            }
        } message: { item in
            Text("\(JST.hm.string(from: item.log.visited_at))　\(item.log.summary)（\(item.log.segment.label)）")
        }
    }
}

// MARK: 入力カード

struct StoreInputCard: View {
    let store: StoreID
    @Binding var draft: Draft
    let wide: Bool
    let metrics: PanelMetrics
    @Environment(LogStore.self) private var logs

    var body: some View {
        VStack(spacing: 0) {
            StoreTodayHeader(store: store, compact: metrics.compact)

            Group {
                if metrics.sideBySide {
                    // iPhone 横向き：左に人数ボタン、右に客層と記録ボタン
                    HStack(alignment: .top, spacing: 12) {
                        AgeGenderGrid(draft: $draft, metrics: metrics)
                            .frame(maxWidth: .infinity)
                        VStack(spacing: metrics.sectionSpacing) {
                            FrequentComboBar(store: store, draft: $draft, compact: metrics.compact)
                            SegmentPicker(draft: $draft, metrics: metrics)
                            Divider().padding(.vertical, 2)
                            DraftSummaryRow(draft: $draft)
                            actionRow
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: metrics.sectionSpacing) {
                        AgeGenderGrid(draft: $draft, metrics: metrics)
                        FrequentComboBar(store: store, draft: $draft, compact: metrics.compact)
                        SegmentPicker(draft: $draft, metrics: metrics)
                            .padding(.top, metrics.compact ? 2 : 4)
                        Divider().padding(.vertical, metrics.compact ? 2 : 4)
                        DraftSummaryRow(draft: $draft)
                        actionRow
                    }
                }
            }
            .padding(metrics.cardPadding)
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    // 一つ戻す：クリア：記録する ＝ 1：1：2（どの iOS でも同じ見た目の自前ボタン）
    private var actionRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ActionButton(title: "一つ戻す", fill: Palette.quietFill, foreground: Color.primary,
                             height: metrics.actionHeight) { draft.undo() }
                    .disabled(draft.taps.isEmpty)
                ActionButton(title: "クリア", fill: Palette.quietFill, foreground: Color.primary,
                             height: metrics.actionHeight) { draft.clear() }
                    .disabled(draft.isPristine)
            }
            .frame(maxWidth: .infinity)
            ActionButton(title: wide ? "記録する" : "\(store.label) に記録", fill: store.accent, foreground: .white,
                         height: metrics.actionHeight, bold: true) {
                logs.record(store: store, draft: draft)
                draft.clear()
            }
            .disabled(!draft.canRecord)
            .frame(maxWidth: .infinity)
        }
    }
}

/// 店舗名と今日の組数・人数（同期で変わるのはここだけ）
struct StoreTodayHeader: View {
    let store: StoreID
    let compact: Bool
    @Environment(LogStore.self) private var logs

    var body: some View {
        let today = logs.today(for: store)
        VStack(spacing: 2) {
            Text(store.label).font(.title3.weight(.heavy))
            Text("今日 \(today.groups)組・\(today.people)名").font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(store.deep)
        .padding(.horizontal, 16).padding(.vertical, compact ? 8 : 12)
        .background(store.soft)
    }
}

/// 男女 × 年代の人数ボタン
struct AgeGenderGrid: View {
    @Binding var draft: Draft
    let metrics: PanelMetrics

    var body: some View {
        VStack(spacing: metrics.sectionSpacing) {
            HStack(spacing: 8) {
                Color.clear.frame(width: metrics.labelWidth, height: 1)
                ForEach(Gender.allCases) { g in
                    Label(g.label, systemImage: g.symbol)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: metrics.genderHeaderHeight)
                        .background(g.color, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            ForEach(AgeBand.allCases) { a in
                HStack(spacing: 8) {
                    // 年配のスタッフでも読みやすいよう、全段同じ大きさの太字で表示
                    Text(a.label)
                        .font(.system(size: metrics.ageFontSize, weight: .heavy))
                        .foregroundStyle(Color.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .frame(width: metrics.labelWidth, alignment: .leading)
                    ForEach(Gender.allCases) { g in
                        CountButton(gender: g, age: a, count: draft.count(g, a), height: metrics.cellHeight) {
                            draft.add(g, a)
                        }
                    }
                }
            }
        }
    }
}

/// よく使う組み合わせ（直近30日で3回以上・上位3つ）。押すと人数と客層がまとめて入る。
/// 記録がたまるまでは何も表示しない
struct FrequentComboBar: View {
    let store: StoreID
    @Binding var draft: Draft
    let compact: Bool
    @Environment(LogStore.self) private var logs

    var body: some View {
        let combos = logs.frequent[store] ?? []
        if !combos.isEmpty {
            HStack(spacing: 6) {
                Text("よく使う")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Palette.sub)
                    .fixedSize()
                ForEach(combos) { c in
                    Button {
                        draft.fill(segment: c.segment, with: c)
                    } label: {
                        Text(c.label)
                            .font(.footnote.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(Palette.teal)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: compact ? 30 : 34)
                            .background(Capsule().fill(Color.white))
                            .overlay(Capsule().strokeBorder(Palette.chipBorder, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("よく使う組み合わせ \(c.label) を入れる")
                }
            }
        }
    }
}

/// 客層（1つ選択）とデリヘルの注意書き
struct SegmentPicker: View {
    @Binding var draft: Draft
    let metrics: PanelMetrics

    private var gridColumns: [GridItem] {
        metrics.segmentsInOneRow ? Array(repeating: GridItem(.flexible(), spacing: 4), count: Segment.allCases.count)
                        : [GridItem(.adaptive(minimum: 80), spacing: 6)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("客層（1つ選択）").font(.footnote.weight(.bold)).foregroundStyle(Palette.ink2)
            LazyVGrid(columns: gridColumns, spacing: 6) {
                ForEach(Segment.allCases) { s in
                    SegmentChip(segment: s, selected: draft.segment == s, height: metrics.segmentChipHeight) {
                        draft.segment = s
                    }
                }
            }
            if draft.segment == .deli {
                Text(draft.deliHasMale ? "デリヘルは女性のみ記録できます。男性は「一般」で別に記録してください"
                                       : "デリヘルは女性1名のみ記録（男性は「一般」で別に記録）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(draft.deliHasMale ? Palette.sunday : Palette.teal)
            }
        }
    }
}

/// 「この組」の内容・来店時刻・合計人数
struct DraftSummaryRow: View {
    @Binding var draft: Draft

    private static let minuteOptions = [0, 5, 10, 15]
    private var delayed: Bool { draft.minutesAgo > 0 }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(delayed ? "この組（\(draft.minutesAgo)分前の来店として記録）" : "この組")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(delayed ? Palette.sunday : Palette.sub)
                Text(draft.isEmpty ? "タップして人数を追加" : draft.summary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
            arrivalMenu
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(draft.total)")
                    .font(.system(size: 30, weight: .bold)).monospacedDigit()
                Text("名").font(.subheadline).foregroundStyle(Palette.sub)
            }
        }
    }

    // 記録が遅れたときだけ使う、来店時刻の小さなボタン（押すと選択肢が出る）
    private var arrivalMenu: some View {
        Menu {
            ForEach(Self.minuteOptions, id: \.self) { m in
                Button(m == 0 ? "今（通常）" : "\(m)分前に来店") { draft.minutesAgo = m }
            }
        } label: {
            Label(delayed ? "\(draft.minutesAgo)分前" : "今", systemImage: "clock")
                .font(.footnote.weight(.bold))
                .foregroundStyle(delayed ? Color.white : Palette.sub)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(delayed ? Palette.sunday : Palette.ground))
        }
        .accessibilityLabel("来店時刻")
    }
}

// MARK: 直前5組

struct StoreHistoryCard: View {
    let store: StoreID
    let metrics: PanelMetrics
    let onDelete: (DisplayLog) -> Void
    @Environment(LogStore.self) private var logs

    var body: some View {
        let items = logs.recent(for: store)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(store.label)
                    .font(.footnote.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(store.soft, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(store.deep)
                Text("直前5組").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            if items.isEmpty {
                Text("まだ記録がありません")
                    .font(.subheadline).foregroundStyle(Palette.sub)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            ForEach(items) { item in
                HistoryRow(item: item, minHeight: metrics.historyRowHeight) { onDelete(item) }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 6)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct HistoryRow: View {
    let item: DisplayLog
    let minHeight: CGFloat
    let onDelete: () -> Void

    var body: some View {
        let time = JST.hm.string(from: item.log.visited_at)
        HStack(spacing: 10) {
            Text(time)
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.log.summary).font(.subheadline).lineLimit(1)
                Text(item.log.segment.label).font(.caption.weight(.bold)).foregroundStyle(Palette.teal)
            }
            Spacer(minLength: 4)
            if item.isPending {
                Image(systemName: "icloud.slash").font(.caption).foregroundStyle(Palette.pending)
                    .accessibilityLabel("未送信")
            }
            Text("\(item.log.total)名").font(.subheadline.weight(.bold)).foregroundStyle(Palette.ink2)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.sunday)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(time)の記録を削除")
        }
        .frame(minHeight: minHeight)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .contextMenu {
            Button("この記録を削除", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

struct CountButton: View {
    let gender: Gender
    let age: AgeBand
    let count: Int
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(count > 0 ? "\(count)名" : "＋")
                .font(.system(size: height > 52 ? 22 : 19, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? Color.white : gender.color)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(RoundedRectangle(cornerRadius: 14).fill(count > 0 ? gender.color : gender.soft))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(count > 0 ? gender.color : gender.border, lineWidth: 1.5))
                .shadow(color: count > 0 ? gender.color.opacity(0.35) : .clear, radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(gender.label) \(age.label) を1名追加。現在\(count)名")
    }
}

struct SegmentChip: View {
    let segment: Segment
    let selected: Bool
    var height: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(segment.label)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(selected ? Color.white : Palette.ink2)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(Capsule().fill(selected ? Palette.teal : Color.white))
                .overlay(Capsule().strokeBorder(selected ? Palette.teal : Palette.chipBorder, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 記録欄の操作ボタン（OS の標準ボタンに頼らず、iPadOS 17 でも潰れない）
struct ActionButton: View {
    let title: String
    let fill: Color
    let foreground: Color
    var height: CGFloat = 46
    var bold: Bool = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(bold ? .headline : .subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(foreground)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(RoundedRectangle(cornerRadius: 12).fill(fill))
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}
