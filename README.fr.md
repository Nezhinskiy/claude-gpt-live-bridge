<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.hi.md">हिन्दी</a> · <a href="README.es.md">Español</a> · <b>Français</b> · <a href="README.ru.md">Русский</a> · <a href="README.uk.md">Українська</a></p>

<p align="center"><img src="site/assets/icon.png" alt="Icône de l'application LiveBridge" width="144"></p>

<h1 align="center">LiveBridge</h1>

<p align="center"><strong>Parlez à voix haute à une session Claude Code ouverte.</strong></p>

<p align="center">
  <a href="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml"><img src="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="Licence : MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B%20%C2%B7%20Apple%20Silicon-lightgrey.svg" alt="Plateforme : macOS 14+ sur Apple Silicon">
</p>

<p align="center">
  <a href="https://getlivebridge.com">getlivebridge.com</a> ·
  <a href="#démarrage-rapide">Démarrage rapide</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#utilisation">Utilisation</a> ·
  <a href="#facturation-maîtrisée-par-conception">Facturation</a> ·
  <a href="#confidentialité">Confidentialité</a> ·
  <a href="#limitations-connues">Limitations</a> ·
  <a href="#feuille-de-route-et-aide-recherchée">Aide recherchée</a> ·
  <a href="#contribuer">Contribuer</a>
</p>

LiveBridge est une application de barre des menus macOS qui garde une ligne vocale GPT-Live
prête à l'emploi via `codex app-server`, avec votre connexion ChatGPT (sans clé d'API). La voix
fait office d'accueil : elle discute, demande ce que vous voulez dire, et confie le vrai travail
à votre session Claude Code par l'intermédiaire d'un petit mod Claude Code, `livebridge`. Claude
fait le travail avec son propre modèle, ses propres outils et son propre mode de permissions, et
la voix vous annonce le résultat.

*Le texte anglais fait foi ([README.md](README.md)) ; cette traduction peut avoir du retard.*

<p align="center"><img src="site/assets/demo.gif" alt="Conversation avec une session Claude Code via LiveBridge" width="100%"></p>

**Local par conception.** Pas de télémétrie et pas de serveur propre : LiveBridge est un pont sur
votre Mac entre votre propre codex et votre propre Claude Code. L'application et le mod
communiquent uniquement par un socket Unix que seul votre utilisateur peut ouvrir, et
l'application n'écoute sur aucun port réseau. En dehors de ce que ces deux outils envoient déjà
(la ligne vocale vers OpenAI via votre codex, uniquement tant qu'elle est ouverte, et le travail
de Claude vers Anthropic via votre session Claude Code), le seul trafic propre à l'application
sert aux [mises à jour](#mises-à-jour) : une demande automatique à GitHub pour savoir s'il existe
une nouvelle version (quotidienne, et à chaque lancement tant qu'une version qu'elle a annoncée
n'est pas installée), que vous pouvez désactiver ; la même demande quand vous cliquez sur **Check
for update** ; `gh auth status` quand une nouvelle version est annoncée ; et, quand vous cliquez
sur **Install**, le téléchargement, sa vérification et la mise à jour du mod.
[Confidentialité](#confidentialité) liste précisément ce qui parvient à OpenAI et nomme les
requêtes de l'application vers GitHub ; [SECURITY.md](SECURITY.md) explique ce que cela protège
et ce que cela ne protège pas.

> **Non officiel.** Sans lien avec Anthropic ou OpenAI, qui ne l'approuvent ni ne le prennent en
> charge. Il s'appuie sur l'API temps réel expérimentale de codex, qui peut changer à chaque
> version de codex.

## Démarrage rapide

Il vous faut macOS 14+ sur Apple Silicon, Claude Code 2.1.289+, et
[codex](https://github.com/openai/codex) connecté (`codex login`) à une offre ChatGPT incluant la
voix en temps réel ; pour compiler l'application vous-même, il faut aussi Xcode avec Swift 6.0+.
Le détail se trouve sous [Prérequis](#prérequis).

```sh
# 1. The mod, from this repository's marketplace
claude plugin marketplace add getLiveBridge/LiveBridge
claude plugin install livebridge@livebridge

# 2. The app, built from source, installed in /Applications and opened
git clone https://github.com/getLiveBridge/LiveBridge.git
cd livebridge
scripts/build-app.sh --release
```

3. Dans la session Claude Code à laquelle vous voulez parler, tapez `/live on`.
4. Appuyez sur **Start** dans la bande au-dessus du prompt, autorisez le microphone, et parlez.

Vous préférez ne pas compiler ? Chaque [version](https://github.com/getLiveBridge/LiveBridge/releases/latest)
fournit l'application sous forme d'image disque, compilée et attestée par GitHub Actions ;
[Depuis l'image disque](#depuis-limage-disque) explique comment la vérifier et l'ouvrir. Le mod
s'installe de la même manière dans les deux cas.

Si `/live` est introuvable dans une session déjà ouverte, rouvrez la session
([pourquoi](#limitations-connues)). La mise à jour, les autorisations, la conservation de
l'autorisation du microphone d'une recompilation à l'autre et la désinstallation sont décrites
sous [Installation](#installation).

## Prérequis

- macOS 14 ou ultérieur sur Apple Silicon.
- Claude Code 2.1.289 ou ultérieur (mods).
- [Codex CLI](https://github.com/openai/codex) (`codex`, testé avec 0.166.0), installé avec
  Homebrew (`brew install --cask codex`) ou npm (`npm install -g @openai/codex`), présent dans le
  `PATH` que votre shell définit dans une fenêtre Terminal, et connecté avec `codex login` à une
  offre ChatGPT incluant la voix en temps réel. LiveBridge refuse un codex dont il ne peut pas
  lire le `codex features list`, donc une autre version peut ne pas démarrer tant que LiveBridge
  n'a pas été mis à jour.
- Pour compiler l'application : Xcode avec une chaîne d'outils Swift 6.0 ou ultérieure. Les
  versions testées sont indiquées dans [CONTRIBUTING.md](CONTRIBUTING.md#toolchain).
  L'application compilée fonctionne sur macOS 14 ou ultérieur.

## Installation

Le mod provient de la marketplace de ce dépôt (les commandes du [Démarrage
rapide](#démarrage-rapide)), qui désigne le tag de la dernière version : le mod que vous
installez est donc celui de cette version. L'application va dans `/Applications` dans les deux
cas : depuis l'image disque, ou compilée depuis les sources. Dans les deux cas, elle est signée
ad hoc et non notarisée.

### Depuis l'image disque

1. Téléchargez
   [LiveBridge.dmg](https://github.com/getLiveBridge/LiveBridge/releases/latest/download/LiveBridge.dmg)
   depuis la dernière version.
2. Vérifiez-la avec la [GitHub CLI](https://cli.github.com), dans le dossier où vous l'avez
   enregistrée :

   ```sh
   gh attestation verify LiveBridge.dmg --repo getLiveBridge/LiveBridge \
     --signer-workflow getLiveBridge/LiveBridge/.github/workflows/release.yml \
     --source-ref refs/tags/vX.Y.Z --deny-self-hosted-runners
   ```

   où `vX.Y.Z` est le tag de la version, tel que sa page le nomme. La vérification ne réussit que
   pour une image que le [workflow de publication](.github/workflows/release.yml) de ce dépôt a
   compilée à partir de ce tag, sur un runner hébergé par GitHub, et qui n'a pas changé depuis.
   C'est l'unique preuve d'origine de l'image : la signature ad hoc ne désigne personne. Elle ne
   prouve pas que quiconque ait relu le code.
3. Ouvrez-la et faites glisser LiveBridge dans Applications.
4. Au premier lancement, macOS bloque l'application jusqu'à ce que vous l'autorisiez dans
   Réglages Système > Confidentialité et sécurité > **Open Anyway**.

### Depuis les sources

`scripts/build-app.sh --release` compile l'application, l'installe dans `/Applications` (votre
compte doit pouvoir y écrire, comme celui d'un administrateur) et l'ouvre. Relancez-le pour
recompiler. La compilation est signée ad hoc, donc macOS redemande l'accès au microphone après
chaque recompilation. Pour conserver l'autorisation, exécutez une fois
`scripts/build-app.sh --make-signing-identity` : il demande d'abord confirmation, puis crée dans
votre trousseau de session un certificat de signature de code auto-signé, et les compilations
release suivantes sont signées avec lui.

La marketplace épingle le mod au tag de la dernière version : une application compilée depuis la
branche principale tourne donc avec le mod de cette version. Pour les faire correspondre,
compilez le tag de la version (`git checkout vX.Y.Z`) ou chargez le mod de votre copie de travail
avec `claude --plugin-dir plugin`.

Une compilation depuis les sources ne vérifie les mises à jour d'elle-même que si vous l'activez
dans Settings. Installer une mise à jour la remplace par l'image de la version, signée ad hoc, si
bien que le certificat auto-signé ne s'applique plus ; **Install** le signale et demande d'abord
confirmation.

### Mises à jour

LiveBridge met à jour l'application et son mod quand vous cliquez sur **Install**, et jamais de
lui-même. Seule la copie située à `/Applications/LiveBridge.app` se met à jour ; toute autre
copie l'indique dans Settings.

- **Check for updates automatically**, dans Settings (activé par défaut, désactivé pour une
  compilation depuis les sources) : une fois par jour, l'application demande à GitHub quelle est
  la dernière version. Une version plus récente est annoncée une seule fois, par une notification
  dont le bouton **Install** l'installe, et le menu de la barre des menus propose **Install
  LiveBridge X.Y.Z…** jusqu'à son installation, en interrogeant de nouveau GitHub à chaque
  lancement pour conserver cet élément. **Check for update**, dans Settings, interroge GitHub
  tout de suite.
- **Install** a besoin de la [GitHub CLI](https://cli.github.com) connectée (`gh auth login`) ;
  sans elle, Install ne télécharge rien et renvoie à la page de la version. Il télécharge l'image
  de la version, la vérifie avec le même `gh attestation verify` que ci-dessus, puis vérifie
  l'application qu'elle contient, et n'installe rien si une seule vérification échoue. Il attend
  tant que Claude traite encore une demande vocale, met à jour le mod avec
  `claude plugin marketplace update livebridge` et `claude plugin update livebridge@livebridge`,
  arrête l'appel, met la nouvelle application en place en une seule étape et l'ouvre.
- Ensuite, Settings indique la version d'origine de la mise à jour. Si le mod n'a pas pu être mis
  à jour, il affiche ces deux commandes pour que vous les exécutiez vous-même. Les sessions
  Claude Code déjà ouvertes gardent l'ancien mod jusqu'à leur redémarrage ; Settings liste
  celles qui sont rejointes et l'utilisent encore.
- Le téléchargement de la mise à jour ne pose pas d'attribut de quarantaine, donc macOS ne
  devrait pas bloquer le premier lancement de l'application mise à jour comme il a bloqué le
  premier téléchargement ; cela découle du code et n'a pas encore été observé. Les vérifications
  ci-dessus en tiennent lieu ([SECURITY.md](SECURITY.md#what-an-update-installs)). macOS
  redemande en revanche l'accès au microphone au premier **Start** après une mise à jour, parce
  que chaque version est signée ad hoc.

Pour mettre à jour à la main, exécutez `/live off` dans chaque session (le mod rouvre
l'application de `/Applications` dès qu'elle ne répond plus), quittez LiveBridge, installez
l'image plus récente comme ci-dessus et exécutez les deux commandes `claude plugin`.

### Autorisations

Le premier Start demande à macOS l'accès au microphone. S'il a été refusé, l'appel s'arrête avec
une phrase d'explication, et **Open Microphone Settings** dans le menu de la barre des menus
ouvre Confidentialité et sécurité > Microphone, où vous autorisez LiveBridge. Avec la signature
ad hoc, macOS redemande au premier Start après chaque mise à jour ou recompilation (voir
ci-dessus). macOS peut aussi demander si LiveBridge peut trouver des appareils sur votre réseau
local. La ligne vocale a besoin de cette seconde autorisation également ; sans elle, l'appel
s'arrête avec une phrase qui indique où l'accorder.

### Désinstallation

Depuis un clone, `scripts/build-app.sh --uninstall` supprime `/Applications/LiveBridge.app`,
quelle que soit la manière dont il a été installé, son élément d'ouverture de session et tous les
fichiers qu'il conserve, puis affiche les deux commandes qu'il vous laisse exécuter :
`tccutil reset Microphone com.getlivebridge.livebridge` et
`claude plugin uninstall livebridge@livebridge`.

Sans clone, désactivez **Open at login** dans les Settings de LiveBridge, quittez LiveBridge, puis
exécutez les mêmes étapes dans Terminal :

```sh
rm -rf /Applications/LiveBridge.app ~/Library/Application\ Support/LiveBridge \
  ~/Library/{Caches,WebKit}/com.getlivebridge.livebridge \
  ~/Library/HTTPStorages/com.getlivebridge.livebridge{,.binarycookies} \
  ~/Library/Preferences/com.getlivebridge.livebridge.plist
tccutil reset Microphone com.getlivebridge.livebridge
claude plugin uninstall livebridge@livebridge
```

Aucune des deux méthodes ne supprime une copie nommée `/Applications/.LiveBridge-update-….app`,
qu'une mise à jour interrompue en pleine installation peut laisser. L'application supprime ces
copies à son lancement suivant ; après une désinstallation, supprimez-la à la main si elle
existe.

## Utilisation

### Commandes

Dans la session Claude Code à laquelle vous voulez parler :

| Commande | Ce qu'elle fait |
|---|---|
| `/live on` | Rejoint LiveBridge sous le titre de la session, et ouvre l'application si elle n'est pas lancée. |
| `/live off` | Quitte LiveBridge. |
| `/live target` | Fait de cette session celle à qui la voix confie le travail. |
| `/live status` (ou simplement `/live`) | Une ligne : l'appel, la cible, les résultats non entendus, les minutes du jour. |
| `/live context` | Envoie à la voix un nouveau résumé de cette session, rédigé par le modèle de la session. |

La commande est `/live`, et non `/voice`, car `/voice` est le mode vocal propre à Claude Code.
Charger ou non le résumé d'une session chaque fois qu'une ligne s'ouvre n'est pas une
commande : c'est un réglage unique pour toutes les sessions, dans la fenêtre
[Settings](#réglages) de LiveBridge.

### La bande et le menu

Appuyez sur **Start**, dans la bande au-dessus du prompt ou dans le menu de la barre des menus, et
parlez.

- **Le Start de la bande** fait de sa session la cible et démarre l'appel ; avec
  **Load context automatically when a line opens** activé, la ligne qu'il ouvre charge le résumé de la session
  ([détails](docs/architecture/overview.md#components)). Tant que l'appel parle à une autre
  session, la bande affiche **Talk here**. Si la bande n'apparaît pas dans une session rejointe,
  `/live on` la fait revenir.
- **Le menu de la barre des menus** contient l'appel, les sessions rejointes (cliquez sur l'une
  pour en faire la cible), **Load context**, la **Conversation** de la cible telle que LiveBridge
  la conserve, les minutes, **Star LiveBridge on GitHub** (ouvre la page du dépôt), **Settings…** et
  **Quit LiveBridge**.
- **New conversation…** efface la conversation de la cible et son contexte chargé, et le × d'une
  session la retire et efface sa propre conversation ; les deux demandent confirmation. La voix
  repart de zéro à la prochaine ouverture de la ligne, sauf si **Load context automatically when
  a line opens** est activé : cette ligne recharge un résumé de la même transcription de la
  session, donc désactivez le réglage ou faites `/clear` dans la session avant. `/live on` dans
  une session retirée la rejoint de nouveau.

### Réglages

**Settings…** ouvre la fenêtre Settings de LiveBridge :

- **Voice** : l'une des voix temps réel proposées par votre codex, que codex liste à l'ouverture
  de la fenêtre, ou **Codex default**. Elle s'entend dès la prochaine ouverture de la ligne.
- **Prompt** (vide par défaut) : vos propres instructions pour la voix, par exemple « Parle-moi
  en espagnol », jusqu'à 2 000 caractères. Elles sont ajoutées après les règles propres de
  LiveBridge pour la voix, qui l'emportent en cas de désaccord, et s'appliquent dès la prochaine
  ouverture de la ligne.
- **Load context automatically when a line opens** (activé par défaut) : chaque
  ligne que l'application ouvre (un Start, une ligne rouverte après un silence, la ligne après un
  changement de cible) demande son résumé à la cible sans l'attendre ; un réglage unique pour
  toutes les sessions, conservé par l'application.
- **Play a sound when a request is queued for Claude** (activé par défaut) : un son bref pour
  chaque demande que la voix transmet à Claude ([pourquoi](#limitations-connues)).
- **Notify when a result is waiting** (activé par défaut) : avec le carillon pour un résultat qui
  attend pendant que la ligne est fermée, une notification macOS nomme la session (« Alpha has a
  new result — speak to hear it »), jamais le résultat lui-même. Cliquer dessus ouvre le menu de
  la barre des menus.
- **Open at login** (désactivé par défaut).
- **Updates** : la version en cours, **Check for update**, **Check for updates automatically** et
  ce qu'a fait la dernière mise à jour ([Mises à jour](#mises-à-jour)).

### Ce que fait la voix

- Elle répond elle-même aux bavardages et aux explications, et transmet tout ce qui requiert le
  dépôt ou la session : tâches, questions sur le code, décisions, corrections et arrêts.
- Avant de transmettre quoi que ce soit de destructeur ou tourné vers l'extérieur (supprimer,
  pousser, publier, envoyer, déployer, payer), elle répète la demande et demande « oui ? ». C'est
  une habitude que la voix a pour consigne de garder, pas une garantie de sécurité ;
  [SECURITY.md](SECURITY.md) explique ce qui en est une.
- Elle relit les résultats en une phrase ou deux, avec le nom de la session. Les blocs de code et
  les tableaux restent dans la session, et les identifiants qu'elle reconnaît sont masqués.
- Quand Claude pose une question, la voix vous la pose et renvoie votre réponse à cette session.
  Le travail que Claude termine plus tard en arrière-plan est signalé comme une mise à jour.
- Quand Claude attend une demande de permission, la voix le dit. Vous répondez à la demande dans
  Claude Code ; LiveBridge n'y répond jamais à votre place.

## Facturation maîtrisée par conception

Une session vocale en temps réel coûte tant qu'elle est ouverte, donc LiveBridge ne l'ouvre que
pendant que quelqu'un parle, pendant que la réponse de Claude à une demande que vous venez de
faire peut encore arriver, ou pour dire cette réponse, une question de Claude ou que Claude
attend votre autorisation :

- Tant qu'un appel est en cours et que personne ne parle, le microphone alimente uniquement un
  détecteur de voix sur votre Mac. Rien n'est envoyé nulle part.
- Quand vous commencez à parler, la ligne s'ouvre. Les 2 secondes précédant votre prise de parole
  sont conservées et envoyées en premier, afin que vos premiers mots ne soient pas perdus.
- La ligne se ferme après 20 secondes de silence. Un son sans paroles (musique, télévision) la
  ferme après 90 secondes.
- Quand la voix transmet une demande à Claude (un transfert), la ligne reste ouverte jusqu'à
  2 minutes après ce transfert, facturée comme n'importe quelle ligne ouverte, et la voix annonce
  la réponse de Claude dès que plus personne ne parle. Un transfert ultérieur relance les
  2 minutes ; un échange qui n'envoie rien à Claude se ferme après les 20 secondes de silence
  habituelles.
- La réponse de Claude à une demande confiée à la session à laquelle vous parlez, une question
  que Claude vous y pose ou une demande d'autorisation qu'il attend rouvre la ligne si elle arrive
  alors que la ligne est fermée, et la voix la dit, facturée comme toute ligne ouverte. Tout le
  reste de ce qui arrive ligne fermée (tout ce qui vient d'une session que vous avez quittée, une
  mise à jour ultérieure) joue un carillon et attend : la bande et le menu l'affichent comme non
  entendu, et la voix vous le dit la prochaine fois que vous parlez
  ([quand il compte comme entendu](docs/architecture/overview.md#a-result-while-the-line-is-closed)).
- Chaque session Claude Code a sa propre conversation avec la voix. Elle est reportée sur la
  session temps réel suivante, et d'un Stop à un Start, de sorte que la voix se souvient de ce que
  vous avez dit il y a une minute. Une nouvelle cible change de conversation : une ligne ouverte
  se ferme, et vos prochains mots l'ouvrent avec la conversation de la nouvelle cible.
- Le menu affiche les minutes pendant lesquelles la ligne a été ouverte, mesurées par
  l'application ; la manière dont votre offre mesure la voix en temps réel n'est pas publiée.

## Confidentialité

LiveBridge n'a pas de télémétrie et n'écoute sur aucun port réseau ; le mod parle à l'application
par un socket Unix situé dans un dossier que seul votre utilisateur peut ouvrir. Ce qui part vers
OpenAI, via la session temps réel de codex :

- l'audio du microphone tant que la ligne est ouverte, de 2 secondes avant que vous ne commenciez
  à parler (ou, pour une ligne qu'une réponse, une question ou une demande d'autorisation de
  Claude a ouverte, dès son ouverture) jusqu'à sa fermeture ;
- les instructions de la voix : les règles propres de LiveBridge, puis le **Prompt** de vos
  Settings si vous en avez écrit un ;
- la conversation récente de la session cible (jusqu'aux 24 dernières lignes) pour la poursuivre
  dans une nouvelle session temps réel ;
- les demandes encore ouvertes de la session cible, sous forme de résumés d'une ligne ;
- chaque résultat, question, mise à jour et avis d'approbation, en une ligne d'au plus
  2 000 caractères, blocs de code et tableaux retirés. Une question que Claude pose en cours de
  tour, et l'avis d'approbation d'une permission que demande la boucle principale de Claude (pas
  un sous-agent), portent aussi ce que Claude a écrit juste avant de demander. Une mise à jour
  est la réponse de Claude dans un tour ultérieur déclenché par la notification d'une tâche
  d'arrière-plan, pendant au plus 10 minutes après une demande vocale et jusqu'à ce qu'un autre
  tour démarre dans la session ;
- le résumé de contexte de la session cible, en une ligne d'au plus 1 500 caractères. Il est
  enregistré quand il est chargé et envoyé à chaque ouverture de la ligne tant que cette session
  est la cible, d'un Stop à un Start et d'un redémarrage de l'application à l'autre. Le
  sous-menu Conversation du menu affiche cette ligne exactement telle qu'elle est envoyée ;
- avec chacune des lignes ci-dessus, le libellé de sa session : le titre de la session Claude
  Code, ou le nom du dossier de la session si elle n'en a pas ;
- l'offre WebRTC, qui liste les adresses réseau locales du Mac comme candidats de connexion.

Les résultats, questions, mises à jour et résumés passent d'abord par un masqueur de formes
connues d'identifiants (clés privées, JWT, jetons d'API courants, mots de passe dans les URL,
champs de type `password=`). C'est une liste de motifs, pas une garantie.

Le thread codex qui porte la voix est éphémère et en lecture seule, avec toutes les
fonctionnalités de codex désactivées sauf celles qui conservent votre connexion et gèrent
l'utilisation de votre proxy, et tous les serveurs MCP désactivés ; il ne sert qu'à parler. Le
travail de Claude va vers Anthropic comme le fait toujours votre session Claude Code.

Pour les mises à jour, l'application parle à GitHub. Avec **Check for updates automatically**
activé, une fois par jour (et à chaque lancement tant qu'une version qu'elle a annoncée n'est pas
installée), elle demande à l'API de GitHub, sans identifiants, quelle est la dernière version ;
GitHub voit l'adresse IP de votre Mac. **Check for update**, dans Settings, envoie la même
requête quand vous cliquez dessus. Quand la vérification automatique trouve une version plus
récente, l'application exécute `gh auth status` pour indiquer si l'image peut être vérifiée. Ce
n'est que lorsque vous cliquez sur **Install** qu'elle télécharge l'image et exécute
`gh attestation verify` et `claude plugin`, qui contactent GitHub, et Sigstore pour la racine de
confiance de `gh`, sous vos propres connexions. [SECURITY.md](SECURITY.md#what-leaves-the-mac)
liste chaque requête.

Sur votre Mac, l'application conserve ses réglages, le compteur d'utilisation, la date de sa
dernière recherche de mise à jour et les versions qu'elle a annoncées, ce qu'a fait la dernière
mise à jour et, pour chacune des 20 dernières sessions utilisées, sa conversation récente et la
ligne de contexte chargée en dernier depuis elle, dans
`~/Library/Application Support/LiveBridge`. Les lignes d'une session disparaissent quand vous
appuyez sur **New conversation** avec elle comme cible ou que vous la retirez avec ×. Une session
qui est partie les conserve jusqu'à ce que 20 sessions utilisées ensuite les évincent ; pour les
effacer plus tôt, exécutez de nouveau `/live on` dans cette session et appuyez sur **New
conversation**. La désinstallation les supprime toutes.

[SECURITY.md](SECURITY.md) contient le modèle de menace : en bref, tout ce que votre microphone
peut entendre peut devenir une demande que Claude exécute avec le mode de permissions propre à la
session.

## Limitations connues

- La voix dit parfois qu'elle regarde (« On it », « Looking now ») sans transmettre la demande,
  si bien que rien n'arrive à Claude : environ une demande sur cinq lors des
  [tests](docs/bugs/BR-001.md), alors que la règle de la voix l'interdit. L'application joue un
  son bref quand elle met une demande en file pour Claude ; si la voix dit qu'elle regarde et
  qu'aucun son ne suit, répétez la demande. L'application ne peut pas distinguer une telle
  promesse d'une réponse par ses mots, car la voix parle votre langue.
- Un résultat qui arrive pendant que la ligne l'attend est transmis à la voix sous forme de texte
  à dire ; codex n'a aucun appel qui fasse parler la voix immédiatement, c'est donc le modèle qui
  décide du moment. Lors des tests, elle a parlé en quelques secondes. Si ce n'est pas le cas, le
  résultat reste non entendu : la voix le dit après vos prochains mots, ou un carillon retentit
  à la fermeture de la ligne.
- Quand la réponse de Claude rouvre la ligne, la voix reste parfois muette
  ([mesuré](docs/adr/0001-platform-findings.md)). La ligne se ferme alors au bout de 5 secondes,
  et la réponse joue un carillon et attend, comme ci-dessous.
- Quand vos prochains mots rouvrent la ligne, la voix répond parfois uniquement à ceux-ci sans
  dire le résultat en attente. Le résultat n'est pas perdu : il reste en attente, déclenche un
  carillon et publie une notification à la fermeture de la ligne, et il est de nouveau transmis à
  la voix à la prochaine ouverture de la ligne.
- Une session Claude Code déjà ouverte avant le chargement du mod peut devoir être rouverte pour
  que `/live` y fonctionne.
- Dans l'application de bureau Claude, `/live` saisi dans une session dont le processus Claude
  Code n'a pas encore démarré (une nouvelle session, ou une session à peine rouverte) peut
  afficher « /live isn't a command here. ». La commande s'exécute quand même. L'application de
  bureau établit la liste des commandes d'une telle session à partir d'une vérification qu'elle
  lance avec les hooks désactivés, donc le code du mod, qui déclare `/live`, ne s'y exécute pas ;
  une fois la session lancée, l'application de bureau prend sa liste dans la session elle-même. Le
  mod n'a pas de correctif : un fichier de commande statique serait listé comme
  `/livebridge:live` et non `/live`, et, hooks désactivés, il enverrait son texte au modèle au
  lieu d'exécuter le mod.
- Le fait qu'une réponse ait dit un résultat en attente est jugé d'après ses mots, avec une liste
  de mots courants en anglais et en russe seulement
  ([la règle](docs/architecture/overview.md#a-result-while-the-line-is-closed)). Dans une autre
  langue, un résultat peut compter comme entendu alors que la voix l'a seulement mentionné.

## Fonctionnement

[docs/architecture/overview.md](docs/architecture/overview.md) décrit les composants, le protocole
entre le mod et l'application, et les flux de messages ;
l'[ADR 0001](docs/adr/0001-platform-findings.md) consigne les faits de plateforme sur lesquels
repose la conception.

## Feuille de route et aide recherchée

LiveBridge est aujourd'hui une application Mac, un exécutant (Claude Code) et un fournisseur de
voix (codex avec une connexion ChatGPT). Les trois se rencontrent à des jointures étroites, et
chacune des directions ci-dessous est ouverte aux contributeurs. Les tickets qui les concernent
portent le label
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22) ;
[CONTRIBUTING.md](CONTRIBUTING.md#where-to-start) indique les fichiers à lire en premier.

- **Windows et Linux.** L'application de barre des menus, sa page audio et le serveur de socket
  sont liés à macOS ; le protocole entre le mod et l'application, ainsi que le mod lui-même, sont
  portables. Un portage commence par une application pour la nouvelle plateforme qui parle le même
  protocole.
- **D'autres agents comme exécutant**, tels que Codex CLI, Hermes Agent ou Gemini CLI : chacun
  nécessite son propre adaptateur parlant le même protocole que le mod Claude Code.
- **D'autres fournisseurs de voix**, tels que l'API OpenAI Realtime avec votre propre clé d'API ou
  l'API Gemini Live de Google : chacun serait une autre implémentation du protocole temps réel de
  l'application.

## Contribuer

Les contributions sont les bienvenues. Pour tout ce qui dépasse un correctif, ouvrez d'abord un
ticket afin de s'accorder sur la forme avant de commencer le travail. Bons points de départ : les
tickets [help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22),
les [limitations connues](#limitations-connues) et les directions
[ci-dessus](#feuille-de-route-et-aide-recherchée).

- [CONTRIBUTING.md](CONTRIBUTING.md) : l'organisation du dépôt, la chaîne d'outils, les
  vérifications (`scripts/check.sh`) et les conventions.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) : comment nous nous traitons ici.
- [SECURITY.md](SECURITY.md) : signalez une vulnérabilité en privé, pas dans un ticket public.
- [CHANGELOG.md](CHANGELOG.md) : ce qui a changé dans chaque version.

## Crédits

Le protocole entre le mod et l'application s'est inspiré de
[claude-code-voice-mod](https://github.com/ldk00315-jpg/claude-code-voice-mod). Aucun code ni
texte n'en a été copié.

## Licence

[MIT](LICENSE).
