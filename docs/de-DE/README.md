<p>
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

# PZ Tools

PZ Tools ist eine inoffizielle Windows-App zum Sichern und Wiederherstellen von Project-Zomboid-Spielständen. Für das unterstützte Speicherformat bietet sie auch eine Charakterwiederherstellung. Sie ist kein Produkt von The Indie Stone.

<a id="features"></a>
## Funktionen

Manuelle und geplante Sicherungen, benennbarer Sicherungsverlauf mit Vorschaubildern und Charakterdaten, ZIP-Import und -Export sowie Heilung und Wiederbelebung außerhalb einer laufenden Partie. Oberfläche, neue Standardnamen für Sicherungen und Spielspeicherhinweise unterstützen 18 Sprachen. Dazu kommen Designs, ein optionaler Infobereich-Modus, Fortschrittsanzeigen und Protokollfilter.

<a id="getting-started"></a>
## Installation und Start

Erforderlich sind **Windows x64** und die **[.NET-10-Runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)** für Windows x64. Die App fordert derzeit Administratorrechte für die USN-Dateiänderungsverfolgung an. Ein veröffentlichtes Paket enthält die WinUI-Komponenten und eine kleine Java-Laufzeit für die Spielverbindung, aber keine Spiel-JARs.

Ausführbare Pakete findest du unter [Releases](https://github.com/isxcsm/pz-tools/releases). Ist noch keines veröffentlicht, nutze die Bauanleitung unten. Das **„Source code“-ZIP von GitHub ist keine ausführbare App**.

1. Entpacke das **vollständige** Paket in einen Ordner und starte `PzTools.App.exe`. Kopiere nicht nur die EXE und mische keine Dateien verschiedener Builds.
2. Prüfe in den Einstellungen den Spielstandordner und wähle einen getrennten Sicherungsordner. Verwende den Spielstandordner nicht als Sicherungsziel.
3. Wähle einen Spielstand, erstelle eine manuelle Sicherung und prüfe die Erfolgsmeldung. Stelle Intervall und Anzahl automatischer Sicherungen ein.
4. Beende PZ Tools vor einem Update und lege das neue vollständige Paket in einem anderen Ordner ab. Bewahre Spielstände und Sicherungen getrennt von den Programmdateien auf.

Einstellungen und Verwaltungsdaten liegen unter `%LOCALAPPDATA%\PzTools`, Sicherungen im ausgewählten Ordner. Siehe [Dateiablage und Bereitstellung (Koreanisch)](../deployment-layout.md).

<a id="backups-and-retention"></a>
## Aufbewahrung und Löschen

Die Anfangswerte sind **5 Minuten** und **20 automatische Sicherungen**. Automatische Sicherungen lassen sich separat ein- und ausschalten. Das Intervall von 1–60 Minuten bleibt beim Ausschalten erhalten. Sie folgen dem aktiven Spielstand; ein App-Neustart beginnt ein neues Intervall. Vorhandene Einstellungen bleiben erhalten.

Manuelle Sicherungen lassen sich umbenennen und zählen nicht zum automatischen Aufbewahrungslimit. **Sie werden aber nicht dauerhaft geschützt:** ausdrückliches Löschen oder die Bereinigung nach dem Verschwinden des ursprünglichen Spielstands kann auch sie entfernen. Exportiere wichtige Sicherungen vor dem Löschen oder Verschieben des Originals als ZIP auf ein anderes Laufwerk.

Das Löschen einer Sicherung lässt den aktuellen Spielstand bestehen, verhindert aber die Wiederherstellung und den Export dieser Sicherung. Das Löschen eines Spielstands in der App entfernt auch dessen Sicherungen. Speicherplatz kann erst später freigegeben werden; Dateien werden nicht unbedingt sofort kleiner. Siehe [Einstellungen (Koreanisch)](../configuration.md) und [Bereinigungsregeln (Englisch)](../repository-housekeeping.md).

<a id="game-saving"></a>
## Spiel vor der Sicherung speichern

Die optionale Verbindung fordert das aktive Spiel vor dem Kopieren zum Speichern auf. Sie lädt einen JVM-Agenten und ruft `GameWindow.save(true)` im Spielthread auf, ohne Workshop-Mod oder Änderung der Spielinstallation. Die experimentelle Funktion richtet sich an die geprüfte **Build-42-/Java-25-Einzelspielerstruktur**; Mehrspieler wird nicht unterstützt.

Speichern und Fünf-Sekunden-Countdown haben getrennte Schalter. **„Spiel gespeichert“ bedeutet nicht „Sicherung abgeschlossen“:** danach folgen Dateierfassung und Kompression. Ohne Verbindung oder bei einem inaktiven Spielstand werden nur bereits auf die Platte geschriebene Daten gesichert. Fehlgeschlagene oder unklare Speicherantworten gelten nicht als Erfolg. Siehe [Spielanbindung (Englisch)](../save-bridge.md).

<a id="restore-and-archives"></a>
## Wiederherstellen und ZIP-Dateien

Beende die Partie des ausgewählten Spielstands vor der Wiederherstellung. Prüfe Sicherung und Bestätigung: **Die aktuellen Dateien werden ersetzt; Fortschritte seit dieser Sicherung gehen verloren.** Bei einer Unterbrechung öffne PZ Tools erneut und prüfe den Zustand, bevor du den Spielstand lädst. Verlasse dich nicht darauf, dass eine automatische Rücknahme erfolgreich war.

Exportiere den aktuellen Spielstand oder eine Sicherung als ZIP und prüfe ein ZIP vor dem Import. Langfristige Archive gehören außerhalb des App-Sicherungsordners. Sicherungen auf demselben Laufwerk schützen nicht vor dessen Ausfall. Entsprechende Befehle stehen in der [CLI-Anleitung (Koreanisch)](../cli.md).

<a id="character-recovery"></a>
## Charakterwiederherstellung

Erstelle zuerst eine manuelle Sicherung oder ein ZIP: **Die Charakterwiederherstellung legt keine zusätzliche Kopie der Originaldateien an.** Sie ändert nur den aktuellen, nicht gespielten Spielstand und keine früheren Sicherungen. Unterstützt werden **Build 42.20.4, Weltformat 249 und ein lokaler Spieler (ID 1)**.

Heilung oder Wiederbelebung stellt Gesundheit wieder her und entfernt unterstützte Verletzungen und vorübergehende Zustände. Positive und negative Eigenschaften, Erfahrung, Fähigkeiten, Rezepte und vorhandenes Inventar bleiben erhalten. Das ist keine dauerhafte Immunität und entfernt nicht alle modabhängigen Effekte.

Bei leerem Inventar eines verstorbenen Charakters ist eine Gegenstandsrückholung nur aus einem eindeutig passenden gespeicherten Spielerzombie möglich, anhand von Position und Ausweisname. Bewegte Zombies, Ziele ohne Ausweis und Leichen in Karten-Chunks werden nicht unterstützt. Handausrüstung muss eventuell neu zugewiesen werden. Siehe [Charakterwiederherstellung und Grenzen (Englisch)](../character-recovery.md).

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Speicherung und Kompatibilität

Die Engine speichert Änderungen statt jedes Mal einen vollständigen Spielstand zu duplizieren. Sie verwendet NTFS USN, falls verfügbar, sonst einen vollständigen Scan mit Inhaltsvergleich. Kopierprüfung und Brotli-Kompression sind standardmäßig aktiv; Deduplizierung ist optional. Spielspeicherantwort und Einzeldateiprüfungen **garantieren keinen exakt gemeinsamen Zeitpunkt aller Dateien**.

Die Software befindet sich vor der Veröffentlichung. Inkompatible Sicherungsablagen werden mit `repository-reset-required` abgewiesen, nicht automatisch konvertiert oder gelöscht. Wähle einen **neuen leeren Sicherungsordner** und behalte den alten bei Bedarf. **Lösche weder `Zomboid/Saves` noch nur `repository.db`, um den Fehler zu umgehen.** Das aktuelle Format steht unter [Ablageformat (Koreanisch)](../repository-format.md), weitere Optionen unter [Laufzeitkonfiguration (Englisch)](../runtime-configuration.md).

<a id="troubleshooting"></a>
## Probleme prüfen und melden

Startet die App nicht, prüfe Runtime und Paketvollständigkeit. Bei benutzten oder ständig geänderten Dateien warte das Speichern im Spiel ab und versuche die Sicherung erneut. Bleiben automatische Sicherungen aus, prüfe Intervall, aktiven Spielstand und ob PZ Tools noch läuft; in den Infobereich schließen ist kein Beenden.

Lies bei Fehlern oder Teilerfolgen vor einer Wiederholung das Protokoll. Unterbrochene Wiederherstellungen oder Charakteränderungen müssen vor erneutem Laden geprüft werden. Gib in einem [Issue](https://github.com/isxcsm/pz-tools/issues) App-Version oder Commit, Spielversion, Schritte und relevante Protokolle an. Entferne persönliche Pfade und private Daten; lade nicht unnötig einen vollständigen Spielstand hoch.

<a id="building"></a>
## Aus dem Quellcode bauen

Benötigt werden Windows, das durch `global.json` gewählte .NET SDK, PowerShell 7, ein Windows-x64-Java-25-JDK und Visual-Studio-C++-/WinUI-Buildtools. Führe diese Befehle im Repository-Stamm aus und ersetze den JDK-Beispielpfad:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

Das Veröffentlichungsskript erstellt App und Arbeitsprozesse gemeinsam in einem **neuen oder leeren Ausgabeordner**. Wähle für eine weitere Veröffentlichung einen anderen Pfad. [Entwicklung und Prüfung (Englisch)](../development.md) beschreibt Abhängigkeiten, Pakettests, CLI und ausdrücklich zu aktivierende Tests.

<a id="technical-documentation"></a>
## Dokumentation

Das [Dokumentationsverzeichnis (Englisch/Koreanisch)](../README.md) enthält alle Referenzen mit Originalsprache. [Lokalisierung (Englisch)](../localization.md) erklärt den Übersetzungsumfang. [Prüfberichte (Koreanisch)](../verification-report.md) sind datierte Ergebnisse, keine Aussage über alle späteren Commits oder Spielversionen. Beachte auch die [Drittanbieterhinweise (Englisch)](../../THIRD_PARTY_NOTICES.md).
