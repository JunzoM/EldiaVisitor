import SwiftUI

/// フロントマニュアル（来店記録の画面から全画面で開く）
struct ManualRootView: View {
    @Environment(ManualStore.self) private var manual
    @Environment(\.dismiss) private var dismiss
    @State private var showAdminLogin = false
    @State private var editingCard: ManualCard?

    var body: some View {
        @Bindable var manual = manual
        VStack(spacing: 0) {
            NavigationStack(path: $manual.path) {
                ManualHomeView()
                    .background(SwipeBackEnabler().frame(width: 0, height: 0))
                    .navigationDestination(for: ManualRoute.self) { route in
                        destination(for: route)
                            // 標準の「<」だけでは分かりにくいので、行き先を書いた大きな戻るボタンにする
                            .navigationBarBackButtonHidden(true)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) { backButton(for: route) }
                                editToolbar
                            }
                    }
                    .toolbar { editToolbar }
            }
            bottomBar
        }
        .background(Palette.ground)
        .task { await manual.load() }
        .sheet(isPresented: $showAdminLogin) { AdminLoginSheet() }
        .fullScreenCover(item: $editingCard) { card in
            ManualEditorView(original: card)
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
            .background(fill, in: Capsule())
    }
}
