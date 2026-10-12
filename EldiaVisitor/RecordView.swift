import SwiftUI

/// 記録画面。iPad（横幅が広い）は2店舗を左右に並べ、iPhone は店舗を切り替える。
struct RecordView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(LogStore.self) private var logs
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var drafts: [StoreID: Draft] = [.modern: Draft(), .luxury: Draft()]
    @State private var selected: StoreID = .modern
    @State private var confirmLogout = false
    @State private var landscape = false

    private var isWide: Bool { sizeClass == .regular }
    /// iPad 横向き：時計を上のバーに移し、ボタンを低くして1画面に収める
    private var compact: Bool { isWide && landscape }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: compact ? 10 : 16) {
                    if !compact { ClockHeader(large: isWide) }
                    if let err = logs.lastError {
                        Label(err, systemImage: "exclamationmark.icloud")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(hex: 0x6B4E06))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color(hex: 0xF5E9C8), in: Capsule())
                    }
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
            .background(Palette.ground)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { landscape = g.size.width > g.size.height }
                        .onChange(of: g.size) { _, size in landscape = size.width > size.height }
                }
            )
            .refreshable { await logs.syncNow() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if compact { CompactClock() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Text(auth.email)
                        if let t = logs.lastSync {
                            Text("最終同期 \(JST.hms.string(from: t))")
                        }
                        Button("ログアウト", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            confirmLogout = true
                        }
                    } label: {
                        Image(systemName: logs.pending.isEmpty ? "person.crop.circle" : "icloud.slash")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AnalysisView()
                    } label: {
                        Label("分析", systemImage: "chart.bar.xaxis")
                            .labelStyle(.titleAndIcon)
                    }
                }
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

    private func binding(_ s: StoreID) -> Binding<Draft> {
        Binding(get: { drafts[s] ?? Draft() }, set: { drafts[s] = $0 })
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

struct StorePanel: View {
    let store: StoreID
    @Binding var draft: Draft
    let wide: Bool
    var compact: Bool = false
    @Environment(LogStore.self) private var logs
    @State private var deleting: DisplayLog?

    private var cellHeight: CGFloat { compact ? 38 : (wide ? 56 : 48) }

    var body: some View {
        VStack(spacing: compact ? 10 : 12) {
            inputCard
            historyCard
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

    // 入力
    private var inputCard: some View {
        let today = logs.today(for: store)
        return VStack(spacing: 0) {
            HStack {
                Text(store.label).font(.title3.weight(.heavy)).tracking(1)
                Spacer()
                Text("今日 \(today.groups)組・\(today.people)名").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(store.deep)
            .padding(.horizontal, 16).padding(.vertical, compact ? 8 : 12)
            .background(store.soft)

            VStack(spacing: compact ? 6 : 8) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 64, height: 1)
                    ForEach(Gender.allCases) { g in
                        Label(g.label, systemImage: g.symbol)
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: compact ? 30 : 36)
                            .background(g.color, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                ForEach(AgeBand.allCases) { a in
                    HStack(spacing: 8) {
                        Text(a.label)
                            .font(.subheadline.weight(.bold))
                            .frame(width: 64, alignment: .leading)
                            .minimumScaleFactor(0.8)
                        ForEach(Gender.allCases) { g in
                            CountButton(gender: g, age: a, count: draft.count(g, a), height: cellHeight) {
                                draft.add(g, a)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("客層（1つ選択）").font(.footnote.weight(.bold)).foregroundStyle(Palette.ink2)
                    LazyVGrid(columns: compact ? Array(repeating: GridItem(.flexible(), spacing: 4), count: Segment.allCases.count)
                                               : [GridItem(.adaptive(minimum: 80), spacing: 6)],
                              spacing: 6) {
                        ForEach(Segment.allCases) { s in
                            SegmentChip(segment: s, selected: draft.segment == s, height: compact ? 34 : 38) {
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
                .padding(.top, compact ? 2 : 4)

                Divider().padding(.vertical, compact ? 2 : 4)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("この組").font(.caption.weight(.bold)).foregroundStyle(Palette.sub)
                        Text(draft.isEmpty ? "タップして人数を追加" : draft.summary)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(draft.total)")
                            .font(.system(size: 30, weight: .bold)).monospacedDigit()
                        Text("名").font(.subheadline).foregroundStyle(Palette.sub)
                    }
                }

                HStack(spacing: 8) {
                    Button { draft.undo() } label: {
                        Text("一つ戻す").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .glassButton()
                    .disabled(draft.taps.isEmpty)
                    Button { draft.clear() } label: {
                        Text("クリア").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .glassButton()
                    .disabled(draft.isEmpty && draft.segment == .general)
                    Button {
                        logs.record(store: store, draft: draft)
                        draft.clear()
                    } label: {
                        Text(wide ? "記録する" : "\(store.label) に記録")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .prominentGlassButton()
                    .tint(store.accent)
                    .disabled(!draft.canRecord)
                    .layoutPriority(1)
                }
                .controlSize(compact ? .regular : .large)
            }
            .padding(compact ? 10 : 14)
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    // 直前5組
    private var historyCard: some View {
        let items = logs.recent(for: store)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("直前5組").font(.headline)
                Spacer()
                Text(store.label)
                    .font(.caption2.weight(.bold)).tracking(0.5)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(store.soft, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(store.deep)
            }
            .padding(.vertical, 10)
            if items.isEmpty {
                Text("まだ記録がありません")
                    .font(.subheadline).foregroundStyle(Palette.sub)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Text(JST.hm.string(from: item.log.visited_at))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .frame(width: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.log.summary).font(.subheadline).lineLimit(1)
                        Text(item.log.segment.label).font(.caption.weight(.bold)).foregroundStyle(Palette.teal)
                    }
                    Spacer(minLength: 4)
                    if item.isPending {
                        Image(systemName: "icloud.slash").font(.caption).foregroundStyle(Color(hex: 0x8A6408))
                            .accessibilityLabel("未送信")
                    }
                    Text("\(item.log.total)名").font(.subheadline.weight(.bold)).foregroundStyle(Palette.ink2)
                    Button {
                        deleting = item
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.sunday)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(JST.hm.string(from: item.log.visited_at))の記録を削除")
                }
                .frame(minHeight: compact ? 44 : 52)
                .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("この記録を削除", systemImage: "trash", role: .destructive) { deleting = item }
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 6)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
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
                .overlay(Capsule().strokeBorder(selected ? Palette.teal : Color(hex: 0xD1D1D6), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
