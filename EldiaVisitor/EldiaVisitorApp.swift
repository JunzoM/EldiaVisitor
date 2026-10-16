import SwiftUI

@main
struct EldiaVisitorApp: App {
    @State private var auth: AuthManager
    @State private var logs: LogStore
    @State private var manual: ManualStore

    init() {
        let a = AuthManager()
        _auth = State(initialValue: a)
        _logs = State(initialValue: LogStore(api: API(auth: a)))
        _manual = State(initialValue: ManualStore(auth: a))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(logs)
                .environment(manual)
                .preferredColorScheme(.light)
                .onAppear {
                    // 24時間モニターを見ながら使うので画面を消さない
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

struct RootView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(LogStore.self) private var logs
    @Environment(ManualStore.self) private var manual
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if auth.session == nil {
                LoginView()
            } else {
                RecordView()
                    .task { if !DemoMode.enabled { logs.start() } }
                    // 回線が切れても見られるよう、マニュアルを先に端末へ保存しておく
                    .task { if !DemoMode.enabled { await manual.load() } }
                    .task { if DemoMode.landscape { await DemoMode.rotateToLandscape() } }
            }
        }
        .animation(.default, value: auth.session == nil)
        // 別のアプリに切り替えている間は同期を止め、戻ったらすぐ最新にする
        .onChange(of: scenePhase) { _, phase in
            guard auth.session != nil, !DemoMode.enabled else { return }
            switch phase {
            case .active: logs.start()
            case .background: logs.pause()
            default: break
            }
        }
    }
}

struct LoginView: View {
    @Environment(AuthManager.self) private var auth
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "person.2.badge.gearshape")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(Palette.teal)
                VStack(spacing: 4) {
                    Text("来店記録").font(.largeTitle.bold())
                    Text("ELDIA 共通ログイン").font(.subheadline).foregroundStyle(Palette.sub)
                }
                VStack(spacing: 12) {
                    TextField("メールアドレス", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    SecureField("パスワード", text: $password)
                        .textContentType(.password)
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                        .onSubmit { Task { await login() } }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Palette.sunday)
                }
                Button {
                    Task { await login() }
                } label: {
                    Group {
                        if busy { ProgressView().tint(.white) } else { Text("ログイン").font(.headline) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .prominentGlassButton()
                .tint(Palette.teal)
                .disabled(busy || email.isEmpty || password.isEmpty)
            }
            .frame(maxWidth: 420)
            .padding(24)
        }
    }

    private func login() async {
        guard !email.isEmpty, !password.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await auth.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            error = nil
        } catch {
            if let u = error as? URLError {
                // 通信エラーは原因を調べやすいようにコードも表示する
                let ns = u as NSError
                let stream = ns.userInfo["_kCFStreamErrorCodeKey"].map { " / \($0)" } ?? ""
                self.error = "\(u.localizedDescription)（通信エラー \(u.errorCode)\(stream)）"
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}

/// 画面確認用の起動オプション（DEBUG ビルドだけ。CI のスクリーンショットで使う）
/// -demoLayout：ログイン済みの画面を通信なしで表示 / -demoLandscape：横向き / -demoMenuOpen：iPhone 縦のメニューを開いた状態 / -demoManual：マニュアルを開いた状態
enum DemoMode {
    #if DEBUG
    private static let args = ProcessInfo.processInfo.arguments
    static let enabled = args.contains("-demoLayout")
    static let landscape = enabled && args.contains("-demoLandscape")
    static let menuOpen = enabled && args.contains("-demoMenuOpen")
    static let manualOpen = enabled && args.contains("-demoManual")
    #else
    static let enabled = false
    static let landscape = false
    static let menuOpen = false
    static let manualOpen = false
    #endif

    @MainActor
    static func rotateToLandscape() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
    }
}
