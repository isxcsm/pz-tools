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
  <a href="../de-DE/README.md">Deutsch</a> ·
  <a href="../pl-PL/README.md">Polski</a> ·
  <a href="../tr-TR/README.md">Türkçe</a> ·
  <a href="../uk-UA/README.md">Українська</a> ·
  <strong>Italiano</strong> ·
  <a href="../th-TH/README.md">ไทย</a> ·
  <a href="../id-ID/README.md">Bahasa Indonesia</a> ·
  <a href="../cs-CZ/README.md">Čeština</a> ·
  <a href="../es-MX/README.md">Español (Latinoamérica)</a>
</p>

<p align="center">
  <img src="../../src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

# PZ Tools

**Tu pensa a sopravvivere. PZ Tools conserva un punto a cui tornare.** Backup automatici, cronologia dei salvataggi e recupero del personaggio per Project Zomboid.

## Funzioni

- Rileva il salvataggio in uso; per impostazione predefinita esegue un backup ogni **5 minuti** e conserva **20 backup automatici**.
- I backup manuali sono rinominabili ed esclusi dal limite di conservazione di quelli automatici.
- Richiesta facoltativa di `save(true)` tramite un agente JVM prima del backup, con conto alla rovescia di 5 secondi nel gioco, senza mod Workshop.
- Miniature, nome, tempo di sopravvivenza e indicazione della morte.
- Acquisizione incrementale con USN, compressione e deduplicazione facoltativa; senza USN, scansione completa con confronto degli hash attivo per impostazione predefinita.
- Ispezione, importazione ed esportazione ZIP, avanzamento e registri delle operazioni.
- Cura e resurrezione fuori dalla partita, conservando tratti positivi e negativi, abilità ed esperienza.

## Per iniziare

Servono **Windows x64 e il runtime .NET 10**. Avvia `PzTools.App.exe` e controlla le cartelle dei salvataggi e dei backup. Crea un backup manuale o usa quelli automatici mentre giochi. L'intervallo `0` li disattiva. Esci da quel salvataggio prima di ripristinarlo o recuperare il personaggio.

## Limiti

Il recupero modifica solo il salvataggio attuale, non i backup precedenti. Supporta **Build 42.20.4, formato mondo 249 e un giocatore locale (ID 1)**. Gli oggetti possono essere recuperati da un unico record corrispondente del proprio zombi, in base alla posizione salvata e al nome sul documento d'identità. Non sono supportati zombi spostati, bersagli senza documento o cadaveri nei chunk della mappa. I tratti negativi rimangono; gli effetti dei mod non vengono necessariamente rimossi.

Il ponte di salvataggio è sperimentale, per giocatore singolo in Build 42 / Java 25, ed è disattivabile. Il messaggio di salvataggio completato nel gioco non indica che il backup sia finito né garantisce un'istantanea atomica del mondo.

I backup manuali possono ancora essere eliminati esplicitamente o dalla pulizia dei backup orfani se scompare il salvataggio originale. Esporta quelli importanti su un altro dispositivo.

[Compilazione (inglese)](../../README.md#building) · [Documentazione tecnica (lingue originali)](../../README.md#technical-documentation)

Strumento non ufficiale; non è un prodotto di The Indie Stone.
