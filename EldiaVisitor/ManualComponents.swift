import SwiftUI
import UIKit

// MARK: - マニュアルの画面で共通に使う部品

/// カテゴリのタイル（ホーム）
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

/// カード1枚の行（一覧・検索結果）
struct CardRow: View {
    let card: ManualCard
    var showCategory = false

    private var detail: String {
        "\(card.steps.count) ステップ" + (card.updated_at.map { "・更新 \(JST.shortDate.string(from: $0))" } ?? "")
    }

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
                Text(detail)
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

/// 注意の帯（通信できないときなど）
struct NoticeBanner: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.noticeText)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Palette.noticeFill, in: Capsule())
    }
}

/// ツールバー用のボタンの見た目（標準の Label だとアイコンだけになることがあるため）
struct BarPill: View {
    let title: String
    let symbol: String
    let fill: Color
    let foreground: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(fill, in: Capsule())
        .fixedSize()
    }
}

// MARK: - 写真

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

/// 写真を全画面で拡大（ピンチ・ダブルタップ）
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

// MARK: - スワイプで戻る

/// 戻るボタンを自前にすると画面左端からのスワイプで戻れなくなるため、マニュアルの画面だけスワイプを有効に戻す。
/// iOS 全体の部品（UINavigationController）は書き換えず、マニュアルのホームに置いた見えない部品が担当する。
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ uiViewController: Controller, context: Context) { uiViewController.attach() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var nav: UINavigationController?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }

        func attach() {
            guard let n = navigationController ?? parent?.navigationController else { return }
            nav = n
            n.interactivePopGestureRecognizer?.isEnabled = true
            n.interactivePopGestureRecognizer?.delegate = self
        }

        /// 1つ目の画面（マニュアルのホーム）ではスワイプしない
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (nav?.viewControllers.count ?? 0) > 1
        }
    }
}

extension JST {
    static let shortDate = formatter("yyyy/M/d")
}
