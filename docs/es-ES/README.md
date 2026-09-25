<p>
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

# PZ Tools

PZ Tools es una aplicación no oficial para Windows que permite crear y restaurar copias de partidas de Project Zomboid. También ofrece recuperación del personaje para el formato compatible. No es un producto de The Indie Stone.

<a id="features"></a>
## Funciones

Copias manuales y programadas, historial con nombres editables, miniaturas y datos del personaje, importación/exportación ZIP y curación o resurrección fuera de una partida activa. La interfaz, los nombres predeterminados de las nuevas copias y los avisos de guardado admiten 18 idiomas. Incluye temas, modo de bandeja del sistema opcional, progreso y filtros de registros.

<a id="getting-started"></a>
## Instalación y ejecución

Necesitas **Windows x64** y **[.NET 10 Runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)** para Windows x64. Actualmente la aplicación solicita permisos de administrador para seguir cambios de archivos mediante USN. El paquete publicado incluye los componentes WinUI y un pequeño entorno Java para conectarse al juego, pero no los JAR del juego.

Consulta [Releases](https://github.com/isxcsm/pz-tools/releases) para obtener un paquete ejecutable. Si no hay ninguno publicado, sigue las instrucciones de compilación de abajo. El **ZIP «Source code» de GitHub no es una aplicación lista para ejecutar**.

1. Extrae el paquete **completo** en una carpeta y ejecuta `PzTools.App.exe`. No copies solo el EXE ni mezcles archivos de compilaciones diferentes.
2. Comprueba la carpeta de partidas en los ajustes y elige una carpeta de copias separada. No uses la carpeta de partidas como destino de las copias.
3. Selecciona una partida, crea una copia manual y comprueba que la aplicación confirme su finalización. Configura el intervalo y el número de copias automáticas.
4. Para actualizar, cierra PZ Tools y prepara todo el paquete nuevo en otra carpeta. Mantén partidas y copias separadas de los archivos de la aplicación.

Los ajustes y datos de gestión están en `%LOCALAPPDATA%\PzTools`; las copias, en la carpeta elegida. Consulta [las rutas de distribución y datos (coreano)](../deployment-layout.md).

<a id="backups-and-retention"></a>
## Conservación y eliminación

Los valores iniciales son **5 minutos** y **20 copias automáticas**. Usa el interruptor de copias automáticas para activarlas o desactivarlas. El intervalo de 1 a 60 minutos se conserva al desactivarlas. Se realizan sobre la partida activa; reiniciar la aplicación comienza un intervalo nuevo. Los ajustes existentes se conservan.

Las copias manuales se pueden renombrar y quedan fuera del límite de copias automáticas. **No se conservan indefinidamente:** una eliminación explícita o la limpieza tras desaparecer la partida original también puede borrarlas. Antes de eliminar o mover la partida original, exporta las copias importantes a ZIP en otra unidad.

Eliminar una copia no altera la partida actual, pero esa copia ya no podrá restaurarse ni exportarse. Eliminar una partida desde la aplicación también elimina sus copias. El espacio puede recuperarse más tarde; los archivos no siempre reducen su tamaño inmediatamente. Consulta [los ajustes (coreano)](../configuration.md) y [la política de limpieza (inglés)](../repository-housekeeping.md).

<a id="game-saving"></a>
## Guardado del juego antes de la copia

La conexión opcional pide al juego activo que guarde antes de copiar los archivos. Carga un agente JVM y llama a `GameWindow.save(true)` en el hilo del juego, sin necesitar un mod de Workshop ni modificar la instalación. Es experimental para la estructura examinada de **Build 42 / Java 25 en un jugador**; no admite multijugador.

El guardado y la cuenta atrás de cinco segundos tienen interruptores separados. **«Partida guardada» no significa «Copia completada»:** después se recopilan y comprimen los archivos. Sin conexión, o en una partida inactiva, solo se copian los datos ya escritos en disco. Una solicitud fallida o de resultado incierto no se anuncia como correcta. Consulta [la integración de guardado (inglés)](../save-bridge.md).

<a id="restore-and-archives"></a>
## Restauración y archivos ZIP

Sal de la partida seleccionada antes de restaurarla. Elige la copia y revisa la confirmación: **se reemplazan los archivos actuales y se pierde el progreso posterior a esa copia**. Si se interrumpe, vuelve a abrir PZ Tools y comprueba el estado antes de cargar la partida. No supongas que se ha recuperado automáticamente el estado anterior.

Puedes exportar la partida actual o una copia a ZIP e inspeccionar un ZIP antes de importarlo. Guarda los archivos de larga duración fuera de la carpeta de copias de la aplicación. Una copia en la misma unidad no protege frente a su avería. Los [comandos CLI (coreano)](../cli.md) permiten las operaciones equivalentes.

<a id="character-recovery"></a>
## Recuperación del personaje

Crea primero una copia manual o exporta un ZIP: **la recuperación no genera una copia adicional de los archivos originales**. Solo modifica la partida actual e inactiva, nunca las copias anteriores. Admite **Build 42.20.4, formato del mundo 249 y un jugador local (ID 1)**.

La curación o resurrección recupera la salud y elimina lesiones y estados temporales compatibles. Conserva rasgos positivos y negativos, experiencia, habilidades, recetas e inventario existente. No concede inmunidad permanente ni elimina todos los efectos propios de los mods.

Si el inventario del personaje muerto está vacío, solo se pueden recuperar objetos de un único registro guardado de su zombi, identificado por posición y nombre del documento de identidad. No se admiten zombis desplazados, objetivos sin documento ni cadáveres en bloques del mapa. Puede ser necesario volver a equipar las manos. Consulta [la recuperación y sus límites (inglés)](../character-recovery.md).

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Almacenamiento y compatibilidad

El motor guarda datos modificados en lugar de duplicar toda la partida cada vez. Usa NTFS USN si está disponible; de lo contrario, realiza un análisis completo con comparación del contenido. La verificación de copias y compresión Brotli están activadas por defecto; la deduplicación es opcional. La respuesta del juego y las comprobaciones individuales **no garantizan que todos los archivos correspondan exactamente al mismo instante**.

El proyecto está en desarrollo previo a su publicación. Los repositorios incompatibles se rechazan con `repository-reset-required`, sin conversión ni eliminación automática. Selecciona una **carpeta de copias nueva y vacía** y conserva la anterior si la necesitas. **No elimines `Zomboid/Saves` ni solo `repository.db` para evitar el error.** Consulta [el formato del repositorio (coreano)](../repository-format.md) y [la configuración avanzada (inglés)](../runtime-configuration.md).

<a id="troubleshooting"></a>
## Problemas e informes

Si la aplicación no inicia, comprueba el runtime y el paquete completo. Si un archivo está ocupado o cambia continuamente, deja terminar el guardado del juego antes de repetir la copia. Si no se ejecutan copias automáticas, revisa intervalo, partida activa y que PZ Tools siga ejecutándose; cerrar a la bandeja no es salir.

Ante un error o resultado parcial, lee los registros antes de repetir la operación. Una restauración o edición de personaje interrumpida requiere atención antes de cargar la partida. En un [informe](https://github.com/isxcsm/pz-tools/issues), incluye versión o commit de la aplicación, versión del juego, pasos y registros relevantes. Elimina rutas personales y datos privados; no adjuntes una partida completa sin necesidad.

<a id="building"></a>
## Compilar desde el código fuente

Necesitas Windows, el SDK .NET indicado en `global.json`, PowerShell 7, un JDK Java 25 Windows x64 y las herramientas C++/WinUI de Visual Studio. Ejecuta desde la raíz del repositorio y sustituye la ruta del JDK:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

El script prepara aplicación y procesos de trabajo juntos en una carpeta de salida **nueva o vacía**. Usa otra ruta para una nueva publicación. [Desarrollo y validación (inglés)](../development.md) explica dependencias, pruebas de distribución, CLI y pruebas que requieren activación explícita.

<a id="technical-documentation"></a>
## Documentación

El [índice (inglés/coreano)](../README.md) enumera todas las referencias y sus idiomas originales. [Localización (inglés)](../localization.md) describe la cobertura de traducción. Los [informes de verificación (coreano)](../verification-report.md) son resultados fechados, no una garantía para cada commit o versión posterior del juego. Consulta también los [avisos de terceros (inglés)](../../THIRD_PARTY_NOTICES.md).
