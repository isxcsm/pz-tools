<p align="center">
  <a href="../ko-KR/README.md">한국어</a> ·
  <a href="../../README.md">English</a> ·
  <a href="../zh-CN/README.md">简体中文</a> ·
  <a href="../zh-TW/README.md">繁體中文</a> ·
  <a href="../ja-JP/README.md">日本語</a> ·
  <a href="../ru-RU/README.md">Русский</a> ·
  <a href="../pt-BR/README.md">Português (Brasil)</a> ·
  <strong>Español (España)</strong> ·
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

**Tú te encargas de sobrevivir. PZ Tools conserva un punto al que volver.** Copias de seguridad, historial de partidas y recuperación de personajes para Project Zomboid.

## Funciones

- Detecta la partida en curso; por defecto, crea una copia cada **5 minutos** y conserva **20 copias automáticas**.
- Permite renombrar las copias manuales y las excluye del límite de conservación de las automáticas.
- Solicita opcionalmente `save(true)` mediante un agente JVM antes de copiar, con una cuenta atrás de 5 segundos en el juego y sin mods de Workshop.
- Muestra miniaturas, nombre, tiempo de supervivencia y estado del personaje.
- Copias incrementales con USN, compresión y deduplicación opcional; si USN no está disponible, análisis completo con comparación de hashes activada por defecto.
- Inspección, importación y exportación de ZIP, progreso y registros de operaciones.
- Curación y resurrección fuera de la partida, conservando rasgos positivos y negativos, habilidades y experiencia.

## Primeros pasos

Necesitas **Windows x64 y el entorno de ejecución .NET 10**. Ejecuta `PzTools.App.exe` y comprueba las carpetas de partidas y copias. Crea una copia manual o juega con las automáticas. El intervalo `0` las desactiva. Sal de esa partida antes de restaurarla o recuperar al personaje.

## Límites

La recuperación solo modifica la partida actual, no las copias históricas. Admite **Build 42.20.4, formato de mundo 249 y un jugador local (ID 1)**. Puede recuperar objetos de un único registro coincidente del propio zombi, según la posición guardada y el nombre del documento de identidad. No admite zombis desplazados, objetivos sin documento ni cadáveres en los chunks del mapa. No elimina rasgos negativos ni garantiza eliminar efectos específicos de mods.

El puente de guardado es experimental, para un jugador en Build 42 / Java 25, y se puede desactivar. El aviso de guardado completado en el juego no significa que la copia haya terminado ni garantiza una instantánea atómica del mundo.

Las copias manuales aún pueden borrarse explícitamente o al limpiar copias huérfanas si desaparece la partida original. Exporta las importantes a otro dispositivo.

[Compilación (inglés)](../../README.md#building) · [Documentación técnica (idiomas originales)](../../README.md#technical-documentation)

Herramienta no oficial; no es un producto de The Indie Stone.
