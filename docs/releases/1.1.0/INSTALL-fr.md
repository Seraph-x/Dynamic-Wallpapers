# Installer Dynamic Wallpaper 1.1.0

Apple Silicon (arm64) · macOS 14.0 ou ultérieur · build 5

1. Téléchargez `DynamicWallpaper-1.1.0-arm64.dmg` et `SHA256SUMS.txt` depuis la publication GitHub officielle.
2. Exécutez `shasum -a 256 DynamicWallpaper-1.1.0-arm64.dmg` et comparez le résultat à la ligne correspondante du fichier de sommes.
3. Ouvrez le DMG, glissez **Dynamic Wallpaper.app** dans **Applications**, éjectez le DMG et lancez l’app installée. Pour le ZIP, décompressez-le puis déplacez l’app dans Applications.
4. L’app utilise une signature ad hoc, sans notarisation Apple. Si macOS bloque le lancement, vérifiez le téléchargement, puis autorisez cette app dans **Réglages Système → Confidentialité et sécurité**.

Quittez l’ancienne version avant de la remplacer. Les médias importés sont conservés séparément. Pour pouvoir revenir à une ancienne version, copiez `~/Library/Application Support/DynamicWallpaper` avant le premier lancement : 1.1.0 enregistre le format de bibliothèque 4, que l’ancienne app peut refuser. L’action de sauvegarde et d’effacement de la bibliothèque efface aussi la bibliothèque active.

Importez un média, un projet web ou un projet de scène, choisissez l’écran et appliquez le fond. Un projet de scène doit contenir `project.json`, son entrée JSON/PKG et ses ressources. Utilisez uniquement des projets fiables. Une scène reprend au même endroit ; une page web est rechargée après la pause.

Le guide hors ligne explique les propriétés de scène, l’autorisation explicite Music/Spotify et la réaction audio. La réaction à l’audio système nécessite macOS 14.2 ou ultérieur ; les autres fonctions restent compatibles avec macOS 14.0. Les scènes ne sont pas compatibles avec l’économiseur d’écran natif. Editor 0.1.0 est un téléchargement facultatif séparé, avec ses propres projets et réglages.

Pour supprimer Main, quittez-le et placez uniquement **Dynamic Wallpaper.app** dans la corbeille. Si vous avez installé l’économiseur d’écran facultatif, retirez-le séparément dans Réglages Système. Les médias restent dans `~/Library/Application Support/DynamicWallpaper/` ; ne supprimez ce dossier que pour effacer volontairement la bibliothèque. Editor et ses projets restent disponibles. ThirdParty conserve les sources, notices et mesures des dépendances compilées de manière contrôlée ; consultez les notes de version pour les limites de validation.
