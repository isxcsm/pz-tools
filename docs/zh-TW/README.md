<p align="center">
  <a href="../ko-KR/README.md">한국어</a> ·
  <a href="../../README.md">English</a> ·
  <a href="../zh-CN/README.md">简体中文</a> ·
  <strong>繁體中文</strong> ·
  <a href="../ja-JP/README.md">日本語</a> ·
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

**專心求生，把退路交給 PZ Tools。** 為 Project Zomboid 提供自動備份、存檔歷史與角色復原的 Windows 工具。

## 主要功能

- 偵測正在遊玩的存檔並定時備份，預設每 **5 分鐘**一次，保留 **20 個自動備份**。
- 手動備份可重新命名，不受自動備份數量上限的清理影響。
- 可在備份前透過 JVM 代理請求遊戲執行 `save(true)`，並顯示 5 秒倒數，無須安裝 Workshop 模組。
- 透過縮圖、角色姓名、生存時間與死亡標記挑選還原點。
- USN 增量偵測、不可變資料封裝、壓縮與選用去重；無法使用 USN 時，預設以完整掃描與雜湊比較偵測變更。
- 支援 ZIP 檢查、匯入、匯出，以及進度卡片與操作記錄。
- 支援離線治療與復活，保留正面及負面特質、技能與經驗。符合條件時，可從唯一匹配的自身殭屍記錄找回物品。

## 開始使用

需要 **Windows x64 與 .NET 10 執行階段**。執行發佈目錄中的 `PzTools.App.exe`，確認存檔與備份目錄，再建立手動備份或開始遊戲。將間隔設為 `0` 可關閉自動備份。還原備份或復原角色前，請先結束該存檔的遊玩。

## 範圍與限制

角色復原僅支援 **Build 42.20.4 / 世界格式 249 / 單一本機玩家（ID 1）**，只修改目前存檔，不編輯歷史備份。物品找回依賴儲存位置與身分證姓名；不支援已移動的殭屍、缺少身分證的目標或地圖區塊中的屍體。負面特質不會被移除，模組專屬的負面狀態也不保證全部清除。

遊戲儲存橋接是針對 Build 42 / Java 25 的實驗性單人功能，可在設定中關閉。遊戲內「儲存完成」僅代表遊戲儲存呼叫已返回，不代表備份完成，也不保證整個世界的原子快照。

手動備份仍可能因主動刪除或原存檔消失後的孤立備份清理而移除。重要節點請匯出至其他儲存裝置。

[建置指南（英語）](../../README.md#building) · [技術文件（原文語言）](../../README.md#technical-documentation)

本工具並非 The Indie Stone 官方產品。
