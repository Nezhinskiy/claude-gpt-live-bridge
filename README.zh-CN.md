<p align="center"><a href="README.md">English</a> · <b>简体中文</b> · <a href="README.hi.md">हिन्दी</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.ru.md">Русский</a> · <a href="README.uk.md">Українська</a></p>

<p align="center"><img src="site/assets/icon.png" alt="LiveBridge 应用图标" width="144"></p>

<h1 align="center">LiveBridge</h1>

<p align="center"><strong>用语音与已打开的 Claude Code 会话对话。</strong></p>

<p align="center">
  <a href="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml"><img src="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="许可证：MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B%20%C2%B7%20Apple%20Silicon-lightgrey.svg" alt="平台：Apple Silicon 上的 macOS 14+">
</p>

<p align="center">
  <a href="https://getlivebridge.com">getlivebridge.com</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#安装">安装</a> ·
  <a href="#使用">使用</a> ·
  <a href="#按需计费的设计">计费</a> ·
  <a href="#隐私">隐私</a> ·
  <a href="#已知限制">限制</a> ·
  <a href="#路线图与欢迎协助">欢迎协助</a> ·
  <a href="#参与贡献">参与贡献</a>
</p>

LiveBridge 是一款 macOS 菜单栏应用，它通过 `codex app-server`，使用你的 ChatGPT 登录（无需 API 密钥）保持一条随时可用的
GPT-Live 语音线路。语音相当于前台接待：它负责闲聊、询问你的意思，并通过一个小型 Claude Code 模组 `livebridge`
把真正的工作交给你的 Claude Code 会话。Claude 用自己的模型、工具和权限模式完成工作，再由语音把结果告诉你。

*英文原文为准（[README.md](README.md)）；本译文可能滞后。*

<p align="center"><img src="site/assets/demo.gif" alt="通过 LiveBridge 与 Claude Code 会话对话" width="100%"></p>

**设计上完全本地。** 没有遥测，也没有自己的服务器：LiveBridge 只是你 Mac 上的一座桥，连接你自己的 codex 与你自己的
Claude Code。应用与模组之间通过只有你的用户才能打开的 Unix 套接字通信，应用不监听任何网络端口。除了这两个工具本来就会发送的内容
（语音线路经你的 codex 发往 OpenAI，仅在线路打开期间；Claude 的工作经你的 Claude Code 会话发往 Anthropic），
应用自身唯一的流量用于[更新](#更新应用)：向 GitHub 自动检查是否有新版本（每天一次，以及在它通知过的版本尚未安装时的每次启动），可以关闭；
你点击 **Check for update** 时的同一检查；通知新版本时的 `gh auth status`；以及你点击 **Install** 时的下载、验证和模组更新。
[隐私](#隐私)准确列出了哪些内容会到达 OpenAI，并列出应用向 GitHub 发出的请求；[SECURITY.md](SECURITY.md) 说明了它能防范什么、不能防范什么。

> **非官方项目。** 与 Anthropic 或 OpenAI 无任何隶属、认可或支持关系。它依赖 codex 的实验性实时 API，该 API
> 可能随任何一次 codex 发布而变化。

## 快速开始

你需要 Apple Silicon 上的 macOS 14+、Claude Code 2.1.289+，以及已登录（`codex login`）到包含实时语音的 ChatGPT 套餐的
[codex](https://github.com/openai/codex)；若要自行构建应用，还需要带 Swift 6.0+ 的 Xcode。详情见
[系统要求](#系统要求)。

```sh
# 1. The mod, from this repository's marketplace
claude plugin marketplace add getLiveBridge/LiveBridge
claude plugin install livebridge@livebridge

# 2. The app, built from source, installed in /Applications and opened
git clone https://github.com/getLiveBridge/LiveBridge.git
cd livebridge
scripts/build-app.sh --release
```

3. 在你想与之对话的 Claude Code 会话中，输入 `/live on`。
4. 点击提示输入框上方状态条中的 **Start**，允许使用麦克风，然后开始说话。

不想自己构建？每个[发布版本](https://github.com/getLiveBridge/LiveBridge/releases/latest)都附有磁盘映像形式的应用，
由 GitHub Actions 构建并出具证明；[通过磁盘映像安装](#通过磁盘映像安装)说明了如何验证并打开它。无论哪种方式，模组的安装方法都相同。

如果在已经打开的会话中找不到 `/live`，请重新打开该会话（[原因](#已知限制)）。更新、权限、重新构建后保留麦克风权限以及卸载，见[安装](#安装)。

## 系统要求

- Apple Silicon 上的 macOS 14 或更高版本。
- Claude Code 2.1.289 或更高版本（支持模组）。
- [Codex CLI](https://github.com/openai/codex)（`codex`，已在 0.166.0 上测试），通过
  Homebrew（`brew install --cask codex`）或 npm（`npm install -g @openai/codex`）安装，位于你的 shell 在终端窗口中设置的
  `PATH` 上，并已用 `codex login` 登录到包含实时语音的 ChatGPT 套餐。如果 LiveBridge 无法读取某个 codex 的
  `codex features list`，它会拒绝使用该 codex，因此其他版本可能要等 LiveBridge 更新后才能启动。
- 构建应用：Xcode，Swift 6.0 或更高版本的工具链。已测试的版本见
  [CONTRIBUTING.md](CONTRIBUTING.md#toolchain)。构建出的应用可在 macOS 14 或更高版本上运行。

## 安装

模组来自本仓库的 marketplace（即[快速开始](#快速开始)中的命令），它指向最新发布版本的标签，因此你安装的就是该版本的模组。
应用无论采用哪种方式，都安装在 `/Applications`：
通过磁盘映像，或从源码构建。两种方式的应用都使用 ad hoc 签名，且未经公证。

### 通过磁盘映像安装

1. 从最新发布版本下载
   [LiveBridge.dmg](https://github.com/getLiveBridge/LiveBridge/releases/latest/download/LiveBridge.dmg)。
2. 在保存该文件的文件夹中，用 [GitHub CLI](https://cli.github.com) 验证：

   ```sh
   gh attestation verify LiveBridge.dmg --repo getLiveBridge/LiveBridge \
     --signer-workflow getLiveBridge/LiveBridge/.github/workflows/release.yml \
     --source-ref refs/tags/vX.Y.Z --deny-self-hosted-runners
   ```

   其中 `vX.Y.Z` 是该发布版本的标签，以其发布页面上的名称为准。只有由本仓库的[发布工作流](.github/workflows/release.yml)
   在 GitHub 托管的 runner 上根据该标签构建、且此后未被改动的映像才能通过验证。
   这是映像唯一的来源证明：ad hoc 签名不指向任何人。它并不能证明有人审查过代码。
3. 打开映像，把 LiveBridge 拖到“应用程序”。
4. 首次启动时，macOS 会拦截该应用，直到你在“系统设置”>“隐私与安全性”中点击 **Open Anyway** 予以允许。

### 从源码构建

`scripts/build-app.sh --release` 会构建应用，把它安装到 `/Applications`（你的账户必须有写入权限，管理员账户即可）并打开它。
再次运行即可重新构建。该构建使用 ad hoc 签名，因此每次重新构建后 macOS 都会再次请求麦克风权限。若想保留该权限，
请运行一次 `scripts/build-app.sh --make-signing-identity`：它会先征求确认，然后在你的登录钥匙串中创建一个自签名代码签名证书，
之后的发布构建都会用它签名。

marketplace 把模组固定在上一个发布版本的标签上，因此从默认分支构建的应用会搭配该版本的模组运行。若要两者一致，请构建该发布版本的标签（`git checkout vX.Y.Z`），
或用 `claude --plugin-dir plugin` 加载工作树中的模组。

从源码构建的应用只有在你于 Settings 中开启后才会自行检查更新。安装更新会用发布版本的映像替换它，该映像使用 ad hoc 签名，
因此自签名证书将不再适用；**Install** 会说明这一点并先征求确认。

### 更新应用

LiveBridge 只在你点击 **Install** 时更新应用及其模组，从不自行安装。只有位于 `/Applications/LiveBridge.app` 的副本会更新；
其他任何副本都会在 Settings 中说明这一点。

- **Check for updates automatically**，位于 Settings（默认开启，从源码构建时默认关闭）：应用每天向 GitHub 询问一次最新的发布版本。
  较新的版本只通知一次：一条通知，其中的 **Install** 会安装它；菜单栏菜单也会显示 **Install LiveBridge X.Y.Z…**，直到它被安装，
  为保留这一项，应用每次启动时都会再次询问 GitHub。Settings 中的 **Check for update** 会立即询问。
- **Install** 需要已登录的 [GitHub CLI](https://cli.github.com)（`gh auth login`）；否则 Install 不会下载任何内容，并给出发布页面的链接。
  它会下载该发布版本的映像，用上文同样的 `gh attestation verify` 验证它，再检查其中的应用；只要有一项检查未通过，就什么都不安装。
  如果 Claude 仍在处理语音请求，它会等待；然后用 `claude plugin marketplace update livebridge` 和
  `claude plugin update livebridge@livebridge` 更新模组，停止通话，一步将新应用放到原位并打开它。
- 之后，Settings 会显示是从哪个版本更新而来。如果模组未能更新，那里会列出这两条命令，供你自己运行。
  已经打开的 Claude Code 会话在重启之前仍使用旧模组。
- 更新的下载不会设置隔离（quarantine）属性，因此 macOS 不应像拦截首次下载那样拦截更新后应用的首次启动；这是从代码推出的结论，尚未实际观察到。
  由上述检查承担这一把关作用（[SECURITY.md](SECURITY.md#what-an-update-installs)）。更新后第一次点击 **Start** 时，macOS 会再次请求麦克风权限，因为每个发布版本都使用 ad hoc 签名。

若要手动更新，请先在每个会话中运行 `/live off`（应用一旦停止响应，模组就会重新打开 `/Applications` 中的应用），退出 LiveBridge，
按上文安装较新的映像，然后运行这两条 `claude plugin` 命令。

### 权限

首次点击 Start 时，macOS 会请求麦克风权限。如果被拒绝，通话会停止并给出一句提示，此时菜单栏菜单中的
**Open Microphone Settings** 会打开“隐私与安全性”>“麦克风”，你可以在那里允许 LiveBridge。使用 ad hoc 签名时，每次更新或重新构建后
第一次点击 Start，macOS 都会再次询问（见上文）。macOS 还可能询问是否允许 LiveBridge 查找本地网络上的设备。语音线路同样需要这第二项权限；
没有它，通话会停止并给出一句提示，说明在哪里允许。

### 卸载

在克隆的仓库中运行 `scripts/build-app.sh --uninstall`，无论应用是如何安装的，它都会移除
`/Applications/LiveBridge.app`、其登录项以及它保存的所有文件，并打印出留给你自己执行的两条命令：
`tccutil reset Microphone com.getlivebridge.livebridge` 和
`claude plugin uninstall livebridge@livebridge`。

如果没有克隆仓库，请在 LiveBridge 的 Settings 中关闭 **Open at login**，退出 LiveBridge，然后在终端中执行同样的步骤：

```sh
rm -rf /Applications/LiveBridge.app ~/Library/Application\ Support/LiveBridge \
  ~/Library/{Caches,WebKit}/com.getlivebridge.livebridge \
  ~/Library/HTTPStorages/com.getlivebridge.livebridge{,.binarycookies} \
  ~/Library/Preferences/com.getlivebridge.livebridge.plist
tccutil reset Microphone com.getlivebridge.livebridge
claude plugin uninstall livebridge@livebridge
```

两种方式都不会删除名为 `/Applications/.LiveBridge-update-….app` 的副本，这种副本可能由安装中途中断的更新留下。应用会在下次启动时删除这类副本；
卸载之后，如果它存在，请手动删除。

## 使用

### 命令

在你想与之对话的 Claude Code 会话中：

| 命令 | 作用 |
|---|---|
| `/live on` | 以会话标题加入 LiveBridge；如果应用未运行，则将其打开。 |
| `/live off` | 离开 LiveBridge。 |
| `/live target` | 让当前会话成为语音交办工作的目标会话。 |
| `/live status`（或直接 `/live`） | 一行信息：通话、目标、未听取的结果、今日分钟数。 |
| `/live context` | 向语音发送由该会话的模型撰写的、关于此会话的新摘要。 |

命令是 `/live` 而不是 `/voice`，因为 `/voice` 是 Claude Code 自带的语音模式。会话成为目标时是否同时发送其摘要，并不是一个命令：
它是对所有会话生效的一项设置，位于 LiveBridge 的[设置](#设置)窗口中。

### 状态条与菜单

在提示输入框上方的状态条或菜单栏菜单中点击 **Start**，然后开始说话。

- **状态条上的 Start** 会让它所属的会话成为目标，开始通话，并把该会话的摘要发送给语音
  （[详情](docs/architecture/overview.md#components)）。当通话正在对接另一个会话时，状态条显示 **Talk here**。若已加入的会话中没有
  状态条，`/live on` 会让它重新出现。
- **菜单栏菜单**包含通话、已加入的会话（点击某个会话使其成为目标）、
  **Load context**、LiveBridge 保存的目标会话 **Conversation**、分钟数、
  **Settings…** 和 **Quit LiveBridge**。
- **New conversation…** 会清除目标会话的对话及其已加载的上下文；会话上的 × 会移除该会话并清除它自己的对话；两者都会先询问确认。
  语音从线路下次打开时重新开始，而在被移除的会话中执行 `/live on` 可让它重新加入。

### 设置

**Settings…** 会打开 LiveBridge 的设置窗口：

- **Voice**：你的 codex 提供的实时语音之一（窗口打开时由 codex 列出），或 **Codex default**。从线路下次打开起生效。
- **Prompt**（默认为空）：你给语音的自定义指令，例如“用西班牙语和我说话”，最多 2,000 个字符。它们会追加在 LiveBridge
  为语音设定的规则之后；两者冲突时以 LiveBridge 的规则为准。从线路下次打开起生效。
- **Load a session's context automatically when it becomes the target**（默认关闭）：对所有会话生效的一项设置，由应用保存。
- **Play a sound when a request is queued for Claude**（默认开启）：语音每转交一个请求给 Claude，就播放一声短音（[原因](#已知限制)）。
- **Notify when a result is waiting**（默认开启）：当线路关闭期间有结果在等待时，除提示音外，还会弹出一条 macOS 通知，其中写明会话名称
  （“Alpha has a new result — speak to hear it”），但绝不包含结果本身。点击通知会打开菜单栏菜单。
- **Open at login**（默认关闭）。
- **Updates**：当前运行的版本、**Check for update**、**Check for updates automatically**，以及上一次更新做了什么（[更新应用](#更新应用)）。

### 语音做什么

- 闲聊和解释由它自己回答；凡是需要用到仓库或会话的事情，它都会交办出去：任务、关于代码的问题、决策、更正和中止。
- 在交办任何具有破坏性或对外影响的操作（删除、推送、发布、发送、部署、付款）之前，它会复述请求并询问“确认吗？”。
  这是语音被要求遵守的习惯，而不是一道安全保障；哪些才算保障，见 [SECURITY.md](SECURITY.md)。
- 它用一两句话念出结果，并带上会话名称。代码块和表格留在会话中，它能识别的凭据会被遮蔽。
- 当 Claude 提出问题时，语音会向你转述，并把你的回答发回该会话。Claude 之后在后台完成的工作会作为更新播报。
- 当 Claude 正在等待权限提示时，语音会告诉你。你需要在 Claude Code 中回应该提示；LiveBridge 绝不会替你回答。

## 按需计费的设计

实时语音会话在打开期间产生费用，因此 LiveBridge 只在有人说话时，或在你刚提出的请求的 Claude 答复可能即将到来时，才打开它：

- 通话进行中且无人说话时，麦克风只为你 Mac 上的语音检测器供音，不会向任何地方发送任何内容。
- 当你开始说话时，线路打开。你开口前的 2 秒音频会被保留并最先发送，因此你的头几个字不会丢失。
- 静音 20 秒后线路关闭。没有语言的声音（音乐、电视）会在 90 秒后将其关闭。
- 当语音把请求交给 Claude（即一次交办）后，线路最多保持打开 2 分钟，与任何打开的线路一样计费；一旦无人说话，语音就会说出 Claude 的答复。
  之后的交办会重新开始这 2 分钟；而没有向 Claude 发送任何内容的交流，则在通常的 20 秒静音后关闭。
- 线路关闭期间稍后到达的结果会播放提示音并等待：状态条和菜单会将其显示为未听取，语音会在你下次说话时告诉你
  （[何时算作已听取](docs/architecture/overview.md#a-result-while-the-line-is-closed)）。
- 每个 Claude Code 会话都与语音有各自的对话。它会延续到下一个实时会话中，并在 Stop 和 Start 之间保留，因此语音记得你一分钟前说过的话。
  切换目标会同时切换对话：已打开的线路会关闭，你接下来说的话会带着新目标的对话重新打开它。
- 菜单显示线路打开的分钟数，由应用测量；你的套餐如何对实时语音计量，并未公布。

## 隐私

LiveBridge 没有遥测，也不监听任何网络端口；模组通过一个只有你的用户才能打开的文件夹中的 Unix 套接字与应用通信。
通过 codex 的实时会话发送给 OpenAI 的内容有：

- 线路打开期间的麦克风音频，从你开始说话前 2 秒起，直到线路关闭；
- 语音的指令：LiveBridge 自己的规则，其后是你在设置中写下的 **Prompt**（如果有）；
- 目标会话最近的对话（最多最后 24 行），用于在新的实时会话中继续对话；
- 目标会话中仍未完成的请求，以其单行简述的形式；
- 每条结果、问题、更新和审批通知，各为一行，最多 2,000 个字符，已去除代码块和表格。Claude 在一轮中途提出的问题还会附带 Claude 提问前刚写下的内容。更新是指后台任务通知所触发的后续一轮中 Claude 的答复，
  在一次语音请求之后最长 10 分钟内，且持续到会话中开始任何其他一轮为止；
- 目标会话的上下文摘要，为一行，最多 1,500 个字符。它在加载时保存，并且只要该会话是目标，每次线路打开时都会发送，
  Stop 和 Start 之间以及应用重启之后也是如此。菜单的 Conversation 子菜单会原样显示这一行的发送内容；
- 以上每一行都附带其会话的标签：Claude Code 会话标题，没有标题时则为会话文件夹的名称；
- WebRTC offer，其中以连接候选项的形式列出了这台 Mac 的本地网络地址。

结果、问题、更新和摘要会先经过一个针对已知凭据形态的遮蔽器（私钥、JWT、常见 API 令牌、URL 中的密码、`password=` 之类的字段）。
它只是一份模式列表，并不是保证。

承载语音的 codex 线程是临时的、只读的，除保存你的登录信息和使用你的代理的方式之外，codex 的所有功能都已关闭，所有 MCP 服务器也都已关闭；
它只用于对话。Claude 的工作则像你的 Claude Code 会话一贯的做法那样发往 Anthropic。

为了更新，应用会与 GitHub 通信。开启 **Check for updates automatically** 后，它每天一次（以及在它通知过的版本尚未安装时的每次启动）在不带任何凭据的情况下向 GitHub 的 API
询问最新的发布版本；GitHub 会看到你 Mac 的 IP 地址。点击 Settings 中的 **Check for update** 时也会发出同样的请求。
自动检查发现较新的版本时，应用会运行 `gh auth status`，以说明映像能否被验证。
只有在你点击 **Install** 时，它才会下载映像并运行 `gh attestation verify` 和 `claude plugin`，它们以你自己的登录身份访问 GitHub，
`gh` 还会访问 Sigstore 获取信任根。[SECURITY.md](SECURITY.md#what-leaves-the-mac) 列出了每一项请求。

在你的 Mac 上，应用把设置、用量计量、上次检查更新的时间和已通知过的版本、上一次更新做了什么，以及最近使用的 20 个会话各自的近期对话和上次从中加载的上下文行，保存在
`~/Library/Application Support/LiveBridge`。当你以某个会话为目标按下 **New
conversation**，或用 × 移除它时，该会话的这些行就会被删除。已离开的会话会保留这些内容，
直到之后使用的 20 个会话将其挤出；若想更早地清除，请在其中再次运行 `/live on` 并点击 **New conversation**。卸载会将它们全部移除。

[SECURITY.md](SECURITY.md) 给出了威胁模型：简而言之，凡是你的麦克风能听到的内容，都可能变成一条请求，由 Claude 在该会话自己的权限模式下执行。

## 已知限制

- 语音有时会说它在查看（“On it”“Looking now”），却没有转交请求，于是什么也没有送到 Claude：在[测试](docs/bugs/BR-001.md)中，
  即使语音的规则禁止这样做，仍约有五分之一的请求如此。应用把请求放入 Claude 的队列时会播放一声短音；如果语音说它在查看却没有这声短音，
  请再说一遍。应用无法凭措辞区分这种承诺和回答，因为语音说的是你的语言。
- 在线路等待期间到达的结果，会作为待说出的文本交给语音；codex 没有能让语音立即开口的调用，因此由模型决定何时说。
  测试中它在几秒内就说了。如果没有说，结果仍保持未听取：语音会在你接下来说话之后说出它，或在线路关闭时发出提示音。
- 当你接下来说的话重新打开线路时，语音有时只回应这些话，而不说出等待中的结果。结果并没有丢失：它仍在等待，
  会在线路关闭时发出提示音并推送通知，并在线路下次打开时再次交给语音。
- 在模组加载之前就已打开的 Claude Code 会话，可能需要重新打开，`/live` 才能在其中使用。
- 在 Claude 桌面应用中，如果在其 Claude Code 进程尚未启动的会话（新建的会话，或刚重新打开的会话）里输入 `/live`，
  可能会显示“/live isn't a command here.”，但命令仍会执行。桌面应用是通过一次关闭了 hooks 的检查来列出这类会话的命令的，
  因此声明了 `/live` 的模组代码不会在那里运行；会话运行起来之后，桌面应用就会从会话本身获取命令列表。模组对此没有修复办法：
  静态命令文件会被列为 `/livebridge:live` 而不是 `/live`，而且在 hooks 关闭时，它会把自己的文本发给模型，而不是运行模组。
- 一条答复是否已经说出了等待中的结果，是根据其用词来判断的，所用的常用词表只涵盖英语和俄语
  （[规则](docs/architecture/overview.md#a-result-while-the-line-is-closed)）。在其他语言中，
  语音只是提到了结果，也可能被算作已听取。

## 工作原理

[docs/architecture/overview.md](docs/architecture/overview.md) 描述了各组件、模组与应用之间的通信协议以及消息流；
[ADR 0001](docs/adr/0001-platform-findings.md) 记录了该设计所依据的平台事实。

## 路线图与欢迎协助

目前的 LiveBridge 是一个 Mac 应用、一个执行者（Claude Code）和一个语音提供方（使用 ChatGPT 登录的 codex）。三者在狭窄的接缝处相接，
下面的每个方向都欢迎贡献者参与。相关议题带有
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
标签；[CONTRIBUTING.md](CONTRIBUTING.md#where-to-start) 指出了应先阅读的文件。

- **Windows 和 Linux。** 菜单栏应用、它的音频页面和套接字服务器都与 macOS 绑定；模组与应用之间的协议以及模组本身是可移植的。
  移植从为新平台编写一个使用同一协议的应用开始。
- **其他智能体作为执行者**，例如 Codex CLI、Hermes Agent 或 Gemini CLI：每一个都需要自己的适配器，使用与 Claude Code 模组相同的协议。
- **其他语音提供方**，例如使用你自己 API 密钥的 OpenAI Realtime API，或 Google 的 Gemini Live API：每一个都将是应用实时协议的另一种实现。

## 参与贡献

欢迎贡献。对于比一次修复更大的改动，请先开一个议题，以便在开工前商定方案。适合入手的地方有
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
议题、[已知限制](#已知限制)以及[上文](#路线图与欢迎协助)的各个方向。

- [CONTRIBUTING.md](CONTRIBUTING.md)：目录布局、工具链、检查（`scripts/check.sh`）和约定。
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)：我们在这里如何相互对待。
- [SECURITY.md](SECURITY.md)：请私下报告漏洞，不要发在公开议题中。
- [CHANGELOG.md](CHANGELOG.md)：每个发布版本的变更。

## 致谢

模组与应用之间的通信协议受到
[claude-code-voice-mod](https://github.com/ldk00315-jpg/claude-code-voice-mod) 的启发。没有复制它的任何代码或文字。

## 许可证

[MIT](LICENSE)。
