# Instalar Dynamic Wallpaper 1.1.0

Apple Silicon (arm64) · macOS 14.0 o posterior · compilación 5

1. Descarga `DynamicWallpaper-1.1.0-arm64.dmg` y `SHA256SUMS.txt` desde la publicación oficial de GitHub.
2. Ejecuta `shasum -a 256 DynamicWallpaper-1.1.0-arm64.dmg` y compara el resultado con la línea correspondiente del archivo de sumas.
3. Abre el DMG, arrastra **Dynamic Wallpaper.app** a **Applications**, expulsa el DMG y abre la app instalada. Si usas el ZIP, descomprímelo y mueve la app a Applications.
4. La app tiene firma ad hoc, sin notarización de Apple. Si macOS bloquea el inicio, verifica la descarga y permite esta app desde **Ajustes del Sistema → Privacidad y seguridad**.

Cierra normalmente la versión anterior antes de reemplazarla. Los contenidos se guardan aparte de la app. Para poder volver a una versión anterior, copia `~/Library/Application Support/DynamicWallpaper` antes del primer inicio: 1.1.0 guarda el formato de biblioteca 4, que versiones anteriores pueden rechazar. La acción de copia y vaciado también vacía la biblioteca activa.

Importa archivos multimedia, proyectos web o proyectos de escena, elige la pantalla y aplica el fondo. Una escena necesita `project.json`, su entrada JSON/PKG y los recursos dentro de la carpeta. Importa solo proyectos de confianza. La escena reanuda desde la pausa; la página web vuelve a cargarse.

La guía sin conexión explica las propiedades de escena, la autorización explícita de Music/Spotify y la respuesta al audio. La respuesta al audio del sistema requiere macOS 14.2 o posterior; las demás funciones mantienen la compatibilidad con macOS 14.0. Las escenas no se admiten en el salvapantallas nativo. Editor 0.1.0 es una descarga opcional independiente, con proyectos y ajustes propios.

Para eliminar Main, ciérralo y mueve solo **Dynamic Wallpaper.app** a la papelera. Si instalaste el salvapantallas opcional, elimínalo por separado en Ajustes del Sistema. Los contenidos permanecen en `~/Library/Application Support/DynamicWallpaper/`; borra esa carpeta solo si quieres eliminar la biblioteca. Editor y sus proyectos permanecen. ThirdParty conserva las fuentes, licencias y registros medidos de las dependencias compiladas de forma controlada; consulta las notas de versión para conocer los límites de validación.
