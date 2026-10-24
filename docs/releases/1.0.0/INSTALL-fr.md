# Installer Dynamic Wallpaper 1.0.0

Apple Silicon (arm64) · macOS 14.0 ou ultérieur · build 4

1. Téléchargez `DynamicWallpaper-1.0.0-arm64.dmg` et `SHA256SUMS.txt` depuis la publication GitHub officielle.
2. Exécutez `shasum -a 256 DynamicWallpaper-1.0.0-arm64.dmg` et comparez le résultat à la ligne correspondante du fichier de sommes.
3. Ouvrez le DMG, glissez **Dynamic Wallpaper.app** dans **Applications**, éjectez le DMG et lancez l’app installée. Pour le ZIP, décompressez-le puis déplacez l’app dans Applications.
4. L’app utilise une signature ad hoc, sans notarisation Apple. Si macOS bloque le lancement, vérifiez le téléchargement, puis autorisez cette app dans **Réglages Système → Confidentialité et sécurité**.

Quittez l’ancienne version avant de la remplacer. Les médias importés sont conservés séparément. Pour pouvoir revenir à une ancienne version, copiez `~/Library/Application Support/DynamicWallpaper` avant le premier lancement : 1.0.0 enregistre le format de bibliothèque 4, que l’ancienne app peut refuser. L’action de sauvegarde et d’effacement de la bibliothèque efface aussi la bibliothèque active.

Importez un média, un projet web ou un projet de scène, choisissez l’écran et appliquez le fond. Un projet de scène doit contenir `project.json`, son entrée JSON/PKG et ses ressources. Utilisez uniquement des projets fiables. Une scène reprend au même endroit ; une page web est rechargée après la pause.

Le guide intégré est disponible hors ligne. La compatibilité des scènes varie selon les effets et scripts. Le spectre audio système, l’édition et l’économiseur d’écran pour les scènes sont exclus. Les limites des dossiers de sources/licences tiers restent décrites dans ThirdParty et les notes de version.
