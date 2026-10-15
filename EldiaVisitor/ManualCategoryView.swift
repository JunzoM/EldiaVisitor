import SwiftUI

// MARK: - カテゴリの中のカード一覧

struct ManualCategoryView: View {
    let category: ManualCategory
    @Binding var editingCard: ManualCard?
    @Environment(ManualStore.self) private var manual
    @State private var error: String?
    @State private var showDeleted = false

    var body: some View {
        let list = manual.cards(in: category)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let error {
                    Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Palette.sunday)
                }
                if list.isEmpty { emptyState }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                    if manual.editing {
                        editRow(c, isFirst: i == 0, isLast: i == list.count - 1)
                    } else {
                        NavigationLink(value: ManualRoute.card(c.id)) { CardRow(card: c) }
                            .buttonStyle(.plain)
                    }
                }
                if manual.editing { editButtons }
            }
            .padding(20)
        }
        .background(Palette.ground)
        .navigationTitle(category.label)
        .sheet(isPresented: $showDeleted) { DeletedCardsSheet(category: category) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: category.symbol).font(.largeTitle).foregroundStyle(category.tint)
            Text("まだカードがありません").font(.title3.weight(.bold))
            Text(manual.editing ? "下の「カードを追加」から作れます" : "右上の「編集」から追加できます")
                .foregroundStyle(Palette.sub)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var editButtons: some View {
        HStack(spacing: 12) {
            Button {
                editingCard = ManualCard(category: category)
            } label: {
                Label("カードを追加", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(category.tint)
            Button {
                showDeleted = true
            } label: {
                Label("削除したカード", systemImage: "trash.slash")
                    .frame(minHeight: 52)
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 6)
    }

    private func editRow(_ c: ManualCard, isFirst: Bool, isLast: Bool) -> some View {
        HStack(spacing: 8) {
            Button { editingCard = c } label: { CardRow(card: c) }
                .buttonStyle(.plain)
            VStack(spacing: 6) {
                MoveButton(symbol: "chevron.up", label: "上へ") { await move(c, by: -1) }
                    .disabled(isFirst)
                MoveButton(symbol: "chevron.down", label: "下へ") { await move(c, by: 1) }
                    .disabled(isLast)
            }
            .buttonStyle(.bordered)
        }
    }

    private func move(_ c: ManualCard, by offset: Int) async {
        do {
            try await manual.move(c, by: offset)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 並べ替えの上下ボタン
private struct MoveButton: View {
    let symbol: String
    let label: String
    let action: () async -> Void

    var body: some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol).frame(width: 44, height: 34)
        }
        .accessibilityLabel(label)
    }
}
