<p>
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

# PZ Tools

PZ Tools é um aplicativo Windows não oficial para fazer backup e restaurar saves do Project Zomboid. Também oferece recuperação de personagem para o formato compatível. Não é um produto da The Indie Stone.

<a id="features"></a>
## Recursos

Backups manuais e agendados, histórico com nomes editáveis, miniaturas e dados do personagem, importação/exportação ZIP e cura ou ressurreição fora de uma partida em andamento. Interface, nomes padrão de novos backups e avisos de salvamento têm suporte a 18 idiomas. Inclui temas, modo opcional na bandeja do sistema, progresso e filtros de logs.

<a id="getting-started"></a>
## Instalação e execução

É necessário **Windows x64** e **[.NET 10 Runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)** para Windows x64. O aplicativo atualmente solicita permissão de administrador para rastrear alterações de arquivos via USN. O pacote publicado inclui componentes WinUI e um pequeno runtime Java para conexão ao jogo, mas não os JARs do jogo.

Consulte [Releases](https://github.com/isxcsm/pz-tools/releases) para obter um pacote executável. Se não houver um publicado, siga a compilação abaixo. O **ZIP “Source code” do GitHub não é um aplicativo pronto para executar**.

1. Extraia o pacote **inteiro** em uma pasta e execute `PzTools.App.exe`. Não copie apenas o EXE nem misture arquivos de compilações diferentes.
2. Confira a pasta dos saves nas configurações e escolha uma pasta de backup separada. Não use a pasta dos saves como destino de backup.
3. Selecione um save, faça um backup manual e confira a conclusão no aplicativo. Configure o intervalo e a quantidade de backups automáticos.
4. Para atualizar, feche o PZ Tools e coloque o novo pacote completo em outra pasta. Mantenha saves e backups separados dos arquivos do aplicativo.

Configurações e dados de controle ficam em `%LOCALAPPDATA%\PzTools`; os backups, na pasta escolhida. Veja [locais de instalação e dados (coreano)](../deployment-layout.md).

<a id="backups-and-retention"></a>
## Retenção e exclusão

Os valores iniciais são **5 minutos** e **20 backups automáticos**. Use o botão de backups automáticos para ativá-los ou desativá-los. O intervalo de 1 a 60 minutos é preservado ao desativar. Eles acompanham o save em uso; reiniciar o aplicativo inicia um novo intervalo. Configurações existentes são mantidas.

Backups manuais podem ser renomeados e ficam fora do limite de backups automáticos. **Isso não significa retenção permanente:** exclusão explícita ou limpeza após o desaparecimento do save original também pode removê-los. Antes de excluir ou mover o original, exporte backups importantes para ZIP em outra unidade.

Excluir apenas um backup mantém o save atual, mas impede restaurar ou exportar esse backup. Excluir um save pelo aplicativo também remove os backups dele. A recuperação de espaço pode ocorrer depois; os arquivos nem sempre diminuem imediatamente. Veja [configurações (coreano)](../configuration.md) e [política de limpeza (inglês)](../repository-housekeeping.md).

<a id="game-saving"></a>
## Salvar o jogo antes do backup

A conexão opcional pede ao jogo ativo para salvar antes da cópia. Ela carrega um agente JVM e chama `GameWindow.save(true)` na thread do jogo, sem mod do Workshop nem alteração dos arquivos de instalação. É experimental para a estrutura examinada de **Build 42 / Java 25 em um jogador**; multijogador não é compatível.

O salvamento e a contagem regressiva de cinco segundos têm opções separadas. **“Jogo salvo” não significa “Backup concluído”:** a coleta e a compactação dos arquivos acontecem depois. Sem a conexão, ou para um save inativo, só são copiados os dados já gravados em disco. Pedidos malsucedidos ou de resultado incerto não são anunciados como sucesso. Veja [integração com o salvamento (inglês)](../save-bridge.md).

<a id="restore-and-archives"></a>
## Restauração e arquivos ZIP

Saia da partida selecionada antes de restaurar. Escolha o backup e confira a confirmação: **a restauração substitui os arquivos atuais, perdendo o progresso posterior àquele backup**. Se houver interrupção, reabra o PZ Tools e confira o estado antes de carregar o save no jogo. Não presuma que o estado anterior foi restaurado automaticamente.

Exporte o save atual ou um backup para ZIP e inspecione o ZIP antes de importá-lo. Guarde arquivos destinados à retenção prolongada fora da pasta de backup do aplicativo. Um backup na mesma unidade não protege contra falha dessa unidade. Os [comandos CLI (coreano)](../cli.md) oferecem operações equivalentes.

<a id="character-recovery"></a>
## Recuperação de personagem

Faça primeiro um backup manual ou exporte um ZIP: **a recuperação não cria uma cópia adicional dos arquivos originais**. Só modifica o save atual e inativo, nunca os backups anteriores. O suporte é para **Build 42.20.4, formato de mundo 249 e um jogador local (ID 1)**.

Cura ou ressurreição restaura a saúde e elimina ferimentos e estados temporários compatíveis. Traços positivos e negativos, experiência, habilidades, receitas e inventário existente são preservados. Não há imunidade permanente nem remoção de todos os efeitos específicos de mods.

Se o inventário do personagem morto estiver vazio, os itens só podem vir de um registro único do próprio zumbi, identificado pela posição salva e pelo nome na identidade. Zumbis deslocados, alvos sem identidade e cadáveres em blocos do mapa não são compatíveis. Pode ser necessário reequipar as mãos. Veja [recuperação e limites (inglês)](../character-recovery.md).

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Armazenamento e compatibilidade

O mecanismo armazena dados alterados em vez de copiar todo o save a cada vez. Usa NTFS USN quando disponível; caso contrário, faz uma varredura completa com comparação do conteúdo. Verificação de cópias e compactação Brotli são ativadas por padrão; deduplicação é opcional. A resposta do jogo e as verificações por arquivo **não garantem que todos os arquivos representem exatamente o mesmo instante**.

O projeto está em desenvolvimento antes da publicação. Repositórios incompatíveis são recusados com `repository-reset-required`, sem conversão ou exclusão automática. Escolha uma **nova pasta de backup vazia** e guarde a antiga se precisar dos dados. **Não exclua `Zomboid/Saves` nem apenas `repository.db` para contornar o erro.** Veja [formato do repositório (coreano)](../repository-format.md) e [configuração avançada (inglês)](../runtime-configuration.md).

<a id="troubleshooting"></a>
## Solução de problemas e relatos

Se o aplicativo não abrir, confira o runtime e o pacote completo. Se um arquivo estiver em uso ou mudando continuamente, aguarde o jogo terminar de salvar antes de repetir o backup. Se os backups automáticos não ocorrerem, confira intervalo, save ativo e se o PZ Tools ainda está aberto; fechar para a bandeja não é encerrar.

Após falha ou conclusão parcial, leia os logs antes de repetir a operação. Restauração ou edição de personagem interrompida precisa ser verificada antes de carregar o save. Ao abrir uma [issue](https://github.com/isxcsm/pz-tools/issues), informe versão ou commit do aplicativo, versão do jogo, passos e logs relevantes. Remova caminhos pessoais e dados privados; não envie um save inteiro sem necessidade.

<a id="building"></a>
## Compilar o código-fonte

Use Windows, o SDK .NET indicado em `global.json`, PowerShell 7, um JDK Java 25 Windows x64 e as ferramentas C++/WinUI do Visual Studio. Execute na raiz do repositório e substitua o caminho do JDK:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

O script prepara o aplicativo e os processos de trabalho juntos em uma pasta de saída **nova ou vazia**. Escolha outro caminho para publicar novamente. [Desenvolvimento e validação (inglês)](../development.md) explica dependências, testes de distribuição, CLI e testes que exigem ativação explícita.

<a id="technical-documentation"></a>
## Documentação

O [índice (inglês/coreano)](../README.md) lista todas as referências e seus idiomas originais. [Localização (inglês)](../localization.md) descreve a cobertura de tradução. Os [relatórios de verificação (coreano)](../verification-report.md) são resultados datados, não uma garantia para cada commit ou versão posterior do jogo. Veja também [avisos de terceiros (inglês)](../../THIRD_PARTY_NOTICES.md).
