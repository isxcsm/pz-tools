<p align="center">
  <a href="../ko-KR/README.md">한국어</a> ·
  <a href="../../README.md">English</a> ·
  <a href="../zh-CN/README.md">简体中文</a> ·
  <a href="../zh-TW/README.md">繁體中文</a> ·
  <strong>日本語</strong> ·
  <a href="../ru-RU/README.md">Русский</a> ·
  <a href="../pt-BR/README.md">Português (Brasil)</a> ·
  <a href="../es-ES/README.md">Español (España)</a> ·
  <a href="../fr-FR/README.md">Français</a> ·
  <a href="../de-DE/README.md">Deutsch</a> ·
  <a href="../pl-PL/README.md">Polski</a> ·
  <a href="../tr-TR/README.md">Türkçe</a> ·
  <a href="../uk-UA/README.md">Українська</a> ·
  <a href="../it-IT/README.md">Italiano</a> ·
  <a href="../th-TH/README.md">ไทย</a> ·
  <a href="../id-ID/README.md">Bahasa Indonesia</a> ·
  <a href="../cs-CZ/README.md">Čeština</a> ·
  <a href="../es-MX/README.md">Español (Latinoamérica)</a>
</p>

<p align="center">
  <img src="../../src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

# PZ Tools

**生き延びるのはプレイヤー。戻れる場所を残すのは PZ Tools。** Project Zomboid 向けの自動バックアップ・セーブ履歴・キャラクター回復ツールです。

## 主な機能

- プレイ中のセーブを検出して自動バックアップ。初期設定は **5 分間隔・自動バックアップ 20 件**です。
- 手動バックアップは名前を変更でき、自動バックアップの件数制限による削除から除外されます。
- バックアップ前に JVM エージェント経由で `save(true)` を要求し、ゲーム内で 5 秒前から通知できます。Workshop MOD は不要です。
- サムネイル・名前・生存時間・死亡表示から復元時点を選べます。
- USN 差分追跡、圧縮、任意の重複排除に対応。USN が使えない場合は全件走査に切り替え、標準でハッシュ比較を行います。
- ZIP の検査・入出力、進捗表示、操作ログを備えています。
- オフラインで治療・蘇生できます。有利・不利な特性、スキル、経験値は維持し、条件を満たす本人のゾンビ記録から所持品を回収できます。

## 使い方

**Windows x64 と .NET 10 ランタイム**が必要です。配布フォルダーの `PzTools.App.exe` を起動し、セーブとバックアップの保存先を確認してください。手動バックアップを作るか、プレイ中の自動バックアップを利用します。間隔 `0` で自動バックアップを停止できます。復元・キャラクター回復の前に、そのセーブのプレイを終了してください。

## 対応範囲と注意点

キャラクター回復は **Build 42.20.4・ワールド形式 249・ローカルプレイヤー 1 人（ID 1）**の現在のセーブのみが対象です。過去のバックアップは編集しません。所持品回収には保存位置と身分証の名前による一意な一致が必要です。移動済みのゾンビ、身分証のない対象、マップチャンク内の死体は対象外です。不利な特性は削除せず、MOD 独自の状態をすべて治す保証もありません。

保存ブリッジは Build 42 / Java 25 向けの実験的なシングルプレイ機能で、設定から無効にできます。ゲーム内の「保存完了」は保存呼び出しの終了を示し、バックアップ全体の完了やワールド全体の原子的なスナップショットを保証しません。

手動バックアップも明示的な削除や元のセーブが消えた際の孤立バックアップ整理の対象になります。重要な時点は別の記憶装置に書き出してください。

[ビルド手順（英語）](../../README.md#building) · [技術資料（原文）](../../README.md#technical-documentation)

The Indie Stone の公式製品ではありません。
