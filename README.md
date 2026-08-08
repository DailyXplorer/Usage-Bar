# UsageBar

Petite app macOS menu bar (SwiftUI) qui affiche tes limites d'utilisation **Codex**
(plan ChatGPT) et **Claude Code** (plan Anthropic) en un clin d'œil :
**pourcentage restant** et temps avant reset.

Dans la barre de menus : `‹logo ChatGPT› 99% ‹logo Claude› 99%` — la fenêtre
primaire Codex, puis la barre **All models** de Claude Code (la limite
hebdomadaire tous modèles). Le popover détaille toutes les fenêtres des deux
côtés.

Le libellé entier est **composé hors écran en une seule image template**
(`MenuBarLabelImage`), et c'est délibéré : `MenuBarExtra` ne rend qu'une image et
un texte dans son label, supprime une image interpolée dans une chaîne, et fige
la hiérarchie de vues au premier rendu — un segment ajouté ensuite par un `if`
n'apparaîtrait jamais. Une `Image` unique dont seule la valeur change contourne
les trois contraintes. Ne pas revenir à des vues voisines : deux tests le
verrouillent.

## Fonctionnement

### Codex

- Lit `~/.codex/auth.json` (le même fichier que le CLI Codex) pour récupérer le
  `access_token` et l'`account_id` ChatGPT.
- Interroge l'endpoint officiel `https://chatgpt.com/backend-api/wham/usage`
  (le même que celui utilisé par `codex /status`).
- Affiche la fenêtre primaire ("weekly", "5h", … selon la durée retournée par le
  backend, même heuristique que le CLI) et la fenêtre secondaire si présente.

### Claude Code

- Lit le jeton OAuth dans le trousseau macOS via `/usr/bin/security`, exactement
  comme Claude Code l'écrit — c'est ce qui évite une demande d'autorisation
  trousseau à chaque lancement. Repli sur `~/.claude/.credentials.json`.
  Aucun jeton n'est copié ni réécrit.
- Interroge `https://api.anthropic.com/api/oauth/usage`, l'endpoint que Claude
  Code utilise pour sa commande `/usage`.
- Reprend les trois barres intégrées de Claude Code : **Session 5h**,
  **Week · All models** et **Week · ‹modèle›** (la limite par modèle épinglé,
  ex. Opus), chacune avec son heure de reset.
- Si aucune session Claude Code n'existe, la section est simplement masquée.

Les deux comptes sont interrogés en parallèle : un backend lent ne bloque pas
l'autre, et une erreur d'un côté n'efface pas les barres de l'autre.

### Ménager les endpoints

L'endpoint d'usage de Claude renvoie **429** si on le sollicite trop. Trois
garde-fous :

- le dernier état est **persisté** (`UserDefaults`) et réaffiché avant toute
  requête, donc une relance de l'app ne coûte pas un appel réseau et n'affiche
  jamais « – » alors qu'on connaît la valeur ;
- une requête n'est émise que si les données ont plus de 5 minutes (l'ouverture
  du popover ne déclenche donc pas systématiquement un appel ; le bouton
  « Retry » force, lui) ;
- sur 429, **recul progressif** (5 → 15 → 30 → 60 min) pendant lequel les
  dernières valeurs connues restent affichées.

`Updated at` date les **données**, pas la dernière tentative : un rafraîchissement
qui échoue ne fait pas passer un état périmé pour frais. Les pourcentages
persistés sont figés au relevé, mais les comptes-à-rebours sont recalculés depuis
l'heure de reset à la relecture.

- Affiche le **% restant** (ex. 66% restant = 34% utilisé).
- Rafraîchit automatiquement toutes les 5 minutes et à l'ouverture du popover.

## Design

- Interface en anglais.
- Police **Instrument Sans** (variable, bundlée dans l'app), y compris pour le
  libellé de la barre de menus. Attention : le fichier étant variable, une seule
  face est enregistrée (`InstrumentSans-Regular`). Les graisses passent par l'axe
  `wght` (`AppTheme.nsFont`) ; demander « InstrumentSans-SemiBold » par son nom
  échoue et retombe **en silence** sur la police système.
- Logos **Hugeicons** `chat-gpt` et `claude` (catégorie Logos, stroke · rounded),
  bundlés en SVG et rendus en template pour suivre le thème de la barre.

## Build & run

```sh
chmod +x scripts/build-app.sh
scripts/build-app.sh
open .build/UsageBar.app
```

Pour la version debug :

```sh
swift build
./.build/debug/UsageBar
```

## Prérequis

- macOS 14+ (Sonoma ou plus récent)
- Être connecté au CLI Codex avec un compte ChatGPT : `codex login`
- Pour la partie Claude : être connecté à Claude Code (`claude`, puis `/login`)
- Xcode Command Line Tools : `xcode-select --install`

## Notes

- L'app tourne en agent accessoire : aucune icône dans le Dock, uniquement dans
  la barre de menus.
- Aucune donnée ne quitte ta machine en dehors des requêtes d'usage vers
  chatgpt.com et api.anthropic.com, identiques à celles des deux CLI.
- **Trousseau** : l'entrée `Claude Code-credentials` est créée par Claude Code
  via `/usr/bin/security`, donc son ACL ne fait confiance qu'à ce binaire. L'app
  passe par le même chemin : aucune demande d'autorisation, y compris après un
  rebuild (l'app est signée ad hoc, sa signature change à chaque fois).
- Le jeton Claude est rafraîchi par Claude Code lui-même. S'il a expiré et que
  Claude Code n'a pas tourné depuis longtemps, la section affiche « Jeton Claude
  expiré » jusqu'à la prochaine ouverture de Claude Code.

## Licence

Le code de ce projet est sous licence **MIT** — voir [LICENSE](LICENSE).

Les ressources tierces embarquées gardent la leur :

- **Instrument Sans** (`Sources/UsageBar/Resources/Fonts/InstrumentSans.ttf`) —
  © 2022 The Instrument Sans Project Authors, sous
  [SIL Open Font License 1.1](https://openfontlicense.org). La licence est
  distribuée avec la police
  ([`Fonts/OFL.txt`](Sources/UsageBar/Resources/Fonts/OFL.txt)), comme l'OFL
  l'exige : si tu redistribues l'app ou le repo, garde ce fichier à côté du
  `.ttf`.
- **Hugeicons** (`chat-gpt.svg`, `claude.svg`) — icônes du set gratuit, sous
  licence MIT, attribution non requise.

Les logos ChatGPT/OpenAI et Claude/Anthropic restent la propriété de leurs
détenteurs respectifs ; ils sont utilisés ici pour identifier les services
interrogés, pas pour suggérer une affiliation. Ce projet n'est affilié ni à
OpenAI ni à Anthropic.
