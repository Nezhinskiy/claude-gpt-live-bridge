<p align="center"><a href="../../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.hi.md">हिन्दी</a> · <b>Español</b> · <a href="README.fr.md">Français</a> · <a href="README.ru.md">Русский</a> · <a href="README.uk.md">Українська</a></p>

<p align="center"><img src="../../site/assets/icon.png" alt="Icono de la aplicación LiveBridge" width="144"></p>

<h1 align="center">LiveBridge</h1>

<p align="center"><strong>Habla por voz con una sesión abierta de Claude Code.</strong></p>

<p align="center">
  <a href="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml"><img src="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/getLiveBridge/LiveBridge"><img src="https://api.scorecard.dev/projects/github.com/getLiveBridge/LiveBridge/badge" alt="OpenSSF Scorecard"></a>
  <a href="https://www.bestpractices.dev/projects/16502"><img src="https://www.bestpractices.dev/projects/16502/badge" alt="OpenSSF Best Practices"></a>
  <a href="../../LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="Licencia: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B%20%C2%B7%20Apple%20Silicon-lightgrey.svg" alt="Plataforma: macOS 14+ en Apple Silicon">
</p>

<p align="center">
  <a href="https://getlivebridge.com">getlivebridge.com</a> ·
  <a href="#inicio-rápido">Inicio rápido</a> ·
  <a href="#instalación">Instalación</a> ·
  <a href="#uso">Uso</a> ·
  <a href="#facturación-bajo-control-por-diseño">Facturación</a> ·
  <a href="#privacidad">Privacidad</a> ·
  <a href="#limitaciones-conocidas">Limitaciones</a> ·
  <a href="#hoja-de-ruta-y-ayuda-buscada">Ayuda buscada</a> ·
  <a href="#contribuir">Contribuir</a>
</p>

LiveBridge es una aplicación de la barra de menús de macOS que mantiene lista una línea de voz
GPT-Live a través de `codex app-server` con tu inicio de sesión de ChatGPT (sin clave de API). La
voz es la recepción: conversa, pregunta qué quieres decir y pasa el trabajo real a tu sesión de
Claude Code mediante un pequeño mod de Claude Code, `livebridge`. Claude hace el trabajo con su
propio modelo, sus herramientas y su modo de permisos, y la voz te cuenta el resultado. No hace
falta mantener la línea abierta mientras Claude trabaja: su respuesta vuelve a abrir la línea
cerrada y pasa a la voz para que la diga. La voz también sigue lo que escribes en la sesión y lo que
responde Claude, así que puedes alternar entre hablar y escribir.

*El texto en inglés es el canónico ([README.md](../../README.md)); esta traducción puede ir por detrás.*

**Una conversación, no un dictado.** GPT-Live escucha mientras habla: interrúmpelo y se detiene para oírte; piensa en voz alta y puede soltar un breve «ajá». **Dejas de pagar por el silencio:** OpenAI cobra la voz por minuto, así que tras un rato de silencio que fijas en [Ajustes](#ajustes) la línea se cierra y se abre de nuevo cuando hablas, con la conversación donde la dejaste ([Facturación](#facturación-bajo-control-por-diseño)).

<p align="center"><img src="../assets/readme-demo.gif" alt="Hablando con una sesión de Claude Code a través de LiveBridge" width="100%"></p>

**Local por diseño.** Sin telemetría y sin servidor propio: LiveBridge es un puente en tu Mac
entre tu propio codex y tu propio Claude Code. La aplicación y el mod se comunican por un socket
Unix que solo tu usuario puede abrir, y la aplicación no escucha en ningún puerto de red. Además
de lo que esas dos herramientas ya envían (la línea de voz a OpenAI a través de tu codex, solo mientras está abierta, con lo que escribes en una sesión unida, y el trabajo de Claude a Anthropic a través de tu sesión de Claude Code),
el único tráfico propio de la aplicación es un codex de vida corta que, al abrir el menú, pide a
OpenAI las cifras de uso de Codex, también con la llamada apagada, y el de las
[actualizaciones](#actualización): una
consulta automática a GitHub por si hay una versión nueva (diaria, y en cada arranque mientras no
se haya instalado una que anunció), que puedes desactivar; la misma consulta cuando pulsas **Check
for update**; `gh auth status` cuando se anuncia una versión nueva; y, cuando pulsas **Install**,
la descarga, su verificación y la actualización del mod. [Privacidad](#privacidad) enumera
exactamente qué llega a OpenAI y nombra las peticiones de la aplicación a GitHub;
[SECURITY.md](../../SECURITY.md) explica de qué protege y de qué no protege.

> **No oficial.** Sin afiliación, respaldo ni soporte de Anthropic u OpenAI. Depende de la API
> experimental de tiempo real de codex, que puede cambiar con cualquier versión de codex.

## Inicio rápido

Necesitas macOS 14+ en Apple Silicon, Claude Code 2.1.301+ y [codex](https://github.com/openai/codex)
con sesión iniciada (`codex login`) en un plan de ChatGPT cuyo Codex incluya voz; para compilar la
aplicación tú mismo, también Xcode con Swift 6.0+. Los detalles están en
[Requisitos](#requisitos).

```sh
# 1. The mod, from this repository's marketplace
claude plugin marketplace add getLiveBridge/LiveBridge
claude plugin install livebridge@livebridge

# 2. The app, built from source, installed in /Applications and opened
git clone https://github.com/getLiveBridge/LiveBridge.git
cd livebridge
scripts/build-app.sh --release
```

3. En la sesión de Claude Code con la que quieras hablar, escribe `/live`.
4. Pulsa **Start** en la banda situada sobre el prompt, permite el micrófono y habla.

¿Prefieres no compilarla? Cada [versión](https://github.com/getLiveBridge/LiveBridge/releases/latest)
incluye la aplicación como imagen de disco, compilada y atestada por GitHub Actions;
[Desde la imagen de disco](#desde-la-imagen-de-disco) explica cómo comprobarla y abrirla. El mod se
instala igual en ambos casos.

Si `/live` no se encuentra en una sesión que ya estaba abierta, vuelve a abrir la sesión
([por qué](#limitaciones-conocidas)). La actualización, los permisos, cómo conservar el permiso
del micrófono entre recompilaciones y la desinstalación están en [Instalación](#instalación).

## Requisitos

- macOS 14 o posterior en Apple Silicon.
- Claude Code 2.1.301 o posterior.
- [Codex CLI](https://github.com/openai/codex) (`codex`, probado con 0.166.0), instalado con
  Homebrew (`brew install --cask codex`) o npm (`npm install -g @openai/codex`), en el `PATH` que
  tu shell define en una ventana de Terminal, y con sesión iniciada mediante `codex login` en un
  plan de ChatGPT cuyo Codex incluya voz (Plus, Pro, Business, Enterprise o Education, según los
  [precios de Codex de OpenAI](https://learn.chatgpt.com/docs/pricing)). LiveBridge rechaza un codex cuyo
  `codex features list` no pueda leer, por lo que es posible que otra versión no arranque hasta
  que se actualice LiveBridge.
- Para compilar la aplicación: Xcode con una toolchain de Swift 6.0 o posterior. Las versiones
  probadas están en [CONTRIBUTING.md](../../CONTRIBUTING.md#toolchain). La aplicación compilada funciona
  en macOS 14 o posterior.

## Instalación

El mod viene del marketplace de este repositorio (los comandos de [Inicio
rápido](#inicio-rápido)), que apunta a la etiqueta de la última versión, así que el mod que
instalas es el de esa versión. La aplicación va en `/Applications` en ambos casos: desde la imagen
de disco o compilada desde el código fuente. Desde la primera versión posterior
a 0.4.2, la imagen de disco está firmada con el Developer ID de LiveBridge y notarizada por Apple;
la 0.4.2 y las anteriores se firmaron ad hoc y no están notarizadas, y una compilación desde el
código fuente ni está firmada con el Developer ID ni notarizada.

### Desde la imagen de disco

1. Descarga
   [LiveBridge.dmg](https://github.com/getLiveBridge/LiveBridge/releases/latest/download/LiveBridge.dmg)
   de la última versión.
2. Compruébala con la [GitHub CLI](https://cli.github.com), en la carpeta donde la guardaste:

   ```sh
   gh attestation verify LiveBridge.dmg --repo getLiveBridge/LiveBridge \
     --signer-workflow getLiveBridge/LiveBridge/.github/workflows/release.yml \
     --source-ref refs/tags/vX.Y.Z --deny-self-hosted-runners
   ```

   donde `vX.Y.Z` es la etiqueta de la versión, tal como la nombra su página. Solo se supera con
   una imagen que el [flujo de trabajo de publicación](../../.github/workflows/release.yml) de este
   repositorio haya compilado a partir de esa etiqueta, en un runner alojado por GitHub, y que no
   haya cambiado desde entonces. En una versión posterior a 0.4.2, la firma Developer ID, que macOS
   comprueba por sí solo, dice quién firmó la imagen, y esta comprobación dice a partir de qué se
   compiló; en la 0.4.2 y las anteriores, cuya firma ad hoc no nombra a nadie, esta comprobación
   es la única prueba de origen de la imagen. No prueba que nadie haya revisado el código.
3. Ábrela y arrastra LiveBridge a Aplicaciones.
4. En el primer arranque, una versión posterior a 0.4.2 hace que macOS pregunte si abrir una
   aplicación descargada de internet; pulsa **Open**. La 0.4.2 y las anteriores quedan bloqueadas
   hasta que las permitas en Ajustes del Sistema > Privacidad y seguridad > **Open Anyway**.

### Con Homebrew

```sh
brew install --cask getlivebridge/tap/livebridge
```

Instala la misma imagen de disco desde el [tap propio de LiveBridge](https://github.com/getLiveBridge/homebrew-tap), que no es un cask oficial
de Homebrew. Homebrew puede pedirte primero que confíes en el tap, y macOS pregunta en el primer inicio
como se indica arriba. Después la aplicación se actualiza sola.

### Desde el código fuente

`scripts/build-app.sh --release` compila la aplicación, la instala en `/Applications` (tu cuenta
debe poder escribir ahí, como puede la de un administrador) y la abre. Ejecútalo de nuevo para
recompilar. La compilación se firma ad hoc, así que macOS vuelve a pedir el micrófono después de
cada recompilación. Para conservar el permiso, ejecuta una vez
`scripts/build-app.sh --make-signing-identity`: pregunta antes, crea un certificado de firma de
código autofirmado en tu llavero de inicio de sesión, y las compilaciones de release posteriores se
firman con él.

El marketplace fija el mod a la etiqueta de la última versión, así que una aplicación compilada
desde la rama principal funciona con el mod de esa versión. Para que coincidan, compila la
etiqueta de la versión (`git checkout vX.Y.Z`) o carga el mod de tu copia de trabajo con
`claude --plugin-dir plugin`.

Una compilación desde el código fuente busca actualizaciones por sí sola solo si lo activas en
Settings. Instalar una actualización la reemplaza por la imagen de la versión, que está firmada con el
Developer ID de LiveBridge, no con tu certificado autofirmado, así que macOS vuelve a pedir el
micrófono una vez; **Install** lo dice y pregunta antes.

### Actualización

LiveBridge actualiza la aplicación y su mod cuando pulsas **Install**, y nunca por su cuenta. Solo
se actualiza la copia en `/Applications/LiveBridge.app`; cualquier otra copia lo indica en
Settings.

- **Check for updates automatically**, en Settings (activado por defecto, desactivado en una
  compilación desde el código fuente): una vez al día, la aplicación pregunta a GitHub cuál es la
  última versión. Una más reciente se anuncia una sola vez, con una notificación cuyo **Install**
  la instala, y el menú de la barra de menús ofrece **Install LiveBridge X.Y.Z…** hasta que se
  instala, para lo cual vuelve a preguntar a GitHub en cada arranque. **Check for update**, en
  Settings, pregunta en el momento.
- **Install** necesita la [GitHub CLI](https://cli.github.com) con la sesión iniciada
  (`gh auth login`); sin ella, Install no descarga nada y enlaza a la página de la versión.
  Descarga la imagen de la versión, la comprueba con el mismo `gh attestation verify` de arriba,
  después comprueba la aplicación que contiene, y no instala nada a menos que se superen todas las
  comprobaciones. Espera mientras Claude siga con una petición de voz, actualiza el mod con
  `claude plugin marketplace update livebridge` y `claude plugin update livebridge@livebridge`,
  detiene la llamada, pone la aplicación nueva en su sitio en un solo paso y la abre.
- Después, Settings indica desde qué versión se actualizó. Si no se pudo actualizar el mod,
  muestra esos dos comandos para que los ejecutes tú. Las sesiones de Claude Code ya abiertas
  conservan el mod antiguo hasta que se reinician; Settings lista las unidas que aún lo usan.
- La descarga de la actualización no pone el atributo de cuarentena, así que macOS no debería
  detener el primer arranque de la aplicación actualizada para preguntar, como hizo tras la primera
  descarga; esto se deduce del código y aún no se ha observado. Las comprobaciones de arriba
  ocupan ese lugar ([SECURITY.md](../../SECURITY.md#what-an-update-installs)). Las versiones
  posteriores a 0.4.2 se firman con el Developer ID de LiveBridge, así que el permiso del
  micrófono debería pasar de una a la siguiente; esto se deduce de cómo macOS asocia el permiso y
  aún no se ha observado. La 0.4.2 y las anteriores se firmaron ad hoc, así que la
  primera actualización desde una de ellas vuelve a pedir el micrófono una vez, en el primer
  **Start**.

Para actualizar a mano, ejecuta `/live off` en todas las sesiones (el mod vuelve a abrir la
aplicación de `/Applications` en cuanto deja de responder), cierra LiveBridge, instala la imagen
más reciente como se indica arriba y ejecuta los dos comandos `claude plugin`.

### Permisos

El primer Start pide a macOS el micrófono. Si se denegó, la llamada se detiene con una frase y la
opción **Open Microphone Settings** del menú de la barra de menús abre Privacidad y seguridad >
Micrófono, donde permites LiveBridge. macOS vuelve a preguntar en el primer
Start tras la primera actualización desde una versión ad hoc, y tras cada recompilación desde el
código fuente firmada ad hoc (véase más arriba). Es posible que macOS también
pregunte si LiveBridge puede encontrar dispositivos en tu red local. La línea de voz necesita
también este segundo permiso; sin él, la llamada se detiene con una frase que indica dónde
permitirlo.

### Desinstalación

En la copia de `/Applications`, **Feedback & Support ▸ Uninstall LiveBridge…**, en el menú,
pregunta primero y mueve la app a la Papelera; si no puede, lo dice y no cambia nada más, y si macOS no le deja volver a poner el inicio de sesión que quitó antes, también lo dice, y cómo volver a activar **Open at login**. Luego termina la llamada abierta y cada sesión deja LiveBridge, como con la ×
del menú, así que `/live` se apaga en ella en vez de volver a abrir LiveBridge; LiveBridge quita
el inicio de sesión y el permiso del micrófono y se cierra, y una vez cerrado, los archivos que
guarda (los de abajo) van a una carpeta de la Papelera, hasta que la vacíes. Deja
el mod de Claude Code y copia el comando que lo quita, `claude plugin uninstall livebridge@livebridge`,
para que lo ejecutes en Terminal. Una sesión que no estaba abierta entonces puede volver a
buscar LiveBridge cuando se abra; quitar el mod lo termina.

¿Lo instalaste con Homebrew? `brew uninstall --cask getlivebridge/tap/livebridge` quita la app y el registro de Homebrew;
los pasos de abajo siguen siendo para los archivos que guarda la app.

Desde un clon, `scripts/build-app.sh --uninstall` elimina `/Applications/LiveBridge.app`, sea cual
sea la forma en que se instaló, su elemento de inicio de sesión y todos los archivos que conserva, e
imprime los dos comandos que deja de tu mano: `tccutil reset Microphone com.getlivebridge.livebridge`
y `claude plugin uninstall livebridge@livebridge`.

Sin un clon, desactiva **Open at login** en los Ajustes de LiveBridge, cierra LiveBridge y ejecuta
los mismos pasos en Terminal:

```sh
rm -rf /Applications/LiveBridge.app ~/Library/Application\ Support/LiveBridge \
  ~/Library/{Caches,WebKit}/com.getlivebridge.livebridge \
  ~/Library/HTTPStorages/com.getlivebridge.livebridge{,.binarycookies} \
  ~/Library/Preferences/com.getlivebridge.livebridge.plist
tccutil reset Microphone com.getlivebridge.livebridge
claude plugin uninstall livebridge@livebridge
```

Ninguna de estas formas elimina una copia llamada `/Applications/.LiveBridge-update-….app`, que
puede dejar una actualización interrumpida a mitad de la instalación. La aplicación elimina esas
copias en su siguiente arranque; tras desinstalar, bórrala a mano si existe.

`claude plugin uninstall` puede dejar la instantánea del mod,
`~/.claude/plugins/store/livebridge_*.json`: la documentación de Claude Code sobre lo que borra no
nombra ese archivo, y esto no se ha ejecutado. Bórralo a mano si está ahí.

## Uso

### Comandos

En la sesión de Claude Code con la que quieras hablar:

| Comando | Qué hace |
|---|---|
| `/live` | Se une a LiveBridge con el título de la sesión y abre la aplicación si no se está ejecutando. En una sesión ya unida devuelve la banda y responde en una línea: la llamada, el destino, los resultados sin escuchar, los minutos de hoy. |
| `/live off` | Sale de LiveBridge. |

El comando es `/live` y no `/voice` porque `/voice` es el modo de voz propio de Claude Code. Que lo
que escribes en una sesión quede fuera de la voz mientras la llamada está detenida no es un comando: es un
único ajuste para todas las sesiones, en la ventana de [Ajustes](#ajustes) de LiveBridge.

### La banda y el menú

Pulsa **Start**, en la banda situada sobre el prompt o en el menú de la barra de menús, y habla.

- **El Start de la banda** convierte su sesión en el destino e inicia la llamada; la línea que abre
  recibe la conversación de la sesión, y carga además un resumen cuando a la voz le faltaría parte
  de ella (mira **Load context** abajo), pero con **Pause sync** activado o tras una pausa solo si aún no tiene ninguno
  ([detalles](../../docs/architecture/overview.md#when-the-app-asks)). Con un mod de esta versión, el resumen
  se pide al pulsar Start y al cambiar el destino durante la llamada, y la línea lo espera antes de
  conectar, como mucho 10 segundos desde la petición: lo que digas mientras tanto se guarda en el Mac
  y llega a la voz al abrirse la línea. Stop o un cambio de destino durante la espera descartan lo
  guardado, y también una reconexión tras cambiar **Connect over TCP**, que guarda como mucho los
  últimos 2 segundos para la línea que vuelve a abrirse. Mientras la llamada habla con otra sesión,
  la banda muestra **Talk here**. Si la banda no aparece en una sesión unida, `/live` la
  recupera.
- **El menú de la barra de menús** contiene la llamada, las sesiones unidas (haz clic en una para
  convertirla en el destino), **Load context**, la **Conversation** del destino tal como la
  conserva LiveBridge (con una línea **Task** por cada petición que la voz pasó a Claude y una línea **Loaded context** donde se cargó un resumen), los
  límites de uso, los minutos, **Quick Settings** (elementos con marca de verificación para
  **Connect over TCP**, **Play sounds for requests and answers**, **Notify when a result is waiting**, **Pause sync while the call is stopped** y **Load a session's context on its first call**),
  **Settings…**, **Feedback & Support** (**Report a Bug…** abre el formulario de informe de errores
  del repositorio, **LiveBridge Website** abre getlivebridge.com, **Star LiveBridge on GitHub** abre
  la página del repositorio, y luego **Debug Mode** y **Show Debug Files…**, el interruptor y la
  carpeta del [modo de depuración](#ajustes), y **Uninstall LiveBridge…** ([Desinstalación](#desinstalación))) y **Quit LiveBridge**. Quick Settings está ahí incluso cuando el menú
  muestra solo la llamada. Durante una llamada, **Conversation** muestra tus palabras y
  las de la voz a medida que codex las transcribe, así que las tuyas pueden aparecer un momento después
  de decirlas y las de la voz un momento antes de oírlas. Cuando cada frase termina, su texto final
  las sustituye. Solo se conserva el texto final: las palabras que aún lo esperan cuando se cierra la
  línea se pierden.
- **Mute** (junto a **Stop**, en la banda y en la tarjeta de llamada del menú; **Unmute** mientras
  está silenciado) libera tu micrófono mientras la llamada continúa: una respuesta de Claude sigue
  abriendo la línea y pasa a la voz para que la diga. La banda mantiene la fase y añade `· muted`;
  el menú dice "Muted — line closed" mientras no hay línea abierta. Mute no cierra la línea: una
  línea abierta se cierra tras el silencio habitual, contado desde Mute si estabas hablando, y
  cuando lo habría hecho sin Mute si la línea ya estaba en silencio; se factura como cualquier
  silencio, así que Mute no ahorra minutos de tiempo real. **Unmute** vuelve a tomar el micrófono y,
  si no puede (denegado, ocupado, ausente), la llamada termina con el motivo. **Stop** termina la
  llamada y **Mute**; el siguiente **Start** empieza sin silenciar. Mute no es un cerrojo: cualquier
  proceso que se ejecute como tú puede quitarlo
  ([SECURITY.md](../../SECURITY.md#who-can-drive-the-bridge)).
- **Load context** solo está habilitado cuando a la voz le falta parte del destino: no hay resumen y **Pause sync** impide que la siguiente línea lo cargue o el último pedido falló (hasta el siguiente turno de la sesión o el siguiente Start),
  un turno no llegó, una pregunta o un aviso de permiso no llegó a la aplicación, hubo turnos con el
  mod apagado, las líneas desde el resumen ya no caben en lo que la voz puede llevar (una
  conversación larga lo supera), la sesión estuvo en pausa y tiene resumen, o su mod no sincroniza. En otro caso el
  elemento dice **Context up to date** y está deshabilitado, porque la voz ya tiene la conversación.
  Sin línea abierta, cuando la siguiente línea va a cargar el resumen y no falta nada más, dice **Context loads with the line** y está deshabilitado, porque
  la siguiente línea lo pide sola. Mientras un resumen del destino está en camino, lo haya pedido
  quien sea, dice **Loading context…** y está deshabilitado, como mucho el tiempo que el mod le da ([cuánto](../../docs/architecture/overview.md#its-time); con un mod anterior sigue en **Load context**); uno que llega muestra **Context loaded**
  un momento, y una respuesta vacía vuelve a **Load context**. Un resumen no lleva fecha, así que uno puede ignorarse con el elemento aún habilitado
  ([BR-002](../../docs/bugs/BR-002.md)).
- **New conversation…** borra la conversación del destino y su contexto cargado, y la × de una
  sesión la elimina y borra la suya; ambas preguntan antes. La voz empieza de cero la próxima vez
  que se abre la línea. Los resultados que aún no ha dicho se quedan y se añaden de nuevo; solo
  **Stop** los borra. Las preguntas de Claude en espera siguen otras reglas
  ([detalles](../../SECURITY.md#residual-risk-by-design)). Con **Load a session's context on its first call** activado, o con **Pause sync** desactivado y la sesión sin
  pausa, la siguiente línea carga por sí sola un resumen de la misma transcripción de la sesión, que
  incluye el texto de la conversación (una app y un mod de esta versión dejan fuera la salida de las herramientas, el razonamiento y los recordatorios, pero no el texto que los cita, y uno anterior envía la petición entera); para evitarlo, haz `/clear` en la sesión antes y luego pulsa **New
  conversation**. `/live` en una sesión eliminada la une de nuevo.

### Ajustes

**Settings…** abre la ventana Settings de LiveBridge, en cuatro pestañas en su barra de
herramientas.
**Quick Settings**, en el menú, reúne cinco de sus interruptores ([el menú](#la-banda-y-el-menú)):
cada elemento es el propio ajuste, así que un cambio en un sitio se ve al instante en el otro, y
pregunta lo mismo que el interruptor de aquí.
**General** reúne las notificaciones, el inicio de sesión, las actualizaciones y el modo de
depuración:

- **Notify when a result is waiting** (activado por defecto): junto con el timbre para un resultado
  que espera mientras la línea está cerrada, una notificación de macOS nombra la sesión ("Alpha has
  a new result — speak to hear it"), nunca el resultado en sí. Al hacer clic en ella se abre el
  menú de la barra de menús.
- **Open at login** (desactivado por defecto).
- **Updates**: la versión en uso, **Check for update**, **Check for updates automatically** y lo
  que hizo la última actualización ([Actualización](#actualización)).
- **Debug mode** (desactivado por defecto): durante una llamada, una fila por segundo con los
  números de red de la voz (paquetes perdidos y descartados, jitter, muestras ocultadas, si la línea
  va por TCP), un CSV por llamada, en `~/Library/Application Support/LiveBridge/debug/call-stats/`;
  ni audio, ni transcripción, ni nombres de sesión. Activado durante una llamada, registra la línea
  abierta desde ese momento; desactivado, se detiene al instante, y los archivos quedan hasta que
  los borres. **Show Debug Files** abre la carpeta. En el menú es **Debug Mode**, en **Feedback &
  Support** ([cómo leer los números](../../CONTRIBUTING.md#reading-debug-modes-numbers)).

**Voice** reúne lo que oyes durante una llamada:

- **Voice**: una de las voces en tiempo real que ofrece tu codex, que codex enumera al abrir esta
  pestaña, o **Codex default**. Se oye a partir de la próxima vez que se abre la línea.
- **Prompt** (vacío por defecto): tus propias instrucciones para la voz, como "Háblame en español",
  hasta 2000 caracteres. Se añaden después de las reglas propias de LiveBridge para la voz, que
  prevalecen donde ambas discrepan, y se aplican a partir de la próxima vez que se abre la línea.
- **Play sounds for requests and answers** (activado por defecto): un sonido breve por cada petición que
  la voz pasa a Claude ([por qué](#limitaciones-conocidas)) y por cada respuesta, fallo o pregunta
  de Claude que llega a una línea abierta o abriéndose mientras nadie habla. El aviso de un
  resultado en espera suena de todos modos.

**Line** reúne cuánto sigue abierta la línea en silencio y cómo se conecta:

- **Silence before the line closes** (20 segundos por defecto), **Wait for a first word on a line
  a result opened** (5 segundos) y **Sound without words before the line closes** (90 segundos):
  cuánto tiempo mantiene abierta la línea cada tipo de silencio, de 0 a 300 segundos. 0 desactiva
  el silencio o el sonido sin palabras, y una espera de primera palabra en 0 dura lo mismo que el
  silencio. Con los tres en 0, el silencio nunca cierra la línea: sigue abierta, facturada todo ese
  tiempo ([Facturación](#facturación-bajo-control-por-diseño)), hasta que pulsas Stop, cambias el
  destino u OpenAI la cierra. Un silencio corto cierra la línea dentro de las pausas normales, y cada
  reapertura tarda unos segundos antes de que la voz responda, así que Settings avisa de 1 a 9
  segundos; lo mismo hace con el sonido sin palabras, pues tu habla cuenta como tal hasta que se
  reconoce, y de 1 a 3 segundos para la primera palabra, ya que la voz suele empezar unos 2 segundos
  después de que la línea se conecta. Un temporizador que activas empieza enseguida en una línea
  abierta en silencio; uno que ya cuenta conserva su tiempo.
- **Connect over TCP** (desactivado por defecto): si la voz se corta con una conexión mala,
  actívalo. La línea prefiere entonces la ruta TCP que ofrece el servidor de medios (el puerto 443
  en las respuestas vistas) a UDP, y aún puede volver a UDP. En una conexión con pérdidas eso puede
  convertir los cortes en pausas breves entre frases ([hasta dónde está probado](#limitaciones-conocidas)).
  Una línea abierta cuando lo cambias se cierra y se vuelve a abrir en el acto, tras confirmarlo; lo
  que la voz estaba diciendo se corta, y un resultado que la línea esperaba llega igualmente a la
  nueva.

**Context** reúne cómo llegan tus sesiones a la voz:

- **Pause sync while the call is stopped** (desactivado por defecto): por defecto, lo que escribes
  en una sesión unida y la respuesta final de Claude se guardan en la conversación de esa sesión con
  la voz aunque la llamada esté detenida, y la voz los tiene cuando se abre la siguiente línea. Nada
  de ello llega a OpenAI hasta que se abre una línea. Para un texto que no quieres que llegue a OpenAI, activa
  el ajuste, desactiva el siguiente si la sesión puede no tener resumen aún, pulsa Stop y escribe después: nada de lo que escribes con la llamada detenida se
  registra, y la sesión queda marcada como en pausa. Mientras está activado, ninguna línea carga un
  resumen por sí sola, ni tampoco después de una pausa, salvo para una sesión sin resumen (el ajuste
  siguiente); si no, solo lo hace **Load context**. Ese resumen se escribe a partir de la transcripción, así que lleva lo que pausaste. Escribir en un turno que ejecuta una petición por voz hace fallar su respuesta, sin que
  nada de ella se registre ni se diga. No elimina nada ya registrado, y las respuestas posteriores
  de Claude pueden repetir el texto en pausa; qué hace y qué no hace lo explica
  [SECURITY.md](../../SECURITY.md#residual-risk-by-design).
- **Load a session's context on its first call** (activado por defecto; desactivado si **Pause sync** estaba activado al actualizar):
  Start, un cambio de destino durante la llamada o una línea que se abre, para una sesión de la que
  la voz no tiene resumen, lo pide aunque **Pause sync** esté activado o la sesión esté en pausa,
  también en un chat antiguo o tras **New conversation**. Ese resumen se escribe a partir de la transcripción, así que lleva lo que pausaste, y va a
  OpenAI. Cuando la sesión ya tiene resumen, la pausa rige lo que sigue.
  Desactivado, bajo la pausa solo **Load context** carga un resumen.
- **Summary model** (Haiku 5.5 por defecto, también al actualizar; o Sonnet 5.5, Opus 5.5 o **Custom…**): el
  modelo que escribe el resumen que la voz recibe como contexto, siempre con esfuerzo bajo, a cargo
  de tu uso de Claude. Si otro modelo falla, lo escribe Haiku 5.5, salvo que a ese modelo se le acabara el tiempo. Una línea debajo dice cuándo el
  último resumen vino de Haiku 5.5, o de ningún modelo, y por qué. Una sesión con un mod anterior a
  este ajuste lo ignora y escribe con el modelo propio de la sesión. **Custom…** toma un id de
  modelo y **Check and save**, que hace que una sesión unida envíe a ese modelo una petición corta
  ("Reply with OK.") a cargo de tu uso de Claude, y guarda el id solo si responde; si no, el motivo
  aparece junto al campo y la elección anterior sigue. Necesita una sesión con un mod de esta
  versión y habla por el Claude Code de esa sesión: otra sesión puede diferir, y un id guardado no
  se vuelve a comprobar.

### Qué hace la voz

- Responde ella misma a la charla trivial y a las explicaciones, y pasa todo lo que necesita el
  repositorio o la sesión: tareas, preguntas sobre el código, decisiones, correcciones y
  detenciones.
- Antes de pasar algo destructivo o dirigido al exterior (borrar, hacer push, publicar, enviar,
  desplegar, pagar), repite la petición y pregunta "¿sí?". Es un hábito que se le indica a la voz
  mantener, no una salvaguarda; [SECURITY.md](../../SECURITY.md) explica qué sí lo es.
- Lee los resultados en una o dos frases, con el nombre de la sesión. Los bloques de código y las
  tablas se quedan en la sesión, y las credenciales que reconoce se ocultan.
- Vuelve cuando Claude termina. No hace falta mantener la línea abierta: se cierra cuando la
  conversación se calla, y la respuesta de Claude a tu petición vuelve a abrirla y se da a la voz
  para que la diga, así que puedes irte mientras Claude trabaja. Esto vale para la sesión con la que
  hablas; un resultado de otra sesión suena con un timbre y queda en espera ([cómo se
  factura](#facturación-bajo-control-por-diseño)). Si la voz se queda callada en la línea reabierta,
  la respuesta también suena con un timbre y queda en espera, así que no se pierde. Una pregunta que
  Claude te hace o una solicitud de permiso que espera abre la línea igual, pero la voz puede no
  decirla: no confíes en ello cuando estés lejos del Mac ([limitaciones
  conocidas](#limitaciones-conocidas)).
- Cuando Claude hace una pregunta, se da a la voz para que te la plantee, y tu respuesta vuelve a
  esa sesión. Lo mismo ocurre con una pregunta que Claude plantea mientras trabaja (el diálogo con
  opciones): la voz la recibe para hablarte de ella, explicar las opciones con sus propias palabras
  y comentarlas contigo todo el tiempo que quieras, sin preguntar a Claude. Lo que decidas, una
  opción o una pregunta de vuelta a Claude, responde al diálogo; también puedes responderlo en el
  teclado. El trabajo que Claude termina más tarde en segundo plano pasa a la voz como una
  actualización.
- Cuando Claude está esperando una solicitud de permiso, la voz recibe un aviso y puede decirlo,
  salvo [donde una organización administra Claude Code](#limitaciones-conocidas). Tú respondes a la
  solicitud en Claude Code; LiveBridge nunca la responde por ti.
- Recibe lo que escribes. Mientras una sesión está unida, lo que escribes en ella y la respuesta
  final de Claude a cada turno que no fue una petición por voz pasan a la conversación de esa sesión
  con la voz como contexto: no suena ningún aviso por ellos ni abren una línea cerrada ([los límites
  de esto](#limitaciones-conocidas)). Una línea abierta los recibe de inmediato; una línea que se
  abre después empieza con ellos. Una respuesta por voz que una petición más nueva desplazó no se
  dice, pero se guarda y se añade igual. El texto de Claude a mitad de turno no se sincroniza, salvo
  lo que escribió justo antes de una pregunta o una solicitud de permiso, que va con ella; los
  subagentes y la salida de las herramientas tampoco. Una pregunta o una solicitud de permiso en el
  destino se da a la voz, sea cual sea el turno que la causó; en otra sesión va como iría un
  resultado de ella, salvo que la de un turno que no fue una petición por voz solo se registra. Un
  turno que la pausa deja fuera no tiene nada de esto. Cuando una pregunta o una solicitud se
  resuelve sin la voz, o un turno termina sin respuesta, la voz recibe una línea que lo dice ([qué
  líneas](../../SECURITY.md#what-session-text-can-do)).

## Facturación bajo control por diseño

Una sesión de voz en tiempo real cuesta mientras está abierta, así que LiveBridge la abre solo
mientras alguien habla, mientras todavía puede llegar la respuesta de Claude a una petición que
acabas de hacer, o para decir esa respuesta, una pregunta de Claude o que Claude espera tu
permiso:

- Mientras hay una llamada en curso y nadie habla, el micrófono alimenta únicamente un detector de
  voz en tu Mac. No se envía audio a ninguna parte.
  Mientras está silenciado, LiveBridge no tiene el micrófono, y el indicador de micrófono de macOS lo muestra.
- Cuando empiezas a hablar, se abre la línea. Los 2 segundos anteriores a que empezaras se
  conservan y se envían primero, para que no se pierdan tus primeras palabras.
- La línea se cierra tras un rato de silencio, y el sonido sin palabras (música, una tele) la cierra
  tras un rato propio. [Ajustes](#ajustes) fija cada uno; en 0, ese no la cierra.
- Cuando la voz pasa una petición a Claude (un traspaso), la línea permanece abierta hasta 2 minutos
  después de ese traspaso, facturada como cualquier línea abierta, y la respuesta de Claude pasa a
  la voz para que la diga cuando nadie esté hablando. Un traspaso posterior reinicia los 2 minutos;
  un intercambio que no envía nada a Claude se cierra tras el silencio habitual.
- La respuesta de Claude a una petición que le diste a la sesión con la que hablas, una pregunta que
  Claude te hace en ella o una solicitud de permiso que espera vuelve a abrir la línea si llega con
  la línea cerrada, y se da a la voz para que la diga, con el coste de cualquier línea abierta. Todo
  lo demás que llega con la línea cerrada (cualquier cosa de una sesión de la que cambiaste, una
  actualización posterior) reproduce un timbre y queda en espera: la banda y el menú lo muestran
  como sin escuchar, y pasa a la voz la próxima vez que hables ([cuándo se considera
  escuchado](../../docs/architecture/overview.md#a-result-while-the-line-is-closed)).
- Cada sesión de Claude Code tiene su propia conversación con la voz. Se traslada a la siguiente
  sesión en tiempo real, y a través de Stop y Start, de modo que la voz recuerda lo que dijiste hace
  un minuto. Un nuevo destino cambia la conversación: una línea abierta se cierra, y tus siguientes
  palabras la abren con la conversación del nuevo destino.
- El menú muestra los minutos que la línea estuvo abierta, contados por la aplicación desde que la
  voz se conecta, así que tu plan puede contar algo más. OpenAI cobra la voz de escritorio por
  minuto de tu presupuesto de uso de Codex, y en su API la misma familia de modelos factura también
  el silencio ([detalles](../../docs/research/2026-11-04-gpt-live-billing.md),
  [límites](../../docs/research/2026-11-05-gpt-live-limits.md)); la página de uso de tu plan es la
  autoridad.
- El menú muestra cuánto de tu uso de Codex y de Claude se ha gastado, una fila cada uno, como
  porcentaje usado de cada ventana que informa el plan (hasta tres por fila, por ejemplo
  `7% of 5 h · 19% of week`), en naranja desde el 90 %; pasa el cursor sobre una fila para ver
  cuándo se reinicia cada ventana. Las cifras de Codex se leen cada vez que se abre el menú, como
  máximo una vez por minuto, con un codex de corta vida; las de Claude llegan de una sesión unida
  cuando ya ha respondido. Una fila sin nada que mostrar se omite, y la de Codex dice `blocked`
  cuando codex informa de que el uso ordinario no está permitido. La última lectura de Codex se
  muestra enseguida y una nueva la sustituye unos segundos después, así que las cifras pueden cambiar
  con el menú abierto; justo tras el arranque la fila aparece cuando llega la primera lectura, y si
  las lecturas fallan, una lectura desaparece a los 15 minutos. Qué límite detiene primero la
  voz no está documentado ([detalles](../../docs/research/2026-11-05-gpt-live-limits.md)).

## Privacidad

LiveBridge no tiene telemetría ni escucha en ningún puerto de red; el mod habla con la aplicación
por un socket Unix en una carpeta que solo tu usuario puede abrir. Lo que va a OpenAI, a través de
la sesión en tiempo real de codex:

- el audio del micrófono mientras la línea está abierta, desde 2 segundos antes de que empezaras a
  hablar (o, en una línea que abrió una respuesta, pregunta o solicitud de permiso de Claude, desde
  que se abrió) hasta que se cierra (con Mute, LiveBridge no capta nada, así que no sale audio; lo
  que dijiste antes de pulsar Mute, en una línea que ya se estaba conectando, puede salir
  igualmente);
- las instrucciones de la voz: las reglas propias de LiveBridge y, después, el **Prompt** de tus
  Ajustes si escribiste uno;
- la conversación reciente de la sesión de destino (hasta las últimas 64 líneas, y no más de lo que
  admite codex: 128 elementos y unos 8192 tokens con el contexto y las tareas abiertas) para
  continuarla en una nueva sesión en tiempo real. Incluye lo que escribiste en esa sesión y la
  respuesta final de Claude a cada turno que no fue una petición por voz, lo iniciara lo que lo
  iniciara (un turno que escribiste, una tarea programada, otro agente, una tarea en segundo plano),
  además de las notas del mod, tu voz y la de la voz, así que escribir en una sesión lo envía a
  OpenAI cuando se abre una línea con ella. Mientras una línea está abierta, cada línea nueva del
  destino entra de inmediato. Las líneas sincronizadas de otra sesión solo salen cuando se abre una
  línea con ella como destino; sus resultados, preguntas y avisos de aprobación entran en la línea
  abierta sea cual sea la sesión;
- las peticiones de la sesión de destino aún abiertas, como sus resúmenes de una línea;
- cada resultado, pregunta, actualización, aviso de aprobación, texto escrito, respuesta a un turno
  que no fue una petición por voz, respuesta por voz que una petición más nueva desplazó y nota del
  mod, como una línea de como máximo 2000 caracteres, sin bloques de código ni tablas (un texto
  escrito que es solo código o una tabla se sustituye por una frase que dice que se escribió
  código). Las notas del mod nombran la herramienta de una solicitud de permiso permitida o
  resuelta, y dicen que se cerró una pregunta o que un turno terminó sin respuesta. Una pregunta que
  Claude hace a mitad de turno, y el aviso de aprobación de un permiso que pide el bucle principal
  de Claude (no un subagente), llevan también lo que Claude escribió justo antes de pedirlo. Una
  actualización es la respuesta de Claude en un turno posterior iniciado por la notificación de una
  tarea en segundo plano, durante hasta 10 minutos después de una petición por voz y hasta que
  empiece cualquier otro turno en la sesión;
- el resumen de contexto de la sesión de destino, como una línea de como máximo 1500 caracteres. Se
  guarda cuando se carga y se envía cada vez que se abre la línea mientras esa sesión es el
  destino, a través de Stop y Start y de los reinicios de la aplicación. El submenú Conversation del
  menú muestra esa línea exactamente como se envía;
- con cada línea anterior, la etiqueta de su sesión: el título de la sesión de Claude Code (hasta 80
  caracteres) o, si no tiene, el nombre de la carpeta de la sesión. La etiqueta no se oculta y la
  pausa no la toca, así que un título escrito a partir de texto en pausa sale en cada línea;
- la oferta WebRTC, que enumera las direcciones de red local del Mac como candidatas de conexión.

Con **Connect over TCP** activado, el audio sigue yendo al servidor de medios de OpenAI, y puede ir
por TCP (el puerto 443 en las respuestas vistas) en lugar de UDP.

Los resultados, las preguntas, las actualizaciones, los resúmenes y las líneas de los turnos escritos pasan antes por un redactor de
formatos de credenciales conocidos (claves privadas, JWT, tokens de API comunes, contraseñas en
URL, campos del tipo `password=`). Es una lista de patrones, no una garantía: todo lo demás que escribes sale tal cual.

El hilo de codex que transporta la voz es efímero y de solo lectura, con todas las funciones de
codex desactivadas salvo donde conserva tu inicio de sesión y cómo usa tu proxy, y con todos los
servidores MCP desactivados; está ahí solo para conversar. El trabajo de Claude va a Anthropic como
siempre lo hace tu sesión de Claude Code.

Al abrir el menú, LiveBridge inicia un codex de corta vida que pregunta a OpenAI, con tu inicio
de sesión de ChatGPT, cuánto de tu uso de Codex se ha gastado (el porcentaje y la hora de reinicio
de cada ventana). Ocurre como máximo una vez por minuto, también con la llamada apagada, y no
envía audio ni texto. Las cifras de Claude llegan a la aplicación desde el mod por el socket y no
van a ningún otro sitio; la aplicación guarda ambas solo en memoria.

Para las actualizaciones, la aplicación se comunica con GitHub. Con **Check for updates
automatically** activado, una vez al día (y en cada arranque mientras no se haya instalado una
versión que anunció) pregunta a la API de GitHub, sin credenciales, cuál es la última versión;
GitHub ve la dirección IP de tu Mac. **Check for update**, en Settings, envía la misma petición
cuando lo pulsas. Cuando la comprobación automática encuentra una versión más reciente, la
aplicación ejecuta `gh auth status` para indicar si la imagen se puede verificar. Solo cuando
pulsas **Install** descarga la imagen y ejecuta `gh attestation verify` y `claude plugin`, que se
conectan a GitHub, y a Sigstore para la raíz de confianza de `gh`, con tus propios inicios de sesión.
[SECURITY.md](../../SECURITY.md#what-leaves-the-mac) enumera cada petición.

En tu Mac, la aplicación guarda sus ajustes, el contador de uso, cuándo buscó actualizaciones por
última vez y qué versiones anunció, lo que hizo la última actualización y, para cada una de las
últimas 20 sesiones usadas, su conversación reciente (hasta 64 líneas, con lo que escribiste en ella; se registra sin llamada
salvo que actives **Pause sync**) y la última línea de contexto cargada desde ella, en `~/Library/Application Support/LiveBridge`, una carpeta que solo tu usuario puede abrir
([cómo se guarda](../../SECURITY.md#residual-risk-by-design)). Las líneas de una sesión desaparecen cuando
pulsas **New conversation** con ella como destino o la eliminas con la ×. Una sesión que se ha ido
las conserva hasta que 20 sesiones usadas después las desplazan; para borrarlas antes, ejecuta
`/live` en ella de nuevo y pulsa **New conversation**. La desinstalación las elimina todas; Uninstall LiveBridge, en el menú, las mueve a la
Papelera, y desaparecen cuando la vacías. El mod guarda una instantánea propia en el almacén de plugins de Claude Code ([qué contiene](../../SECURITY.md#residual-risk-by-design)).
**Debug mode**, desactivado por defecto, escribe los números de red de la voz durante una llamada
en un archivo de esa carpeta, y nada más ([Ajustes](#ajustes)).

[SECURITY.md](../../SECURITY.md) contiene el modelo de amenazas: en resumen, todo lo que tu micrófono
pueda oír puede convertirse en una petición que Claude ejecuta con el propio modo de permisos de la
sesión.

## Limitaciones conocidas

- **Connect over TCP** prefiere TCP pero no lo impone, y nada muestra durante la llamada qué transporte tomó
  una línea, así que una línea que volvió a UDP aún puede cortarse. La ruta se midió una vez, en
  una compilación de depuración que quitaba los candidatos UDP (ningún audio perdido en 10
  minutos); la forma que se distribuye, bajar su prioridad, eligió TCP una vez. El modo de
  depuración registra el transporte (`onTcp`) ([CONTRIBUTING.md](../../CONTRIBUTING.md#reading-debug-modes-numbers)).
- A veces la voz dice que está mirando ("On it", "Looking now") sin pasar la petición, así que a
  Claude no le llega nada: más o menos una petición de cada cinco con la regla tal como se escribió
  primero, y 0 de 20 con la regla actual, muy pocas para distinguirlo de la suerte
  ([BR-001](../../docs/bugs/BR-001.md)). También puede afirmar un trabajo que no ha hecho, como en "I'll
  take a look.", incluso a partir de líneas que solo tiene como contexto ([ADR 0001 (n),
  (o)](../../docs/adr/0001-platform-findings.md)). La aplicación emite un sonido breve cuando pone una
  petición en la cola de Claude, distinto del de una respuesta; si la voz dice que está mirando y
  ese sonido no llega, repite la petición. La aplicación no puede distinguir esa promesa de una respuesta por sus palabras, porque
  la voz habla tu idioma.
- Una pregunta de Claude, o una solicitud de permiso que espera, solo se da a la voz, y la voz puede
  no decirla; nada la obliga. Por eso no confíes en que la voz anuncie una solicitud cuando estés
  lejos del Mac: Claude puede quedarse esperando sin aviso. La solicitud sigue esperando en Claude
  Code, y es el único control; la voz no es un control, y LiveBridge nunca responde a la solicitud.
  En las comprobaciones, el aviso de permiso de un turno escrito, con la línea abierta, se dijo
  antes de la respuesta en el teclado en 0 de 3 ejecuciones, un recuento y no una tasa ([ADR 0001
  (n)](../../docs/adr/0001-platform-findings.md)). Una línea cerrada se abre para ellas solo si la
  conversación del destino tiene un turno tuyo; si no, la aplicación suena un timbre, y con la
  llamada apagada solo se registra.
- No se ha observado qué informa la aplicación de escritorio de Claude como origen de un prompt
  escrito ([ADR 0001 (m)](../../docs/adr/0001-platform-findings.md)). El mod registra un prompt como tuyo
  solo si su origen es `composer`. Si un prompt escrito allí llega de otra forma, nada de lo escrito
  allí se registra, no se marca ningún hueco, el menú dice **Context up to date** y la pausa alcanza
  menos ([detalles](../../SECURITY.md#what-session-text-can-do)).
- Un resultado que llega mientras la línea lo espera pasa a la voz como texto para decir; codex no
  tiene ninguna llamada que haga hablar a la voz de inmediato, así que el modelo decide cuándo. En
  las pruebas habló en pocos segundos. Si no lo hace, el resultado queda sin escuchar: vuelve a
  pasar a la voz con tus siguientes palabras, o suena un timbre cuando se cierra la línea.
- Cuando la respuesta de Claude vuelve a abrir la línea, la voz puede quedarse callada: ocurrió en 4
  de 14 ejecuciones medidas, una muestra pequeña ([ADR 0001
  (n)](../../docs/adr/0001-platform-findings.md)). La línea se cierra entonces cuando
  termina su espera de una primera palabra ([Ajustes](#ajustes)), y la respuesta suena con un timbre y
  queda en espera, como abajo. Cuando la voz habló, empezó en unos 2 segundos tras la conexión; una
  voz que empezara después de esa espera queda cortada.
- Cuando tus siguientes palabras reabren la línea, a veces la voz responde solo a ellas y no dice el
  resultado en espera. El resultado no se pierde: sigue esperando, suena un timbre y publica una
  notificación cuando se cierra la línea, y vuelve a pasar a la voz la próxima vez que se abre la
  línea.
- Al llegar al límite de uso de tu plan de ChatGPT, la voz se detiene hasta que el límite se
  reinicia. El menú y la banda lo dicen, con la frase de codex y su hora de reinicio cuando codex la
  da, y la llamada termina, para que hablar no abra líneas que fallan. Claude Code sigue trabajando,
  las respuestas siguen esperando y Start lo intenta una vez más. La aplicación reconoce un límite
  solo por la redacción de codex o el código de error del servicio, porque nada más lo comunica
  ([detalles](../../docs/research/2026-11-05-gpt-live-limits.md)). Un rechazo que no reconoce, como una
  línea que cae sin motivo indicado ("The voice session closed (transport_closed)."), deja la
  llamada activa, así que tus siguientes palabras lo vuelven a intentar; pulsa **Stop** hasta que el
  límite se reinicie.
- Un prompt que no se escribe en el compositor (el mensaje de un host, una tarea programada, otro
  agente y presumiblemente Remote Control) no se registra en la conversación de la voz como palabras
  tuyas, aunque sí la respuesta de Claude, y no rechaza un turno en curso bajo la pausa
  ([SECURITY.md](../../SECURITY.md#what-session-text-can-do) dice qué prompts cuentan como tuyos).
- Donde el proveedor de Claude Code (Bedrock, Vertex o Foundry) no ofrece el modelo elegido en
  **Summary model**, o la organización no lo permite, ese modelo falla y Haiku 5.5 escribe el
  resumen; donde tampoco ofrece Haiku 5.5, la voz no recibe resumen, y Settings lo dice. Antes de
  este ajuste lo escribía el modelo propio de la sesión, que funciona dondequiera que funcione la
  sesión. Que un id fijo se resuelva en esos proveedores viene de la documentación de Claude Code y
  no se ha probado.
- Una sesión que sigue con un mod anterior a esta versión, hasta que se reinicie, no se sincroniza:
  carga un resumen como una sesión a la que le faltan turnos, y ninguna pausa rechaza sus líneas
  ([qué más cambia](../../CHANGELOG.md)).
- Una sesión de Claude Code que ya estaba abierta antes de que se cargara el mod puede necesitar
  reabrirse para que `/live` funcione en ella.
- En la aplicación de escritorio de Claude, `/live` escrito en una sesión cuyo proceso de Claude Code
  aún no ha arrancado (una sesión nueva o recién reabierta) puede mostrar "/live isn't a command
  here." El comando se ejecuta igualmente. La aplicación de escritorio obtiene los comandos de esa
  sesión de una comprobación que ejecuta con los hooks desactivados, por lo que el código del mod,
  que declara `/live`, no se ejecuta ahí; una vez que la sesión está en marcha, la aplicación de
  escritorio toma la lista de la propia sesión. El mod no tiene arreglo para esto: un archivo de
  comando estático se listaría como `/livebridge:live`, no como `/live`, y con los hooks
  desactivados enviaría su texto al modelo en lugar de ejecutar el mod.
- Si una respuesta ha dicho un resultado en espera se juzga por sus palabras, con una lista de
  palabras comunes solo en inglés y ruso
  ([la regla](../../docs/architecture/overview.md#a-result-while-the-line-is-closed)). En otro idioma, un
  resultado puede contar como escuchado cuando la voz solo lo ha mencionado.
- Donde una organización administra Claude Code, nada en LiveBridge te avisa de que hay una
  solicitud de permiso esperando. El guardián integrado de Claude Code se carga en un equipo con
  ajustes administrados y en una sesión iniciada con un plan Team o Enterprise, y ahí los hooks de
  permisos del mod no se ejecutan. La solicitud sigue apareciendo en Claude Code y sigue
  esperándote, pero la voz no dice nada de ella y el menú muestra a Claude trabajando,
  así que mira Claude Code si una respuesta parece tardar. `/plugin` nombra los hooks, y las
  versiones recientes de Claude Code también imprimen una línea que dice que un hook se omitió.
  Las preguntas de Claude siguen llegando a la voz. Los hooks se
  [midieron](../../docs/adr/0001-platform-findings.md) en un contenedor Linux; lo que hacen la voz y la
  barra de menús se deduce del código, y no se probó una línea real. El caso de Team y Enterprise
  viene de la documentación de Claude Code.
- Con `allowManagedHooksOnly`, `allowManagedModsOnly` o `disableAllHooks` en los ajustes
  administrados, el mod no se carga y `/live` no funciona. Un administrador puede [instalar el mod
  como propio de la
  organización](https://code.claude.com/docs/en/plugins/mods/admin#install-your-organizations-mods),
  desde una carpeta en cada equipo: entonces los hooks de permisos se ejecutan, también con los
  dos primeros ajustes ([medido](../../docs/adr/0001-platform-findings.md)). Según la documentación de
  Claude Code, activar la copia del marketplace en los ajustes administrados no basta.

## Cómo funciona

[docs/architecture/overview.md](../../docs/architecture/overview.md) describe los componentes, el
protocolo entre el mod y la aplicación, y los flujos de mensajes;
[ADR 0001](../../docs/adr/0001-platform-findings.md) recoge los hechos de la plataforma en los que se
basa el diseño.

## Hoja de ruta y ayuda buscada

Hoy LiveBridge es una aplicación de Mac, un agente de trabajo (Claude Code) y un proveedor de voz
(codex con un inicio de sesión de ChatGPT). Los tres se unen en interfaces estrechas, y cada
dirección siguiente está abierta a colaboradores. Las incidencias correspondientes llevan la
etiqueta
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22);
[CONTRIBUTING.md](../../CONTRIBUTING.md#where-to-start) indica los archivos que conviene leer primero.

- **Windows y Linux.** La aplicación de la barra de menús, su página de audio y el servidor de
  sockets están ligados a macOS; el protocolo entre el mod y la aplicación, y el propio mod, son
  portables. Un port empieza con una aplicación para la nueva plataforma que hable el mismo
  protocolo.
- **Otros agentes como agente de trabajo**, como Codex CLI, Hermes Agent o Gemini CLI: cada uno
  necesita su propio adaptador que hable el mismo protocolo que el mod de Claude Code.
- **Otros proveedores de voz**, como la OpenAI Realtime API con tu propia clave de API o la Gemini
  Live API de Google: cada uno sería otra implementación del protocolo en tiempo real de la
  aplicación.

## Contribuir

Las contribuciones son bienvenidas. Para cualquier cosa mayor que una corrección, abre antes una
incidencia para acordar el planteamiento antes de empezar el trabajo. Buenos lugares para empezar
son las incidencias
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22),
las [limitaciones conocidas](#limitaciones-conocidas) y las direcciones de la
[hoja de ruta](#hoja-de-ruta-y-ayuda-buscada) anterior.

- [CONTRIBUTING.md](../../CONTRIBUTING.md): la estructura, la toolchain, las comprobaciones
  (`scripts/check.sh`) y las convenciones.
- [Formularios de incidencias](https://github.com/getLiveBridge/LiveBridge/issues/new/choose): informa de un error o pide una función.
- [CODE_OF_CONDUCT.md](../../CODE_OF_CONDUCT.md): cómo nos tratamos aquí.
- [SECURITY.md](../../SECURITY.md): informa de una vulnerabilidad en privado, no en una incidencia
  pública.
- [CHANGELOG.md](../../CHANGELOG.md): qué cambió en cada versión.

## Créditos

El protocolo entre el mod y la aplicación se inspiró en
[claude-code-voice-mod](https://github.com/ldk00315-jpg/claude-code-voice-mod). No se copió código
ni texto de él.

## Licencia

[MIT](../../LICENSE).
