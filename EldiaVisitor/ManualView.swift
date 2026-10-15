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
                ManualHomeView(editingCard: $editingCard)
                    .navigationDestination(for: ManualRoute.self) { route in
                        Group {
                            switch route {
                            case .category(let c): ManualCategoryView(category: c, editingCard: $editingCard)
                            case .card(let id): ManualPlayerView(cardID: id, editingCard: $editingCard)
                            }
                        }
                        .toolbar { editToolbar }
                    }
                    .toolbar { editToolbar }
            }
            backToRecordBar
        }
        .background(Palette.ground)
        .task { await manual.load() }
        .sheet(isPresented: $showAdminLogin) { AdminLoginSheet() }
        .fullScreenCover(item: $editingCard) { card in
            ManualEditorView(original: card)
        }
    }

    @ToolbarContentBuilder
    private var editToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if manual.editing {
                Button {
                    manual.endEditing()
                } label: {
                    Label("編集を終える", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                }
                .tint(Palette.sunday)
            } else {
                Button {
                    if manual.canEdit { manual.editing = true } else { showAdminLogin = true }
                } label: {
                    Label("編集", systemImage: "pencil").labelStyle(.titleAndIcon)
                }
            }
        }
    }

    /// どの画面からでも、すぐ来店記録に戻れるバー（来店の記録漏れを防ぐ）
    private var backToRecordBar: some View {
        HStack(spacing: 12) {
            if manual.editing {
                Label("編集中", systemImage: "pencil.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Palette.sunday)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Label("来店記録に戻る", systemImage: "person.2.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 48)
                    .background(Palette.teal, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("マニュアルは今の場所を覚えています")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.white)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

// MARK: - ホーム（7カテゴリ）

struct ManualHomeView: View {
    @Environment(ManualStore.self) private var manual
    @Binding var editingCard: ManualCard?
    @State private var query = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: sizeClass == .regular ? 4 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let err = manual.lastError {
                    Label(err, systemImage: "wifi.exclamationmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x6B4E06))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(hex: 0xF5E9C8), in: Capsule())
                }
                searchField
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
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
                    if let run = manual.run, !run.finished, let card = manual.card(run.cardID) {
                        resumeBanner(card)
                    }
                } else {
                    searchResults
                }
            }
            .padding(20)
        }
        .background(Palette.ground)
        .navigationTitle("フロントマニュアル")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await manual.load() }
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
    private var searchResults: some View {
        let found = manual.search(query)
        if found.isEmpty {
            Text("見つかりません。別の言葉で探すか、上のカテゴリから選んでください")
                .font(.title3).foregroundStyle(Palette.sub)
                .padding(.top, 20)
        } else {
            VStack(spacing: 10) {
                ForEach(found) { c in
                    NavigationLink(value: ManualRoute.card(c.id)) {
                        CardRow(card: c, showCategory: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func resumeBanner(_ card: ManualCard) -> some View {
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

struct CategoryTile: View {
    let category: ManualCategory
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: category.symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(category.tint)
                .frame(width: 56, height: 56)
                .background(category.soft, in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 0)
            Text(category.label)
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(count == 0 ? "まだありません" : "\(count) 件")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.sub)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(Rectangle())
    }
}

struct CardRow: View {
    let card: ManualCard
    var showCategory = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if showCategory {
                    Text(card.category.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(card.category.tint)
                }
                Text(card.title)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                Text("\(card.steps.count) ステップ" + (card.updated_at.map { "・更新 \(JST.shortDate.string(from: $0))" } ?? ""))
                    .font(.footnote)
                    .foregroundStyle(Palette.sub)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.headline).foregroundStyle(Palette.sub)
        }
        .padding(.horizontal, 18).frame(minHeight: 76)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }
}

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
                if list.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: category.symbol).font(.largeTitle).foregroundStyle(category.tint)
                        Text("まだカードがありません").font(.title3.weight(.bold))
                        Text(manual.editing ? "下の「カードを追加」から作れます" : "右上の「編集」から追加できます")
                            .foregroundStyle(Palette.sub)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                    if manual.editing {
                        editRow(c, index: i, count: list.count)
                    } else {
                        NavigationLink(value: ManualRoute.card(c.id)) { CardRow(card: c) }
                            .buttonStyle(.plain)
                    }
                }
                if manual.editing {
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
            }
            .padding(20)
        }
        .background(Palette.ground)
        .navigationTitle(category.label)
        .sheet(isPresented: $showDeleted) { DeletedCardsSheet(category: category) }
    }

    private func editRow(_ c: ManualCard, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Button { editingCard = c } label: { CardRow(card: c) }
                .buttonStyle(.plain)
            VStack(spacing: 6) {
                Button { Task { await move(c, -1) } } label: { Image(systemName: "chevron.up").frame(width: 44, height: 34) }
                    .disabled(index == 0)
                    .accessibilityLabel("上へ")
                Button { Task { await move(c, 1) } } label: { Image(systemName: "chevron.down").frame(width: 44, height: 34) }
                    .disabled(index == count - 1)
                    .accessibilityLabel("下へ")
            }
            .buttonStyle(.bordered)
        }
    }

    private func move(_ c: ManualCard, _ d: Int) async {
        do { try await manual.move(c, by: d); error = nil } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 1画面1ステップの表示

struct ManualPlayerView: View {
    let cardID: UUID
    @Binding var editingCard: ManualCard?
    @Environment(ManualStore.self) private var manual
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var zoom: String?

    var body: some View {
        Group {
            if let card = manual.card(cardID) {
                content(card)
            } else {
                ContentUnavailableView("このカードは削除されました", systemImage: "doc.questionmark")
            }
        }
        .background(Palette.ground)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { startIfNeeded() }
        .fullScreenCover(item: Binding(get: { zoom.map(ZoomTarget.init) }, set: { zoom = $0?.name })) { t in
            ImageZoomView(name: t.name)
        }
    }

    private var run: ManualRun? { manual.run?.cardID == cardID ? manual.run : nil }

    private func startIfNeeded() {
        guard run == nil || run?.finished == true, let first = manual.card(cardID)?.steps.first else { return }
        manual.run = ManualRun(cardID: cardID, stepID: first.id)
    }

    @ViewBuilder
    private func content(_ card: ManualCard) -> some View {
        let r = run
        let idx = card.index(of: r?.stepID) ?? 0
        VStack(spacing: 14) {
            header(card, idx: idx)
            if card.steps.isEmpty {
                ContentUnavailableView("ステップがありません", systemImage: "list.number")
            } else if r?.finished == true {
                finished(card)
            } else {
                let step = card.steps[idx]
                if step.kind == .question {
                    question(card, step)
                } else {
                    stepBody(card, step, idx: idx)
                }
            }
        }
        .padding(20)
        .navigationTitle(card.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if manual.editing {
                    Button("このカードを編集", systemImage: "square.and.pencil") { editingCard = card }
                }
            }
        }
    }

    private func header(_ card: ManualCard, idx: Int) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(card.title).font(.system(size: 22, weight: .heavy)).lineLimit(2)
                Spacer()
                if run?.finished != true {
                    Text("\(idx + 1) / \(card.steps.count)")
                        .font(.title3.weight(.bold)).monospacedDigit()
                        .foregroundStyle(Palette.sub)
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<max(card.steps.count, 1), id: \.self) { i in
                    Capsule()
                        .fill(i <= idx || run?.finished == true ? card.category.tint : Color(hex: 0xDADADF))
                        .frame(height: 7)
                }
            }
        }
    }

    private func question(_ card: ManualCard, _ step: ManualStep) -> some View {
        VStack(spacing: 30) {
            Spacer()
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 44))
                .foregroundStyle(card.category.tint)
            Text(step.text)
                .font(.system(size: 32, weight: .heavy))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 24) {
                bigButton("はい", fill: card.category.tint) { go(card, to: step.yes, from: step) }
                bigButton("いいえ", fill: Palette.ink2) { go(card, to: step.no, from: step) }
            }
            .frame(maxWidth: 560)
            Spacer()
            backButton(card)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func stepBody(_ card: ManualCard, _ step: ManualStep, idx: Int) -> some View {
        let isLast = step.end || idx == card.steps.count - 1
        let text = VStack(alignment: .leading, spacing: 16) {
            if step.kind == .sirius {
                Label("SIRIUS i の操作", systemImage: "desktopcomputer")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(step.kind.badgeText)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(step.kind.badgeFill, in: Capsule())
            }
            ScrollView {
                Text(step.text)
                    .font(.system(size: 28, weight: .semibold))
                    .lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                backButton(card)
                bigButton(isLast ? "完了" : "できた　次へ", fill: card.category.tint, icon: isLast ? "checkmark" : "arrow.right") {
                    if isLast { finish() } else { go(card, to: nil, from: step) }
                }
            }
        }
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: 20) {
                photo(step).frame(maxWidth: .infinity, maxHeight: .infinity)
                text.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 14) {
                if step.image != nil { photo(step).frame(maxHeight: 260) }
                text
            }
        }
    }

    @ViewBuilder
    private func photo(_ step: ManualStep) -> some View {
        if let name = step.image {
            Button { zoom = name } label: {
                ManualImage(name: name)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.bold))
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(10)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("写真を大きく見る")
        } else {
            RoundedRectangle(cornerRadius: 18).fill(Color.white)
                .overlay {
                    Image(systemName: step.kind == .sirius ? "desktopcomputer" : "hand.point.up.left")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(Color(hex: 0xC7C7CC))
                }
        }
    }

    private func finished(_ card: ManualCard) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(card.category.tint)
            Text("対応完了").font(.system(size: 34, weight: .heavy))
            HStack(spacing: 16) {
                Button {
                    manual.run = nil
                    startIfNeeded()
                } label: {
                    Text("最初から見る").font(.headline).frame(minWidth: 160, minHeight: 52)
                }
                .buttonStyle(.bordered)
                Button {
                    manual.run = nil
                    manual.path = [.category(card.category)]
                } label: {
                    Text("\(card.category.label) の一覧へ").font(.headline).frame(minWidth: 180, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(card.category.tint)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func backButton(_ card: ManualCard) -> some View {
        Button {
            back()
        } label: {
            Label("戻る", systemImage: "arrow.left")
                .font(.headline)
                .frame(minWidth: 110, minHeight: 60)
        }
        .buttonStyle(.bordered)
        .disabled(run?.history.isEmpty ?? true)
    }

    private func bigButton(_ title: String, fill: Color, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if let icon { Image(systemName: icon) }
            }
            .font(.system(size: 24, weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(fill, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: run?.stepID)
    }

    // MARK: 進む・戻る

    private func go(_ card: ManualCard, to target: String?, from step: ManualStep) {
        guard var r = run, let cur = card.index(of: step.id) else { return }
        let nextIdx = card.index(of: target) ?? (cur + 1)
        guard card.steps.indices.contains(nextIdx) else { finish(); return }
        r.history.append(step.id)
        r.stepID = card.steps[nextIdx].id
        manual.run = r
    }

    private func back() {
        guard var r = run, let prev = r.history.popLast() else { return }
        r.stepID = prev
        r.finished = false
        manual.run = r
    }

    private func finish() {
        guard var r = run else { return }
        r.finished = true
        manual.run = r
    }
}

private struct ZoomTarget: Identifiable {
    let name: String
    var id: String { name }
}

/// 端末内（無ければダウンロード）の写真を表示
struct ManualImage: View {
    let name: String
    var fill = false
    @Environment(ManualStore.self) private var manual
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(fill ? 0 : 6)
            } else if failed {
                Label("写真を表示できません", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(Palette.sub)
            } else {
                ProgressView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .task(id: name) {
            image = await manual.image(name)
            failed = image == nil
        }
    }
}

struct ImageZoomView: View {
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ManualImage(name: name)
                .scaleEffect(scale * pinch)
                .gesture(MagnificationGesture()
                    .updating($pinch) { v, s, _ in s = v }
                    .onEnded { v in scale = min(max(scale * v, 1), 4) })
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2 } }
                .padding(20)
            Button { dismiss() } label: {
                Label("閉じる", systemImage: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(minHeight: 48)
                    .background(Color.white.opacity(0.2), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(24)
        }
    }
}

extension JST {
    static let shortDate = formatter("yyyy/M/d")
}
