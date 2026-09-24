<p align="center">
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

<p align="center">
  <img src="../../src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

# PZ Tools

**专心生存，把退路交给 PZ Tools。** 为 Project Zomboid 提供自动备份、存档历史和角色恢复的 Windows 工具。

## 主要功能

- 检测正在游玩的存档并定时备份，默认每 **5 分钟**一次，保留 **20 个自动备份**。
- 手动备份可重命名，不受自动备份数量上限的清理影响。
- 可在备份前通过 JVM 代理请求游戏执行 `save(true)`，并显示 5 秒倒计时，无需安装 Workshop 模组。
- 通过缩略图、角色姓名、生存时间和死亡标记选择恢复点。
- USN 增量检测、不可变数据包、压缩、可选去重；无法使用 USN 时，默认通过全量扫描和哈希比较检测变化。
- 支持 ZIP 检查、导入、导出，以及进度卡片和操作日志。
- 支持离线治疗和复活；保留正面与负面特质、技能和经验。符合条件时，可从唯一匹配的本人僵尸记录找回物品。

## 开始使用

需要 **Windows x64 和 .NET 10 运行时**。运行发布目录中的 `PzTools.App.exe`，确认存档及备份目录，然后创建手动备份或开始游戏。将间隔设为 `0` 可关闭自动备份。恢复备份或角色前，请先退出该存档的游玩。

## 范围与限制

角色恢复仅支持 **Build 42.20.4 / 世界格式 249 / 单个本地玩家（ID 1）**，只修改当前存档，不编辑历史备份。物品找回依赖保存位置和身份证姓名；不支持已移动的僵尸、缺少身份证的目标或地图区块中的尸体。负面特质不会被移除，模组特有的负面状态也不保证全部清除。

游戏保存桥接是针对 Build 42 / Java 25 的实验性单人功能，可在设置中关闭。游戏内“保存完成”仅表示游戏保存调用已返回，并不表示备份已完成，也不保证整个世界的原子快照。

手动备份仍可能因主动删除或原存档消失后的孤立备份清理而被移除。重要节点请导出到其他存储设备。

[构建指南（英语）](../../README.md#building) · [技术文档（原文语言）](../../README.md#technical-documentation)

本工具非 The Indie Stone 官方产品。
