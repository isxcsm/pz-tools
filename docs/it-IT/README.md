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

# PZ Tools

PZ Tools è un'app Windows non ufficiale per creare e ripristinare backup dei salvataggi di Project Zomboid. Offre anche il recupero del personaggio per il formato supportato. Non è un prodotto di The Indie Stone.

<a id="features"></a>
## Funzioni

Backup manuali e programmati, cronologia rinominabile con miniature e dati del personaggio, importazione/esportazione ZIP, cura e resurrezione a partita chiusa. Interfaccia, nomi predefiniti dei nuovi backup e avvisi di salvataggio nel gioco supportano 18 lingue. Sono disponibili temi, area di notifica opzionale, indicatori di avanzamento e filtri dei registri.

<a id="getting-started"></a>
## Installazione e avvio

Servono **Windows x64** e **[.NET 10 Runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)** per Windows x64. L'app richiede attualmente privilegi di amministratore per il rilevamento USN delle modifiche ai file. Il pacchetto pubblicato include i componenti WinUI e un piccolo runtime Java per la connessione al gioco, ma non i JAR del gioco.

Cerca un pacchetto eseguibile in [Releases](https://github.com/isxcsm/pz-tools/releases). Se non è disponibile, segui le istruzioni di compilazione sotto. Lo **ZIP «Source code» di GitHub non è un'app pronta all'uso**.

1. Estrai il pacchetto **completo** in una cartella e avvia `PzTools.App.exe`. Non copiare soltanto l'EXE e non mescolare file di build diverse.
2. Verifica la cartella dei salvataggi nelle impostazioni e scegli una cartella di backup separata. Non usare la cartella dei salvataggi come destinazione dei backup.
3. Seleziona un salvataggio, crea un backup manuale e controlla il completamento nell'app. Imposta intervallo e numero di backup automatici.
4. Per aggiornare, chiudi PZ Tools e prepara l'intero nuovo pacchetto in un'altra cartella. Tieni salvataggi e backup separati dai file dell'app.

Impostazioni e dati di gestione si trovano in `%LOCALAPPDATA%\PzTools`; i backup nella cartella scelta. Vedi [percorsi di distribuzione e dati (coreano)](../deployment-layout.md).

<a id="backups-and-retention"></a>
## Conservazione ed eliminazione

I valori iniziali sono **5 minuti** e **20 backup automatici**. L'intervallo `0` disattiva i backup automatici. Questi seguono il salvataggio attivo; riavviare l'app avvia un nuovo intervallo. Le impostazioni esistenti vengono mantenute.

I backup manuali si possono rinominare e sono esclusi dal limite dei backup automatici. **Non sono però conservati per sempre:** l'eliminazione esplicita o la pulizia dopo la scomparsa del salvataggio originale può rimuoverli. Prima di eliminare o spostare l'originale, esporta i backup importanti in ZIP su un'altra unità.

Eliminare un backup lascia intatto il salvataggio attuale, ma impedisce di ripristinare o esportare quel backup. Eliminare un salvataggio dall'app rimuove anche i relativi backup. Lo spazio può essere recuperato in seguito; le dimensioni dei file non diminuiscono necessariamente subito. Vedi [impostazioni (coreano)](../configuration.md) e [regole di pulizia (inglese)](../repository-housekeeping.md).

<a id="game-saving"></a>
## Salvataggio del gioco prima del backup

La connessione opzionale chiede al gioco attivo di salvare prima della copia. Carica un agente JVM e chiama `GameWindow.save(true)` sul thread del gioco, senza mod Workshop né modifiche all'installazione. È sperimentale per la struttura esaminata di **Build 42 / Java 25 in giocatore singolo**; il multigiocatore non è supportato.

Salvataggio e conto alla rovescia di cinque secondi hanno interruttori separati. **«Partita salvata» non significa «Backup completato»:** acquisizione e compressione dei file seguono dopo. Senza connessione, o per un salvataggio inattivo, vengono copiati soltanto i dati già scritti su disco. Una richiesta fallita o incerta non viene indicata come riuscita. Vedi [integrazione del salvataggio (inglese)](../save-bridge.md).

<a id="restore-and-archives"></a>
## Ripristino e archivi ZIP

Esci dalla partita selezionata prima del ripristino. Scegli il backup e controlla la conferma: **i file attuali vengono sostituiti e i progressi successivi a quel backup vanno persi**. Se il ripristino si interrompe, riapri PZ Tools e verifica lo stato prima di caricare la partita. Non presumere che il ritorno automatico allo stato precedente sia riuscito.

Esporta il salvataggio attuale o un backup in ZIP e ispeziona uno ZIP prima di importarlo. Conserva gli archivi a lungo termine fuori dalla cartella di backup dell'app. Una copia sulla stessa unità non protegge dal guasto dell'unità. I [comandi CLI (coreano)](../cli.md) descrivono le operazioni equivalenti.

<a id="character-recovery"></a>
## Recupero del personaggio

Crea prima un backup manuale o un ZIP: **il recupero non crea una copia aggiuntiva dei file originali**. Modifica soltanto il salvataggio attuale non in uso, mai i vecchi backup. Il supporto è limitato a **Build 42.20.4, formato del mondo 249 e un giocatore locale (ID 1)**.

Cura o resurrezione ripristinano la salute ed eliminano lesioni e condizioni temporanee supportate. Tratti positivi e negativi, esperienza, abilità, ricette e inventario esistente restano intatti. Non è un'immunità permanente e non rimuove tutti gli effetti specifici delle mod.

Se l'inventario del personaggio morto è vuoto, gli oggetti possono essere recuperati solo da un unico record corrispondente del proprio zombi, tramite posizione salvata e nome sul documento d'identità. Zombi spostati, bersagli senza documento e cadaveri nei blocchi della mappa non sono supportati. Potrebbe essere necessario riequipaggiare le mani. Vedi [recupero e limiti (inglese)](../character-recovery.md).

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Archiviazione e compatibilità

Il motore archivia i dati modificati invece di duplicare ogni volta tutto il salvataggio. Usa NTFS USN quando disponibile, altrimenti una scansione completa con confronto del contenuto. Verifica della copia e compressione Brotli sono attive per impostazione predefinita; la deduplicazione è opzionale. La risposta del gioco e i controlli sui singoli file **non garantiscono che tutti i file rappresentino lo stesso identico istante**.

Il software è ancora in sviluppo prima della pubblicazione. Gli archivi incompatibili vengono rifiutati con `repository-reset-required`, senza conversione o eliminazione automatica. Scegli una **nuova cartella di backup vuota** e conserva quella precedente se necessaria. **Non eliminare `Zomboid/Saves` o soltanto `repository.db` per aggirare l'errore.** Vedi [formato di archiviazione (coreano)](../repository-format.md) e [configurazione avanzata (inglese)](../runtime-configuration.md).

<a id="troubleshooting"></a>
## Problemi e segnalazioni

Se l'app non si avvia, controlla runtime e completezza del pacchetto. Se un file è in uso o cambia continuamente, lascia terminare il salvataggio del gioco prima di riprovare il backup. Se i backup automatici non partono, verifica intervallo, salvataggio attivo e che PZ Tools sia ancora in esecuzione; chiudere nell'area di notifica non significa uscire.

Dopo un errore o un completamento parziale, leggi i registri prima di ripetere l'operazione. Un ripristino o una modifica del personaggio interrotti richiedono attenzione prima di ricaricare la partita. In una [segnalazione](https://github.com/isxcsm/pz-tools/issues), indica versione o commit dell'app, versione del gioco, passaggi e registri pertinenti. Rimuovi percorsi personali e dati privati; non caricare l'intero salvataggio senza necessità.

<a id="building"></a>
## Compilazione dai sorgenti

Servono Windows, l'SDK .NET indicato da `global.json`, PowerShell 7, un JDK Java 25 Windows x64 e gli strumenti C++/WinUI di Visual Studio. Dalla radice del repository, sostituisci il percorso JDK di esempio:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

Lo script prepara app e processi di lavoro insieme in una cartella di output **nuova o vuota**. Per una nuova pubblicazione scegli un altro percorso. [Sviluppo e verifica (inglese)](../development.md) descrive dipendenze, test dei pacchetti, CLI e test da attivare esplicitamente.

<a id="technical-documentation"></a>
## Documentazione

L'[indice (inglese/coreano)](../README.md) elenca tutti i riferimenti con la lingua originale. [Localizzazione (inglese)](../localization.md) spiega l'ambito delle traduzioni. I [rapporti di verifica (coreano)](../verification-report.md) sono risultati datati, non una garanzia per ogni commit o versione futura del gioco. Vedi anche [le note sui componenti di terze parti (inglese)](../../THIRD_PARTY_NOTICES.md).
