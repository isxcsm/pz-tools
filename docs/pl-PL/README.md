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
  <strong>Polski</strong> ·
  <a href="../tr-TR/README.md">Türkçe</a> ·
  <a href="../uk-UA/README.md">Українська</a> ·
  <a href="../it-IT/README.md">Italiano</a> ·
  <a href="../th-TH/README.md">ไทย</a> ·
  <a href="../id-ID/README.md">Bahasa Indonesia</a> ·
  <a href="../cs-CZ/README.md">Čeština</a> ·
  <a href="../es-MX/README.md">Español (Latinoamérica)</a>
</p>

# PZ Tools

PZ Tools to nieoficjalna aplikacja Windows do tworzenia kopii i przywracania zapisów gry Project Zomboid. Umożliwia też odzyskiwanie postaci w obsługiwanym formacie zapisu. Nie jest produktem The Indie Stone.

<a id="features"></a>
## Funkcje

Kopie ręczne i zaplanowane, historia ze zmiennymi nazwami, miniaturami i danymi postaci, import/eksport ZIP oraz leczenie i wskrzeszanie poza aktywną grą. Interfejs, domyślne nazwy nowych kopii i powiadomienia o zapisie obsługują 18 języków. Dostępne są motywy, opcjonalny tryb zasobnika systemowego, postęp operacji i filtry dziennika.

<a id="getting-started"></a>
## Instalacja i uruchamianie

Wymagane są **Windows x64** oraz **[środowisko uruchomieniowe .NET 10](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)** dla Windows x64. Aplikacja obecnie prosi o uprawnienia administratora do śledzenia zmian plików przez USN. Opublikowany pakiet zawiera komponenty WinUI i małe środowisko Java do połączenia z grą, ale nie pliki JAR gry.

Gotowych pakietów szukaj w [Releases](https://github.com/isxcsm/pz-tools/releases). Jeśli żadnego nie opublikowano, skorzystaj z instrukcji kompilacji poniżej. **ZIP „Source code” z GitHub nie jest gotową aplikacją**.

1. Rozpakuj **cały** pakiet do jednego folderu i uruchom `PzTools.App.exe`. Nie kopiuj samego EXE ani nie mieszaj plików różnych kompilacji.
2. Sprawdź folder zapisów w ustawieniach i wybierz osobny folder kopii. Nie używaj folderu zapisów gry jako miejsca na kopie.
3. Wybierz zapis, utwórz ręczną kopię i sprawdź potwierdzenie ukończenia. Ustaw interwał i liczbę automatycznych kopii.
4. Przed aktualizacją zamknij PZ Tools i przygotuj cały nowy pakiet w innym folderze. Zapisy i kopie przechowuj osobno od plików aplikacji.

Ustawienia i dane zarządzania znajdują się w `%LOCALAPPDATA%\PzTools`, a kopie w wybranym folderze. Zobacz [rozmieszczenie plików (koreański)](../deployment-layout.md).

<a id="backups-and-retention"></a>
## Przechowywanie i usuwanie

Początkowe wartości to **5 minut** i **20 automatycznych kopii**. Interwał `0` wyłącza automatyczne kopie. Dotyczą one aktywnego zapisu; ponowne uruchomienie aplikacji rozpoczyna nowy interwał. Istniejące ustawienia pozostają zachowane.

Ręczne kopie można przemianować i nie wliczają się one do limitu automatycznych kopii. **Nie są jednak przechowywane bezterminowo:** jawne usunięcie lub czyszczenie po zniknięciu oryginalnego zapisu może je usunąć. Przed usunięciem lub przeniesieniem oryginału wyeksportuj ważne kopie do ZIP na inny dysk.

Usunięcie samej kopii pozostawia bieżący zapis, ale uniemożliwia przywrócenie i eksport tej kopii. Usunięcie zapisu przez aplikację usuwa też jego kopie. Odzyskanie miejsca może nastąpić później; pliki nie zawsze maleją od razu. Zobacz [ustawienia (koreański)](../configuration.md) i [zasady czyszczenia (angielski)](../repository-housekeeping.md).

<a id="game-saving"></a>
## Zapis gry przed kopią

Opcjonalne połączenie prosi aktywną grę o zapis przed kopiowaniem plików. Ładuje agenta JVM i wywołuje `GameWindow.save(true)` w wątku gry, bez moda Workshop i zmian w instalacji gry. Jest eksperymentalne dla sprawdzonej struktury **Build 42 / Java 25 w trybie jednoosobowym**; tryb wieloosobowy nie jest obsługiwany.

Zapis i pięciosekundowe odliczanie mają osobne przełączniki. **„Gra zapisana” nie oznacza „Kopia ukończona”:** potem następuje odczyt i kompresja plików. Bez połączenia lub dla nieaktywnego zapisu kopiowane są tylko dane już zapisane na dysku. Nieudane lub niejednoznaczne żądanie nie jest uznawane za sukces. Zobacz [integrację z grą (angielski)](../save-bridge.md).

<a id="restore-and-archives"></a>
## Przywracanie i archiwa ZIP

Zakończ grę w wybranym zapisie przed przywróceniem. Wybierz kopię i sprawdź potwierdzenie: **bieżące pliki zostaną zastąpione, a postęp po utworzeniu tej kopii przepadnie**. Po przerwaniu przywracania otwórz ponownie PZ Tools i sprawdź stan przed wczytaniem zapisu. Nie zakładaj, że automatyczny powrót do poprzedniego stanu się powiódł.

Możesz eksportować bieżący zapis lub kopię do ZIP oraz sprawdzić ZIP przed importem. Archiwa długoterminowe trzymaj poza folderem kopii aplikacji. Kopia na tym samym dysku nie chroni przed awarią dysku. Odpowiedniki operacji opisują [polecenia CLI (koreański)](../cli.md).

<a id="character-recovery"></a>
## Odzyskiwanie postaci

Najpierw utwórz ręczną kopię lub ZIP: **odzyskiwanie postaci nie tworzy dodatkowej kopii oryginalnych plików**. Zmienia tylko bieżący, nieaktywny zapis, nigdy wcześniejsze kopie. Obsługuje **Build 42.20.4, format świata 249 i jednego lokalnego gracza (ID 1)**.

Leczenie lub wskrzeszenie przywraca zdrowie i usuwa obsługiwane obrażenia oraz stany tymczasowe. Zachowuje pozytywne i negatywne cechy, doświadczenie, umiejętności, przepisy i istniejący ekwipunek. Nie zapewnia stałej odporności i nie usuwa wszystkich efektów modów.

Jeśli ekwipunek zmarłej postaci jest pusty, przedmioty można odzyskać tylko z jednego pasującego zapisu jej zombie, na podstawie zapisanej pozycji i nazwiska na dowodzie tożsamości. Przemieszczone zombie, cele bez dowodu i zwłoki w blokach mapy nie są obsługiwane. Przedmioty trzymane w dłoniach mogą wymagać ponownego wyposażenia. Zobacz [odzyskiwanie i ograniczenia (angielski)](../character-recovery.md).

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Przechowywanie i zgodność

Silnik zapisuje zmienione dane zamiast za każdym razem kopiować cały zapis. Używa NTFS USN, gdy jest dostępny, a w przeciwnym razie pełnego skanowania i porównania zawartości. Weryfikacja kopii i kompresja Brotli są domyślnie włączone; deduplikacja jest opcjonalna. Odpowiedź gry i kontrole pojedynczych plików **nie gwarantują, że wszystkie pliki przedstawiają dokładnie tę samą chwilę**.

Projekt jest w fazie rozwoju przed wydaniem. Niezgodne repozytorium jest odrzucane z `repository-reset-required`, bez automatycznej konwersji i usuwania. Wybierz **nowy pusty folder kopii** i zachowaj stary, jeśli jest potrzebny. **Nie usuwaj `Zomboid/Saves` ani samego `repository.db`, aby obejść błąd.** Zobacz [format repozytorium (koreański)](../repository-format.md) oraz [ustawienia zaawansowane (angielski)](../runtime-configuration.md).

<a id="troubleshooting"></a>
## Rozwiązywanie problemów

Gdy aplikacja nie startuje, sprawdź środowisko uruchomieniowe i kompletność pakietu. Jeśli plik jest używany lub ciągle się zmienia, poczekaj na koniec zapisu gry przed ponowną kopią. Jeśli automatyczne kopie nie działają, sprawdź interwał, aktywny zapis i czy PZ Tools nadal działa; zamknięcie do zasobnika nie kończy aplikacji.

Po błędzie lub częściowym wykonaniu przeczytaj dziennik przed powtórzeniem operacji. Przerwane przywracanie lub edycja postaci wymagają sprawdzenia przed wczytaniem gry. W [zgłoszeniu](https://github.com/isxcsm/pz-tools/issues) podaj wersję lub commit aplikacji, wersję gry, kroki i istotne wpisy dziennika. Usuń osobiste ścieżki i prywatne dane; nie przesyłaj całego zapisu bez potrzeby.

<a id="building"></a>
## Kompilacja ze źródeł

Potrzebne są Windows, .NET SDK wskazane w `global.json`, PowerShell 7, Windows x64 Java 25 JDK oraz narzędzia C++/WinUI Visual Studio. Uruchom z katalogu głównego repozytorium, zastępując przykładową ścieżkę JDK:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

Skrypt publikuje aplikację i procesy robocze razem w **nowym lub pustym folderze**. Dla kolejnej publikacji wybierz inną ścieżkę. [Rozwój i weryfikacja (angielski)](../development.md) opisuje zależności, testy dystrybucji, CLI i testy wymagające jawnego włączenia.

<a id="technical-documentation"></a>
## Dokumentacja

[Spis dokumentów (angielski/koreański)](../README.md) zawiera wszystkie odnośniki i języki oryginałów. [Lokalizacja (angielski)](../localization.md) opisuje zakres tłumaczeń. [Raporty weryfikacji (koreański)](../verification-report.md) dotyczą określonej daty, nie wszystkich późniejszych commitów lub wersji gry. Zobacz też [informacje o komponentach zewnętrznych (angielski)](../../THIRD_PARTY_NOTICES.md).
