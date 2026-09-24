<p align="center">
  <a href="../ko-KR/README.md">한국어</a> ·
  <a href="../../README.md">English</a> ·
  <a href="../zh-CN/README.md">简体中文</a> ·
  <a href="../zh-TW/README.md">繁體中文</a> ·
  <a href="../ja-JP/README.md">日本語</a> ·
  <a href="../ru-RU/README.md">Русский</a> ·
  <a href="../pt-BR/README.md">Português (Brasil)</a> ·
  <a href="../es-ES/README.md">Español (España)</a> ·
  <a href="../fr-FR/README.md">Français</a> ·
  <strong>Deutsch</strong> ·
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

**Du kümmerst dich ums Überleben. PZ Tools hält einen Weg zurück offen.** Automatische Backups, Spielstandverlauf und Charakterwiederherstellung für Project Zomboid.

## Funktionen

- Erkennt den aktiven Spielstand; standardmäßig ein Backup alle **5 Minuten**, mit **20 automatischen Backups** im Verlauf.
- Manuelle Backups lassen sich umbenennen und sind vom Aufbewahrungslimit automatischer Backups ausgenommen.
- Optionales `save(true)` über einen JVM-Agenten vor dem Backup, mit 5-Sekunden-Countdown im Spiel, ohne Workshop-Mod.
- Vorschaubilder, Name, Überlebenszeit und Todesanzeige.
- Inkrementelle USN-Erfassung, Komprimierung und optionale Deduplizierung; ohne USN vollständiger Scan mit standardmäßig aktiviertem Hashvergleich.
- ZIP-Prüfung, Import und Export sowie Fortschrittsanzeigen und Protokolle.
- Heilung und Wiederbelebung außerhalb der laufenden Partie; positive und negative Eigenschaften, Fähigkeiten und Erfahrung bleiben erhalten.

## Einstieg

Benötigt werden **Windows x64 und die .NET-10-Laufzeit**. Starte `PzTools.App.exe` und prüfe die Spielstand- und Backupordner. Erstelle ein manuelles Backup oder nutze automatische Backups beim Spielen. Intervall `0` deaktiviert sie. Verlasse den betreffenden Spielstand vor einer Wiederherstellung oder Charakterheilung.

## Grenzen

Die Charakterwiederherstellung bearbeitet nur den aktuellen Spielstand, keine alten Backups. Unterstützt werden **Build 42.20.4, Weltformat 249 und ein lokaler Spieler (ID 1)**. Gegenstände können aus einem eindeutig passenden Datensatz des eigenen Zombies zurückgeholt werden, anhand gespeicherter Position und Ausweisname. Bewegte Zombies, Ziele ohne Ausweis und Leichen in Karten-Chunks werden nicht unterstützt. Negative Eigenschaften bleiben; mod-spezifische Effekte werden nicht vollständig abgedeckt.

Die Speicherbrücke ist experimentell, für Einzelspieler unter Build 42 / Java 25, und abschaltbar. Die Speichermeldung im Spiel bedeutet weder ein abgeschlossenes Backup noch einen garantierten atomaren Schnappschuss der Welt.

Manuelle Backups können weiterhin ausdrücklich gelöscht oder nach Verschwinden des ursprünglichen Spielstands als verwaiste Backups bereinigt werden. Exportiere wichtige Backups auf einen anderen Datenträger.

[Build-Anleitung (Englisch)](../../README.md#building) · [Technische Dokumentation (Originalsprachen)](../../README.md#technical-documentation)

Inoffizielles Werkzeug; kein Produkt von The Indie Stone.
