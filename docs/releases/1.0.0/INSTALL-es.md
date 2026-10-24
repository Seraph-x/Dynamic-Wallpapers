# Instalar Dynamic Wallpaper 1.0.0

Apple Silicon (arm64) · macOS 14.0 o posterior · compilación 4

1. Descarga `DynamicWallpaper-1.0.0-arm64.dmg` y `SHA256SUMS.txt` desde la publicación oficial de GitHub.
2. Ejecuta `shasum -a 256 DynamicWallpaper-1.0.0-arm64.dmg` y compara el resultado con la línea correspondiente del archivo de sumas.
3. Abre el DMG, arrastra **Dynamic Wallpaper.app** a **Applications**, expulsa el DMG y abre la app instalada. Si usas el ZIP, descomprímelo y mueve la app a Applications.
4. La app tiene firma ad hoc, sin notarización de Apple. Si macOS bloquea el inicio, verifica la descarga y permite esta app desde **Ajustes del Sistema → Privacidad y seguridad**.

Cierra normalmente la versión anterior antes de reemplazarla. Los contenidos se guardan aparte de la app. Para poder volver a una versión anterior, copia `~/Library/Application Support/DynamicWallpaper` antes del primer inicio: 1.0.0 guarda el formato de biblioteca 4, que versiones anteriores pueden rechazar. La acción de copia y vaciado también vacía la biblioteca activa.

Importa archivos multimedia, proyectos web o proyectos de escena, elige la pantalla y aplica el fondo. Una escena necesita `project.json`, su entrada JSON/PKG y los recursos dentro de la carpeta. Importa solo proyectos de confianza. La escena reanuda desde la pausa; la página web vuelve a cargarse.

La guía integrada funciona sin conexión. La compatibilidad de escenas depende de efectos y scripts. Se excluyen el espectro de audio del sistema, el editor de escenas y las escenas en el salvapantallas. Las limitaciones del inventario de fuentes/licencias se conservan en ThirdParty y las notas de versión.
