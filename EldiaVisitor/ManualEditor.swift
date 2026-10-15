import SwiftUI
import PhotosUI
import UIKit

// MARK: - カードの編集（管理者のみ）

struct ManualEditorView: View {
    let original: ManualCard
    @Environment(ManualStore.self) private var manual
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ManualCard
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var showHistory = false
    @FocusState private var focusedStep: String?

    init(original: ManualCard) {
        self.original = original
        _draft = State(initialValue: original)
    }

    private var isNew: Bool { manual.card(original.id) == nil }
    private var changed: Bool { draft != original }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleSection
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.sunday)
                    }
                    ForEach($draft.steps) { $step in
                        StepEditorRow(step: $step,
                                      number: number(of: step.id),
                                      isFirst: step.id == draft.steps.first?.id,
                                      isLast: step.id == draft.steps.last?.id,
                                      others: draft.steps.filter { $0.id != step.id },
                                      numberOf: number(of:),
                                      tint: draft.category.tint,
                                      focus: $focusedStep,
                                      onMove: { move(step.id, $0) },
                                      onDelete: { removeStep(step.id) },
                                      onError: { error = $0 })
                    }
                    addButtons
                    if !isNew { footer }
                }
                .padding(20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.ground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? "カードを追加" : "カードを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { if changed { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if busy { ProgressView() } else { Text("保存").bold() }
                    }
                    .disabled(busy)
                }
            }
            .confirmationDialog("変更を保存せずに閉じますか？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("保存せずに閉じる", role: .destructive) { dismiss() }
            }
            .confirmationDialog("「\(original.title)」を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) { Task { await delete() } }
            } message: {
                Text("削除しても、カテゴリの「削除したカード」から元に戻せます。")
            }
            .sheet(isPresented: $showHistory) {
                VersionsSheet(cardID: original.id) { v in
                    draft.title = v.title
                    draft.category = v.category
                    draft.steps = v.steps
                    error = "以前の内容を読み込みました。「保存」で確定します"
                }
            }
        }
        .interactiveDismissDisabled(changed)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("カードのタイトル（例：精算機でお釣りが出ない）", text: $draft.title, axis: .vertical)
                .font(.system(size: 24, weight: .bold))
                .lineLimit(1...3)
                .padding(14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 10) {
                Text("カテゴリ").font(.subheadline.weight(.bold)).foregroundStyle(Palette.sub)
                Picker("カテゴリ", selection: $draft.category) {
                    ForEach(ManualCategory.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(draft.category.tint)
            }
        }
    }

    private var addButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ステップを追加").font(.subheadline.weight(.bold)).foregroundStyle(Palette.sub)
            HStack(spacing: 10) {
                ForEach(StepKind.allCases) { k in
                    Button {
                        let s = ManualStep(kind: k)
                        draft.steps.append(s)
                        focusedStep = s.id
                    } label: {
                        Label(k.label, systemImage: k == .question ? "questionmark.circle" : (k == .sirius ? "desktopcomputer" : "hand.point.up.left"))
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.bordered)
                    .tint(draft.category.tint)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                showHistory = true
            } label: {
                Label("以前の内容", systemImage: "clock.arrow.circlepath").frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            Spacer()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("カードを削除", systemImage: "trash").frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 12)
    }

    // MARK: 操作

    private func number(of id: String) -> Int {
        (draft.steps.firstIndex { $0.id == id } ?? 0) + 1
    }

    private func move(_ id: String, _ d: Int) {
        guard let i = draft.steps.firstIndex(where: { $0.id == id }), draft.steps.indices.contains(i + d) else { return }
        withAnimation { draft.steps.swapAt(i, i + d) }
    }

    private func removeStep(_ id: String) {
        guard draft.steps.count > 1 else {
            error = "ステップは1つ以上必要です"
            return
        }
        withAnimation {
            draft.steps.removeAll { $0.id == id }
            // 消したステップを分岐先にしていた質問は「次のステップ」に戻す
            for i in draft.steps.indices {
                if draft.steps[i].yes == id { draft.steps[i].yes = nil }
                if draft.steps[i].no == id { draft.steps[i].no = nil }
            }
        }
    }

    private func validate() -> String? {
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "タイトルを入力してください" }
        if draft.steps.isEmpty { return "ステップは1つ以上必要です" }
        if let i = draft.steps.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "ステップ \(i + 1) が空です。入力するか削除してください"
        }
        return nil
    }

    private func save() async {
        if let msg = validate() { error = msg; return }
        busy = true
        defer { busy = false }
        do {
            try await manual.save(draft)
            dismiss()
        } catch {
            self.error = "保存できませんでした：\(error.localizedDescription)"
        }
    }

    private func delete() async {
        busy = true
        defer { busy = false }
        do {
            try await manual.delete(original)
            if manual.path.last == .card(original.id) { manual.path.removeLast() }
            dismiss()
        } catch {
            self.error = "削除できませんでした：\(error.localizedDescription)"
        }
    }
}

// MARK: - 1ステップの編集欄

struct StepEditorRow: View {
    @Binding var step: ManualStep
    let number: Int
    let isFirst: Bool
    let isLast: Bool
    let others: [ManualStep]
    let numberOf: (String) -> Int
    let tint: Color
    var focus: FocusState<String?>.Binding
    let onMove: (Int) -> Void
    let onDelete: () -> Void
    let onError: (String) -> Void

    @Environment(ManualStore.self) private var manual
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var uploading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(tint, in: Circle())
                Picker("種類", selection: $step.kind) {
                    ForEach(StepKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
                Spacer()
                Group {
                    Button { onMove(-1) } label: { Image(systemName: "chevron.up").frame(width: 30, height: 30) }
                        .disabled(isFirst).accessibilityLabel("上へ")
                    Button { onMove(1) } label: { Image(systemName: "chevron.down").frame(width: 30, height: 30) }
                        .disabled(isLast).accessibilityLabel("下へ")
                    Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash").frame(width: 30, height: 30) }
                        .accessibilityLabel("このステップを削除")
                }
                .buttonStyle(.bordered)
            }

            TextField(step.kind == .question ? "質問（例：お客様は精算機の前にいますか？）" : "やること（例：部屋番号を聞く）",
                      text: $step.text, axis: .vertical)
                .font(.title3)
                .lineLimit(2...8)
                .focused(focus, equals: step.id)
                .padding(12)
                .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12))

            if step.kind == .question {
                branches
            } else {
                photoRow
                Toggle(isOn: $step.end) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ここで対応完了").font(.subheadline.weight(.bold))
                        Text("分岐の途中で終わるステップに使います").font(.caption).foregroundStyle(Palette.sub)
                    }
                }
                .tint(tint)
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                defer { pickerItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else {
                    onError(ManualError.badImage.localizedDescription)
                    return
                }
                await upload(img)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in Task { await upload(img) } }
                .ignoresSafeArea()
        }
    }

    private var branches: some View {
        VStack(alignment: .leading, spacing: 8) {
            branchPicker("はい のとき", selection: $step.yes)
            branchPicker("いいえ のとき", selection: $step.no)
        }
    }

    private func branchPicker(_ title: String, selection: Binding<String?>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline.weight(.bold)).frame(width: 110, alignment: .leading)
            Picker(title, selection: selection) {
                Text("次のステップへ").tag(String?.none)
                ForEach(others) { o in
                    Text("ステップ \(numberOf(o.id))：\(o.text.isEmpty ? "（未入力）" : String(o.text.prefix(18)))")
                        .tag(String?.some(o.id))
                }
            }
            .pickerStyle(.menu)
            .tint(tint)
        }
    }

    private var photoRow: some View {
        HStack(spacing: 12) {
            if let name = step.image {
                ManualImage(name: name, fill: true)
                    .frame(width: 140, height: 96)
                Button(role: .destructive) { step.image = nil } label: {
                    Label("写真を外す", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
            if uploading {
                ProgressView("アップロード中…")
            } else {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(step.image == nil ? "写真を選ぶ" : "写真を変える", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: { Label("撮影", systemImage: "camera") }
                        .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
    }

    private func upload(_ img: UIImage) async {
        uploading = true
        defer { uploading = false }
        do {
            step.image = try await manual.upload(img)
        } catch {
            onError("写真を保存できませんでした：\(error.localizedDescription)")
        }
    }
}

// MARK: - カメラ

struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onPick(img) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - 管理者ログイン（編集のときだけ）

struct AdminLoginSheet: View {
    @Environment(ManualStore.self) private var manual
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("マニュアルの編集は管理者のみです。管理者のメールアドレスとパスワードを入力してください。")
                    .font(.subheadline).foregroundStyle(Palette.sub)
                TextField("メールアドレス", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12))
                SecureField("パスワード", text: $password)
                    .textContentType(.password)
                    .padding(14)
                    .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit { Task { await login() } }
                if let error {
                    Text(error).font(.footnote.weight(.semibold)).foregroundStyle(Palette.sunday)
                }
                Text("このログインは端末に保存されず、「編集を終える」かマニュアルを閉じると解除されます。")
                    .font(.caption).foregroundStyle(Palette.sub)
                Spacer()
            }
            .padding(20)
            .navigationTitle("管理者として編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await login() }
                    } label: {
                        if busy { ProgressView() } else { Text("ログイン").bold() }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func login() async {
        guard !email.isEmpty, !password.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await manual.adminSignIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 以前の内容

struct VersionsSheet: View {
    let cardID: UUID
    let onPick: (ManualVersion) -> Void
    @Environment(ManualStore.self) private var manual
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [ManualVersion]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(Palette.sunday) }
                if let versions, versions.isEmpty {
                    Text("以前の内容はまだありません").foregroundStyle(Palette.sub)
                }
                ForEach(versions ?? []) { v in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(v.title).font(.headline)
                            Text("\(JST.csv.string(from: v.saved_at)) より前・\(v.steps.count) ステップ")
                                .font(.caption).foregroundStyle(Palette.sub)
                        }
                        Spacer()
                        Button("この内容に戻す") {
                            onPick(v)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .overlay { if versions == nil && error == nil { ProgressView() } }
            .navigationTitle("以前の内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .task {
                do { versions = try await manual.versions(of: cardID) } catch { self.error = error.localizedDescription }
            }
        }
    }
}

// MARK: - 削除したカード

struct DeletedCardsSheet: View {
    let category: ManualCategory
    @Environment(ManualStore.self) private var manual
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ManualVersion]?
    @State private var error: String?
    @State private var restoring: Int?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(Palette.sunday) }
                if let items, items.isEmpty {
                    Text("削除したカードはありません").foregroundStyle(Palette.sub)
                }
                ForEach(items ?? []) { v in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(v.title).font(.headline)
                            Text("\(JST.csv.string(from: v.saved_at)) に削除・\(v.steps.count) ステップ")
                                .font(.caption).foregroundStyle(Palette.sub)
                        }
                        Spacer()
                        if restoring == v.id {
                            ProgressView()
                        } else {
                            Button("元に戻す") { Task { await restore(v) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .overlay { if items == nil && error == nil { ProgressView() } }
            .navigationTitle("削除した\(category.label)のカード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        do { items = try await manual.deletedCards(in: category) } catch { self.error = error.localizedDescription }
    }

    private func restore(_ v: ManualVersion) async {
        restoring = v.id
        defer { restoring = nil }
        do {
            try await manual.restoreDeleted(v)
            items?.removeAll { $0.card_id == v.card_id }
        } catch {
            self.error = "元に戻せませんでした：\(error.localizedDescription)"
        }
    }
}
