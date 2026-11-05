<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.hi.md">हिन्दी</a> · <b>Español</b> · <a href="README.fr.md">Français</a> · <a href="README.ru.md">Русский</a> · <a href="README.uk.md">Українська</a></p>

<p align="center"><img src="site/assets/icon.png" alt="Icono de la aplicación LiveBridge" width="144"></p>

<h1 align="center">LiveBridge</h1>

<p align="center"><strong>Habla por voz con una sesión abierta de Claude Code.</strong></p>

<p align="center">
  <a href="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml"><img src="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="Licencia: MIT"></a>
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
propio modelo, sus herramientas y su modo de permisos, y la voz te cuenta el resultado.

*El texto en inglés es el canónico ([README.md](README.md)); esta traducción puede ir por detrás.*

<p align="center"><img src="site/assets/demo.gif" alt="Hablando con una sesión de Claude Code a través de LiveBridge" width="100%"></p>

**Local por diseño.** Sin telemetría y sin servidor propio: LiveBridge es un puente en tu Mac
entre tu propio codex y tu propio Claude Code. La aplicación y el mod se comunican por un socket
Unix que solo tu usuario puede abrir, y la aplicación no escucha en ningún puerto de red. Además
de lo que esas dos herramientas ya envían (la línea de voz a OpenAI a través de tu codex, solo
mientras está abierta, y el trabajo de Claude a Anthropic a través de tu sesión de Claude Code),
el único tráfico propio de la aplicación es para las [actualizaciones](#actualización): una
consulta automática a GitHub por si hay una versión nueva (diaria, y en cada arranque mientras no
se haya instalado una que anunció), que puedes desactivar; la misma consulta cuando pulsas **Check
for update**; `gh auth status` cuando se anuncia una versión nueva; y, cuando pulsas **Install**,
la descarga, su verificación y la actualización del mod. [Privacidad](#privacidad) enumera
exactamente qué llega a OpenAI y nombra las peticiones de la aplicación a GitHub;
[SECURITY.md](SECURITY.md) explica de qué protege y de qué no protege.

> **No oficial.** Sin afiliación, respaldo ni soporte de Anthropic u OpenAI. Depende de la API
> experimental de tiempo real de codex, que puede cambiar con cualquier versión de codex.

## Inicio rápido

Necesitas macOS 14+ en Apple Silicon, Claude Code 2.1.289+ y [codex](https://github.com/openai/codex)
con sesión iniciada (`codex login`) en un plan de ChatGPT con voz en tiempo real; para compilar la
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

3. En la sesión de Claude Code con la que quieras hablar, escribe `/live on`.
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
- Claude Code 2.1.289 o posterior (mods).
- [Codex CLI](https://github.com/openai/codex) (`codex`, probado con 0.166.0), instalado con
  Homebrew (`brew install --cask codex`) o npm (`npm install -g @openai/codex`), en el `PATH` que
  tu shell define en una ventana de Terminal, y con sesión iniciada mediante `codex login` en un
  plan de ChatGPT que incluya voz en tiempo real. LiveBridge rechaza un codex cuyo
  `codex features list` no pueda leer, por lo que es posible que otra versión no arranque hasta
  que se actualice LiveBridge.
- Para compilar la aplicación: Xcode con una toolchain de Swift 6.0 o posterior. Las versiones
  probadas están en [CONTRIBUTING.md](CONTRIBUTING.md#toolchain). La aplicación compilada funciona
  en macOS 14 o posterior.

## Instalación

El mod viene del marketplace de este repositorio (los comandos de [Inicio
rápido](#inicio-rápido)), que apunta a la etiqueta de la última versión, así que el mod que
instalas es el de esa versión. La aplicación va en `/Applications` en ambos casos: desde la imagen
de disco o compilada desde el código fuente. En ambos casos está firmada ad hoc y no está
notarizada.

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
   una imagen que el [flujo de trabajo de publicación](.github/workflows/release.yml) de este
   repositorio haya compilado a partir de esa etiqueta, en un runner alojado por GitHub, y que no
   haya cambiado desde entonces. Es la única prueba de origen de la imagen: la firma ad hoc no
   identifica a nadie. No prueba que nadie haya revisado el código.
3. Ábrela y arrastra LiveBridge a Aplicaciones.
4. En el primer arranque, macOS bloquea la aplicación hasta que la permitas en Ajustes del Sistema >
   Privacidad y seguridad > **Open Anyway**.

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
Settings. Instalar una actualización la reemplaza por la imagen de la versión, que está firmada ad
hoc, así que el certificado autofirmado deja de aplicarse; **Install** lo dice y pregunta antes.

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
  bloquear el primer arranque de la aplicación actualizada como bloqueó la primera descarga; esto
  se deduce del código y aún no se ha observado. Las comprobaciones de arriba ocupan ese lugar
  ([SECURITY.md](SECURITY.md#what-an-update-installs)). macOS sí vuelve a pedir el micrófono en el
  primer **Start** tras una actualización, porque cada versión se firma ad hoc.

Para actualizar a mano, ejecuta `/live off` en todas las sesiones (el mod vuelve a abrir la
aplicación de `/Applications` en cuanto deja de responder), cierra LiveBridge, instala la imagen
más reciente como se indica arriba y ejecuta los dos comandos `claude plugin`.

### Permisos

El primer Start pide a macOS el micrófono. Si se denegó, la llamada se detiene con una frase y la
opción **Open Microphone Settings** del menú de la barra de menús abre Privacidad y seguridad >
Micrófono, donde permites LiveBridge. Con la firma ad hoc, macOS vuelve a preguntar en el primer
Start tras cada actualización o recompilación (véase más arriba). Es posible que macOS también
pregunte si LiveBridge puede encontrar dispositivos en tu red local. La línea de voz necesita
también este segundo permiso; sin él, la llamada se detiene con una frase que indica dónde
permitirlo.

### Desinstalación

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

Ninguna de las dos formas elimina una copia llamada `/Applications/.LiveBridge-update-….app`, que
puede dejar una actualización interrumpida a mitad de la instalación. La aplicación elimina esas
copias en su siguiente arranque; tras desinstalar, bórrala a mano si existe.

## Uso

### Comandos

En la sesión de Claude Code con la que quieras hablar:

| Comando | Qué hace |
|---|---|
| `/live on` | Se une a LiveBridge con el título de la sesión y abre la aplicación si no se está ejecutando. |
| `/live off` | Sale de LiveBridge. |
| `/live target` | Convierte esta sesión en aquella a la que la voz pasa el trabajo. |
| `/live status` (o solo `/live`) | Una línea: la llamada, el destino, los resultados sin escuchar, los minutos de hoy. |
| `/live context` | Envía a la voz un nuevo resumen de esta sesión, escrito por el modelo de la sesión. |

El comando es `/live` y no `/voice` porque `/voice` es el modo de voz propio de Claude Code. Que se
cargue también el resumen de una sesión cada vez que se abre una línea no es un comando: es un
único ajuste para todas las sesiones, en la ventana de [Ajustes](#ajustes) de LiveBridge.

### La banda y el menú

Pulsa **Start**, en la banda situada sobre el prompt o en el menú de la barra de menús, y habla.

- **El Start de la banda** convierte su sesión en el destino e inicia la llamada; con
  **Load context automatically when a line opens** activado, la línea que abre carga el resumen de la sesión
  ([detalles](docs/architecture/overview.md#components)). Mientras la llamada habla con otra
  sesión, la banda muestra **Talk here**. Si la banda no aparece en una sesión unida,
  `/live on` la recupera.
- **El menú de la barra de menús** contiene la llamada, las sesiones unidas (haz clic en una para
  convertirla en el destino), **Load context**, la **Conversation** del destino tal como la
  conserva LiveBridge, los minutos, **Star LiveBridge on GitHub** (abre la página del repositorio),
  **Settings…** y **Quit LiveBridge**.
- **Mute** (junto a **Stop**, en la banda y en la tarjeta de llamada del menú; **Unmute** mientras
  está silenciado) libera tu micrófono mientras la llamada continúa: una respuesta de Claude sigue
  abriendo la línea y la voz la dice. La banda mantiene la fase y añade `· muted`; el menú dice
  "Muted — line closed" mientras no hay línea abierta. Mute no cierra la línea: una línea abierta se
  cierra como si hubieras dejado de hablar al pulsar Mute, y se factura como cualquier silencio, así
  que Mute no ahorra minutos de tiempo real. **Unmute** vuelve a tomar el micrófono y, si no puede
  (denegado, ocupado, ausente), la llamada termina con el motivo. **Stop** termina la llamada y
  **Mute**; el siguiente **Start** empieza sin silenciar. Mute no es un cerrojo: cualquier proceso
  que se ejecute como tú puede quitarlo ([SECURITY.md](SECURITY.md#who-can-drive-the-bridge)).
- **New conversation…** borra la conversación del destino y su contexto cargado, y la × de una
  sesión la elimina y borra la suya; ambas preguntan antes. La voz empieza de cero la próxima vez
  que se abre la línea, salvo con **Load context automatically when a line opens** activado: esa
  línea vuelve a cargar un resumen de la misma transcripción de la sesión, así que desactiva el
  ajuste o haz `/clear` en la sesión antes. `/live on` en una sesión eliminada la une de nuevo.

### Ajustes

**Settings…** abre la ventana Settings de LiveBridge:

- **Voice**: una de las voces en tiempo real que ofrece tu codex, que codex enumera al abrir la
  ventana, o **Codex default**. Se oye a partir de la próxima vez que se abre la línea.
- **Prompt** (vacío por defecto): tus propias instrucciones para la voz, como "Háblame en español",
  hasta 2000 caracteres. Se añaden después de las reglas propias de LiveBridge para la voz, que
  prevalecen donde ambas discrepan, y se aplican a partir de la próxima vez que se abre la línea.
- **Load context automatically when a line opens** (activado por defecto): cada
  línea que abre la aplicación (un Start, una línea reabierta tras el silencio, la línea tras
  cambiar de destino) pide el resumen al destino y no lo espera; un único ajuste para todas las
  sesiones, que guarda la aplicación.
- **Play a sound when a request is queued for Claude** (activado por defecto): un sonido breve por
  cada petición que la voz pasa a Claude ([por qué](#limitaciones-conocidas)).
- **Notify when a result is waiting** (activado por defecto): junto con el timbre para un resultado
  que espera mientras la línea está cerrada, una notificación de macOS nombra la sesión ("Alpha has
  a new result — speak to hear it"), nunca el resultado en sí. Al hacer clic en ella se abre el
  menú de la barra de menús.
- **Open at login** (desactivado por defecto).
- **Updates**: la versión en uso, **Check for update**, **Check for updates automatically** y lo
  que hizo la última actualización ([Actualización](#actualización)).

### Qué hace la voz

- Responde ella misma a la charla trivial y a las explicaciones, y pasa todo lo que necesita el
  repositorio o la sesión: tareas, preguntas sobre el código, decisiones, correcciones y
  detenciones.
- Antes de pasar algo destructivo o dirigido al exterior (borrar, hacer push, publicar, enviar,
  desplegar, pagar), repite la petición y pregunta "¿sí?". Es un hábito que se le indica a la voz
  mantener, no una salvaguarda; [SECURITY.md](SECURITY.md) explica qué sí lo es.
- Lee los resultados en una o dos frases, con el nombre de la sesión. Los bloques de código y las
  tablas se quedan en la sesión, y las credenciales que reconoce se ocultan.
- Cuando Claude hace una pregunta, la voz te la plantea y devuelve tu respuesta a esa sesión. El
  trabajo que Claude termina más tarde en segundo plano se comunica como una actualización.
- Cuando Claude está esperando una solicitud de permiso, la voz lo dice. Tú respondes a la
  solicitud en Claude Code; LiveBridge nunca la responde por ti.

## Facturación bajo control por diseño

Una sesión de voz en tiempo real cuesta mientras está abierta, así que LiveBridge la abre solo
mientras alguien habla, mientras todavía puede llegar la respuesta de Claude a una petición que
acabas de hacer, o para decir esa respuesta, una pregunta de Claude o que Claude espera tu
permiso:

- Mientras hay una llamada en curso y nadie habla, el micrófono alimenta únicamente un detector de
  voz en tu Mac. No se envía nada a ninguna parte.
  Mientras está silenciado, LiveBridge no tiene el micrófono, y el indicador de micrófono de macOS lo muestra.
- Cuando empiezas a hablar, se abre la línea. Los 2 segundos anteriores a que empezaras se
  conservan y se envían primero, para que no se pierdan tus primeras palabras.
- La línea se cierra tras 20 segundos de silencio. El sonido sin palabras (música, una tele) la
  cierra tras 90 segundos.
- Cuando la voz pasa una petición a Claude (un traspaso), la línea permanece abierta hasta 2 minutos
  después de ese traspaso, facturada como cualquier línea abierta, y la voz dice la respuesta de
  Claude cuando nadie esté hablando. Un traspaso posterior reinicia los 2 minutos; un intercambio
  que no envía nada a Claude se cierra tras los 20 segundos habituales de silencio.
- La respuesta de Claude a una petición que le diste a la sesión con la que hablas, una pregunta
  que Claude te hace en ella o una solicitud de permiso que espera vuelve a abrir la línea si
  llega con la línea cerrada, y la voz la dice, con el coste de cualquier línea abierta. Todo lo
  demás que llega con la línea cerrada (cualquier cosa de una sesión de la que cambiaste, una
  actualización posterior) reproduce un timbre y queda en espera: la banda y el menú lo muestran
  como sin escuchar, y la voz te lo dice la próxima vez que hables
  ([cuándo se considera escuchado](docs/architecture/overview.md#a-result-while-the-line-is-closed)).
- Cada sesión de Claude Code tiene su propia conversación con la voz. Se traslada a la siguiente
  sesión en tiempo real, y a través de Stop y Start, de modo que la voz recuerda lo que dijiste hace
  un minuto. Un nuevo destino cambia la conversación: una línea abierta se cierra, y tus siguientes
  palabras la abren con la conversación del nuevo destino.
- El menú muestra los minutos que la línea estuvo abierta, medidos por la aplicación; cómo mide tu
  plan la voz en tiempo real no es público.

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
- la conversación reciente de la sesión de destino (hasta las últimas 24 líneas) para continuarla
  en una nueva sesión en tiempo real;
- las peticiones de la sesión de destino aún abiertas, como sus resúmenes de una línea;
- cada resultado, pregunta, actualización y aviso de aprobación, como una línea de como máximo 2000
  caracteres, sin bloques de código ni tablas. Una pregunta que Claude hace a mitad de turno, y el
  aviso de aprobación de un permiso que pide el bucle principal de Claude (no un subagente),
  llevan también lo que Claude escribió justo antes de pedirlo. Una actualización es la respuesta
  de Claude en un turno posterior iniciado por la notificación de una tarea en segundo plano,
  durante hasta 10 minutos después de una petición por voz y hasta que empiece cualquier otro
  turno en la sesión;
- el resumen de contexto de la sesión de destino, como una línea de como máximo 1500 caracteres. Se
  guarda cuando se carga y se envía cada vez que se abre la línea mientras esa sesión es el
  destino, a través de Stop y Start y de los reinicios de la aplicación. El submenú Conversation del
  menú muestra esa línea exactamente como se envía;
- con cada línea anterior, la etiqueta de su sesión: el título de la sesión de Claude Code o, si no
  tiene, el nombre de la carpeta de la sesión;
- la oferta WebRTC, que enumera las direcciones de red local del Mac como candidatas de conexión.

Los resultados, las preguntas, las actualizaciones y los resúmenes pasan antes por un redactor de
formatos de credenciales conocidos (claves privadas, JWT, tokens de API comunes, contraseñas en
URL, campos del tipo `password=`). Es una lista de patrones, no una garantía.

El hilo de codex que transporta la voz es efímero y de solo lectura, con todas las funciones de
codex desactivadas salvo donde conserva tu inicio de sesión y cómo usa tu proxy, y con todos los
servidores MCP desactivados; está ahí solo para conversar. El trabajo de Claude va a Anthropic como
siempre lo hace tu sesión de Claude Code.

Para las actualizaciones, la aplicación se comunica con GitHub. Con **Check for updates
automatically** activado, una vez al día (y en cada arranque mientras no se haya instalado una
versión que anunció) pregunta a la API de GitHub, sin credenciales, cuál es la última versión;
GitHub ve la dirección IP de tu Mac. **Check for update**, en Settings, envía la misma petición
cuando lo pulsas. Cuando la comprobación automática encuentra una versión más reciente, la
aplicación ejecuta `gh auth status` para indicar si la imagen se puede verificar. Solo cuando
pulsas **Install** descarga la imagen y ejecuta `gh attestation verify` y `claude plugin`, que se
conectan a GitHub, y a Sigstore para la raíz de confianza de `gh`, con tus propias sesiones.
[SECURITY.md](SECURITY.md#what-leaves-the-mac) enumera cada petición.

En tu Mac, la aplicación guarda sus ajustes, el contador de uso, cuándo buscó actualizaciones por
última vez y qué versiones anunció, lo que hizo la última actualización y, para cada una de las
últimas 20 sesiones usadas, su conversación reciente y la última línea de contexto cargada desde
ella, en `~/Library/Application Support/LiveBridge`. Las líneas de una sesión desaparecen cuando
pulsas **New conversation** con ella como destino o la eliminas con la ×. Una sesión que se ha ido
las conserva hasta que 20 sesiones usadas después las desplazan; para borrarlas antes, ejecuta
`/live on` en ella de nuevo y pulsa **New conversation**. La desinstalación las elimina todas.

[SECURITY.md](SECURITY.md) contiene el modelo de amenazas: en resumen, todo lo que tu micrófono
pueda oír puede convertirse en una petición que Claude ejecuta con el propio modo de permisos de la
sesión.

## Limitaciones conocidas

- A veces la voz dice que está mirando ("On it", "Looking now") sin pasar la petición, así que a
  Claude no le llega nada: más o menos una petición de cada cinco en las
  [pruebas](docs/bugs/BR-001.md), aunque la regla de la voz lo prohíbe. La aplicación emite un
  sonido breve cuando pone una petición en la cola de Claude; si la voz dice que está mirando y no
  suena nada, repite la petición. La aplicación no puede distinguir esa promesa de una respuesta
  por sus palabras, porque la voz habla tu idioma.
- Un resultado que llega mientras la línea lo espera pasa a la voz como texto para decir; codex no
  tiene ninguna llamada que haga hablar a la voz de inmediato, así que el modelo decide cuándo. En
  las pruebas habló en pocos segundos. Si no lo hace, el resultado queda sin escuchar: la voz lo
  dice tras tus siguientes palabras, o suena un timbre cuando se cierra la línea.
- Cuando la respuesta de Claude vuelve a abrir la línea, a veces la voz se queda callada
  ([medido](docs/adr/0001-platform-findings.md)). La línea se cierra entonces a los 5 segundos y
  la respuesta suena con un timbre y queda en espera, como abajo.
- Cuando tus siguientes palabras reabren la línea, a veces la voz responde solo a ellas y no dice el
  resultado en espera. El resultado no se pierde: sigue esperando, suena un timbre y publica una
  notificación cuando se cierra la línea, y vuelve a pasar a la voz la próxima vez que se abre la
  línea.
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
  ([la regla](docs/architecture/overview.md#a-result-while-the-line-is-closed)). En otro idioma, un
  resultado puede contar como escuchado cuando la voz solo lo ha mencionado.

## Cómo funciona

[docs/architecture/overview.md](docs/architecture/overview.md) describe los componentes, el
protocolo entre el mod y la aplicación, y los flujos de mensajes;
[ADR 0001](docs/adr/0001-platform-findings.md) recoge los hechos de la plataforma en los que se
basa el diseño.

## Hoja de ruta y ayuda buscada

Hoy LiveBridge es una aplicación de Mac, un agente de trabajo (Claude Code) y un proveedor de voz
(codex con un inicio de sesión de ChatGPT). Los tres se unen en interfaces estrechas, y cada
dirección siguiente está abierta a colaboradores. Las incidencias correspondientes llevan la
etiqueta
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22);
[CONTRIBUTING.md](CONTRIBUTING.md#where-to-start) indica los archivos que conviene leer primero.

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

- [CONTRIBUTING.md](CONTRIBUTING.md): la estructura, la toolchain, las comprobaciones
  (`scripts/check.sh`) y las convenciones.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md): cómo nos tratamos aquí.
- [SECURITY.md](SECURITY.md): informa de una vulnerabilidad en privado, no en una incidencia
  pública.
- [CHANGELOG.md](CHANGELOG.md): qué cambió en cada versión.

## Créditos

El protocolo entre el mod y la aplicación se inspiró en
[claude-code-voice-mod](https://github.com/ldk00315-jpg/claude-code-voice-mod). No se copió código
ni texto de él.

## Licencia

[MIT](LICENSE).
