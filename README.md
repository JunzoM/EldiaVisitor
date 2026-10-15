# 来店記録（EldiaVisitor）

MODERN・LUXURY 2店舗の来店客層（男女×年齢層・客層）を、カメラモニターの目視で記録・分析する iPhone / iPad アプリ。

- 記録先：共通 Supabase（cleaning-log）の `visitor_logs`、集計は `visitor_stats()`
- ログイン：ELDIA 共通ログイン（メール＋パスワード）
- iPad（縦）は2店舗を左右に並べて同時記録、iPhone は店舗を切り替えて記録
- 記録はいったん端末に保存し、通信できたら自動送信（二重登録なし）
- フロントマニュアル：精算・ご予約・メンバーズ・クーポン・食事・伝票・シリウス操作の7カテゴリ。1画面1ステップで表示し、はい／いいえで分岐。共通 Supabase の `manual_cards`（写真は非公開バケット `manual-images`）。端末に保存するので回線が切れても見られる。編集は `manual_admins` に登録した管理者のみ（フロント用アカウントでログイン中でも、編集のときだけ管理者でログインできる）。変更前の内容は `manual_card_versions` に残り、元に戻せる
- 分析：概要・年齢層×性別・客層別・客層×年齢層・時間帯・組の人数・曜日別、CSV書き出し

## 開くとき

1. `EldiaVisitor.xcodeproj` を Xcode 26 以降で開く
2. ターゲット EldiaVisitor › Signing & Capabilities で Team を選ぶ
3. 実機を選んで実行

Bundle ID：`com.bestdelight.eldiavisitor`／対応：iOS・iPadOS 17 以降（iOS 26 以降は Liquid Glass 表示）
