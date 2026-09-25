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
  <a href="../it-IT/README.md">Italiano</a> ·
  <a href="../th-TH/README.md">ไทย</a> ·
  <a href="../id-ID/README.md">Bahasa Indonesia</a> ·
  <strong>Čeština</strong> ·
  <a href="../es-MX/README.md">Español (Latinoamérica)</a>
</p>

# PZ Tools

PZ Tools je neoficiální aplikace pro Windows k zálohování a obnovení uložených her Project Zomboid. Pro podporovaný formát nabízí také obnovu postavy. Není produktem The Indie Stone.

<a id="features"></a>
## Funkce

Ruční a plánované zálohy, přejmenovatelná historie s náhledy a údaji o postavě, import/export ZIP a léčení či oživení mimo aktivní hru. Rozhraní, výchozí názvy nových záloh a oznámení o ukládání podporují 18 jazyků. K dispozici jsou motivy, volitelný režim oznamovací oblasti, ukazatele průběhu a filtry záznamů.

<a id="getting-started"></a>
## Instalace a spuštění

Potřebujete **Windows x64** a **[běhové prostředí .NET 10](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)** pro Windows x64. Aplikace nyní vyžaduje oprávnění správce pro sledování změn souborů pomocí USN. Publikovaný balíček obsahuje součásti WinUI a malé prostředí Java pro připojení ke hře, nikoli herní soubory JAR.

Spustitelný balíček hledejte v [Releases](https://github.com/isxcsm/pz-tools/releases). Pokud žádný není vydán, použijte níže uvedený postup sestavení. **ZIP „Source code“ z GitHubu není hotová spustitelná aplikace**.

1. Rozbalte **celý** balíček do jedné složky a spusťte `PzTools.App.exe`. Nekopírujte jen EXE ani nemíchejte soubory různých sestavení.
2. V nastavení ověřte složku uložených her a vyberte samostatnou složku záloh. Jako cíl záloh nepoužívejte složku herních uložení.
3. Vyberte uloženou hru, vytvořte ruční zálohu a ověřte dokončení v aplikaci. Nastavte interval a počet automatických záloh.
4. Před aktualizací ukončete PZ Tools a připravte celý nový balíček v jiné složce. Uložené hry a zálohy uchovávejte odděleně od souborů aplikace.

Nastavení a řídicí data jsou v `%LOCALAPPDATA%\PzTools`, zálohy ve zvolené složce. Viz [rozmístění souborů (korejsky)](../deployment-layout.md).

<a id="backups-and-retention"></a>
## Uchovávání a mazání

Výchozí hodnoty jsou **5 minut** a **20 automatických záloh**. Automatické zálohování zapínejte a vypínejte samostatným přepínačem. Interval 1–60 minut se při vypnutí zachová. Zálohují aktivní uloženou hru; restart aplikace zahájí nový interval. Existující nastavení zůstane zachováno.

Ruční zálohy lze přejmenovat a nepočítají se do limitu automatických záloh. **Nejde však o trvalé uchování:** výslovné smazání nebo úklid po zmizení původní uložené hry může odstranit i je. Před smazáním či přesunutím originálu exportujte důležité zálohy do ZIP na jiný disk.

Smazání samotné zálohy ponechá aktuální hru, ale tuto zálohu už nelze obnovit ani exportovat. Smazání uložené hry v aplikaci odstraní také její zálohy. Místo se může uvolnit později; soubory se nemusí zmenšit okamžitě. Viz [nastavení (korejsky)](../configuration.md) a [pravidla úklidu (anglicky)](../repository-housekeeping.md).

<a id="game-saving"></a>
## Uložení hry před zálohou

Volitelné připojení požádá aktivní hru o uložení před kopírováním. Načte agenta JVM a zavolá `GameWindow.save(true)` v herním vlákně, bez modu Workshop a bez změny instalace hry. Jde o experimentální funkci pro ověřenou strukturu **Build 42 / Java 25 pro jednoho hráče**; hra více hráčů není podporována.

Ukládání a pětisekundový odpočet mají samostatné přepínače. **„Hra uložena“ neznamená „Záloha dokončena“:** následuje sběr a komprese souborů. Bez připojení nebo u neaktivní hry se zálohují pouze data již zapsaná na disk. Neúspěšný nebo nejistý požadavek není hlášen jako úspěch. Viz [připojení ke hře (anglicky)](../save-bridge.md).

<a id="restore-and-archives"></a>
## Obnovení a archivy ZIP

Před obnovením ukončete hraní vybrané uložené hry. Vyberte zálohu a zkontrolujte potvrzení: **aktuální soubory se nahradí a postup po vytvoření této zálohy se ztratí**. Při přerušení znovu otevřete PZ Tools a ověřte stav dříve, než hru načtete. Nepředpokládejte, že automatický návrat k původnímu stavu uspěl.

Aktuální uloženou hru nebo zálohu můžete exportovat do ZIP a před importem ZIP prohlédnout. Dlouhodobé archivy udržujte mimo složku záloh aplikace. Záloha na stejném disku nechrání před jeho poruchou. Odpovídající operace popisují [příkazy CLI (korejsky)](../cli.md).

<a id="character-recovery"></a>
## Obnova postavy

Nejprve vytvořte ruční zálohu nebo ZIP: **obnova postavy nevytváří další kopii původních souborů**. Mění jen aktuální neaktivní uloženou hru, nikdy starší zálohy. Podporuje **Build 42.20.4, formát světa 249 a jednoho místního hráče (ID 1)**.

Léčení nebo oživení obnoví zdraví a odstraní podporovaná zranění a dočasné stavy. Kladné i záporné vlastnosti, zkušenosti, dovednosti, recepty a stávající inventář zůstanou zachovány. Nejde o trvalou imunitu a neodstraňují se všechny účinky modů.

Pokud smrt vyprázdnila inventář, získá předměty ze zombie nebo mrtvoly postavy a tento zdroj odstraní. Průkaz totožnosti není nutný. Stav předmětů, obsah tašek a údaje o oblečení a připevnění zůstanou zachovány. Uložená ID obnoví předměty v rukou, jsou-li dostupná; jinak je nutné je znovu vybavit. Ztracené předměty nevytváří. Při nejisté totožnosti se nic nezmění. [obnova a omezení (anglicky)](../character-recovery.md)

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Ukládání a kompatibilita

Jádro ukládá změněná data, nikoli celou hru při každém zálohování. Využívá NTFS USN, je-li dostupný, jinak úplné prohledání s porovnáním obsahu. Kontrola kopií a komprese Brotli jsou standardně zapnuté; deduplikace je volitelná. Odpověď hry a kontrola jednotlivých souborů **nezaručují, že všechny soubory zachycují přesně stejný okamžik**.

Projekt je ve vývoji před vydáním. Nekompatibilní úložiště se odmítne s `repository-reset-required`, bez automatického převodu či smazání. Zvolte **novou prázdnou složku záloh** a starou si podle potřeby ponechte. **Kvůli obejití chyby nemažte `Zomboid/Saves` ani samotný `repository.db`.** Viz [formát úložiště (korejsky)](../repository-format.md) a [pokročilá nastavení (anglicky)](../runtime-configuration.md).

<a id="troubleshooting"></a>
## Řešení problémů

Pokud aplikace nejde spustit, ověřte runtime a úplnost balíčku. Je-li soubor používán nebo se stále mění, vyčkejte na dokončení ukládání hry před opakováním zálohy. Pokud automatické zálohy neběží, zkontrolujte interval, aktivní uloženou hru a zda PZ Tools stále běží; zavření do oznamovací oblasti není ukončení.

Po chybě nebo částečném dokončení si před opakováním přečtěte záznamy. Přerušené obnovení či editace postavy vyžadují kontrolu před načtením hry. Do [hlášení](https://github.com/isxcsm/pz-tools/issues) přidejte verzi či commit aplikace, verzi hry, postup a relevantní záznamy. Odstraňte osobní cesty a soukromá data; neposílejte celou uloženou hru bez potřeby.

<a id="building"></a>
## Sestavení ze zdrojů

Potřebujete Windows, .NET SDK z `global.json`, PowerShell 7, Windows x64 Java 25 JDK a nástroje C++/WinUI Visual Studia. Spusťte z kořene repozitáře a nahraďte ukázkovou cestu JDK:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

Publikační skript připraví aplikaci i pracovní procesy v **nové nebo prázdné složce**. Pro další publikaci použijte jiný výstup. [Vývoj a ověřování (anglicky)](../development.md) popisuje závislosti, testy distribuce, CLI a testy vyžadující výslovné povolení.

<a id="technical-documentation"></a>
## Dokumentace

[Rozcestník (anglicky/korejsky)](../README.md) uvádí všechny dokumenty a původní jazyky. [Lokalizace (anglicky)](../localization.md) vysvětluje rozsah překladů. [Ověřovací zprávy (korejsky)](../verification-report.md) jsou výsledky k určitému datu, nikoli zárukou pro všechny další commity nebo verze hry. Viz také [oznámení třetích stran (anglicky)](../../THIRD_PARTY_NOTICES.md).
