import SwiftUI

@main
struct EldiaVisitorApp: App {
    @State private var auth: AuthManager
    @State private var logs: LogStore

    init() {
        let a = AuthManager()
        _auth = State(initialValue: a)
        _logs = State(initialValue: LogStore(api: API(auth: a)))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(logs)
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

    var body: some View {
        Group {
            if auth.session == nil {
                LoginView()
            } else {
                RecordView()
                    .task { logs.start() }
            }
        }
        .animation(.default, value: auth.session == nil)
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
                .buttonStyle(.glassProminent)
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
            self.error = error.localizedDescription
        }
    }
}
