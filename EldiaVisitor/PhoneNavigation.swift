import SwiftUI

// MARK: - Liquid Glass の部品（iOS 26 以上はガラス、iPadOS 17 などはこれまでの見た目）

extension View {
    /// ガラスの面を付ける。tint を渡すとその色のガラス、interactive は押したときに反応する
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: shape)
        } else if let tint {
            self.background(tint, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.6), lineWidth: 1))
        }
    }

    /// iOS 26 以上はガラス（tinted なら fill の色のガラス）、それ未満は fill の色で塗る。
    /// iPadOS 17 の見た目は変えずに、新しい iOS だけ Liquid Glass にするときに使う
    @ViewBuilder
    func glassFill<S: Shape>(_ shape: S, fill: Color, tinted: Bool) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.makeGlass(tint: tinted ? fill : nil, interactive: true), in: shape)
        } else {
            self.background(fill, in: shape)
        }
    }

    @available(iOS 26.0, *)
    private static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    /// ガラス同士を形が変わりながらつなぐための目印（iOS 26 以上のみ有効）
    @ViewBuilder
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// 近くのガラスをひとまとまりに描く入れ物（iOS 26 未満はそのまま並べる）
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - 記録とマニュアルで共通のメニュー

/// いま表示している画面（メニューで「ここにいる」ことを色で示す）
enum ShellScreen {
    case record, manual
}

/// iPhone のメニュー（縦：左上の丸いボタン、横：右のドック）から行ける先。記録とマニュアルで同じ並び
struct AppActions {
    var screen: ShellScreen = .record
    /// 記録している店舗（ドックで色を付ける）
    var selectedStore: StoreID
    /// 店舗のボタン：その店舗の記録画面へ
    let selectStore: (StoreID) -> Void
    /// 「来店記録」：記録画面へ
    let record: () -> Void
    /// 「フロントマニュアル」：マニュアル（マニュアル表示中はマニュアルのホーム）へ
    let manual: () -> Void
    let analysis: () -> Void
    let logout: () -> Void
}

/// 記録画面からマニュアルへ渡す戻り先（マニュアルのメニューから記録・分析・ログアウトへ行くため）
struct ShellLinks {
    let selectedStore: StoreID
    /// 記録画面へ戻る（店舗を指定すればその店舗に切り替える）
    let openRecord: (StoreID?) -> Void
    let openAnalysis: () -> Void
    let logout: () -> Void
}

private struct ShellLinksKey: EnvironmentKey {
    static let defaultValue: ShellLinks? = nil
}

extension EnvironmentValues {
    var shellLinks: ShellLinks? {
        get { self[ShellLinksKey.self] }
        set { self[ShellLinksKey.self] = newValue }
    }
}

/// iPhone のときだけ、縦横で同じメニュー（縦＝左上の丸いボタン、横＝右のドック）を使う
enum DeviceKind {
    @MainActor static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
}

// MARK: - アカウントの中身（メール・最終同期・ログアウト）

/// メニューの中身。最終同期の時刻はここだけで読む（10秒ごとの同期で画面全体を描き直さない）
struct AccountMenuItems: View {
    @Environment(AuthManager.self) private var auth
    @Environment(LogStore.self) private var logs
    let onLogout: () -> Void

    var body: some View {
        Text(auth.email)
        if let t = logs.lastSync {
            Text("最終同期 \(JST.hms.string(from: t))")
        }
        if !logs.pending.isEmpty {
            Text("未送信 \(logs.pending.count)件")
        }
        Button("ログアウト", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
            onLogout()
        }
    }
}

/// マニュアルのボタンの文字（マニュアル表示中は「ホーム」、途中まで見ていれば「続き」）
@MainActor
private func manualTitle(_ manual: ManualStore, screen: ShellScreen) -> String {
    if screen == .manual { return "マニュアルのホーム" }
    return manual.run.map { $0.finished ? "フロントマニュアル" : "フロントマニュアル（続き）" } ?? "フロントマニュアル"
}

// MARK: - iPhone 縦：左上の丸いボタン（押すと展開）

/// 押すとガラスが伸びて「来店記録・フロントマニュアル・分析・アカウント」が並ぶ。周りを押すと閉じる。
/// 記録とマニュアルで同じ位置・同じ並び。いま表示している画面の行は色付き
struct ActionCluster: View {
    let actions: AppActions
    @Environment(LogStore.self) private var logs
    @Environment(ManualStore.self) private var manual
    @Environment(AuthManager.self) private var auth
    @State private var open = DemoMode.menuOpen
    @Namespace private var glass

    var body: some View {
        ZStack(alignment: .topLeading) {
            if open {
                // 周りを薄く暗くして、押すと閉じる
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { toggle() }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            GlassGroup(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    toggleButton
                    if open {
                        row("record", title: "来店記録", subtitle: actions.selectedStore.label, icon: "person.2.fill",
                            current: actions.screen == .record, action: actions.record)
                        row("manual", title: manualTitle(manual, screen: actions.screen), subtitle: nil, icon: "book.pages",
                            current: actions.screen == .manual, action: actions.manual)
                        row("analysis", title: "分析", subtitle: "店舗比較・曜日別・CSV", icon: "chart.bar.xaxis",
                            current: false, action: actions.analysis)
                        Menu {
                            AccountMenuItems {
                                toggle()
                                actions.logout()
                            }
                        } label: {
                            ClusterRow(title: "アカウント", subtitle: auth.email, icon: "person.crop.circle")
                                .foregroundStyle(Color.primary)
                        }
                        .glassSurface(Capsule())
                        .glassID("account", in: glass)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.top, 4)
        }
    }

    private func row(_ id: String, title: String, subtitle: String?, icon: String,
                     current: Bool, action: @escaping () -> Void) -> some View {
        Button {
            toggle()
            action()
        } label: {
            ClusterRow(title: title, subtitle: subtitle, icon: icon)
                .foregroundStyle(current ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .glassSurface(Capsule(), tint: current ? Palette.teal.opacity(0.9) : nil)
        .glassID(id, in: glass)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var toggleButton: some View {
        let pending = !logs.pending.isEmpty
        return Button(action: toggle) {
            Image(systemName: open ? "xmark" : (pending ? "icloud.slash" : "line.3.horizontal"))
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(open ? Color.primary : (pending ? Palette.pending : Palette.teal))
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(Circle())
        .glassID("toggle", in: glass)
        .accessibilityLabel(open ? "閉じる" : "メニュー（来店記録・マニュアル・分析・アカウント）")
    }

    private func toggle() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { open.toggle() }
    }
}

/// 展開したときの1行（年配のスタッフでも押しやすい大きさ）
private struct ClusterRow: View {
    let title: String
    let subtitle: String?
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).opacity(0.75).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(minWidth: 230, minHeight: 54, alignment: .leading)
        .contentShape(Capsule())
    }
}

// MARK: - iPhone 横：右のドック

/// 上に店舗（押すとその店舗の記録画面）、下にマニュアル・分析・アカウント。記録とマニュアルで同じ並び。
/// いま表示している画面のボタンは色付き（記録中はその店舗の色、マニュアル中はマニュアル）
struct SideDock: View {
    let actions: AppActions
    @Environment(LogStore.self) private var logs

    var body: some View {
        let inManual = actions.screen == .manual
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                ForEach(StoreID.allCases) { s in
                    let isOn = !inManual && actions.selectedStore == s
                    Button {
                        withAnimation(.snappy) { actions.selectStore(s) }
                    } label: {
                        DockItem(icon: isOn ? "building.2.fill" : "building.2", title: s.label)
                            .foregroundStyle(isOn ? Color.white : s.deep)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(RoundedRectangle(cornerRadius: 18), tint: isOn ? s.accent : nil)
                    .accessibilityLabel("\(s.label)を記録")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }

                Spacer(minLength: 6)

                Button(action: actions.manual) {
                    DockItem(icon: "book.pages", title: inManual ? "ホーム" : "マニュアル")
                        .foregroundStyle(inManual ? Color.white : Palette.ink2)
                }
                .buttonStyle(.plain)
                .glassSurface(RoundedRectangle(cornerRadius: 18), tint: inManual ? Palette.teal.opacity(0.9) : nil)
                .accessibilityLabel(inManual ? "マニュアルのホームへ" : "フロントマニュアルを開く")
                .accessibilityAddTraits(inManual ? .isSelected : [])

                Button(action: actions.analysis) {
                    DockItem(icon: "chart.bar.xaxis", title: "分析")
                        .foregroundStyle(Palette.ink2)
                }
                .buttonStyle(.plain)
                .glassSurface(RoundedRectangle(cornerRadius: 18))

                Menu {
                    AccountMenuItems(onLogout: actions.logout)
                } label: {
                    DockItem(icon: logs.pending.isEmpty ? "person.crop.circle" : "icloud.slash", title: "アカウント")
                        .foregroundStyle(logs.pending.isEmpty ? Palette.ink2 : Palette.pending)
                }
                .glassSurface(RoundedRectangle(cornerRadius: 18))
            }
        }
        .frame(width: 84)
    }
}

private struct DockItem: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
            Text(title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(.horizontal, 4)
        .frame(width: 80, height: 56)
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}
