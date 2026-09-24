<p align="center">
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

<p align="center">
  <img src="../../src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

# PZ Tools

**À vous de survivre. À PZ Tools de garder un point de retour.** Copies automatiques, historique des parties et récupération de personnage pour Project Zomboid.

## Fonctionnalités

- Détection de la partie active ; par défaut, une copie toutes les **5 minutes**, avec **20 copies automatiques** conservées.
- Copies manuelles renommables, exclues de la limite de conservation des copies automatiques.
- Appel facultatif à `save(true)` via un agent JVM avant la copie, avec compte à rebours de 5 secondes en jeu, sans mod Workshop.
- Miniatures, nom, durée de survie et état du personnage.
- Suivi incrémental USN, compression et déduplication facultative ; sans USN, analyse complète avec comparaison des empreintes activée par défaut.
- Inspection, importation et exportation ZIP, progression et journaux.
- Soins et résurrection hors partie, sans supprimer les traits positifs ou négatifs, les compétences ni l'expérience.

## Premiers pas

Il faut **Windows x64 et l'environnement d'exécution .NET 10**. Lancez `PzTools.App.exe` et vérifiez les dossiers des parties et des copies. Créez une copie manuelle ou jouez avec les copies automatiques. L'intervalle `0` les désactive. Quittez la partie concernée avant toute restauration ou récupération du personnage.

## Limites

La récupération ne modifie que la sauvegarde actuelle, jamais les anciennes copies. Elle prend en charge **Build 42.20.4, le format de monde 249 et un seul joueur local (ID 1)**. Les objets peuvent être récupérés depuis un unique enregistrement correspondant de votre zombie, selon la position enregistrée et le nom sur la pièce d'identité. Les zombies déplacés, les cibles sans pièce d'identité et les cadavres dans les chunks ne sont pas pris en charge. Les traits négatifs restent ; les effets propres aux mods ne sont pas tous traités.

Le pont de sauvegarde est expérimental, pour le mode solo Build 42 / Java 25, et peut être désactivé. Le message de sauvegarde terminée en jeu n'indique pas la fin de la copie et ne garantit pas un instantané atomique du monde.

Une copie manuelle peut toujours être supprimée explicitement ou par le nettoyage des copies orphelines si la partie d'origine disparaît. Exportez les copies importantes sur un autre support.

[Compilation (anglais)](../../README.md#building) · [Documentation technique (langues d'origine)](../../README.md#technical-documentation)

Outil non officiel, qui n'est pas un produit de The Indie Stone.
