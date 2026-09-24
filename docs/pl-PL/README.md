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
  <strong>Polski</strong> ·
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

**Ty walczysz o przetrwanie. PZ Tools zachowuje punkt powrotu.** Automatyczne kopie, historia zapisów i przywracanie postaci w Project Zomboid.

## Funkcje

- Wykrywanie aktywnego zapisu; domyślnie kopia co **5 minut** i **20 zachowanych kopii automatycznych**.
- Zmiana nazw kopii ręcznych; limit kopii automatycznych ich nie usuwa.
- Opcjonalne `save(true)` przez agenta JVM przed kopiowaniem i odliczanie 5 sekund w grze, bez moda Workshop.
- Miniatury, imię postaci, czas przetrwania i oznaczenie śmierci.
- Przyrostowe śledzenie USN, kompresja i opcjonalna deduplikacja; bez USN pełne skanowanie z domyślnym porównywaniem skrótów.
- Sprawdzanie, import i eksport ZIP, postęp oraz dzienniki operacji.
- Leczenie i wskrzeszanie poza rozgrywką; pozytywne i negatywne cechy, umiejętności oraz doświadczenie pozostają.

## Pierwsze kroki

Wymagane są **Windows x64 i środowisko uruchomieniowe .NET 10**. Uruchom `PzTools.App.exe` i sprawdź katalogi zapisów oraz kopii. Wykonaj kopię ręczną lub graj z kopiami automatycznymi. Interwał `0` je wyłącza. Przed przywracaniem zapisu lub postaci zakończ grę w danym zapisie.

## Ograniczenia

Przywracanie postaci zmienia wyłącznie bieżący zapis, nie starsze kopie. Obsługuje **Build 42.20.4, format świata 249 i jednego gracza lokalnego (ID 1)**. Przedmioty można odzyskać z jednoznacznie dopasowanego rekordu własnego zombie na podstawie zapisanej pozycji i imienia w dokumencie tożsamości. Przemieszczone zombie, cele bez dokumentu i zwłoki w chunkach mapy nie są obsługiwane. Negatywne cechy nie są usuwane; efekty modów mogą pozostać.

Most zapisu to eksperymentalna, wyłączalna funkcja dla jednego gracza w Build 42 / Java 25. Komunikat o zapisaniu w grze nie oznacza zakończenia kopii ani gwarantowanej atomowej migawki świata.

Kopie ręczne nadal podlegają jawnemu usuwaniu i czyszczeniu osieroconych kopii po zniknięciu źródłowego zapisu. Ważne kopie eksportuj na inny nośnik.

[Budowanie (angielski)](../../README.md#building) · [Dokumentacja techniczna (języki oryginalne)](../../README.md#technical-documentation)

Narzędzie nieoficjalne, nie jest produktem The Indie Stone.
