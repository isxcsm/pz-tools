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
  <a href="../it-IT/README.md">Italiano</a> ·
  <a href="../th-TH/README.md">ไทย</a> ·
  <a href="../id-ID/README.md">Bahasa Indonesia</a> ·
  <strong>Čeština</strong> ·
  <a href="../es-MX/README.md">Español (Latinoamérica)</a>
</p>

<p align="center">
  <img src="../../src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

# PZ Tools

**Vy se starejte o přežití. PZ Tools uchová místo, kam se vrátit.** Automatické zálohy, historie uložených her a obnova postavy v Project Zomboid.

## Funkce

- Rozpoznání aktivní uložené hry; ve výchozím nastavení záloha každých **5 minut** a uchování **20 automatických záloh**.
- Ruční zálohy lze přejmenovat; limit automatických záloh je nemaže.
- Volitelné `save(true)` přes agenta JVM před zálohováním a odpočet 5 sekund ve hře, bez modu z Workshopu.
- Náhledy, jméno postavy, doba přežití a označení úmrtí.
- Přírůstkové sledování USN, komprese a volitelná deduplikace; bez USN úplné prohledání s výchozím porovnáváním hashů.
- Kontrola, import a export ZIP, ukazatele průběhu a záznamy operací.
- Léčení a oživení mimo rozehranou hru; kladné i záporné vlastnosti, dovednosti a zkušenosti zůstávají zachovány.

## Začínáme

Potřebujete **Windows x64 a běhové prostředí .NET 10**. Spusťte `PzTools.App.exe` a zkontrolujte složky uložených her a záloh. Vytvořte ruční zálohu nebo používejte automatické při hraní. Interval `0` je vypne. Před obnovením zálohy nebo postavy ukončete hraní dané uložené hry.

## Omezení

Obnova postavy mění jen aktuální uloženou hru, nikoli starší zálohy. Podporuje **Build 42.20.4, formát světa 249 a jednoho místního hráče (ID 1)**. Předměty lze získat z jednoznačně odpovídajícího záznamu vlastního zombie podle uložené pozice a jména na průkazu totožnosti. Přemístění zombie, cíle bez průkazu a mrtvoly v mapových chunkech nejsou podporovány. Záporné vlastnosti se nemažou; odstranění všech účinků modů není zaručeno.

Ukládací můstek je experimentální funkce pro jednoho hráče v Build 42 / Java 25 a lze jej vypnout. Zpráva o dokončeném uložení ve hře neznamená hotovou zálohu ani záruku atomického snímku celého světa.

Ruční zálohy lze nadále výslovně smazat; po zmizení původní uložené hry je může odstranit také úklid osiřelých záloh. Důležité zálohy exportujte na jiné úložiště.

[Sestavení (anglicky)](../../README.md#building) · [Technická dokumentace (původní jazyky)](../../README.md#technical-documentation)

Neoficiální nástroj, nikoli produkt The Indie Stone.
