<p>
  <a href="../ko-KR/README.md">한국어</a> ·
  <a href="../../README.md">English</a> ·
  <a href="../zh-CN/README.md">简体中文</a> ·
  <a href="../zh-TW/README.md">繁體中文</a> ·
  <a href="../ja-JP/README.md">日本語</a> ·
  <a href="../ru-RU/README.md">Русский</a> ·
  <a href="../pt-BR/README.md">Português (Brasil)</a> ·
  <a href="../es-ES/README.md">Español (España)</a> ·
  <strong>Français</strong> ·
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

PZ Tools est une application Windows non officielle pour sauvegarder et restaurer les parties de Project Zomboid. Elle propose aussi la récupération du personnage pour le format pris en charge. Ce n'est pas un produit de The Indie Stone.

<a id="features"></a>
## Fonctionnalités

Copies manuelles et planifiées, historique renommable avec miniatures et informations sur le personnage, importation/exportation ZIP, soins et résurrection hors partie. L'interface, les noms par défaut des nouvelles copies et les notifications de sauvegarde en jeu sont disponibles en 18 langues. Des thèmes, un mode zone de notification, des indicateurs de progression et des filtres de journal sont inclus.

<a id="getting-started"></a>
## Installation et lancement

Il faut **Windows x64** et **[.NET 10 Runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)** pour Windows x64. L'application demande actuellement les droits administrateur pour suivre les changements de fichiers via USN. Le paquet publié contient les composants WinUI et un petit environnement Java pour la connexion au jeu, mais pas les fichiers JAR du jeu.

Consultez [Releases](https://github.com/isxcsm/pz-tools/releases) pour obtenir un paquet exécutable. À défaut, utilisez les instructions de compilation ci-dessous. Le **ZIP « Source code » de GitHub n'est pas une application prête à lancer**.

1. Extrayez le paquet **en entier** dans un dossier, puis lancez `PzTools.App.exe`. Ne déplacez pas seulement l'EXE et ne mélangez pas des fichiers de compilations différentes.
2. Vérifiez le dossier des parties dans les paramètres et choisissez un dossier distinct pour les copies. N'utilisez pas le dossier des parties comme destination des copies.
3. Sélectionnez une partie, créez une copie manuelle et vérifiez sa réussite dans l'application. Réglez l'intervalle et le nombre de copies automatiques à conserver.
4. Pour mettre à jour, fermez PZ Tools et préparez le nouveau paquet complet dans un autre dossier. Conservez les parties et les copies séparément des fichiers de l'application.

Les paramètres et données de gestion sont dans `%LOCALAPPDATA%\PzTools`, les copies dans le dossier choisi. Voir [les emplacements de déploiement (coréen)](../deployment-layout.md).

<a id="backups-and-retention"></a>
## Conservation et suppression

Les valeurs initiales sont **5 minutes** et **20 copies automatiques**. L'intervalle `0` désactive les copies automatiques. Elles concernent la partie active ; le redémarrage de l'application commence un nouvel intervalle. Les paramètres existants sont conservés.

Les copies manuelles sont renommables et exclues de la limite des copies automatiques. **Elles ne sont pas conservées indéfiniment :** une suppression explicite ou le nettoyage après disparition de la partie d'origine peut aussi les supprimer. Avant de déplacer ou supprimer cette partie, exportez les copies importantes en ZIP sur un autre lecteur.

Supprimer une copie laisse la partie actuelle intacte, mais empêche de restaurer ou d'exporter cette copie. Supprimer une partie dans l'application supprime aussi ses copies. L'espace peut être récupéré ultérieurement ; la taille des fichiers ne diminue pas toujours immédiatement. Voir [les paramètres (coréen)](../configuration.md) et [la politique de nettoyage (anglais)](../repository-housekeeping.md).

<a id="game-saving"></a>
## Enregistrement du jeu avant la copie

La connexion facultative demande au jeu actif d'enregistrer avant de copier les fichiers. Elle charge un agent JVM et appelle `GameWindow.save(true)` sur le thread du jeu, sans mod Workshop ni modification de l'installation. Cette fonction expérimentale vise la structure inspectée de **Build 42 / Java 25 en solo** ; le multijoueur n'est pas pris en charge.

L'enregistrement et le compte à rebours de cinq secondes ont des interrupteurs distincts. **« Partie enregistrée » ne signifie pas que la copie de sécurité est terminée :** collecte et compression suivent. Sans connexion, ou pour une partie inactive, seules les données déjà écrites sur disque sont copiées. Une demande échouée ou incertaine n'est pas annoncée comme réussie. Voir [l'intégration au jeu (anglais)](../save-bridge.md).

<a id="restore-and-archives"></a>
## Restauration et archives ZIP

Quittez la partie concernée avant de la restaurer. Choisissez la copie et vérifiez la confirmation : **la restauration remplace les fichiers actuels et efface la progression postérieure à cette copie**. En cas d'interruption, rouvrez PZ Tools et vérifiez l'état avant de charger la partie. Ne présumez pas qu'un retour automatique à l'état précédent a réussi.

Exportez une partie actuelle ou une copie en ZIP et inspectez un ZIP avant de l'importer. Gardez les archives destinées à une conservation durable hors du dossier de copies de l'application. Une copie sur le même lecteur ne protège pas contre sa panne. Les [commandes d'archives (coréen)](../cli.md) permettent les mêmes opérations en ligne de commande.

<a id="character-recovery"></a>
## Récupération du personnage

Créez d'abord une copie manuelle ou un ZIP : **la récupération ne crée pas de copie supplémentaire des fichiers d'origine**. Elle ne modifie que la partie actuelle et inactive, jamais les anciennes copies. Elle prend en charge **Build 42.20.4, le format de monde 249 et un seul joueur local (ID 1)**.

Les soins ou la résurrection restaurent la santé et effacent les blessures et états temporaires pris en charge. Les traits positifs et négatifs, l'expérience, les compétences, les recettes et l'inventaire existant sont conservés. Ce n'est pas une immunité permanente et tous les effets propres aux mods ne sont pas supprimés.

Si l'inventaire du personnage mort est vide, les objets ne peuvent venir que d'un enregistrement unique de son zombie, correspondant à la position enregistrée et au nom sur la pièce d'identité. Les zombies déplacés, les cibles sans pièce d'identité et les cadavres dans les blocs de carte ne sont pas pris en charge. Il peut être nécessaire de rééquiper les mains. Voir [la récupération et ses limites (anglais)](../character-recovery.md).

<a id="backup-engine"></a>
<a id="compatibility-and-limits"></a>
## Stockage et compatibilité

Le moteur stocke les données modifiées plutôt qu'une copie complète à chaque fois. Il utilise le suivi NTFS USN quand il est disponible, sinon une analyse complète avec comparaison du contenu. Vérification des copies et compression Brotli sont activées par défaut ; la déduplication est facultative. La réponse du jeu et les vérifications par fichier **ne garantissent pas que tous les fichiers décrivent exactement le même instant**.

Le logiciel est encore en développement avant publication. Un dépôt incompatible est refusé avec `repository-reset-required`, sans conversion ni suppression automatique. Choisissez un **nouveau dossier de copies vide** et conservez l'ancien si nécessaire. **Ne supprimez ni `Zomboid/Saves` ni seulement `repository.db` pour contourner cette erreur.** Consultez [le format du dépôt (coréen)](../repository-format.md) et [les réglages avancés (anglais)](../runtime-configuration.md).

<a id="troubleshooting"></a>
## Dépannage et signalement

Si l'application ne démarre pas, vérifiez le runtime et l'intégralité du paquet. Si un fichier est utilisé ou change continuellement, laissez le jeu terminer l'enregistrement avant de réessayer. Si les copies automatiques ne démarrent pas, vérifiez l'intervalle, la partie active et que PZ Tools fonctionne toujours : réduire dans la zone de notification n'est pas quitter.

Après un échec ou une réussite partielle, consultez le journal avant de répéter l'opération. Une restauration ou une modification de personnage interrompue doit être examinée avant de recharger la partie. Dans un [signalement](https://github.com/isxcsm/pz-tools/issues), indiquez la version ou le commit de l'application, la version du jeu, les étapes et le journal pertinent. Retirez les chemins personnels et données privées ; ne joignez pas une partie complète sans nécessité.

<a id="building"></a>
## Compilation

Utilisez Windows, le SDK .NET indiqué par `global.json`, PowerShell 7, un JDK Java 25 Windows x64 et les outils C++/WinUI de Visual Studio. Depuis la racine du dépôt, remplacez le chemin du JDK dans l'exemple :

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

Le script publie l'application et ses processus de travail dans un dossier **nouveau ou vide**. Choisissez un autre chemin pour une nouvelle publication. Le [guide de développement et de validation (anglais)](../development.md) détaille les dépendances, les tests de distribution, la CLI et les tests à activer explicitement.

<a id="technical-documentation"></a>
## Documentation

L'[index documentaire (anglais/coréen)](../README.md) indique tous les documents et leurs langues. La [localisation (anglais)](../localization.md) décrit la couverture des traductions. Les [rapports de validation (coréen)](../verification-report.md) concernent une date précise, pas tous les commits ou versions du jeu à venir. Consultez aussi les [mentions des composants tiers (anglais)](../../THIRD_PARTY_NOTICES.md).
