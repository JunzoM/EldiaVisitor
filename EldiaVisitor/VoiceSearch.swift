import Foundation
import Speech
import AVFoundation
import Observation

/// 音声検索（日本語）。話した言葉を文字にして検索欄に入れる。
/// 話し終わって少し間があくと自動で止まる。
@MainActor
@Observable
final class VoiceSearch {
    private(set) var listening = false
    private(set) var error: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Task<Void, Never>?
    @ObservationIgnored private var limitTimer: Task<Void, Never>?

    /// 話し終わりとみなす無音の長さ
    private let silence: UInt64 = 1_500_000_000
    /// 1回に聞き取る最長時間
    private let maxLength: UInt64 = 12_000_000_000

    func toggle(onText: @escaping (String) -> Void) {
        if listening { stop() } else { Task { await start(onText: onText) } }
    }

    func start(onText: @escaping (String) -> Void) async {
        error = nil
        guard await authorize() else { return }
        guard let recognizer, recognizer.isAvailable else {
            error = "いまは音声検索を使えません。通信を確認してください"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()
            listening = true

            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self, self.listening else { return }
                    if let text, !text.isEmpty {
                        onText(Self.clean(text))
                        self.restartSilenceTimer()
                    }
                    if final || err != nil { self.stop() }
                }
            }
            restartSilenceTimer()
            limitTimer = Task { [weak self, maxLength] in
                try? await Task.sleep(nanoseconds: maxLength)
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            self.error = "マイクを使えませんでした（\(error.localizedDescription)）"
            stop()
        }
    }

    func stop() {
        silenceTimer?.cancel(); silenceTimer = nil
        limitTimer?.cancel(); limitTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restartSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self, silence] in
            try? await Task.sleep(nanoseconds: silence)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
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
