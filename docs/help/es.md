# Ayuda de Dynamic Wallpaper

**v0.3.0 · Compilación 3 · Guía sin conexión**

<!-- help-languages -->
Idioma de la guía: [简体中文](zh-Hans.md) · [English](en.md) · [日本語](ja.md) · [Français](fr.md) · [Español](es.md)
<!-- /help-languages -->

Abre la **Guía de uso** desde el menú Ayuda de la app o desde su icono en la barra de menús. Se abrirá en el idioma actual de la interfaz. Los enlaces de arriba solo cambian el idioma de la guía, no los ajustes de la app. La ayuda está incluida en la aplicación y se puede leer sin conexión.

## Índice {#contents}

1. [Acerca de la app](#introduction)
2. [Primeros pasos](#quick-start)
3. [Cómo usar las funciones](#features)
4. [Referencia de ajustes](#settings)
5. [Solución de problemas](#troubleshooting)
6. [Rendimiento y consumo](#performance)
7. [Atajos y gestos](#shortcuts)
8. [Información de versión](#version)
9. [Apéndice](#appendix)

## 1. Acerca de la app {#introduction}

Dynamic Wallpaper organiza fondos locales en macOS y permite mostrar vídeos, animaciones, imágenes y proyectos web en el escritorio, de forma individual o mediante listas de reproducción.

Es útil para dar movimiento al escritorio, agrupar contenidos por temas o dedicar un fondo distinto a cada pantalla. Puedes aplicar un único fondo directamente o ajustar el orden, la duración, las transiciones y el volumen de cada elemento de una lista. La interfaz está disponible en chino simplificado, inglés, japonés, francés y español.

| Lo que quieres hacer | Empieza aquí | ¿Se guarda como configuración activa? |
| --- | --- | --- |
| Ver el resultado | **Reproducir vista previa** en los detalles del contenido | No; al terminar vuelve el fondo anterior |
| Configurar el escritorio | **Aplicar fondo** o **Aplicar lista** | Sí; continúa tras cerrar la ventana principal |
| Configurar el salvapantallas de macOS | Publica en **Salvapantallas** y selecciónalo en Ajustes del Sistema | Se guarda por separado del fondo del escritorio |

## 2. Primeros pasos {#quick-start}

1. Abre Dynamic Wallpaper y haz clic en **Importar fondo** (el botón de suma) de la barra de herramientas, o pulsa `⌘O`.
2. Selecciona **Archivos multimedia**, haz clic en **Elegir archivos…**, selecciona uno o varios vídeos, animaciones o imágenes y confirma la importación.
3. Haz clic en un elemento de **Todos los fondos** para abrir **Detalles del fondo** a la derecha.
4. Elige la pantalla de destino. La opción predeterminada, **Todas las pantallas · Sincronizadas**, aplica la misma fuente a todas. Si solo quieres cambiar una pantalla, selecciónala primero.
5. Elige **Rellenar** o **Ajustar** y haz clic en **Aplicar fondo**. Un fondo individual no necesita una lista.
6. Para escuchar el vídeo, desactiva **Silenciar todo** y ajusta **Silenciar este elemento** y **Volumen** en los detalles antes de aplicar el fondo.
7. Al cerrar la ventana principal, el fondo aplicado sigue funcionando. Desde el icono de la barra de menús puedes pausar, reanudar, cambiar de lista, abrir los ajustes o volver a la ventana principal.

> 💡 **Consejo:** **Reproducir vista previa** muestra temporalmente el contenido en los detalles y en el escritorio elegido. Después, pulsa **Aplicar fondo** para guardar esa configuración.

## 3. Cómo usar las funciones {#features}

### 3.1 Importar, buscar y organizar contenidos {#library}

La biblioteca guarda registros de los contenidos y copias independientes de las nuevas importaciones para que puedas reutilizarlos.

1. Haz clic en **Importar fondo** o arrastra vídeos, animaciones o imágenes a la ventana principal.
2. Escribe parte del nombre en **Buscar fondos** para filtrar los resultados.
3. Selecciona un elemento y pulsa **Añadir a favoritos** para encontrarlo fácilmente en **Favoritos**.
4. Pulsa **Mostrar en Finder** para localizar la copia gestionada que usa la app.

Si importas mientras estás en una lista, los nuevos contenidos también se añaden a ella. Quitar un contenido de la biblioteca retira sus elementos de todas las listas y elimina su copia gestionada. Quitar un elemento de una lista concreta solo afecta a esa lista, sin eliminar la copia. Ninguna de estas acciones elimina el archivo original.

### 3.2 Crear y reproducir una lista {#playlists}

Las listas agrupan contenidos para alternar fondos por temas o cambiarlos a intervalos.

1. Haz clic en **Nueva lista** en la barra lateral.
2. Escribe un nombre y pulsa **Renombrar** o la tecla Retorno.
3. Usa **Añadir fondo** para elegir contenidos de la biblioteca, o **Añadir a lista** en los detalles de un elemento.
4. Arrastra los elementos o utiliza sus flechas de subir y bajar para ordenarlos.
5. Elige el modo de reproducción, la transición, el ajuste de imagen y la pantalla; después pulsa **Aplicar lista**.

| Opción | Valores y valor predeterminado | Efecto y uso |
| --- | --- | --- |
| Modo de reproducción | En orden (predeterminado), Aleatorio sin repetir, Repetir uno | En orden sirve para secuencias preparadas; el modo aleatorio aporta variedad; Repetir uno mantiene el elemento actual |
| Transición | Instantánea, Fundido · 0,3 s (predeterminado), Fundido · 0,8 s | El fundido afecta a imagen y sonido. La transición instantánea marca un cambio directo y reduce el procesamiento simultáneo de dos elementos |
| Duración de visualización | Duración fija (30 segundos de forma predeterminada), Reproducir una vez completa, Número de repeticiones (inicialmente 1) | Selecciona un elemento, modifica el tiempo en sus detalles y pulsa Guardar duración |

Para una duración fija, introduce un valor y elige s (segundos), m (minutos) o h (horas); por ejemplo, 1.5 m equivale a 90 segundos. La reproducción completa y las repeticiones de vídeos y animaciones se calculan con su duración original. En imágenes fijas, una reproducción completa utiliza la duración elegida; el tiempo total con repeticiones es «duración × repeticiones». Los fondos web solo admiten duración fija. La duración debe ser mayor que 0 y las repeticiones deben ser un número entero positivo.

Aleatorio sin repetir distingue los elementos de la lista: añadir dos veces el mismo contenido crea dos elementos. Con **Repetir uno**, **Siguiente fondo** vuelve a seleccionar el elemento actual; cambia de modo para avanzar a otro. Si no se puede preparar el siguiente, se mantiene la imagen actual y se muestra un error. No se omite automáticamente el elemento que falla.

El submenú **Listas de reproducción** de la barra de menús permite aplicar rápidamente una lista a todas las pantallas con **Rellenar**.

### 3.3 Configurar varias pantallas {#displays}

Usa configuraciones independientes si las pantallas tienen funciones distintas, o sincronízalas para compartir una misma fuente.

1. Antes de aplicar un contenido o una lista, selecciona una pantalla para cambiar solo esa.
2. Elige **Todas las pantallas · Sincronizadas** para una reproducción compartida.
3. Abre **Pantallas** en la barra lateral y revisa la fuente y el estado de cada una.
4. En la tarjeta de una pantalla, elige una lista y el ajuste de imagen, y pulsa el botón de aplicar correspondiente. Para elegir otro fondo individual, vuelve a la biblioteca.
5. Pulsa **Restaurar fondo del sistema** para detener el fondo de la app en esa pantalla.

**Rellenar** conserva las proporciones y recorta lo que sobresale. **Ajustar** muestra la imagen completa y deja en negro las zonas sobrantes. Las pantallas de un grupo sincronizado comparten la fuente y los ajustes de audio relacionados.

> ⚠️ **Importante:** **Restaurar fondo del sistema** detiene la capa de escritorio de la app. Si se había activado la sincronización del fondo del sistema, macOS conserva la última imagen fija sincronizada. Consulta [Sincronizar el fondo del sistema](#system-wallpaper).

### 3.4 Vista previa vinculada y audio {#preview-audio}

La vista previa vinculada permite comprobar el encuadre en el escritorio real sin guardar una asignación de pantalla.

1. Selecciona un contenido o un elemento de lista y elige pantalla y ajuste de imagen.
2. Pulsa **Reproducir vista previa**. La reproducción aplicada se suspende temporalmente; si el destino pertenece a un grupo sincronizado, se suspende todo el grupo.
3. Pulsa **Detener vista previa**, selecciona otro elemento o cierra la ventana que inició la vista previa para recuperar el fondo anterior.

Solo los detalles emiten el audio de la vista previa; las copias del escritorio permanecen silenciadas. No se garantiza que ambas imágenes coincidan fotograma a fotograma.

| Dónde cambias el audio | Qué afecta y dónde se guarda |
| --- | --- |
| Audio del elemento en los detalles de la biblioteca | Se usa en la vista previa actual y se guarda en la pantalla de destino al pulsar Aplicar fondo. No cambia las listas |
| Audio del elemento en los detalles de una lista | Se guarda en ese elemento y solo afecta a su reproducción y vista previa |
| Audio de un fondo individual aplicado, en Pantallas | Actualiza el fondo inmediatamente. El grupo sincronizado comparte el cambio; las listas no se modifican |
| Silenciar todo | Tiene prioridad sobre los ajustes individuales y también silencia las vistas previas |

Los vídeos y fondos web tienen controles de audio individuales. **Silenciar este elemento** está desactivado de forma predeterminada y el volumen inicial es del 100 %. El intervalo es de 0–100 %, en pasos del 1 %. Usa Silenciar todo para un escritorio silencioso y ajusta cada elemento si sus niveles son diferentes.

### 3.5 Operaciones con varios elementos {#batch}

1. Pulsa **Selección múltiple** y marca los elementos. **Seleccionar todos los resultados** selecciona los resultados del filtro actual.
2. En la biblioteca puedes añadir o quitar favoritos, añadir contenidos a una lista o quitarlos en conjunto.
3. En una lista, pulsa **Editar selección…**. Activa **Cambiar duración**, **Cambiar silencio** o **Cambiar volumen**, introduce los valores y pulsa **Guardar cambios**.
4. Pulsa **Listo** para salir de la selección múltiple.

Los tres interruptores de cambio empiezan desactivados. Los campos que no actives conservan su valor. El editor comienza con 30 segundos, 1 repetición, sonido sin silenciar y volumen del 100 %; no representa los valores comunes de la selección. Si hay elementos web, el cambio de duración en grupo solo admite tiempo fijo. Los cambios de audio solo se aplican a vídeos y fondos web.

### 3.6 Fondos web locales e interacción {#web}

Un proyecto web local permite utilizar contenido de escritorio creado con HTML, estilos y scripts.

1. Pulsa **Importar fondo** y selecciona **Proyecto web**.
2. Pulsa **Elegir carpeta…** y selecciona la carpeta que contiene la página y sus recursos.
3. Indica el **Archivo de entrada (HTML)**. El valor inicial es `index.html`; usa **Elegir archivo de entrada…** o escribe una ruta relativa, como `pages/index.html`.
4. Pulsa **Importar proyecto web** y aplícalo desde la biblioteca.

La importación copia toda la carpeta del proyecto, conserva las rutas relativas y convierte los enlaces simbólicos internos en archivos o carpetas independientes. Los enlaces externos, los enlaces cíclicos y los archivos especiales hacen que falle la importación. Los cambios posteriores en el proyecto original no se sincronizan con la copia. Mantén HTML, imágenes, estilos y scripts dentro del proyecto; el acceso a archivos externos y a la red externa sigue restringido. Al pausar se conserva la imagen; al reanudar se recarga la página sin conservar su progreso interno.

Para interactuar, activa **Interacción web** desde la barra de menús (desactivada inicialmente). Sigue las indicaciones para permitir **Accesibilidad** y **Monitorización de entrada** en los Ajustes del Sistema de macOS y vuelve a activar Interacción web en el menú. Si se retira un permiso, la interacción se desactiva. La función reenvía clics izquierdos en zonas vacías del escritorio de Finder; no ofrece todas las interacciones de un navegador.

### 3.7 Convertir vídeo para mejorar la compatibilidad {#transcoding}

**Convertir…** aparece cuando la comprobación de compatibilidad de los detalles confirma que el vídeo es apto. Sirve para generar un archivo más compatible; el resultado de la comprobación determina si está disponible.

1. Pulsa **Convertir…** y espera a que termine el análisis del vídeo.
2. Elige **Tamaño y frecuencia originales** (predeterminado) o **Ajustar a 1080p · Hasta ~30 fps**.
3. Comprueba la carpeta y el nombre de salida. Inicialmente se usa la carpeta de la fuente importada originalmente y el nombre `nombre-original-h264.mp4`. No se permite escribir la salida en la carpeta `Media` de la app ni en sus subcarpetas.
4. Pulsa **Añadir a la cola de conversión**. Cuando termine, pulsa **Importar a la biblioteca** para crear una copia gestionada independiente y conservar el archivo de salida. Sustituye los elementos de lista que quieras.

Si cierras la ventana, vuelve a abrirla desde **Tareas de conversión** en la barra de menús para consultar el progreso.

El resultado es un MP4 con vídeo H.264 y audio AAC, generado mediante codificación por hardware de VideoToolbox. Recodificar no es una copia sin pérdida. El perfil de tamaño original añade borde para convertir dimensiones impares en pares; el perfil 1080p reduce proporcionalmente, sin ampliar, y limita la frecuencia a unos 30 fps. Solo conserva la primera pista de vídeo y la primera de audio, sin subtítulos ni capítulos. Si el original no tiene audio, el resultado tampoco. Los ajustes de silencio y volumen de la app no cambian el sonido del archivo generado.

No se sobrescriben archivos existentes. Las tareas se ejecutan de una en una y continúan al cerrar la ventana de conversión. Al salir de la app, se pide confirmar la cancelación de las tareas pendientes; los archivos terminados se conservan. Si falla la codificación por hardware, se muestra el error sin pasar automáticamente a codificación por software.

### 3.8 Sincronizar el fondo del sistema {#system-wallpaper}

**Sincronizar fondo del sistema** guarda una imagen fija PNG del fondo aplicado y la establece como fondo de macOS en esa pantalla. Así queda un fondo parecido cuando se detiene la capa animada.

1. Abre **Ajustes → General** y activa **Sincronizar fondo del sistema**.
2. Aplica un fondo y consulta el estado de sincronización de cada pantalla.
3. Si falla, revisa la causa, corrígela y pulsa **Reintentar sincronización**.

Es una imagen fija, no un fondo del sistema actualizado en cada fotograma. Las vistas previas temporales no modifican el fondo del sistema.

> ⚠️ **Importante:** desactivar la sincronización, detener el fondo o salir de la app conserva la última imagen sincronizada. Ninguna de estas acciones recupera el fondo anterior a la sincronización. Para elegir otra imagen, abre **Fondo de pantalla** en los Ajustes del Sistema de macOS.

### 3.9 Apariencia y fondo a pantalla completa {#appearance}

La interfaz usa Liquid Glass en macOS 26 y posteriores, incluido macOS 27, y materiales nativos compatibles en macOS 14 y 15. En **Ajustes → Apariencia** puedes ajustar el tema, la transparencia y el desenfoque para equilibrar la visibilidad del fondo con la lectura del texto.

La ventana principal puede mostrar el fondo detrás de su interfaz mientras ocupa el espacio activo a pantalla completa. Las ventanas normales y los espacios en segundo plano no mantienen esa captura continua. Si no hay un fondo de la app, se utiliza una imagen fija del fondo del sistema, que puede no coincidir con la imagen de la hora actual de un fondo dinámico de macOS.

### 3.10 Configurar el salvapantallas nativo {#screensaver}

La página **Salvapantallas** de la barra lateral gestiona su contenido por separado del fondo del escritorio. Elige un vídeo nativo, una imagen fija, una animación o una lista que los contenga. **Importar contenido para el salvapantallas…** añade archivos locales. Se excluyen los elementos web y los del reproductor ampliado. Tras importar o elegir un origen, el cuadro de confirmación muestra centrados los elementos incluidos; si hay exclusiones, incluidos y excluidos aparecen en dos columnas. Confirma las exclusiones antes de publicar. La lista original no cambia y cualquier nueva exclusión requiere otra confirmación.

La app copia el contenido publicado en `DynamicWallpaper/ScreenSaverExport`, dentro de Application Support. La página solo indica si hay contenido utilizable publicado. Si falla la sincronización, muestra el error y conserva la última copia válida. Los cambios pertinentes de la lista se sincronizan automáticamente; **Sincronizar ahora** solicita otra publicación. El contenido nuevo se aplica en el **siguiente inicio del salvapantallas** o al volver a abrir la vista previa de la app. Una instancia activa conserva su versión inicial. Borrar el archivo de origen no elimina de inmediato la copia publicada. **Borrar contenido publicado…** solo afecta al salvapantallas; las copias antiguas se recuperan cuando terminan las instancias activas.

La primera vez, pulsa **Instalar o actualizar salvapantallas…** y sigue los pasos de macOS. Después selecciona personalmente **Dynamic Wallpaper Screen Saver** en Ajustes del Sistema. **Volver a comprobar instalación** verifica el resultado, pero estar instalado no significa estar seleccionado. En el panel de configuración del salvapantallas, autoriza la carpeta de publicación que muestra la app. Este permiso independiente permite leer el contenido después de cerrar la app. Una carpeta movida, un permiso caducado o la falta de contenido publicado generan un error explícito. La vista previa de la app muestra el contenido publicado; comprueba por separado la reproducción real en macOS.

### 3.11 Fondos de escena locales {#scene}

Elige **Importar fondo → Proyecto de escena** y selecciona la carpeta con `project.json` y todos sus recursos. Los proyectos locales JSON y PKG se copian a la biblioteca y se renderizan con WebWallGL y el CEF incluido. Mantén todos los recursos dentro del proyecto.

Usa duraciones fijas. La pausa conserva el reloj de la escena y reanuda la misma instancia. Se aplican los ajustes de volumen, silencio, encuadre y frecuencia web. Activa la interacción y sus permisos para movimientos del ratón y clics izquierdos en el escritorio vacío. La vista previa acepta el ratón directamente.

Se usan las propiedades predeterminadas del autor. No se admiten el espectro de audio del sistema, la edición de escenas ni su uso en el salvapantallas nativo. La compatibilidad depende de la versión fijada de WebWallGL; los fallos de carga o renderizado muestran errores. Algunos efectos o scripts incompatibles pueden generar solo avisos, registrados en el log de CEF. No se sustituye la escena por una imagen o vídeo.

## 4. Referencia de ajustes {#settings}

Estos valores predeterminados corresponden a una biblioteca nueva. Las preferencias existentes se conservan. Los ajustes habituales se guardan y aplican inmediatamente. Los editores con un botón de guardar, como el de duración, requieren pulsarlo.

### 4.1 General {#general-settings}

| Ajuste | Opciones / valor predeterminado | Efecto y recomendación |
| --- | --- | --- |
| Idioma de la interfaz | Seguir el sistema (predeterminado), 简体中文, English, 日本語, Français, Español | Elige el idioma de la app; consulta el apartado de idiomas |
| Abrir al iniciar sesión | Activado / desactivado; una instalación nueva no lo registra inicialmente | Ejecuta la app al iniciar sesión en macOS. Si necesita aprobación, usa Abrir ítems de inicio del sistema… |
| Mostrar el icono en el Dock | Activado / desactivado; activado inicialmente | Si está desactivado, abrir una ventana de gestión muestra temporalmente el icono del Dock y los menús de la app. El icono se oculta al cerrar todas esas ventanas; minimizarlas u ocultarlas no las cierra. La preferencia guardada no cambia. No detiene la reproducción ni es un ajuste de ahorro |
| Sincronizar fondo del sistema | Activado / desactivado; desactivado inicialmente | Genera una imagen fija del fondo aplicado y la escribe como fondo del sistema. Déjalo desactivado si no necesitas esa generación y escritura de imágenes |
| Silenciar todo | Activado / desactivado; activado inicialmente | Silencia vídeo, web y vistas previas sin poner a cero los volúmenes individuales |
| Pausar en modo de bajo consumo | Activado / desactivado; desactivado inicialmente | Responde al modo de bajo consumo de macOS, no a un porcentaje concreto de batería. Útil al trabajar sin cargador |
| Pausar si el dispositivo se calienta | Activado / desactivado; activado inicialmente | Pausa cuando macOS informa de un estado térmico grave o crítico. Se recomienda mantenerlo activado |

La reproducción se pausa automáticamente al bloquear la pantalla, al entrar en reposo el sistema o la pantalla, o cuando la sesión de usuario está inactiva. No hace falta configurarlo. Solo se reanuda cuando desaparecen todas las causas automáticas; una pausa manual requiere reanudar manualmente. Consulta las causas en la barra de menús.

### 4.2 Apariencia {#appearance-settings}

| Ajuste | Opciones / valor predeterminado | Efecto y equilibrio |
| --- | --- | --- |
| Modo de apariencia | Seguir el sistema (predeterminado), Claro, Oscuro | Cambia la interfaz, no el archivo de fondo. Elige según la iluminación del entorno |
| Transparencia del fondo | 0–100 %; 75 % inicialmente | El 100 % es transparente sin desenfoque; el 0 % es opaco. Reducirla facilita leer sobre fondos complejos |
| Estilo de desenfoque | Transparente, Esmerilado (predeterminado) | Se usa por debajo del 100 % de transparencia. Esmerilado separa mejor el contenido del primer plano |
| Frecuencia del fondo en pantalla completa | 30 Hz (predeterminado), 60 Hz | Controla la captura del fondo de la app a pantalla completa, no el límite de fps del vídeo del escritorio. 60 Hz es más fluido, pero necesita más procesamiento |

La opción **Reducir transparencia** de macOS tiene prioridad para facilitar la lectura. No sobrescribe los valores de transparencia y desenfoque guardados en la app.

### 4.3 Archivos, Avanzado y Acerca de {#other-settings}

| Panel | Contenido | Utilidad |
| --- | --- | --- |
| Archivos | Explicación de las copias independientes, respaldo y vaciado de la biblioteca, última copia de la configuración y cantidad de limpiezas pendientes | Gestiona contenidos y su limpieza sin cambiar los originales ni los ajustes de la app |
| Avanzado | Nombre del archivo de configuración, versión del formato, ruta completa y Mostrar en Finder | Información de solo lectura para localizar y respaldar la configuración |
| Acerca de | Nombre, versión y descripción de la app | Permite comprobar la versión utilizada |

Para empezar con una biblioteca vacía:

1. Abre **Ajustes → Archivos** y pulsa **Respaldar y vaciar la biblioteca…**. No se puede vaciar durante una importación.
2. Confirma la eliminación de contenidos, incluidos los favoritos, listas y asignaciones de pantalla. Los ajustes de la app, los originales y las imágenes del sistema sincronizadas no cambian.
3. Solo después de crear el respaldo se vacían los registros y se eliminan las copias gestionadas. En **Última copia de la configuración**, consulta la ruta o muestra la copia en Finder.

El respaldo solo contiene JSON, no contenidos, y no puede restaurar copias eliminadas. Si una conversión relacionada sigue usando el contenido, espera a que termine, o cancélala y espera a que libere los recursos antes de intentarlo de nuevo; las tareas no relacionadas no se ven afectadas. Los fallos de limpieza muestran un error y conservan un registro pendiente para reintentarlo en el siguiente inicio.

Si un contenido desaparece de la biblioteca pero su archivo sigue en el disco, revisa la cantidad de limpiezas pendientes y los detalles del error en **Archivos**. Es posible que la carpeta gestionada se haya sustituido o ya no coincida con el registro de la app, por lo que se rechaza su eliminación. Eso no significa que se haya borrado el original. Identifica la copia restante antes de actuar; no vacíes toda la carpeta de contenidos.

### 4.4 Idioma y formato regional {#language-settings}

1. Abre **Ajustes → General → Idioma de la interfaz**.
2. Elige **Seguir el sistema** o uno de los cinco idiomas.
3. Cuando el ajuste se guarde correctamente, la interfaz propia de la app cambiará inmediatamente. No hace falta reiniciar ni se reinicia la reproducción del fondo.

Seguir el sistema elige el primer idioma compatible según el orden de preferencias de macOS, o inglés si ninguno coincide. Los números usan el formato regional del idioma actual. Los nombres de archivos, contenidos y listas personalizadas no se traducen. Los menús y selectores de archivos proporcionados por el sistema pueden seguir usando el idioma de macOS.

Al volver a abrir la **Guía de uso** desde la app, se usa de nuevo el idioma actual de la interfaz. Elegir un idioma en la parte superior de la guía solo cambia el documento que estás leyendo.

## 5. Solución de problemas {#troubleshooting}

Primero identifica si el problema ocurre en el fondo aplicado, en una vista previa temporal o en el fondo de la ventana de la app. Empieza por las comprobaciones sencillas. Si un error ofrece **Ver detalles…**, conserva el texto para identificar el contenido o la operación afectados.

| Síntoma | Posibles causas | Comprobaciones y soluciones | Alternativa temporal |
| --- | --- | --- | --- |
| No aparece el fondo o se ve negro | Sin aplicar, pantalla incorrecta, archivo inaccesible, error de decodificación, pausa activa | ① Selecciona contenido y pantalla y vuelve a aplicar. ② Usa Mostrar en Finder para comprobar el archivo que realmente se usa. ③ Revisa las causas de pausa del menú. ④ Prueba una imagen que se pueda leer. ⑤ Consulta el error de análisis del contenido | Usa una imagen que funcione o detén el fondo de la app en esa pantalla |
| Vídeo entrecortado, pérdida de fotogramas o alto consumo | Resolución/fps elevados, varias fuentes independientes, vista previa o conversión simultánea, calor | ① Detén las vistas previas. ② Espera a la conversión o cancela una tarea innecesaria. ③ Reduce las pantallas animadas independientes. ④ Ajusta el fondo a pantalla completa a 30 Hz. ⑤ Si se ofrece Convertir, crea una versión 1080p / unos 30 fps | Pausa el fondo o usa una imagen fija y activa la pausa de ahorro |
| Cambiar el volumen no tiene efecto | Silencio global, ajuste de otro elemento o de vista previa, archivo sin audio, salida del sistema incorrecta | ① Revisa silencio global, individual y volumen. ② Confirma el elemento o pantalla actual. ③ Vuelve a aplicar tras cambiar el audio desde la biblioteca. ④ Comprueba el vídeo original y la salida de sonido de macOS | Prueba un vídeo que sepas que tiene sonido; usa Silenciar todo si necesitas silencio |
| Varias pantallas cambian juntas | Se aplicó Todas las pantallas · Sincronizadas, destino antiguo, cambio de conexiones | ① Revisa las pantallas conectadas. ② Aplica una fuente por separado a cada una. ③ Vuelve a elegir el destino tras reconectar. ④ Comprueba el grupo sincronizado | Configura una pantalla primero y después las demás |
| No carga el proyecto web | Carpeta o entrada incorrecta, recursos movidos, dependencia de red, error de script | ① Confirma que HTML/HTM está dentro de la carpeta. ② Revisa la ruta relativa. ③ Restaura los recursos. ④ Compara con una página sencilla totalmente local. ⑤ Consulta los detalles del error | Usa un proyecto con todas sus dependencias locales u otro contenido |
| El fondo web no responde a clics | Interacción desactivada, permisos ausentes o retirados, clic fuera del escritorio vacío de Finder | ① Activa Interacción web. ② Revisa Accesibilidad y Monitorización de entrada. ③ Vuelve a activar tras autorizar. ④ Prueba un clic izquierdo en una zona vacía | Reprodúcelo sin interacción |
| La lista no avanza o cambia de forma inesperada | Repetir uno, duración excesiva o sin guardar, lista vacía, siguiente elemento no disponible | ① Revisa el modo. ② Comprueba y guarda duración, unidad y repeticiones. ③ Confirma que haya elementos. ④ Comprueba el archivo realmente usado por el siguiente elemento. ⑤ Vuelve a aplicar tras corregirlo | Usa En orden y una duración fija más corta; retira manualmente el elemento problemático |
| La app no responde o se cierra | Contenido o web pesado/defectuoso, carga de conversión, configuración ilegible | ① Espera un momento si hay trabajo activo. ② Si responde, pausa, sal normalmente y vuelve a abrir. ③ Si no, fuerza la salida desde macOS y abre de nuevo. ④ Prueba una imagen sencilla. ⑤ Considera el restablecimiento de abajo solo ante un error explícito de lectura de biblioteca | Evita el contenido desencadenante. Forzar la salida interrumpe las conversiones pendientes |
| macOS informa de falta de permisos | Web sin autorizar, contenido o carpeta de salida inaccesibles, restricciones de captura a pantalla completa | ① Identifica la función del error. ② Para web, revisa Accesibilidad y Monitorización de entrada. ③ Vuelve a elegir un archivo legible o una carpeta con escritura. ④ Si una versión temprana de macOS 14 pide grabación de pantalla para el fondo a pantalla completa, revisa el permiso y reintenta | Desactiva la interacción o sal de la pantalla completa de la app y usa la reproducción normal |
| Idioma incorrecto, texto sin traducir o cambio sin efecto | Seguir el sistema, guardado fallido, nombre de contenido, algunos errores aún no localizados | ① Elige explícitamente el idioma. ② Revisa errores al guardar. ③ Abre de nuevo la ventana o ayuda. ④ Distingue texto del sistema, nombres y etiquetas de la app | Usa temporalmente otro idioma disponible. Puedes renombrar listas; la lista inicial de una biblioteca nueva puede conservar el nombre «我的播放列表» |
| El fondo del sistema no se sincroniza o permanece al detener | Sincronización desactivada o esperando aplicación, error, conservación de la última imagen | ① Revisa el interruptor y cada pantalla. ② Aplica un fondo. ③ Corrige problemas de archivos/pantallas y reintenta. ④ Para cambiar la imagen, elige otra en macOS | Desactiva la sincronización y elige el fondo del sistema. Desactivarla por sí sola no restaura la imagen anterior |
| El contenido ya no aparece en la biblioteca, pero queda una copia local | Limpieza pendiente o carpeta que no coincide con el registro de la app | ① Revisa las limpiezas pendientes en **Ajustes → Archivos**. ② Conserva el error y confirma que es una copia gestionada que no necesitas. ③ Reinicia la app para reintentar. ④ Si sigue fallando, trata solo la copia residual identificada | Conserva el archivo mientras tanto; no borres toda la carpeta de contenidos |

**Respaldar y restablecer una biblioteca que no se puede leer**

Usa esta acción únicamente si la app indica expresamente que no puede leer la biblioteca. Primero respalda la configuración existente y después borra los registros de contenidos, las listas, las asignaciones de pantalla y los ajustes de biblioteca. No elimina los archivos originales. Tendrás que importar y configurar de nuevo. Si puedes abrir los ajustes, localiza y copia antes la configuración desde **Avanzado**. Restablecer no debe ser el primer paso ante una pantalla negra o un vídeo entrecortado.

## 6. Rendimiento y consumo {#performance}

- **Prioriza la batería:** activa la pausa en modo de bajo consumo y conserva la pausa por temperatura. Pausa manualmente desde el menú cuando no necesites animación.
- **Reduce trabajo de CPU y GPU:** la CPU realiza cálculos generales y la GPU procesa gráficos. Elige resolución y fps adecuados para tus pantallas. Cuando la conversión esté disponible, el perfil 1080p puede reducir la carga de reproducción.
- **Asigna contenido según la pantalla:** un vídeo en la principal y una imagen en la secundaria suelen consumir menos que varios vídeos independientes de alta resolución. La sincronización comparte contenido, pero el número y tamaño de las pantallas siguen influyendo.
- **Evita superponer tareas:** detén las vistas previas al terminar. Pausa fondos si la conversión provoca tirones. Los fundidos procesan brevemente dos elementos; usa Instantánea para reducir ese solapamiento.
- **Ajusta el fondo a pantalla completa según el uso:** empieza con 30 Hz y elige 60 Hz solo si necesitas más fluidez en la app. No limita los fps propios del vídeo del escritorio.
- **Mantén los archivos accesibles:** usa una unidad conectada de forma estable y recursos web locales. Deja desactivada la sincronización de imágenes del sistema si no la necesitas.

## 7. Atajos y gestos {#shortcuts}

| Acción | Atajo o gesto | Dónde se usa |
| --- | --- | --- |
| Importar fondo | `⌘O` | Menú de la app |
| Mostrar u ocultar barra lateral | `⌃⌘S` | Ventana principal |
| Salir de la app | `⌘Q` | Menú; confirma si quedan conversiones sin terminar |
| Ejecutar la acción predeterminada | Retorno | Diálogos con botón predeterminado |
| Cancelar o cerrar una explicación | Esc | Diálogos correspondientes y ayudas con interrogación |
| Abrir la explicación de un control | Enfoca el botón de ayuda y pulsa Espacio o Retorno, o haz clic | Controles con botón de ayuda |
| Reordenar lista | Arrastrar elementos o pulsar flechas de subir/bajar | Lista, fuera de selección múltiple |
| Importar contenido | Arrastrar archivos | Ventana principal |
| Abrir menú contextual | Clic derecho o clic con dos dedos | Contenidos o listas |

`⌘` significa Comando y `⌃` significa Control. Puedes reproducir, pausar y pasar al siguiente fondo desde la barra de menús.

## 8. Información de versión {#version}

| Elemento | Información |
| --- | --- |
| App | Dynamic Wallpaper |
| Versión | v0.3.0, compilación 3 |
| Alcance de la guía | Operaciones, ajustes, efectos sobre los datos y solución de problemas de la app actual |

Consulta **Ajustes → Acerca de** para comprobar la versión instalada. Esta guía se incluye en la app y funciona sin conexión.

## 9. Apéndice {#appendix}

### 9.1 Glosario {#glossary}

| Término | Significado |
| --- | --- |
| Biblioteca | Registros y copias independientes guardadas al importar |
| Elemento de lista | Una incorporación a la lista; el mismo contenido puede tener varios elementos independientes |
| Grupo sincronizado | Pantallas que comparten fuente y estado de reproducción |
| Fondo aplicado / vista previa vinculada | El primero se guarda como ajuste de pantalla; la segunda es temporal y recupera el fondo anterior al terminar |
| Fondo del sistema | Imagen de macOS situada bajo la capa animada de la app |
| Conversión o transcodificación | Recodificar vídeo en otro formato y crear un archivo nuevo |
| Archivo de entrada | Primer archivo HTML que se abre en un proyecto web local |
| Liquid Glass | Material de interfaz con aspecto de cristal de macOS 26 |

### 9.2 Formatos compatibles {#formats}

| Tipo | Extensiones |
| --- | --- |
| Vídeo | MP4, MOV, M4V, MKV, WebM, AVI |
| Imagen fija | JPEG/JPG, PNG, HEIC, HEIF |
| Animación | GIF, APNG |
| Web local | HTML, HTM; importados mediante la carpeta de un proyecto web |

La extensión indica el tipo de archivo, pero no garantiza que se reproduzcan todos los códecs que pueda contener. Usa el resultado del análisis de la app para el archivo concreto. Cambiar la extensión no cambia la codificación del vídeo.

### 9.3 Sistema e idiomas {#requirements}

- Sistema: macOS 14.0 o posterior.
- Procesador: Apple Silicon (arm64).
- Las necesidades dependen de las dimensiones, los fps, la complejidad de la página y el número de pantallas. Elige contenidos acordes con la carga.
- Idiomas: 简体中文, English, 日本語, Français, Español.

### 9.4 Ubicaciones y datos guardados {#data}

Para localizar la configuración, abre **Ajustes → Avanzado** y usa **Mostrar en Finder**. No muevas ni sustituyas manualmente las carpetas de contenidos gestionadas por la app. Las imágenes del sistema sincronizadas también se guardan por separado.

Se guardan los registros de contenidos, favoritos, listas, asignaciones de pantalla, preferencias y limpiezas pendientes. Las búsquedas, selecciones múltiples, vistas previas temporales, pausas manuales y colas de conversión sin terminar no se conservan tras reiniciar. Una copia de configuración no incluye contenidos ni permite recuperar copias eliminadas; conserva los originales o respalda por separado los contenidos gestionados.
