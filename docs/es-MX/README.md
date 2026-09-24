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
  <a href="../cs-CZ/README.md">Čeština</a> ·
  <strong>Español (Latinoamérica)</strong>
</p>

<p align="center">
  <img src="../../src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

# PZ Tools

**Tú te encargas de sobrevivir. PZ Tools guarda un punto al que volver.** Respaldos automáticos, historial de partidas y recuperación de personajes para Project Zomboid.

## Funciones

- Detecta la partida activa; de forma predeterminada, crea un respaldo cada **5 minutos** y conserva **20 respaldos automáticos**.
- Permite cambiar el nombre de los respaldos manuales y los excluye de la limpieza por límite de respaldos automáticos.
- Solicita opcionalmente `save(true)` mediante un agente JVM antes del respaldo, con una cuenta regresiva de 5 segundos en el juego, sin mods de Workshop.
- Muestra miniaturas, nombre, tiempo de supervivencia y estado del personaje.
- Respaldos incrementales con USN, compresión y deduplicación opcional; sin USN, realiza un análisis completo con comparación de hashes activada por defecto.
- Revisión, importación y exportación de ZIP, progreso y registros de operaciones.
- Curación y resurrección fuera de la partida, sin eliminar rasgos positivos o negativos, habilidades ni experiencia.

## Primeros pasos

Necesitas **Windows x64 y el entorno de ejecución .NET 10**. Ejecuta `PzTools.App.exe` y revisa las carpetas de partidas y respaldos. Crea un respaldo manual o juega con los automáticos. El intervalo `0` los desactiva. Sal de esa partida antes de restaurarla o recuperar al personaje.

## Límites

La recuperación solo modifica la partida actual, no los respaldos anteriores. Admite **Build 42.20.4, formato de mundo 249 y un jugador local (ID 1)**. Puede recuperar objetos de un único registro coincidente del propio zombi, según la posición guardada y el nombre de la identificación. No admite zombis que se hayan desplazado, objetivos sin identificación ni cadáveres en los chunks del mapa. No elimina rasgos negativos ni garantiza quitar todos los efectos de mods.

El puente de guardado es experimental, para un jugador en Build 42 / Java 25, y se puede desactivar. El aviso de guardado completado en el juego no significa que el respaldo haya terminado ni garantiza una captura atómica del mundo.

Los respaldos manuales aún pueden eliminarse por una acción explícita o por la limpieza de respaldos huérfanos si desaparece la partida original. Exporta los importantes a otro dispositivo.

[Compilación (inglés)](../../README.md#building) · [Documentación técnica (idiomas originales)](../../README.md#technical-documentation)

Herramienta no oficial; no es un producto de The Indie Stone.
