<p>
  <a href="../ko-KR/README.md">한국어</a> ·
  <a href="../../README.md">English</a> ·
  <strong>简体中文</strong> ·
  <a href="../zh-TW/README.md">繁體中文</a> ·
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

PZ Tools 是用于备份和恢复 Project Zomboid 存档的 Windows 应用，也为受支持的存档格式提供角色恢复功能。它不是 The Indie Stone 的官方产品。

<a id="features"></a>
## 主要功能

支持手动与定时备份、可命名的备份历史、缩略图和角色信息、ZIP 导入导出，以及退出存档后进行的角色治疗与复活。界面、新备份的默认名称和游戏保存通知支持18种语言，并提供主题、系统托盘、进度显示和日志筛选。

<a id="getting-started"></a>
## 安装与运行

需要 **Windows x64** 和 Windows x64 版 **[.NET 10 运行时](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)**。当前应用会为 USN 文件变更跟踪请求管理员权限。发布包包含 WinUI 组件和连接游戏所需的小型 Java 运行时，不包含游戏 JAR 文件。

请在 [Releases](https://github.com/isxcsm/pz-tools/releases) 查看可运行的发布包。若尚未发布，请按下方步骤从源码构建。GitHub 的 **Source code ZIP 不是可直接运行的应用**。

1. 将**整个**发布包解压到同一文件夹，运行 `PzTools.App.exe`。不要只复制 EXE，也不要混用不同构建版本的文件。
2. 在设置中确认存档文件夹，并选择独立的备份文件夹。不要把游戏存档文件夹设为备份目标。
3. 选择存档，创建手动备份，并确认应用显示完成。设置自动备份间隔和保留数量。
4. 更新时先退出 PZ Tools，将完整的新包放到另一文件夹。存档和备份数据应与应用文件分开存放。

设置与管理数据位于 `%LOCALAPPDATA%\PzTools`，备份位于所选文件夹。详情见[部署与数据路径（韩语）](../deployment-layout.md)。

<a id="backups-and-retention"></a>
## 保留与删除备份

初始设置为**每5分钟备份，保留20个自动备份**。 使用自动备份开关开启或关闭备份，间隔可设为1～60分钟。关闭后仍保留间隔。自动备份针对正在游玩的存档；应用重启后会开始新的计时间隔，已有用户设置会保留。

手动备份可重命名，不受自动备份数量上限的清理影响，但**并非永久保留**。主动删除或原存档消失后的清理也可能删除手动备份。删除或移动原存档前，请将重要备份导出为 ZIP 并存到其他驱动器。

只删除备份不会删除当前存档，但该备份将无法恢复或导出。在应用中删除存档也会删除对应的备份。空间回收可能稍后执行，因此文件大小不一定立即缩小。参见[设置（韩语）](../configuration.md)和[清理规则（英语）](../repository-housekeeping.md)。

<a id="game-saving"></a>
## 备份前保存游戏

可选的游戏连接功能会在复制文件前要求正在运行的游戏保存。它加载 JVM 代理，在游戏线程上调用 `GameWindow.save(true)`，不需要 Workshop 模组，也不修改游戏安装文件。此实验性功能面向已检查的 **Build 42 / Java 25 单人游戏**结构，不支持多人游戏。

游戏保存与5秒倒计时可分别开关。**“游戏保存完成”不等于“备份完成”**：之后还要收集和压缩文件。关闭连接或备份非游玩中的存档时，只备份已经写入磁盘的数据。失败或结果不明确的保存请求不会被当作成功。参见[游戏保存集成（英语）](../save-bridge.md)。

<a id="restore-and-archives"></a>
## 恢复、导入和导出

恢复前先退出目标存档的游玩。选择备份后仔细检查确认窗口：**恢复会替换当前文件，因此该备份之后的进度会丢失**。恢复中断时，请先重新打开 PZ Tools 并检查状态，再在游戏中加载存档。不要假定自动回滚已经成功。

可将当前存档或备份导出为 ZIP，也可检查 ZIP 内容后再导入。长期保存的 ZIP 应放在应用备份文件夹之外。同一驱动器上的备份不能防范该驱动器损坏。[命令行说明（韩语）](../cli.md)列出了对应操作。

<a id="character-recovery"></a>
## 角色恢复

先创建手动备份或导出 ZIP：**角色恢复不会额外备份原文件**。它只修改当前且未在游玩的存档，不编辑历史备份。支持范围为 **Build 42.20.4、世界格式249、单个本地玩家（ID 1）**。

治疗或复活会恢复生命值并清除受支持的伤势和临时状态，同时保留正面与负面特质、经验、技能、配方和现有物品。它不提供永久免疫，也不保证移除所有模组效果。

如果死亡清空了物品栏，将从角色的僵尸或尸体中取回物品并移除该来源。无需身份证。物品状态、背包内容、穿戴及附着信息均保留。保存的物品ID可用时会恢复手持装备，否则需手动重新装备。不会生成已丢失的物品；无法确认身份时不会修改存档。 [角色恢复及限制（英语）](../character-recovery.md)

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## 存储方式与兼容性

引擎保存变化的数据，而不是每次复制整个存档。可用时采用 NTFS USN 跟踪，否则执行完整扫描和内容比较。默认启用复制验证与 Brotli 压缩，内容去重是可选功能。游戏保存返回成功和逐文件验证**不能保证所有文件都来自完全相同的瞬间**。

项目仍处于发布前开发阶段。不兼容的备份仓库会以 `repository-reset-required` 拒绝打开，不会自动转换或删除。请选择**新的空备份文件夹**，需要旧备份时保留整个旧文件夹。**不要为解决此错误而删除 `Zomboid/Saves` 或单独删除 `repository.db`。** 当前格式和架构见[仓库格式（韩语）](../repository-format.md)，高级选项见[运行配置（英语）](../runtime-configuration.md)。

<a id="troubleshooting"></a>
## 排查与反馈

应用无法启动时，检查运行时和发布包是否完整。文件被占用或持续变化时，等待游戏保存结束后再重试备份。自动备份不运行时，检查间隔、当前游玩的存档及 PZ Tools 是否仍在运行；关闭到托盘并不是退出应用。

操作失败或部分完成时，先查看日志再决定是否重复执行。恢复或角色编辑中断后，应先处理状态问题，再加载存档。提交 [Issue](https://github.com/isxcsm/pz-tools/issues) 时请说明应用版本或提交、游戏版本、复现步骤和相关日志。去除个人路径与隐私信息；无必要时不要上传整个存档。

<a id="building"></a>
## 从源码构建

需要 Windows、`global.json` 指定的 .NET SDK、PowerShell 7、Windows x64 Java 25 JDK，以及 Visual Studio C++/WinUI 构建工具。在仓库根目录执行，并替换示例中的 JDK 路径：

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

发布脚本只接受**新建或空的输出文件夹**，会一起准备应用和工作进程。再次发布时选择另一输出路径。[开发与验证（英语）](../development.md)说明依赖、发布包测试、CLI 用法和需要主动启用的测试。

<a id="technical-documentation"></a>
## 文档

[文档目录（英语／韩语）](../README.md)列出所有参考资料及原文语言。[本地化（英语）](../localization.md)解释翻译范围。[验证报告（韩语）](../verification-report.md)是有日期的测试记录，不代表之后每次提交或每个游戏版本都已验证。另见[第三方组件声明（英语）](../../THIRD_PARTY_NOTICES.md)。
