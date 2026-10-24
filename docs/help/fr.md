# Aide de Dynamic Wallpaper

**v1.0.0 · Build 4 · Guide hors ligne**

<!-- help-languages -->
Langue du guide : [简体中文](zh-Hans.md) · [English](en.md) · [日本語](ja.md) · [Français](fr.md) · [Español](es.md)
<!-- /help-languages -->

Ouvrez le **Guide d’utilisation** depuis le menu Aide de l’app ou son icône dans la barre des menus. Le guide s’affiche dans la langue actuelle de l’interface. Les liens ci-dessus changent uniquement la langue du guide, sans modifier les réglages de l’app. L’aide est incluse dans l’app et reste accessible hors ligne.

## Sommaire {#contents}

1. [Présentation](#introduction)
2. [Prise en main](#quick-start)
3. [Utiliser les fonctionnalités](#features)
4. [Réglages](#settings)
5. [Résoudre les problèmes](#troubleshooting)
6. [Performances et consommation](#performance)
7. [Raccourcis et gestes](#shortcuts)
8. [Informations de version](#version)
9. [Annexes](#appendix)

## 1. Présentation {#introduction}

Dynamic Wallpaper gère vos fonds d’écran locaux sur macOS : vidéos, animations, images, projets web et scènes peuvent habiller le bureau, seuls ou dans une liste de lecture.

L’app convient à un bureau animé, à des collections organisées par thème ou à des écrans ayant chacun leur contenu. Vous pouvez appliquer directement un fond ou régler l’ordre, la durée, les transitions et le volume de chaque élément d’une liste. L’interface est disponible en chinois simplifié, anglais, japonais, français et espagnol.

| Votre objectif | Point de départ | Configuration enregistrée ? |
| --- | --- | --- |
| Vérifier le rendu | **Lire l’aperçu** dans les détails du média | Non ; l’ancien fond revient à la fin de l’aperçu |
| Définir le bureau | **Appliquer le fond** ou **Appliquer la liste** | Oui ; le fond continue après fermeture de la fenêtre principale |
| Définir l’économiseur d’écran macOS | Publier dans **Économiseur d’écran**, puis le sélectionner dans les Réglages Système | Enregistré séparément du fond du bureau |

## 2. Prise en main {#quick-start}

1. Ouvrez Dynamic Wallpaper. Cliquez sur **Importer un fond** (le bouton plus) dans la barre d’outils, ou appuyez sur `⌘O`.
2. Sélectionnez **Fichiers multimédias**, cliquez sur **Choisir des fichiers…**, sélectionnez une ou plusieurs vidéos, animations ou images, puis confirmez.
3. Cliquez sur un élément dans **Tous les fonds** pour ouvrir les **Détails du fond** à droite.
4. Choisissez l’écran cible. Par défaut, **Tous les écrans · Synchronisés** applique la même source à tous les écrans. Pour ne changer qu’un écran, sélectionnez-le d’abord.
5. Choisissez **Remplir** ou **Ajuster**, puis cliquez sur **Appliquer le fond**. Un fond unique n’a pas besoin de liste de lecture.
6. Pour entendre une vidéo, désactivez **Tout couper**, puis réglez **Couper cet élément** et **Volume** dans les détails avant d’appliquer le fond.
7. Fermer la fenêtre principale laisse le fond appliqué fonctionner. L’icône de la barre des menus permet de mettre en pause, reprendre, changer de liste, ouvrir les réglages ou retrouver la fenêtre principale.

> 💡 **Astuce :** **Lire l’aperçu** affiche temporairement le contenu dans les détails et sur le bureau choisi. Cliquez ensuite sur **Appliquer le fond** pour enregistrer cette configuration.

## 3. Utiliser les fonctionnalités {#features}

### 3.1 Importer, retrouver et organiser les médias {#library}

La bibliothèque conserve les références des médias et des copies indépendantes des nouvelles importations pour les réutiliser.

1. Cliquez sur **Importer un fond**, ou faites glisser des vidéos, animations ou images dans la fenêtre principale.
2. Saisissez une partie du nom dans **Rechercher des fonds** pour filtrer les résultats.
3. Sélectionnez un élément et cliquez sur **Ajouter aux favoris** pour le retrouver dans **Favoris**.
4. Cliquez sur **Afficher dans le Finder** pour localiser la copie gérée utilisée par l’app.

Une importation effectuée depuis une liste ajoute également les nouveaux médias à cette liste. Retirer un média de la bibliothèque supprime ses éléments dans toutes les listes ainsi que sa copie gérée. Retirer un élément d’une seule liste ne modifie que cette liste, sans supprimer la copie. Aucune de ces opérations ne supprime le fichier d’origine.

### 3.2 Créer et lire une liste {#playlists}

Une liste regroupe des médias pour une rotation thématique ou des changements à intervalles réguliers.

1. Cliquez sur **Nouvelle liste** dans la barre latérale.
2. Saisissez un nom, puis cliquez sur **Renommer** ou appuyez sur Retour.
3. Utilisez **Ajouter un fond** pour sélectionner des médias de la bibliothèque, ou **Ajouter à une liste** dans les détails d’un média.
4. Faites glisser les éléments, ou utilisez leurs flèches haut et bas, pour modifier l’ordre.
5. Choisissez le mode de lecture, la transition, le cadrage et l’écran, puis cliquez sur **Appliquer la liste**.

| Option | Choix et valeur par défaut | Effet et utilisation |
| --- | --- | --- |
| Mode de lecture | Dans l’ordre (par défaut), Aléatoire sans répétition, Répéter un élément | L’ordre convient à une séquence préparée, l’aléatoire apporte de la variété et la répétition maintient l’élément actuel |
| Transition | Instantanée, Fondu · 0,3 s (par défaut), Fondu · 0,8 s | Le fondu agit sur l’image et le son. Une transition instantanée marque une coupure nette et réduit le traitement simultané des deux éléments |
| Durée d’affichage | Durée fixe (30 secondes par défaut), Lecture complète unique, Nombre de répétitions (initialement 1) | Sélectionnez un élément, modifiez sa durée dans les détails, puis cliquez sur Enregistrer la durée |

Pour une durée fixe, saisissez une valeur et choisissez s (secondes), m (minutes) ou h (heures) ; par exemple, 1.5 m équivaut à 90 secondes. La lecture complète et les répétitions d’une vidéo ou d’une animation utilisent sa durée propre. Pour une image fixe, la lecture complète utilise la durée choisie ; la durée totale en répétition vaut « durée × répétitions ». Les fonds web et de scène acceptent uniquement une durée fixe. La durée doit être supérieure à 0 et le nombre de répétitions doit être un entier positif.

Le mode aléatoire distingue les éléments de la liste : le même média ajouté deux fois compte comme deux éléments. Avec **Répéter un élément**, **Fond suivant** sélectionne encore l’élément actuel ; changez de mode pour passer à un autre. Si le suivant ne peut pas être préparé, l’image actuelle reste affichée et une erreur apparaît. L’élément défaillant n’est pas ignoré automatiquement.

Le sous-menu **Listes de lecture** de la barre des menus applique rapidement une liste à tous les écrans, avec le cadrage **Remplir**.

### 3.3 Configurer plusieurs écrans {#displays}

Utilisez des configurations indépendantes si vos écrans ont des usages différents, et la synchronisation pour partager une même source.

1. Avant d’appliquer un média ou une liste, choisissez un écran pour ne modifier que celui-ci.
2. Choisissez **Tous les écrans · Synchronisés** pour une lecture commune.
3. Ouvrez **Écrans** dans la barre latérale pour vérifier la source et l’état de chaque écran.
4. Dans une fiche d’écran, choisissez une liste et un cadrage, puis cliquez sur le bouton d’application correspondant. Pour changer de fond unique, retournez dans la bibliothèque.
5. Cliquez sur **Restaurer le fond système** pour arrêter le fond de l’app sur cet écran.

**Remplir** conserve les proportions et recadre les parties qui dépassent. **Ajuster** affiche l’image entière et remplit les zones inutilisées en noir. Un groupe synchronisé partage sa source et les réglages audio associés.

> ⚠️ **Attention :** **Restaurer le fond système** arrête la couche affichée par l’app. Si la synchronisation du fond système était activée, macOS conserve la dernière image fixe synchronisée. Consultez la [synchronisation du fond système](#system-wallpaper).

### 3.4 Aperçu lié au bureau et audio {#preview-audio}

L’aperçu lié permet de vérifier le cadrage sur le véritable bureau sans enregistrer l’affectation à l’écran.

1. Sélectionnez un média ou un élément de liste, puis choisissez l’écran et le cadrage.
2. Cliquez sur **Lire l’aperçu**. La lecture appliquée est suspendue temporairement. Si l’écran appartient à un groupe synchronisé, tout le groupe est suspendu.
3. Cliquez sur **Arrêter l’aperçu**, sélectionnez un autre élément ou fermez la fenêtre à l’origine de l’aperçu pour retrouver le fond précédent.

Seuls les détails produisent le son de l’aperçu ; les copies sur le bureau sont muettes. Les images des détails et du bureau ne sont pas nécessairement synchronisées à l’image près.

| Emplacement du réglage audio | Portée et enregistrement |
| --- | --- |
| Audio de l’élément dans les détails de la bibliothèque | Sert à l’aperçu actuel, puis est enregistré pour l’écran cible avec Appliquer le fond. Ne modifie pas les listes |
| Audio de l’élément dans les détails d’une liste | Est enregistré pour cet élément et concerne uniquement sa lecture et son aperçu |
| Audio d’un fond unique déjà appliqué, dans Écrans | Modifie immédiatement le fond actuel. Le groupe synchronisé partage le réglage ; les listes ne changent pas |
| Tout couper | Est prioritaire sur les réglages individuels et coupe aussi les aperçus |

Les vidéos, les fonds web et les scènes disposent de réglages audio individuels. Par défaut, **Couper cet élément** est désactivé et le volume est de 100 %. Le volume va de 0 à 100 %, par pas de 1 %. Utilisez Tout couper pour un bureau silencieux, puis ajustez les éléments séparément pour équilibrer leurs niveaux.

### 3.5 Modifier plusieurs éléments {#batch}

1. Cliquez sur **Sélection multiple**, puis cochez les éléments. **Tout sélectionner** sélectionne les résultats du filtre actuel.
2. Dans la bibliothèque, vous pouvez ajouter ou retirer des favoris, ajouter à une liste ou retirer des médias en une seule opération.
3. Dans une liste, cliquez sur **Modifier la sélection…**. Activez **Modifier la durée**, **Modifier la mise en sourdine** ou **Modifier le volume**, renseignez les valeurs, puis cliquez sur **Enregistrer les modifications**.
4. Cliquez sur **Terminé** pour quitter la sélection multiple.

Les trois options de modification sont désactivées au départ. Les champs non activés conservent leurs valeurs. L’éditeur démarre à 30 secondes, 1 répétition, son non coupé et volume de 100 % : ce ne sont pas les valeurs communes de la sélection. Si elle contient un élément web ou de scène, seule la durée fixe est disponible pour la modification groupée. Les changements audio concernent les vidéos, les fonds web et les scènes.

### 3.6 Fonds web locaux et interaction {#web}

Un projet web local convient aux contenus de bureau réalisés en HTML, avec des styles et des scripts.

1. Cliquez sur **Importer un fond**, puis sélectionnez **Projet web**.
2. Cliquez sur **Choisir un dossier…** et sélectionnez le dossier contenant la page et ses ressources.
3. Indiquez le **Fichier d’entrée (HTML)**. Par défaut, il s’agit de `index.html`. Utilisez **Choisir le fichier d’entrée…** ou saisissez un chemin relatif, par exemple `pages/index.html`.
4. Cliquez sur **Importer le projet web**, puis appliquez-le depuis la bibliothèque.

L’importation copie tout le dossier du projet, conserve les chemins relatifs et transforme les liens symboliques internes en fichiers ou dossiers indépendants. Les liens vers l’extérieur, les liens cycliques et les fichiers spéciaux font échouer l’importation. Les modifications ultérieures du projet d’origine ne sont pas synchronisées avec la copie. Gardez HTML, images, styles et scripts dans le projet ; l’accès aux fichiers extérieurs et au réseau externe reste limité. La pause garde l’image affichée ; la reprise recharge la page sans conserver sa progression interne.

Pour interagir avec la page, activez **Interaction web** depuis la barre des menus (désactivée par défaut). Suivez les indications pour autoriser **Accessibilité** et **Surveillance de l’entrée** dans les Réglages Système de macOS, puis revenez activer Interaction web. Le retrait d’une autorisation désactive l’interaction. Cette fonction transmet les clics gauches sur une zone vide du bureau du Finder, et non l’ensemble des interactions d’un navigateur.

### 3.7 Convertir une vidéo pour améliorer la compatibilité {#transcoding}

**Convertir…** apparaît lorsque la vérification de compatibilité des détails confirme que la vidéo peut être convertie. L’objectif est de créer un fichier plus compatible ; sa disponibilité dépend du résultat de cette vérification.

1. Cliquez sur **Convertir…** et attendez la fin de l’analyse.
2. Choisissez **Taille et fréquence d’origine** (par défaut) ou **Adapter en 1080p · Jusqu’à ~30 fps**.
3. Vérifiez le dossier et le nom du fichier de sortie. Par défaut, le dossier est celui de la source initialement importée et le nom suit la forme `nom-original-h264.mp4`. La sortie ne peut pas être écrite dans le dossier `Media` de l’app ni dans ses sous-dossiers.
4. Cliquez sur **Ajouter à la file de conversion**. Une fois la tâche terminée, cliquez sur **Importer dans la bibliothèque** pour créer une copie gérée indépendante tout en conservant le fichier de sortie. Remplacez les éléments de liste si nécessaire.

Après avoir fermé la fenêtre, ouvrez **Tâches de conversion** dans la barre des menus pour retrouver la progression.

La sortie est un MP4 en H.264 avec audio AAC, produit par l’encodage matériel VideoToolbox. Le réencodage n’est pas une copie sans perte. Le réglage d’origine complète les dimensions impaires pour les rendre paires ; le réglage 1080p réduit proportionnellement sans agrandir et limite la fréquence à environ 30 images par seconde. Seules la première piste vidéo et la première piste audio sont conservées, sans sous-titres ni chapitres. Une source sans audio reste muette. Les réglages de volume et de mise en sourdine de l’app ne modifient pas le son du fichier produit.

Les fichiers existants ne sont jamais écrasés. Les tâches s’exécutent une par une et continuent après la fermeture de la fenêtre. Quitter l’app demande confirmation pour annuler les tâches inachevées ; les fichiers terminés restent disponibles. Un échec de l’encodage matériel est signalé, sans basculement automatique vers un encodage logiciel.

### 3.8 Synchroniser le fond système {#system-wallpaper}

**Synchroniser le fond d’écran système** fige le fond appliqué dans une image PNG et la définit comme fond macOS de l’écran concerné. Une image similaire reste ainsi présente lorsque la couche animée s’arrête.

1. Dans **Réglages → Général**, activez **Synchroniser le fond d’écran système**.
2. Appliquez un fond et consultez l’état de synchronisation de chaque écran.
3. En cas d’échec, corrigez la cause indiquée, puis cliquez sur **Réessayer la synchronisation**.

Il s’agit d’une image fixe, pas d’un fond système mis à jour à chaque image. Les aperçus temporaires ne modifient pas le fond système.

> ⚠️ **Attention :** désactiver la synchronisation, arrêter le fond ou quitter l’app conserve la dernière image synchronisée. Ces actions ne rétablissent pas le fond système utilisé avant la synchronisation. Pour choisir une autre image, ouvrez **Fond d’écran** dans les Réglages Système de macOS.

### 3.9 Apparence et arrière-plan plein écran {#appearance}

L’interface utilise Liquid Glass sous macOS 26 et versions ultérieures, y compris macOS 27, et des matériaux natifs compatibles sous macOS 14 et 15. Dans **Réglages → Apparence**, ajustez le thème, la transparence et le flou pour équilibrer la visibilité du fond et la lisibilité du texte.

La fenêtre principale peut montrer le fond derrière son interface lorsqu’elle occupe l’espace plein écran actif. Les fenêtres ordinaires et les espaces en arrière-plan ne capturent pas continuellement ce fond plein écran. Sans fond fourni par l’app, une image fixe du fond système est utilisée ; elle ne correspond pas nécessairement au moment actuel d’un fond dynamique macOS.

### 3.10 Configurer l’économiseur d’écran natif {#screensaver}

La page **Économiseur d’écran** de la barre latérale gère son contenu indépendamment du fond du bureau. Choisissez une vidéo native, une image fixe, une animation ou une liste qui en contient. **Importer des médias pour l’économiseur…** ajoute des fichiers locaux. Les éléments web, les scènes et ceux du lecteur étendu sont exclus. Après importation ou sélection de la source, la fenêtre de confirmation centre les éléments inclus ; s’il y a des exclusions, les éléments inclus et exclus apparaissent côte à côte. Confirmez les exclusions avant publication. La liste d’origine reste intacte et toute nouvelle exclusion demande une nouvelle confirmation.

L’app copie les médias publiés dans `DynamicWallpaper/ScreenSaverExport`, sous Application Support. La page indique seulement si un contenu utilisable est publié. Si la synchronisation échoue, elle signale l’erreur et conserve la dernière copie valide. Les changements pertinents de la liste se synchronisent automatiquement ; **Synchroniser maintenant** relance la publication. Le nouveau contenu entre en vigueur au **prochain démarrage de l’économiseur**, ou à la réouverture de l’aperçu dans l’app. Une instance en cours garde sa version initiale. Supprimer la source ne supprime pas aussitôt sa copie publiée. **Effacer le contenu publié…** ne touche qu’à l’économiseur ; les anciennes copies sont récupérées après l’arrêt des instances actives.

La première fois, cliquez sur **Installer ou mettre à jour l’économiseur…** et suivez macOS. Sélectionnez ensuite vous-même **Dynamic Wallpaper Screen Saver** dans Réglages Système. **Revérifier l’installation** vérifie le résultat, mais une installation ne signifie pas que l’économiseur est sélectionné. Dans sa configuration système, autorisez le dossier de publication affiché par l’app. Cette autorisation distincte permet la lecture après la fermeture de l’app. Un dossier déplacé, une autorisation expirée ou l’absence de publication produit une erreur explicite. L’aperçu dans l’app montre le contenu publié ; vérifiez séparément la lecture réelle dans macOS.

### 3.11 Fonds de scène locaux {#scene}

1. Choisissez **Importer un fond → Projet de scène**.
2. Sélectionnez le dossier contenant `project.json`, le fichier JSON ou PKG et toutes les ressources, plutôt qu’un fichier JSON/PKG isolé.
3. Cliquez sur **Importer un projet de scène**. Une copie indépendante est enregistrée ; les changements du dossier original ne sont pas synchronisés.
4. Sélectionnez la scène, vérifiez l’aperçu, choisissez l’écran et le cadrage, puis appliquez le fond.

Importez uniquement des projets fiables : les scripts de scène peuvent s’exécuter. Des métadonnées invalides, un chemin hors du projet ou un fichier d’entrée absent produisent une erreur d’importation.

Utilisez une durée fixe. La pause conserve l’horloge de la scène et reprend la même instance. Les réglages de volume, de sourdine, de cadrage et de fréquence web s’appliquent. Activez l’interaction et ses autorisations pour les mouvements de souris et clics gauches sur le bureau vide. L’aperçu accepte directement la souris.

Les propriétés par défaut de l’auteur sont utilisées. Le spectre audio du système, l’édition de scènes et l’économiseur d’écran natif ne sont pas pris en charge. La compatibilité dépend de la version figée de WebWallGL ; les échecs de chargement ou de rendu affichent une erreur. Certains effets ou scripts incompatibles peuvent uniquement produire un avertissement dans le journal CEF. La scène n’est pas remplacée par une image ou une vidéo.

## 4. Réglages {#settings}

Les valeurs par défaut ci-dessous concernent une nouvelle bibliothèque. Les préférences existantes sont conservées. Les réglages ordinaires sont enregistrés et appliqués immédiatement. Les éditeurs dotés d’un bouton d’enregistrement, comme celui de la durée, nécessitent sa validation.

### 4.1 Général {#general-settings}

| Réglage | Choix / valeur par défaut | Effet et conseil |
| --- | --- | --- |
| Langue de l’interface | Suivre le système (par défaut), 简体中文, English, 日本語, Français, Español | Définit la langue de l’app ; voir la section consacrée aux langues |
| Ouvrir à la connexion | Activé / désactivé ; non enregistré par défaut à la première installation | Lance l’app après la connexion à macOS. Si une approbation est nécessaire, utilisez Ouvrir les éléments de connexion… |
| Afficher l’icône dans le Dock | Activé / désactivé ; activé par défaut | Si désactivé, l’ouverture d’une fenêtre de gestion affiche temporairement l’icône du Dock et les menus de l’app. L’icône se masque quand toutes ces fenêtres sont fermées ; les réduire ou les masquer ne les ferme pas. Le réglage enregistré reste inchangé. Cela n’arrête pas la lecture et ne constitue pas un réglage d’économie d’énergie |
| Synchroniser le fond d’écran système | Activé / désactivé ; désactivé par défaut | Crée une image fixe du fond appliqué et l’écrit comme fond système. Laissez désactivé si vous n’avez pas besoin de ces générations et écritures d’images |
| Tout couper | Activé / désactivé ; activé par défaut | Coupe les vidéos, le web, les scènes et les aperçus sans ramener les volumes individuels à zéro |
| Suspendre en mode économie d’énergie | Activé / désactivé ; désactivé par défaut | Suit le mode économie d’énergie de macOS, pas un pourcentage de batterie. Utile sur batterie |
| Suspendre en cas de surchauffe | Activé / désactivé ; activé par défaut | Suspend la lecture lorsque macOS signale un état thermique grave ou critique. Il est conseillé de le laisser activé |

La lecture se suspend automatiquement au verrouillage, à la veille du système ou de l’écran, et lorsque la session utilisateur est inactive. Aucun réglage n’est nécessaire. Elle reprend après disparition de toutes les causes automatiques ; une pause manuelle exige une reprise manuelle. Les raisons sont visibles dans la barre des menus.

### 4.2 Apparence {#appearance-settings}

| Réglage | Choix / valeur par défaut | Effet et compromis |
| --- | --- | --- |
| Mode d’apparence | Suivre le système (par défaut), Clair, Sombre | Modifie l’interface, pas le fichier du fond. Choisissez selon la lumière ambiante |
| Transparence du fond | 0–100 % ; 75 % par défaut | À 100 %, le fond est transparent sans flou ; à 0 %, il est opaque. Réduisez la transparence pour lire sur un fond chargé |
| Style de flou | Transparent, Dépoli (par défaut) | S’applique sous 100 % de transparence. Dépoli distingue davantage le contenu au premier plan |
| Fréquence du fond en plein écran | 30 Hz (par défaut), 60 Hz | Règle la capture du fond de l’app en plein écran, pas la fréquence maximale de la vidéo sur le bureau. 60 Hz est plus fluide mais demande plus de traitement |

La préférence macOS **Réduire la transparence** est prioritaire pour la lisibilité. Elle ne remplace pas les valeurs de transparence et de flou enregistrées dans l’app.

### 4.3 Stockage, Avancé et À propos {#other-settings}

| Panneau | Contenu | Utilité |
| --- | --- | --- |
| Stockage | Explication des copies indépendantes, sauvegarde et vidage de la bibliothèque, dernière sauvegarde de configuration et nombre de nettoyages en attente | Gère les médias et leur nettoyage sans modifier les originaux ni les réglages de l’app |
| Avancé | Nom du fichier de configuration, version du format, chemin complet et Afficher dans le Finder | Informations en lecture seule pour localiser et sauvegarder la configuration |
| À propos | Nom, version et présentation de l’app | Permet de vérifier la version utilisée |

Pour repartir d’une bibliothèque vide :

1. Ouvrez **Réglages → Stockage** et cliquez sur **Sauvegarder et vider la bibliothèque…**. Cette action est indisponible pendant une importation.
2. Confirmez la suppression des médias, favoris compris, des listes et des affectations aux écrans. Les réglages de l’app, les originaux et les images système synchronisées restent inchangés.
3. L’app ne vide les références et ne supprime les copies gérées qu’après une sauvegarde réussie. Sous **Dernière sauvegarde de configuration**, consultez le chemin ou affichez la sauvegarde dans le Finder.

La sauvegarde contient seulement le JSON, pas les médias : elle ne restaure pas les copies supprimées. Si une conversion associée utilise encore le média, attendez sa fin, ou annulez-la et attendez la libération des ressources avant de réessayer ; les autres tâches ne sont pas concernées. Un échec de nettoyage affiche une erreur et reste enregistré pour une nouvelle tentative au prochain lancement.

Si un média disparaît de la bibliothèque mais que son fichier reste sur le disque, consultez le nombre de nettoyages en attente et les détails de l’erreur dans **Stockage**. Le dossier géré a peut-être été remplacé ou ne correspond plus à l’enregistrement de l’app, qui refuse alors de le supprimer. Cela ne signifie pas que l’original a été supprimé. Identifiez la copie restante avant d’agir ; ne videz pas tout le dossier des médias.

### 4.4 Langue et formats régionaux {#language-settings}

1. Ouvrez **Réglages → Général → Langue de l’interface**.
2. Sélectionnez **Suivre le système** ou l’une des cinq langues.
3. Une fois l’enregistrement réussi, l’interface propre à l’app change immédiatement. Aucun redémarrage n’est nécessaire et la lecture du fond ne redémarre pas.

Suivre le système choisit la première langue prise en charge dans l’ordre des langues préférées de macOS, ou l’anglais si aucune ne correspond. Les nombres utilisent le format régional de la langue actuelle. Les noms de fichiers, de médias et de listes personnalisées ne sont pas traduits. Les menus et sélecteurs de fichiers fournis par le système peuvent conserver la langue de macOS.

Ouvrir à nouveau le **Guide d’utilisation** depuis l’app rétablit la langue actuelle de l’interface. Les liens de langue en haut du guide ne changent que le document consulté.

## 5. Résoudre les problèmes {#troubleshooting}

Distinguez d’abord le fond réellement appliqué, l’aperçu temporaire et l’arrière-plan de la fenêtre de l’app. Commencez par les vérifications simples du tableau. Si une erreur propose **Voir les détails…**, conservez son texte pour identifier le média ou l’opération en cause.

| Symptôme | Causes possibles | Vérifications et solutions | Solution provisoire |
| --- | --- | --- | --- |
| Fond absent ou noir | Non appliqué, mauvais écran, fichier inaccessible, décodage en échec, lecture suspendue | ① Sélectionnez à nouveau média et écran, puis appliquez. ② Utilisez Afficher dans le Finder pour vérifier le fichier réellement utilisé. ③ Consultez les raisons de pause. ④ Essayez une image lisible. ⑤ Lisez l’erreur d’analyse du média | Utilisez une image qui fonctionne ou arrêtez le fond de l’app sur cet écran |
| Vidéo saccadée ou consommation élevée | Résolution/fréquence élevée, sources indépendantes multiples, aperçu ou conversion en cours, chaleur | ① Arrêtez les aperçus. ② Attendez la conversion ou annulez une tâche inutile. ③ Réduisez le nombre d’écrans animés indépendants. ④ Réglez le fond plein écran à 30 Hz. ⑤ Si la conversion est proposée, créez une version 1080p / environ 30 fps | Mettez en pause ou utilisez une image fixe ; activez la pause d’économie d’énergie |
| Le volume semble inchangé | Son global coupé, mauvais élément ou réglage temporaire modifié, absence de piste audio, mauvaise sortie système | ① Vérifiez la coupure globale, celle de l’élément et le volume. ② Confirmez l’élément ou l’écran actuel. ③ Réappliquez après une modification dans la bibliothèque. ④ Vérifiez la vidéo source et la sortie audio de macOS | Testez une vidéo dont le son est connu ; utilisez Tout couper pour le silence |
| Plusieurs écrans changent ensemble | Tous les écrans synchronisés, ancienne cible sélectionnée, branchement modifié | ① Vérifiez les écrans connectés. ② Appliquez une source séparément sur chacun. ③ Resélectionnez après reconnexion. ④ Vérifiez le groupe de synchronisation | Configurez d’abord un écran, puis les autres |
| Le projet web ne se charge pas | Dossier ou entrée incorrects, ressources déplacées, dépendance réseau, erreur de script | ① Vérifiez que le HTML/HTM est dans le dossier choisi. ② Contrôlez le chemin relatif. ③ Rétablissez les ressources. ④ Comparez avec une page simple entièrement locale. ⑤ Consultez les détails | Utilisez un projet autonome ou un autre média |
| Le fond web ne réagit pas aux clics | Interaction désactivée, autorisation manquante ou retirée, clic hors de l’espace vide du Finder | ① Activez Interaction web. ② Vérifiez Accessibilité et Surveillance de l’entrée. ③ Réactivez après autorisation. ④ Essayez un clic gauche sur le bureau vide | Lisez le fond sans interaction |
| La liste n’avance pas ou change mal | Répétition d’un élément, durée trop longue ou non enregistrée, liste vide, préparation suivante en échec | ① Vérifiez le mode. ② Corrigez et enregistrez durée, unité et répétitions. ③ Vérifiez le contenu de la liste. ④ Contrôlez le fichier réellement utilisé par l’élément suivant. ⑤ Réappliquez après correction | Utilisez Dans l’ordre avec une durée fixe courte ; retirez manuellement l’élément défaillant |
| L’app ne répond plus ou se ferme | Média/page trop lourd ou défectueux, charge de conversion, configuration illisible | ① Laissez du temps à un traitement actif. ② Si possible, mettez en pause, quittez normalement et rouvrez. ③ Sinon, forcez la fermeture via macOS et rouvrez. ④ Testez une image simple. ⑤ N’envisagez la réinitialisation ci-dessous que pour une erreur explicite de lecture de bibliothèque | Évitez le média déclencheur. Une fermeture forcée interrompt les conversions inachevées |
| macOS signale une autorisation manquante | Web non autorisé, média ou dossier de sortie inaccessible, capture plein écran limitée | ① Identifiez la fonction concernée. ② Pour le web, vérifiez Accessibilité et Surveillance de l’entrée. ③ Resélectionnez un fichier lisible ou un dossier accessible en écriture. ④ Si une ancienne version de macOS 14 demande l’enregistrement de l’écran pour le fond plein écran, vérifiez cette autorisation puis réessayez | Désactivez l’interaction ou quittez le plein écran de l’app ; continuez la lecture normale du fond |
| Mauvaise langue, texte non traduit ou changement sans effet | Suivre le système sélectionné, échec d’enregistrement, nom de média, quelques erreurs encore non localisées | ① Choisissez explicitement la langue voulue. ② Vérifiez les erreurs de sauvegarde. ③ Rouvrez la fenêtre ou l’aide. ④ Distinguez texte système, noms et libellés de l’app | Choisissez temporairement une autre langue disponible. Les listes peuvent être renommées ; la liste initiale d’une nouvelle bibliothèque peut encore s’appeler « 我的播放列表 » |
| Le fond système ne se synchronise pas ou reste après l’arrêt | Synchronisation désactivée ou en attente, échec, conservation de la dernière image | ① Vérifiez l’option et l’état des écrans. ② Appliquez un fond. ③ Corrigez les problèmes de fichier/écran puis réessayez. ④ Choisissez un autre fond dans macOS si souhaité | Désactivez la synchronisation et choisissez vous-même le fond système. Désactiver seul ne restaure pas l’ancienne image |
| Média absent de la bibliothèque, mais copie locale encore présente | Nettoyage en attente ou dossier ne correspondant plus à l’enregistrement de l’app | ① Consultez les nettoyages en attente dans **Réglages → Stockage**. ② Conservez l’erreur et vérifiez qu’il s’agit d’une copie gérée inutile. ③ Relancez l’app pour réessayer. ④ Si l’échec persiste, ne traitez que la copie résiduelle identifiée | Conservez provisoirement le fichier ; ne supprimez pas tout le dossier des médias |

**Sauvegarder et réinitialiser une bibliothèque illisible**

Utilisez cette action uniquement lorsque l’app indique explicitement qu’elle ne peut pas lire la bibliothèque. Elle sauvegarde la configuration existante, puis efface les références des médias, les listes, les affectations aux écrans et les réglages de bibliothèque. Les fichiers d’origine ne sont pas supprimés. Il faudra réimporter et reconfigurer. Si les réglages s’ouvrent, utilisez d’abord **Avancé** pour localiser et copier la configuration. Ne commencez pas par une réinitialisation pour un écran noir ou des saccades.

## 6. Performances et consommation {#performance}

- **Préserver la batterie :** activez la pause en mode économie d’énergie et conservez la pause en cas de surchauffe. Mettez en pause manuellement quand l’animation n’est pas utile.
- **Réduire le travail du CPU et du GPU :** le CPU réalise les calculs généraux et le GPU traite les graphismes. Choisissez une résolution et une fréquence adaptées à vos écrans. Si la conversion est disponible, le profil 1080p peut alléger la lecture.
- **Adapter le contenu aux écrans :** une vidéo sur l’écran principal et une image sur le secondaire sont généralement moins coûteuses que plusieurs vidéos haute résolution indépendantes. La synchronisation partage le contenu, mais le nombre et la taille des écrans comptent toujours.
- **Éviter le cumul :** arrêtez les aperçus une fois terminés. Suspendez les fonds si la conversion provoque des saccades. Les fondus traitent brièvement deux éléments ; choisissez Instantanée pour réduire ce chevauchement.
- **Régler le plein écran selon le besoin :** commencez à 30 Hz. Passez à 60 Hz si la fluidité du fond de l’app le justifie. Cela ne limite pas la fréquence propre de la vidéo du bureau.
- **Garder les médias accessibles :** utilisez un disque connecté de façon fiable et des ressources web locales. Laissez la synchronisation d’images fixes désactivée si elle n’est pas utile.

## 7. Raccourcis et gestes {#shortcuts}

| Action | Raccourci ou geste | Emplacement |
| --- | --- | --- |
| Importer un fond | `⌘O` | Menu de l’app |
| Afficher/masquer la barre latérale | `⌃⌘S` | Fenêtre principale |
| Quitter l’app | `⌘Q` | Menu ; confirmation si des conversions restent en cours |
| Exécuter l’action par défaut | Retour | Boîtes de dialogue avec bouton par défaut |
| Annuler/fermer une explication | Échap | Boîtes de dialogue concernées et bulles d’aide avec point d’interrogation |
| Ouvrir l’explication d’un contrôle | Placez le focus sur le bouton d’aide puis appuyez sur Espace ou Retour, ou cliquez | Contrôles disposant d’un bouton d’aide |
| Réorganiser une liste | Glisser les éléments ou cliquer sur les flèches haut/bas | Liste, hors sélection multiple |
| Importer des médias | Glisser les fichiers | Fenêtre principale |
| Ouvrir un menu contextuel | Clic droit ou clic à deux doigts | Médias ou listes |

`⌘` signifie Commande et `⌃` signifie Contrôle. Lecture, pause et fond suivant sont accessibles dans la barre des menus.

## 8. Informations de version {#version}

| Élément | Information |
| --- | --- |
| App | Dynamic Wallpaper |
| Version | v1.0.0, build 4 |
| Portée du guide | Opérations, réglages, conséquences pour les données et dépannage de l’app actuelle |

Consultez **Réglages → À propos** pour vérifier la version installée. Ce guide est inclus dans l’app et fonctionne hors ligne.

## 9. Annexes {#appendix}

### 9.1 Glossaire {#glossary}

| Terme | Signification |
| --- | --- |
| Bibliothèque | Références des médias et copies indépendantes créées lors de l’importation |
| Élément de liste | Un ajout à une liste ; un même média peut avoir plusieurs éléments indépendants |
| Groupe synchronisé | Écrans partageant une source et un état de lecture |
| Fond appliqué / aperçu lié | Le premier est enregistré pour l’écran ; le second est temporaire et rétablit le fond précédent à la fin |
| Fond système | Image de macOS sous la couche animée de l’app |
| Conversion ou transcodage | Réencodage d’une vidéo dans un autre format, créant un nouveau fichier |
| Fichier d’entrée | Premier fichier HTML ouvert dans un projet web local |
| Liquid Glass | Matériau d’interface à l’aspect de verre fourni par macOS 26 |

### 9.2 Formats pris en charge {#formats}

| Type | Extensions |
| --- | --- |
| Vidéo | MP4, MOV, M4V, MKV, WebM, AVI |
| Image fixe | JPEG/JPG, PNG, HEIC, HEIF |
| Animation | GIF, APNG |
| Web local | HTML, HTM ; importés via le dossier d’un projet web |
| Scène locale | JSON ou PKG avec `project.json` ; dossier de projet de scène |

L’extension désigne un type de fichier, sans garantir la lecture de tous les codecs qu’il peut contenir. Fiez-vous à l’analyse du fichier par l’app. Renommer une extension ne modifie pas l’encodage vidéo.

### 9.3 Système et langues {#requirements}

- Système : macOS 14.0 ou version ultérieure.
- Processeur : Apple Silicon (arm64).
- La charge dépend des dimensions, de la fréquence, de la complexité web et du nombre d’écrans. Choisissez les médias en conséquence.
- Langues : 简体中文, English, 日本語, Français, Español.

### 9.4 Emplacements et données enregistrées {#data}

Pour localiser la configuration, ouvrez **Réglages → Avancé** et utilisez **Afficher dans le Finder**. Ne déplacez ni ne remplacez manuellement les dossiers de médias gérés par l’app. Celle-ci conserve aussi séparément les images système synchronisées.

Les références des médias, favoris, listes, affectations aux écrans, préférences et nettoyages en attente sont enregistrés. Recherches, sélections multiples, aperçus temporaires, pause manuelle et files de conversion inachevées ne sont pas conservés après redémarrage. Une sauvegarde de configuration ne contient aucun média et ne restaure pas les copies supprimées ; conservez les originaux ou sauvegardez séparément les médias gérés.
