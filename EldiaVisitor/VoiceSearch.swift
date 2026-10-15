import Foundation
import Speech
import AVFoundation
import Observation

/// 音声検索（日本語）。ボタンを押している間だけ聞き取り、離すと止めて検索欄に入れる。
@MainActor
@Observable
final class VoiceSearch {
    /// 聞き取り中（ボタンを押している間）
    private(set) var listening = false
    private(set) var error: String?

    /// 聞き取った文字を受け取る
    @ObservationIgnored var onText: ((String) -> Void)?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var limitTimer: Task<Void, Never>?
    @ObservationIgnored private var finishTimer: Task<Void, Never>?
    /// ボタンが押されているか（許可の確認中に離された場合に開始しないため）
    @ObservationIgnored private var pressed = false
    /// 古い聞き取りの結果を無視するための番号
    @ObservationIgnored private var session = 0

    /// 1回に聞き取る最長時間（押しっぱなしの防止）
    private let maxLength: UInt64 = 30_000_000_000

    // MARK: ボタン

    func press() {
        guard !pressed else { return }
        pressed = true
        error = nil
        Task { await start() }
    }

    func release() {
        pressed = false
        finish()
    }

    // MARK: 聞き取り

    private func start() async {
        cleanup()
        session += 1
        let my = session
        guard await authorize() else { return }
        // 許可の確認中にボタンを離していたら始めない
        guard pressed, my == session else { return }
        guard let recognizer, recognizer.isAvailable else {
            error = "いまは音声検索を使えません。通信を確認してください"
            return
        }

        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()
            listening = true

            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self, my == self.session else { return }
                    if let text, !text.isEmpty { self.onText?(Self.clean(text)) }
                    if final || err != nil { self.cleanup() }
                }
            }
            limitTimer = Task { [weak self, maxLength] in
                try? await Task.sleep(nanoseconds: maxLength)
                guard !Task.isCancelled else { return }
                self?.pressed = false
                self?.finish()
            }
        } catch {
            self.error = "マイクを使えませんでした（\(error.localizedDescription)）"
            cleanup()
        }
    }

    /// 録音を止め、最後の聞き取り結果を少し待ってから終える
    private func finish() {
        guard listening else { return }
        listening = false
        limitTimer?.cancel(); limitTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        finishTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.cleanup()
        }
    }

    /// すべて片付ける（画面を離れたときも呼ぶ）
    func cleanup() {
        limitTimer?.cancel(); limitTimer = nil
        finishTimer?.cancel(); finishTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
        session += 1
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stopAll() {
        pressed = false
        cleanup()
    }

    private func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            error = "音声認識が許可されていません。設定アプリ ＞ 来店記録 で「音声認識」をオンにしてください"
            return false
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else {
            error = "マイクが許可されていません。設定アプリ ＞ 来店記録 で「マイク」をオンにしてください"
            return false
        }
        return true
    }

    /// 句読点を除いて検索しやすくする
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "、", with: " ")
            .replacingOccurrences(of: "？", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
