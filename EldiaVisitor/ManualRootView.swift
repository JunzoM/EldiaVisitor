import SwiftUI

/// フロントマニュアル（来店記録の画面から全画面で開く）
/// - iPad：上のバー（戻る・編集）と下のバー（ホーム・来店記録に戻る）
/// - iPhone：来店記録と同じメニュー（縦＝左上の丸いボタン、横＝右のドック）。上には戻る・編集だけを置く
struct ManualRootView: View {
    @Environment(ManualStore.self) private var manual
    @Environment(\.dismiss) private var dismiss
    @Environment(\.shellLinks) private var links
    @State private var showAdminLogin = false
    @State private var editingCard: ManualCard?
    @State private var landscape = false

    private var isPhone: Bool { DeviceKind.isPhone }

    var body: some View {
        Group {
            if isPhone {
                if landscape { phoneLandscape } else { phonePortrait }
            } else {
                VStack(spacing: 0) {
                    navigationStack(phone: false)
                    bottomBar
                }
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
        .task { if !DemoMode.enabled { await manual.load() } }
        .sheet(isPresented: $showAdminLogin) { AdminLoginSheet() }
        .fullScreenCover(item: $editingCard) { card in
            ManualEditorView(original: card)
        }
    }

    // MARK: 画面の中身（ホーム → カテゴリ → カード）

    private func navigationStack(phone: Bool) -> some View {
        @Bindable var manual = manual
        return NavigationStack(path: $manual.path) {
            home(phone: phone)
                .navigationDestination(for: ManualRoute.self) { route in
                    if phone {
                        // iPhone は自前の上の行（戻る・編集）を使うので、標準のバーは出さない
                        destination(for: route)
                            .toolbar(.hidden, for: .navigationBar)
                    } else {
                        destination(for: route)
                            // 標準の「<」だけでは分かりにくいので、行き先を書いた大きな戻るボタンにする
                            .navigationBarBackButtonHidden(true)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) { backButton(for: route) }
                                editToolbar
                            }
                    }
                }
        }
    }

    @ViewBuilder
    private func home(phone: Bool) -> some View {
        if phone {
            ManualHomeView()
                .background(SwipeBackEnabler().frame(width: 0, height: 0))
                .toolbar(.hidden, for: .navigationBar)
        } else {
            ManualHomeView()
                .background(SwipeBackEnabler().frame(width: 0, height: 0))
                .toolbar { editToolbar }
        }
    }

    // MARK: iPhone（来店記録と同じメニュー）

    /// iPhone のメニューから行ける先（マニュアル表示中）
    private var shellActions: AppActions {
        AppActions(screen: .manual,
                   selectedStore: links?.selectedStore ?? .modern,
                   selectStore: { store in
                       if let links { links.openRecord(store) } else { dismiss() }
                   },
                   record: {
                       if let links { links.openRecord(nil) } else { dismiss() }
                   },
                   manual: { manual.path.removeAll() },
                   analysis: {
                       if let links { links.openAnalysis() } else { dismiss() }
                   },
                   logout: { links?.logout() })
    }

    private var phonePortrait: some View {
        VStack(spacing: 0) {
            phoneTopBar(reserveMenuSpace: true)
            navigationStack(phone: true)
        }
        .overlay(alignment: .topLeading) {
            ActionCluster(actions: shellActions)
        }
    }

    private var phoneLandscape: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                phoneTopBar(reserveMenuSpace: false)
                navigationStack(phone: true)
            }
            SideDock(actions: shellActions)
                .padding(.trailing, 8)
                // 画面の角の丸み（半径 約60pt）に店舗ボタンの角が掛からないよう、上を空ける
                .padding(.top, 28)
                .padding(.bottom, 8)
        }
        .useFreeLandscapeEdge()
    }

    /// iPhone の上の行：［メニューの場所］［◯◯に戻る／見出し］……［編集］
    private func phoneTopBar(reserveMenuSpace: Bool) -> some View {
        HStack(spacing: 10) {
            if reserveMenuSpace {
                // 左上の丸いボタン（ActionCluster）がここに重なる
                Color.clear.frame(width: 50, height: 50)
            }
            if let route = manual.path.last {
                backButton(for: route)
            } else {
                Text("フロントマニュアル")
                    .font(.title3.weight(.heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 4)
            phoneEditButtons
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .padding(.top, 4).padding(.bottom, 6)
    }

    /// 編集のボタン（編集中は「このカードを編集」「編集を終える」）
    @ViewBuilder
    private var phoneEditButtons: some View {
        if manual.editing {
            if case .card(let id) = manual.path.last, let card = manual.card(id) {
                Button {
                    editingCard = card
                } label: {
                    BarPill(title: "カード編集", symbol: "square.and.pencil", fill: Palette.chip, foreground: Palette.ink2)
                }
                .buttonStyle(.plain)
            }
            Button {
                manual.endEditing()
            } label: {
                BarPill(title: "終える", symbol: "checkmark.circle.fill", fill: Palette.sunday, foreground: .white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("編集を終える")
        } else {
            Button {
                if manual.canEdit { manual.editing = true } else { showAdminLogin = true }
            } label: {
                BarPill(title: "編集", symbol: "pencil", fill: Palette.chip, foreground: Palette.ink2)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func destination(for route: ManualRoute) -> some View {
        switch route {
        case .category(let c): ManualCategoryView(category: c, editingCard: $editingCard)
        case .card(let id): ManualPlayerView(cardID: id, editingCard: $editingCard)
        }
    }

    // MARK: 上のバー

    @ToolbarContentBuilder
    private var editToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if manual.editing {
                Button {
                    manual.endEditing()
                } label: {
                    BarPill(title: "編集を終える", symbol: "checkmark.circle.fill", fill: Palette.sunday, foreground: .white)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    if manual.canEdit { manual.editing = true } else { showAdminLogin = true }
                } label: {
                    BarPill(title: "編集", symbol: "pencil", fill: Palette.chip, foreground: Palette.ink2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 1つ前の画面の名前（戻るボタンに書く）
    private func backTitle(for route: ManualRoute) -> String {
        guard let i = manual.path.lastIndex(of: route), i > 0 else { return "ホーム" }
        if case .category(let c) = manual.path[i - 1] { return c.label }
        return "前の画面"
    }

    private func backButton(for route: ManualRoute) -> some View {
        let title = "\(backTitle(for: route)) に戻る"
        return Button {
            if !manual.path.isEmpty { manual.path.removeLast() }
        } label: {
            BarPill(title: title, symbol: "chevron.left", fill: Palette.chip, foreground: Palette.ink2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: 下のバー

    /// どの画面からでも、すぐ来店記録に戻れるバー（来店の記録漏れを防ぐ）
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if !manual.path.isEmpty {
                Button {
                    manual.path.removeAll()
                } label: {
                    BottomBarLabel(title: "マニュアルのホーム", symbol: "house.fill",
                                   fill: Palette.chip, foreground: Palette.ink2, horizontalPadding: 20)
                }
                .buttonStyle(.plain)
            }
            if manual.editing {
                Label("編集中", systemImage: "pencil.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Palette.sunday)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                BottomBarLabel(title: "来店記録に戻る", symbol: "person.2.fill",
                               fill: Palette.teal, foreground: .white, horizontalPadding: 24)
            }
            .buttonStyle(.plain)
            .accessibilityHint("マニュアルは今の場所を覚えています")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.white)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

/// 下のバーの大きなボタンの見た目
private struct BottomBarLabel: View {
    let title: String
    let symbol: String
    let fill: Color
    let foreground: Color
    let horizontalPadding: CGFloat

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: 48)
            .glassFill(Capsule(), fill: fill, tinted: fill != Palette.chip)
    }
}
