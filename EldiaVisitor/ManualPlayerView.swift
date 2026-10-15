import SwiftUI

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

    /// このカードを見ている途中の位置（別のカードの位置なら nil）
    private var run: ManualRun? { manual.run?.cardID == cardID ? manual.run : nil }
    private var isFinished: Bool { run?.finished == true }

    @ViewBuilder
    private func content(_ card: ManualCard) -> some View {
        let index = card.index(of: run?.stepID) ?? 0
        VStack(spacing: 14) {
            StepProgressHeader(card: card, index: index, finished: isFinished)
            if card.steps.isEmpty {
                ContentUnavailableView("ステップがありません", systemImage: "list.number")
            } else if isFinished {
                finished(card)
            } else {
                let step = card.steps[index]
                if step.kind == .question {
                    question(card, step)
                } else {
                    stepBody(card, step, isLast: step.end || index == card.steps.count - 1)
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

    // MARK: 質問（はい／いいえ）

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
                bigButton("はい", fill: card.category.tint) { advance(card, from: step, to: step.yes) }
                bigButton("いいえ", fill: Palette.ink2) { advance(card, from: step, to: step.no) }
            }
            .frame(maxWidth: 560)
            Spacer()
            previousStepButton
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 手順（左に写真、右に文章）

    @ViewBuilder
    private func stepBody(_ card: ManualCard, _ step: ManualStep, isLast: Bool) -> some View {
        let text = VStack(alignment: .leading, spacing: 16) {
            if step.kind == .sirius { siriusBadge(step.kind) }
            ScrollView {
                Text(step.text)
                    .font(.system(size: 28, weight: .semibold))
                    .lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                previousStepButton
                bigButton(isLast ? "完了" : "できた　次へ", fill: card.category.tint, icon: isLast ? "checkmark" : "arrow.right") {
                    if isLast { finish() } else { advance(card, from: step, to: nil) }
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

    private func siriusBadge(_ kind: StepKind) -> some View {
        Label("SIRIUS i の操作", systemImage: "desktopcomputer")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(kind.badgeText)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(kind.badgeFill, in: Capsule())
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
                    Image(systemName: step.kind.symbol)
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(Palette.placeholder)
                }
        }
    }

    // MARK: 完了

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

    // MARK: ボタン

    private var previousStepButton: some View {
        Button {
            updateRun { $0.stepBack() }
        } label: {
            Label("前のステップ", systemImage: "arrow.left")
                .font(.headline)
                .frame(minWidth: 160, minHeight: 60)
        }
        .buttonStyle(.bordered)
        .disabled(!(run?.canStepBack ?? false))
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

    // MARK: 進む・戻る（中身は ManualRun 側）

    /// 初めて開いたとき、または完了したあとに開いたときは最初のステップから
    private func startIfNeeded() {
        guard run == nil || isFinished, let first = manual.card(cardID)?.steps.first else { return }
        manual.run = ManualRun(cardID: cardID, stepID: first.id)
    }

    private func advance(_ card: ManualCard, from step: ManualStep, to target: String?) {
        updateRun { $0.advance(in: card, from: step, to: target) }
    }

    private func finish() {
        updateRun { $0.finished = true }
    }

    /// このカードを見ている途中なら、その位置を書き換える
    private func updateRun(_ change: (inout ManualRun) -> Void) {
        guard var r = run else { return }
        change(&r)
        manual.run = r
    }
}

/// 上の「タイトル・何ステップ目か・進み具合の線」
private struct StepProgressHeader: View {
    let card: ManualCard
    let index: Int
    let finished: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(card.title).font(.system(size: 22, weight: .heavy)).lineLimit(2)
                Spacer()
                if !finished {
                    Text("\(index + 1) / \(card.steps.count)")
                        .font(.title3.weight(.bold)).monospacedDigit()
                        .foregroundStyle(Palette.sub)
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<max(card.steps.count, 1), id: \.self) { i in
                    Capsule()
                        .fill(i <= index || finished ? card.category.tint : Palette.track)
                        .frame(height: 7)
                }
            }
        }
    }
}

private struct ZoomTarget: Identifiable {
    let name: String
    var id: String { name }
}
