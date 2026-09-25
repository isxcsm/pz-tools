<p>
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

# PZ Tools

PZ Tools 是用來備份及還原 Project Zomboid 存檔的 Windows 應用程式，也為支援的存檔格式提供角色復原功能。它不是 The Indie Stone 的官方產品。

<a id="features"></a>
## 主要功能

支援手動與定時備份、可命名的備份歷史、縮圖與角色資訊、ZIP 匯入匯出，以及結束遊玩後的角色治療與復活。介面、新備份的預設名稱及遊戲儲存通知支援18種語言，並提供佈景主題、系統匣、進度顯示與記錄篩選。

<a id="getting-started"></a>
## 安裝與執行

需要 **Windows x64** 與 Windows x64 版 **[.NET 10 執行階段](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)**。目前應用程式會為 USN 檔案變更追蹤要求系統管理員權限。發佈套件包含 WinUI 元件與連線遊戲所需的小型 Java 執行環境，不包含遊戲 JAR 檔案。

請在 [Releases](https://github.com/isxcsm/pz-tools/releases) 確認可執行的發佈套件。若尚未發佈，請使用下方原始碼建置步驟。GitHub 的 **Source code ZIP 並不是可直接執行的應用程式**。

1. 將**整個**套件解壓縮至同一資料夾，執行 `PzTools.App.exe`。不要只複製 EXE，也不要混用不同建置版本的檔案。
2. 在設定中確認存檔資料夾，並選擇獨立的備份資料夾。不要將遊戲存檔資料夾設為備份目的地。
3. 選擇存檔，建立手動備份，確認應用程式顯示完成。設定自動備份間隔與保留數量。
4. 更新前先結束 PZ Tools，將完整的新套件放在另一個資料夾。存檔與備份資料應和應用程式檔案分開存放。

設定及管理資料位於 `%LOCALAPPDATA%\PzTools`，備份位於選定的資料夾。詳見[部署與資料路徑（韓文）](../deployment-layout.md)。

<a id="backups-and-retention"></a>
## 備份保留與刪除

初始設定為**每5分鐘備份，保留20個自動備份**。間隔 `0` 關閉自動備份。自動備份針對正在遊玩的存檔；應用程式重新啟動後開始新的計時間隔，已有使用者設定會保留。

手動備份可重新命名，不受自動備份數量上限的清理影響，但**並非永久保留**。主動刪除或原存檔消失後的清理，也可能移除手動備份。刪除或移動原存檔前，請將重要備份匯出為 ZIP 並存放在其他磁碟機。

只刪除備份會保留目前存檔，但該備份將無法還原或匯出。在應用程式中刪除存檔也會移除其備份。空間回收可能稍後執行，因此檔案大小不一定立即縮小。參見[設定（韓文）](../configuration.md)及[清理規則（英文）](../repository-housekeeping.md)。

<a id="game-saving"></a>
## 備份前儲存遊戲

選用的遊戲連線功能會在複製檔案前，要求正在遊玩的遊戲儲存。它載入 JVM 代理程式，在遊戲執行緒呼叫 `GameWindow.save(true)`，不需要 Workshop 模組，也不更動遊戲安裝檔案。此實驗性功能針對已檢查的 **Build 42 / Java 25 單人遊戲**結構，不支援多人遊戲。

遊戲儲存與5秒倒數可分別開關。**「遊戲儲存完成」不等於「備份完成」**：後續還有檔案收集與壓縮。關閉連線或備份未在遊玩的存檔時，只包含已寫入磁碟的資料。失敗或結果不確定的儲存要求不會被視為成功。詳見[遊戲儲存整合（英文）](../save-bridge.md)。

<a id="restore-and-archives"></a>
## 還原、匯入與匯出

還原前先結束目標存檔的遊玩。選擇備份後確認視窗中的目標：**還原會替換目前檔案，因此該備份之後的進度將遺失**。如果還原中斷，請先重新開啟 PZ Tools 並檢查狀態，再於遊戲中載入存檔。不要假定自動回復已經成功。

可將目前存檔或備份匯出為 ZIP，也可檢查 ZIP 內容後匯入。長期保留的 ZIP 應放在應用程式備份資料夾之外。同一磁碟機上的備份無法防範該磁碟機故障。[命令列說明（韓文）](../cli.md)列出對應的操作。

<a id="character-recovery"></a>
## 角色復原

先建立手動備份或匯出 ZIP：**角色復原不會額外備份原始檔案**。它只修改目前且未在遊玩的存檔，不編輯歷史備份。支援範圍為 **Build 42.20.4、世界格式249、單一本機玩家（ID 1）**。

治療或復活會恢復生命值並清除支援的傷勢與暫時狀態，保留正面及負面特質、經驗、技能、配方和既有物品。它不提供永久免疫，也不保證移除所有模組效果。

死亡角色的物品欄為空時，只能從儲存位置與身分證姓名唯一匹配的自身殭屍記錄找回物品。不支援已移動的殭屍、沒有身分證的對象或地圖區塊中的屍體；手持裝備可能需要重新指定。詳見[角色復原與限制（英文）](../character-recovery.md)。

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## 儲存方式與相容性

引擎儲存變更的資料，而不是每次複製整個存檔。可用時採用 NTFS USN 追蹤，否則切換至完整掃描與內容比較。預設啟用複製驗證和 Brotli 壓縮，資料去重是選用功能。遊戲儲存回應與逐檔案驗證**不能保證所有檔案都來自完全相同的瞬間**。

專案仍在正式發佈前的開發階段。不相容的備份儲存庫會以 `repository-reset-required` 拒絕開啟，不會自動轉換或刪除。請選擇**新的空備份資料夾**，需要舊備份時保留整個舊資料夾。**不要為了解決此錯誤而刪除 `Zomboid/Saves` 或單獨刪除 `repository.db`。** 目前格式與結構見[儲存庫格式（韓文）](../repository-format.md)，進階選項見[執行設定（英文）](../runtime-configuration.md)。

<a id="troubleshooting"></a>
## 疑難排解與回報

無法啟動應用程式時，請確認執行階段和發佈套件是否完整。檔案被使用或持續變更時，等遊戲儲存結束後再重試備份。自動備份未執行時，檢查間隔、正在遊玩的存檔及 PZ Tools 是否仍在執行；關閉至系統匣不等於結束應用程式。

操作失敗或部分完成時，先查看記錄再決定是否重複執行。還原或角色編輯中斷後，應先確認處理狀態，再載入存檔。提交 [Issue](https://github.com/isxcsm/pz-tools/issues) 時請附上應用程式版本或提交、遊戲版本、重現步驟與相關記錄。移除個人路徑及隱私資訊；沒有必要時不要上傳整個存檔。

<a id="building"></a>
## 從原始碼建置

需要 Windows、`global.json` 指定的 .NET SDK、PowerShell 7、Windows x64 Java 25 JDK，以及 Visual Studio C++/WinUI 建置工具。在儲存庫根目錄執行，並替換範例中的 JDK 路徑：

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

發佈腳本只接受**新建或空的輸出資料夾**，會一起準備應用程式及工作處理程式。再次發佈時選擇另一個輸出路徑。[開發與驗證（英文）](../development.md)說明相依項目、發佈套件測試、CLI 用法及需要主動啟用的測試。

<a id="technical-documentation"></a>
## 文件

[文件目錄（英文／韓文）](../README.md)列出所有參考資料及原文語言。[本地化（英文）](../localization.md)解釋翻譯範圍。[驗證報告（韓文）](../verification-report.md)是有日期的測試記錄，不代表往後每次提交或每個遊戲版本都已驗證。另見[第三方元件聲明（英文）](../../THIRD_PARTY_NOTICES.md)。
