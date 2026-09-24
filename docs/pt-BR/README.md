<p align="center">
  <a href="../ko-KR/README.md">한국어</a> ·
  <a href="../../README.md">English</a> ·
  <a href="../zh-CN/README.md">简体中文</a> ·
  <a href="../zh-TW/README.md">繁體中文</a> ·
  <a href="../ja-JP/README.md">日本語</a> ·
  <a href="../ru-RU/README.md">Русский</a> ·
  <strong>Português (Brasil)</strong> ·
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
  <a href="../es-MX/README.md">Español (Latinoamérica)</a>
</p>

<p align="center">
  <img src="../../src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

# PZ Tools

**Você cuida da sobrevivência. O PZ Tools guarda um caminho de volta.** Backups automáticos, histórico de saves e recuperação de personagem para Project Zomboid.

## Recursos

- Detecta o save em uso; por padrão, faz backup a cada **5 minutos** e mantém **20 backups automáticos**.
- Backups manuais podem ser renomeados e não entram na limpeza por limite de backups automáticos.
- Chamada opcional a `save(true)` por um agente JVM antes do backup, com contagem de 5 segundos no jogo, sem mod do Workshop.
- Miniaturas, nome, tempo de sobrevivência e indicação de morte para escolher um ponto de restauração.
- Captura incremental via USN, compressão e deduplicação opcional; sem USN, varredura completa com comparação de hashes por padrão.
- Inspeção, importação e exportação de ZIP, progresso e registros de operações.
- Cura e ressurreição fora da partida, preservando traços positivos e negativos, habilidades e experiência.

## Primeiros passos

Requer **Windows x64 e o runtime .NET 10**. Execute `PzTools.App.exe` e confira as pastas de saves e backups. Crie um backup manual ou jogue com os automáticos. O intervalo `0` desativa os backups automáticos. Saia daquele save antes de restaurá-lo ou recuperar o personagem.

## Limites

A recuperação atua somente no save atual e suporta **Build 42.20.4, formato de mundo 249 e um jogador local (ID 1)**. Não modifica backups antigos. Itens podem ser recuperados de um único registro compatível do próprio zumbi, pela posição salva e pelo nome no documento de identidade. Zumbis deslocados, alvos sem documento e cadáveres nos chunks do mapa não são suportados. Traços negativos são preservados; efeitos exclusivos de mods podem permanecer.

A ponte de salvamento é experimental, para um jogador em Build 42 / Java 25, e pode ser desativada. A mensagem de salvamento concluído no jogo não significa que o backup terminou nem garante uma captura atômica de todo o mundo.

Backups manuais ainda podem ser excluídos explicitamente ou pela limpeza de backups órfãos se o save original desaparecer. Exporte os importantes para outro dispositivo.

[Compilação (inglês)](../../README.md#building) · [Documentação técnica (idiomas originais)](../../README.md#technical-documentation)

Ferramenta não oficial, sem vínculo de produto com a The Indie Stone.
