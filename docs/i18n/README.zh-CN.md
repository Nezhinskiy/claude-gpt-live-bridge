<p align="center"><a href="../../README.md">English</a> · <b>简体中文</b> · <a href="README.hi.md">हिन्दी</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.ru.md">Русский</a> · <a href="README.uk.md">Українська</a></p>

<p align="center"><img src="../../site/assets/icon.png" alt="LiveBridge 应用图标" width="144"></p>

<h1 align="center">LiveBridge</h1>

<p align="center"><strong>用语音与已打开的 Claude Code 会话对话。</strong></p>

<p align="center">
  <a href="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml"><img src="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/getLiveBridge/LiveBridge"><img src="https://api.scorecard.dev/projects/github.com/getLiveBridge/LiveBridge/badge" alt="OpenSSF Scorecard"></a>
  <a href="https://www.bestpractices.dev/projects/16502"><img src="https://www.bestpractices.dev/projects/16502/badge" alt="OpenSSF Best Practices"></a>
  <a href="../../LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="许可证：MIT"></a>
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
Claude 工作时你不必让线路一直打开：它的答复会重新打开已关闭的线路，并交给语音去说。语音还会跟进你在会话中输入的内容和 Claude 的答复，所以你可以在说话和打字之间随意切换。

*英文原文为准（[README.md](../../README.md)）；本译文可能滞后。*

**是对话，不是听写。** GPT-Live 一边说一边听：你随时打断，它就停下来听你说；你边想边说时，它还可能插一句“嗯”。**不再为沉默付费：** OpenAI 按分钟计算语音费用，所以静默达到你在[设置](#设置)中设定的时长后线路会关闭，你一开口就重新打开，对话从上次停下的地方继续（[计费](#按需计费的设计)）。

<p align="center"><img src="../assets/readme-demo.gif" alt="通过 LiveBridge 与 Claude Code 会话对话" width="100%"></p>

**设计上完全本地。** 没有遥测，也没有自己的服务器：LiveBridge 只是你 Mac 上的一座桥，连接你自己的 codex 与你自己的
Claude Code。应用与模组之间通过只有你的用户才能打开的 Unix 套接字通信，应用不监听任何网络端口。除了这两个工具本来就会发送的内容
（语音线路经你的 codex 发往 OpenAI，仅在线路打开期间，其中包括你在已加入的会话中输入的内容；Claude 的工作经你的 Claude Code 会话发往 Anthropic），
应用自身唯一的流量是：你打开菜单时，一个短时运行的 codex 向 OpenAI 请求你的 Codex 用量数据（通话关闭时同样如此），以及用于[更新](#更新应用)的流量：向 GitHub 自动检查是否有新版本（每天一次，以及在它通知过的版本尚未安装时的每次启动），可以关闭；
你点击 **Check for update** 时的同一检查；通知新版本时的 `gh auth status`；以及你点击 **Install** 时的下载、验证和模组更新。
[隐私](#隐私)准确列出了哪些内容会到达 OpenAI，并列出应用向 GitHub 发出的请求；[SECURITY.md](../../SECURITY.md) 说明了它能防范什么、不能防范什么。

> **非官方项目。** 与 Anthropic 或 OpenAI 无任何隶属、认可或支持关系。它依赖 codex 的实验性实时 API，该 API
> 可能随任何一次 codex 发布而变化。

## 快速开始

你需要 Apple Silicon 上的 macOS 14+、Claude Code 2.1.301+，以及已登录（`codex login`）到其 Codex 包含语音的 ChatGPT 套餐的
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

3. 在你想与之对话的 Claude Code 会话中，输入 `/live`。
4. 点击提示输入框上方状态条中的 **Start**，允许使用麦克风，然后开始说话。

不想自己构建？每个[发布版本](https://github.com/getLiveBridge/LiveBridge/releases/latest)都附有磁盘映像形式的应用，
由 GitHub Actions 构建并出具证明；[通过磁盘映像安装](#通过磁盘映像安装)说明了如何验证并打开它。无论哪种方式，模组的安装方法都相同。

如果在已经打开的会话中找不到 `/live`，请重新打开该会话（[原因](#已知限制)）。更新、权限、重新构建后保留麦克风权限以及卸载，见[安装](#安装)。

## 系统要求

- Apple Silicon 上的 macOS 14 或更高版本。
- Claude Code 2.1.301 或更高版本。
- [Codex CLI](https://github.com/openai/codex)（`codex`，已在 0.166.0 上测试），通过
  Homebrew（`brew install --cask codex`）或 npm（`npm install -g @openai/codex`）安装，位于你的 shell 在终端窗口中设置的
  `PATH` 上，并已用 `codex login` 登录到其 Codex 包含语音的 ChatGPT 套餐（Plus、Pro、Business、Enterprise 或 Education，见 [OpenAI 的 Codex 定价](https://learn.chatgpt.com/docs/pricing)）。如果 LiveBridge 无法读取某个 codex 的
  `codex features list`，它会拒绝使用该 codex，因此其他版本可能要等 LiveBridge 更新后才能启动。
- 构建应用：Xcode，Swift 6.0 或更高版本的工具链。已测试的版本见
  [CONTRIBUTING.md](../../CONTRIBUTING.md#toolchain)。构建出的应用可在 macOS 14 或更高版本上运行。

## 安装

模组来自本仓库的 marketplace（即[快速开始](#快速开始)中的命令），它指向最新发布版本的标签，因此你安装的就是该版本的模组。
应用无论采用哪种方式，都安装在 `/Applications`：
通过磁盘映像，或从源码构建。从 0.4.2 之后的第一个发布版本起，磁盘映像使用 LiveBridge 的 Developer ID 签名，并经 Apple 公证；0.4.2 及更早的版本使用 ad hoc 签名，未经公证；从源码构建的应用既未使用 Developer ID 签名，也未经公证。

### 通过磁盘映像安装

1. 从最新发布版本下载
   [LiveBridge.dmg](https://github.com/getLiveBridge/LiveBridge/releases/latest/download/LiveBridge.dmg)。
2. 在保存该文件的文件夹中，用 [GitHub CLI](https://cli.github.com) 验证：

   ```sh
   gh attestation verify LiveBridge.dmg --repo getLiveBridge/LiveBridge \
     --signer-workflow getLiveBridge/LiveBridge/.github/workflows/release.yml \
     --source-ref refs/tags/vX.Y.Z --deny-self-hosted-runners
   ```

   其中 `vX.Y.Z` 是该发布版本的标签，以其发布页面上的名称为准。只有由本仓库的[发布工作流](../../.github/workflows/release.yml)
   在 GitHub 托管的 runner 上根据该标签构建、且此后未被改动的映像才能通过验证。
   对于 0.4.2 之后的发布版本，Developer ID 签名由 macOS 自行检查，说明是谁签署了映像，而这项验证说明映像是由什么构建的；对于 0.4.2 及更早的版本，其 ad hoc 签名不指明任何人，这项验证是映像唯一的来源证明。它并不能证明有人审查过代码。
3. 打开映像，把 LiveBridge 拖到“应用程序”。
4. 首次启动时，0.4.2 之后的发布版本会让 macOS 询问是否打开从互联网下载的应用；点击 **Open**。0.4.2 及更早的版本会被拦截，直到你在“系统设置”>“隐私与安全性”> **Open Anyway** 中允许它们。

### 通过 Homebrew 安装

```sh
brew install --cask getlivebridge/tap/livebridge
```

这条命令从 [LiveBridge 自己的 tap](https://github.com/getLiveBridge/homebrew-tap) 安装同一个磁盘映像，它不是 Homebrew 的官方 cask。Homebrew 可能会先要求你信任这个 tap，macOS 也会像上面所说的那样在首次启动时询问。之后应用会自行更新。

### 从源码构建

`scripts/build-app.sh --release` 会构建应用，把它安装到 `/Applications`（你的账户必须有写入权限，管理员账户即可）并打开它。
再次运行即可重新构建。该构建使用 ad hoc 签名，因此每次重新构建后 macOS 都会再次请求麦克风权限。若想保留该权限，
请运行一次 `scripts/build-app.sh --make-signing-identity`：它会先征求确认，然后在你的登录钥匙串中创建一个自签名代码签名证书，
之后的发布构建都会用它签名。

marketplace 把模组固定在上一个发布版本的标签上，因此从默认分支构建的应用会搭配该版本的模组运行。若要两者一致，请构建该发布版本的标签（`git checkout vX.Y.Z`），
或用 `claude --plugin-dir plugin` 加载工作树中的模组。

从源码构建的应用只有在你于 Settings 中开启后才会自行检查更新。安装更新会用发布版本的映像替换它，该映像使用 LiveBridge 的 Developer ID 签名，而不是你的自签名证书，
因此 macOS 会再次请求一次麦克风权限；**Install** 会说明这一点并先征求确认。

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
  已经打开的 Claude Code 会话在重启之前仍使用旧模组；Settings 会列出仍在使用旧模组的已加入会话。
- 更新的下载不会设置隔离（quarantine）属性，因此 macOS 不应像首次下载之后那样，在更新后应用的首次启动时停下来询问；这是从代码推出的结论，尚未实际观察到。
  由上述检查承担这一把关作用（[SECURITY.md](../../SECURITY.md#what-an-update-installs)）。0.4.2 之后的发布版本使用 LiveBridge 的 Developer ID 签名，因此麦克风权限应当会在版本之间保留；这是根据 macOS 对该权限的关联方式推断的，尚未观察到。0.4.2 及更早的版本使用 ad hoc 签名，因此从其中任一版本进行的第一次更新，会在第一次点击 **Start** 时再次请求一次麦克风权限。

若要手动更新，请先在每个会话中运行 `/live off`（应用一旦停止响应，模组就会重新打开 `/Applications` 中的应用），退出 LiveBridge，
按上文安装较新的映像，然后运行这两条 `claude plugin` 命令。

### 权限

首次点击 Start 时，macOS 会请求麦克风权限。如果被拒绝，通话会停止并给出一句提示，此时菜单栏菜单中的
**Open Microphone Settings** 会打开“隐私与安全性”>“麦克风”，你可以在那里允许 LiveBridge。从 ad hoc 签名的发布版本进行第一次更新后，以及每次使用 ad hoc 签名从源码重新构建后，
第一次点击 Start，macOS 都会再次询问（见上文）。macOS 还可能询问是否允许 LiveBridge 查找本地网络上的设备。语音线路同样需要这第二项权限；
没有它，通话会停止并给出一句提示，说明在哪里允许。

### 卸载

在 `/Applications` 中的副本里，菜单中的 **Feedback & Support ▸ Uninstall LiveBridge…** 会先询问，然后把应用移到废纸篓；如果无法移动，它会说明，把应用留在原处，并放回先前移除的登录项（如果移除过）；如果 macOS 不允许它把该登录项放回去，它也会说明，并告诉你如何重新打开 **Open at login**。然后结束正在进行的通话，每个会话都会离开 LiveBridge（与菜单中的 × 相同），因此其中的 `/live` 会关闭，而不会再次打开 LiveBridge；LiveBridge 移除登录项和麦克风权限后退出，退出之后，它保存的文件（见下文）会移到废纸篓中的一个文件夹，直到你清倒废纸篓。它不会移除 Claude Code 模组，而是复制移除模组的命令 `claude plugin uninstall livebridge@livebridge`，供你在终端中运行。当时未打开的会话在再次打开时可能仍会寻找 LiveBridge；移除模组即可停止。

用 Homebrew 安装的？`brew uninstall --cask getlivebridge/tap/livebridge` 会移除应用及 Homebrew 中的记录；下面的步骤仍适用于应用保存的文件。

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

这些方式都不会删除名为 `/Applications/.LiveBridge-update-….app` 的副本，这种副本可能由安装中途中断的更新留下。应用会在下次启动时删除这类副本；
卸载之后，如果它存在，请手动删除。

`claude plugin uninstall` 可能会留下模组的快照 `~/.claude/plugins/store/livebridge_*.json`：Claude Code 文档中列出的删除内容不包括这个文件，这一点也没有实际运行验证。如果它还在，请手动删除。

## 使用

### 命令

在你想与之对话的 Claude Code 会话中：

| 命令 | 作用 |
|---|---|
| `/live` | 以会话标题加入 LiveBridge；如果应用未运行，则将其打开。在已加入的会话中，它会让状态条重新出现，并用一行作答：通话、目标、未听取的结果、今日分钟数。 |
| `/live off` | 离开 LiveBridge。 |

命令是 `/live` 而不是 `/voice`，因为 `/voice` 是 Claude Code 自带的语音模式。通话停止期间，你在会话中输入的内容是否不进入语音，并不是一个命令：
它是对所有会话生效的一项设置，位于 LiveBridge 的[设置](#设置)窗口中。

### 状态条与菜单

在提示输入框上方的状态条或菜单栏菜单中点击 **Start**，然后开始说话。

- **状态条上的 Start** 会让它所属的会话成为目标并开始通话；它打开的线路会带上该会话的对话，并且在语音会缺少该会话的一部分时（见下文 **Load context**）另外加载摘要，但在 **Pause sync** 开启期间或暂停之后，只有在尚无摘要时才加载（[详情](../../docs/architecture/overview.md#when-the-app-asks)）。使用本版本的模组时，摘要会在按下 Start 和通话中切换目标时请求，线路在连接前等待它，最长不超过[等待的上限](../../docs/architecture/overview.md#its-time)：这期间你说的话保留在 Mac 上，线路打开后再交给语音。等待期间按 Stop 或切换目标会丢弃保留的内容；更改 **Connect over TCP** 后的重新连接也会丢弃，最多只为重新打开的线路保留最后 2 秒。当通话正在对接另一个会话时，状态条显示 **Talk here**。若已加入的会话中没有
  状态条，`/live` 会让它重新出现。
- **菜单栏菜单**包含通话、已加入的会话（点击某个会话使其成为目标）、
  **Load context**、LiveBridge 保存的目标会话 **Conversation**（语音交给 Claude 的每个请求都有一行 **Task**，载入摘要的位置有一行 **Loaded context**）、用量限额、分钟数、
  **Quick Settings**（**Connect over TCP**、**Play sounds for requests and answers**、**Notify when a result is waiting**、**Pause sync while the call is stopped** 和 **Load a session's context on its first call** 的勾选项）、**Settings…**、**Feedback & Support**（**Report a Bug…** 打开仓库的错误报告表单，**LiveBridge Website** 打开 getlivebridge.com，**Star LiveBridge on GitHub** 打开仓库页面，随后是 **Debug Mode** 和 **Show Debug Files…**，即[调试模式](#设置)的开关和文件夹，以及 **Uninstall LiveBridge…**（[卸载](#卸载)））和 **Quit LiveBridge**。菜单只显示通话时，Quick Settings 也在。通话期间，**Conversation** 会随着 codex 的转写显示你和语音说的话，因此你的话可能在说出后片刻才出现，语音的话可能在你听到前片刻就出现。每句话结束后，由最终文本替换这些文字。只保留最终文本：线路关闭时仍未等到最终文本的文字会消失。
- **Mute**（在 **Stop** 旁边，位于状态条和菜单的通话卡片中；Mute 后显示 **Unmute**）会在通话继续时释放你的麦克风：Claude 的答复仍会打开线路，并交给语音去说。状态条保留阶段并加上 `· muted`；没有线路打开时，菜单显示 “Muted — line closed”。Mute 不会关闭线路：已打开的线路会在通常的无声时长后关闭：若你当时在说话，则从 Mute 起算；若线路本来就安静，Mute 不会改变它何时关闭，计费与任何无声时段相同，因此 Mute 不会节省实时分钟数。**Unmute** 会重新使用麦克风，若无法使用（被拒绝、被占用、缺失），通话会带着原因结束。**Stop** 会结束通话和 Mute；下一次 **Start** 从未 Mute 开始。Mute 不是锁：任何以你的用户身份运行的进程都可以解除它（[SECURITY.md](../../SECURITY.md#who-can-drive-the-bridge)）。
- **Load context** 只在语音缺少目标的一部分时可用：没有摘要且 **Pause sync** 使下一条线路无法加载或上次请求的摘要失败（直到该会话的下一轮或下一次 Start）、某一轮没有送达、某个问题或权限通知没有送到应用、模组关闭期间有轮次运行、摘要之后的行数已超出语音所能承载（较长的对话会超出）、该会话曾被暂停且已有摘要，或其模组不同步。否则该项显示为 **Context up to date** 且不可用，因为语音已经有了这段对话。如果没有打开的线路、下一条线路将加载摘要且没有缺少其他内容，该项显示为 **Context loads with the line** 且不可用，因为下一条线路会自行请求摘要。目标的摘要正在途中时，无论是谁请求的，该项都显示为 **Loading context…** 且不可用，最长为模组给它的时间（[多久](../../docs/architecture/overview.md#its-time)；旧版模组的会话仍显示 **Load context**）；摘要到达后短暂显示 **Context loaded**，空的回复则回到 **Load context**。摘要不带日期，因此它可能被忽略而该项仍保持可用（[BR-002](../../docs/bugs/BR-002.md)）。
- **New conversation…** 会清除目标会话的对话及其已加载的上下文；会话上的 × 会移除该会话并清除它自己的对话；两者都会先询问确认。语音从线路下次打开时重新开始。它还没说出的结果会保留并再次加入，只有 **Stop** 会清除它们。Claude 等待中的问题遵循其他规则（[详情](../../SECURITY.md#residual-risk-by-design)）。**Load a session's context on its first call** 开启时，或 **Pause sync** 关闭且该会话未被暂停时，下一条线路会自行加载同一会话记录的摘要，其中包括对话的文字（本版本的应用和模组会去掉工具输出、思考和提醒，但不会去掉引用它们的文字；更早的版本会发送整个请求）；要避免这一点，请先在该会话中执行 `/clear`，再点击 **New conversation**。在被移除的会话中执行 `/live` 可让它重新加入。

### 设置

**Settings…** 会打开 LiveBridge 的设置窗口，工具栏中有四个标签页。
菜单中的 **Quick Settings** 收有其中五个开关（[菜单](#状态条与菜单)）：每一项就是设置本身，因此在一处更改会立即显示在另一处，并且它会询问此处开关所询问的内容。
**General** 包含通知、登录、更新和调试模式：

- **Notify when a result is waiting**（默认开启）：当线路关闭期间有结果在等待时，除提示音外，还会弹出一条 macOS 通知，其中写明会话名称
  （“Alpha has a new result — speak to hear it”），但绝不包含结果本身。点击通知会打开菜单栏菜单。
- **Open at login**（默认关闭）。
- **Updates**：当前运行的版本、**Check for update**、**Check for updates automatically**，以及上一次更新做了什么（[更新应用](#更新应用)）。
- **Debug mode**（默认关闭）：通话期间每秒记录一行语音的网络数据（丢失和丢弃的数据包、抖动、隐藏的采样、线路是否走 TCP），每次通话一个 CSV，存放在 `~/Library/Application Support/LiveBridge/debug/call-stats/`；不含音频、转写或会话名称。通话中开启时，从那一刻起记录正在打开的线路；关闭时立即停止，已写入的文件会保留，直到你删除。**Show Debug Files** 打开该文件夹。在菜单中，它是 **Feedback & Support** 里的 **Debug Mode**（[如何解读这些数据](../../CONTRIBUTING.md#reading-debug-modes-numbers)）。

**Voice** 包含通话中你听到的内容：

- **Voice**：你的 codex 提供的实时语音之一（此标签页打开时由 codex 列出），或 **Codex default**。从线路下次打开起生效。
- **Prompt**（默认为空）：你给语音的自定义指令，例如“用西班牙语和我说话”，最多 2,000 个字符。它们会追加在 LiveBridge
  为语音设定的规则之后；两者冲突时以 LiveBridge 的规则为准。从线路下次打开起生效。
- **Play sounds for requests and answers**（默认开启）：语音每转交一个请求给 Claude，就播放一声短音（[原因](#已知限制)）；无人说话时，Claude 的每个回答、失败或提问到达已打开或正在打开的线路，也会播放一声。等待中结果的提示音始终播放。

**Line** 包含线路在安静中保持打开多久，以及它如何连接：

- **Silence before the line closes**（默认 20 秒）、**Wait for a first word on a line a result opened**（5 秒）和 **Sound without words before the line closes**（90 秒）：每种安静能让打开的线路保持多久，范围为 0 到 300 秒。静音或没有语言的声音设为 0 即关闭该项，而等待第一句话设为 0 时，等待时长与静音相同。三项都为 0 时，安静永远不会关闭线路：线路会一直打开，期间一直计费（[计费](#按需计费的设计)），直到你按下 Stop、更换目标或 OpenAI 将其关闭。时长过短会让线路在普通的停顿中关闭，而每次重新打开都要过几秒语音才会回答，所以设为 1 到 9 秒时 Settings 会给出警告；没有语言的声音也是如此，因为你的说话在被识别之前也算作这种声音；第一句话的等待设为 1 到 3 秒时同样会警告，因为语音常在线路连接后约 2 秒才开口。你开启的计时器会在安静的已打开线路上立即开始计时；已在计时的则保留已计的时间。
- **Connect over TCP**（默认关闭）：如果在网络较差时语音断断续续，请打开它。线路随后优先使用媒体服务器提供的 TCP 路线（已见到的应答中为 443 端口）而不是 UDP，并且仍可能退回 UDP。在丢包的连接上，这可以把断续变成句子之间的短暂停顿（[测试到什么程度](#已知限制)）。切换时如果线路正开着，确认后它会立即关闭并重新打开；语音正在说的话会被打断，而线路正在等待的结果仍会进入新的线路。

**Context** 包含你的会话如何到达语音：

- **Pause sync while the call is stopped**（默认关闭）：默认情况下，你在已加入的会话中输入的内容以及 Claude 对此的最终答复，即使通话已停止，也会保存到该会话与语音的对话中，下一条线路打开时语音就拥有它们。在线路打开之前，这些内容都不会到达 OpenAI。若不想让某些文字到达 OpenAI，请开启此项，若该会话可能还没有摘要，请关闭下一项设置，按下 Stop，然后再输入：通话停止期间你输入的内容都不会被记录，该会话会被标记为已暂停。开启期间，没有任何线路会自行加载摘要，暂停之后也是如此，但没有摘要的会话除外（见下一项设置）；其他情况下只有 **Load context** 才会加载。该摘要由会话记录写成，因此会带上你暂停的内容。向正在运行语音请求的那一轮输入，会使它的答复失败，其中的任何内容都不会被记录或说出。此项不会删除已记录的任何内容，Claude 之后的答复也可能重复被暂停的文字；它做什么、不做什么，见 [SECURITY.md](../../SECURITY.md#residual-risk-by-design)。
- **Load a session's context on its first call**（默认开启；如果更新时 **Pause sync** 已开启，则为关闭）：对于语音没有摘要的会话，按下 Start、通话中切换目标或打开线路都会请求摘要，即使 **Pause sync** 已开启或该会话已被暂停，旧对话和 **New conversation** 之后的对话也一样。该摘要由会话记录写成，因此会带上你暂停的内容，并发送给 OpenAI。会话有了摘要之后，后续内容由暂停决定。关闭此项时，暂停期间只有 **Load context** 才会加载摘要。
- **Summary model**（默认 Haiku 5.5，更新后也是；也可选 Sonnet 5.5、Opus 5.5 或 **Custom…**）：撰写语音作为上下文所得摘要的模型，始终使用低推理强度，消耗你的 Claude 用量。若其他模型失败，则由 Haiku 5.5 撰写，除非该模型已超时。设置下方有一行说明上一份摘要何时改由 Haiku 5.5 撰写，或没有任何模型写成，以及原因。使用此设置之前的模组的会话会忽略它，用会话自己的模型撰写。**Custom…** 接受一个模型 id 和 **Check and save**：一个已加入的会话向该模型发送一个简短请求（"Reply with OK."），消耗你的 Claude 用量，只有模型作答时才保存该 id；否则原因显示在输入框旁，之前的选择保持不变。这需要一个运行此版本模组的会话，检查结果只代表该会话的 Claude Code：其他会话可能不同，已保存的 id 不会再次检查。

### 语音做什么

- 闲聊和解释由它自己回答；凡是需要用到仓库或会话的事情，它都会交办出去：任务、关于代码的问题、决策、更正和中止。
- 在交办任何具有破坏性或对外影响的操作（删除、推送、发布、发送、部署、付款）之前，它会复述请求并询问“确认吗？”。
  这是语音被要求遵守的习惯，而不是一道安全保障；哪些才算保障，见 [SECURITY.md](../../SECURITY.md)。
- 它用一两句话念出结果，并带上会话名称。代码块和表格留在会话中，它能识别的凭据会被遮蔽。
- Claude 完成后它会回来。你不必让线路一直打开：谈话安静下来后线路就会关闭，而 Claude 对你请求的答复会重新打开线路并交给语音去说，所以 Claude 工作时你可以走开。这适用于你正在对话的会话；其他会话的结果会发出提示音并等待（[如何计费](#按需计费的设计)）。如果语音在重新打开的线路上保持沉默，答复同样会发出提示音并等待，因此不会丢失。Claude 向你提出的问题或它正在等待的权限提示也会这样打开线路，但语音可能不说：离开 Mac 时不要依赖这一点（[已知限制](#已知限制)）。
- 当 Claude 提出问题时，问题会交给语音向你转述，你的回答则发回该会话。对于 Claude 在工作中提出的问题（带选项的对话框）也是如此：语音收到它，用于告诉你这个问题、用自己的话解释各个选项，并按你的需要与你讨论多久都可以，而不去询问 Claude。你的决定，无论是某个选项还是反问 Claude 的问题，都会作为对话框的回答；你也仍然可以在键盘上回答。Claude 之后在后台完成的工作会作为更新交给语音。
- 当 Claude 正在等待权限提示时，语音会收到一条通知，并可能说出来，但[由组织管理 Claude Code 的环境](#已知限制)除外。你需要在 Claude Code 中回应该提示；LiveBridge 绝不会替你回答。
- 它会收到你输入的内容。会话处于加入状态时，你在其中输入的内容，以及 Claude 对每个非语音请求轮次的最终答复，都会作为上下文进入该会话与语音的对话：它们不会发出提示音，也不会打开已关闭的线路（[相关限制](#已知限制)）。已打开的线路会立即收到它们；之后打开的线路则以它们为开头。被更新的请求取代的语音答复不会被说出，但会以同样方式保留并加入。Claude 在一轮中途的文字不会同步，只有它在提问或权限提示之前刚写下的内容会随之而去；子代理和工具输出不会同步。目标会话中 Claude 的提问或权限提示，无论由哪一轮引起，都会交给语音；在其他会话中，它像那里的结果一样处理，但若那一轮不是语音请求，则只做记录。被暂停挡在外面的一轮没有这些。当提问或权限提示不经语音就已了结，或某一轮没有答复就结束时，语音会收到一行说明（[哪些行](../../SECURITY.md#what-session-text-can-do)）。

## 按需计费的设计

实时语音会话在打开期间产生费用，因此 LiveBridge 只在有人说话时、在你刚提出的请求的 Claude 答复可能即将到来时，或为了说出这条答复、Claude 的提问或 Claude 正在等待你的许可时，才打开它：

- 通话进行中且无人说话时，麦克风只为你 Mac 上的语音检测器供音，不会向任何地方发送音频。
  处于 Mute 时，LiveBridge 不持有麦克风，macOS 的麦克风指示器会显示这一点。
- 当你开始说话时，线路打开。你开口前的 2 秒音频会被保留并最先发送，因此你的头几个字不会丢失。
- 静音一段时间后线路关闭，没有语言的声音（音乐、电视）则在它自己的一段时间后将其关闭。两者各自在[设置](#设置)中设定；某项设为 0 时，它就不会关闭线路。
- 当语音把请求交给 Claude（即一次交办）后，线路最多保持打开 2 分钟，与任何打开的线路一样计费；一旦无人说话，Claude 的答复就会交给语音去说。
  之后的交办会重新开始这 2 分钟；而没有向 Claude 发送任何内容的交流，则在通常的静音后关闭。
- 你交给正在对话的会话的请求的 Claude 答复、Claude 在该会话中向你提出的问题，或它正在等待的权限请求，如果在线路关闭后到达，会重新打开线路并交给语音去说，与任何打开的线路一样计费。
  线路关闭期间到达的其他内容（来自你已切换离开的会话的任何内容、之后的更新）会播放提示音并等待：状态条和菜单会将其显示为未听取，并在你下次说话时交给语音
  （[何时算作已听取](../../docs/architecture/overview.md#a-result-while-the-line-is-closed)）。
- 每个 Claude Code 会话都与语音有各自的对话。它会延续到下一个实时会话中，并在 Stop 和 Start 之间保留，因此语音记得你一分钟前说过的话。
  切换目标会同时切换对话：已打开的线路会关闭，你接下来说的话会带着新目标的对话重新打开它。
- 菜单显示线路打开的分钟数，由应用从语音连接时开始计算，因此你的套餐计入的可能略多一些。OpenAI 按你的 Codex 用量预算的分钟数为桌面语音计价，其 API 上同一模型系列也对静默计费（[详情](../../docs/research/2026-11-04-gpt-live-billing.md)，[限额](../../docs/research/2026-11-05-gpt-live-limits.md)）；以你的套餐自身的用量页面为准。
- 菜单显示你的 Codex 和 Claude 用量已用多少：各一行，按套餐所报告的每个窗口给出已用百分比（每行最多三个，例如 `7% of 5 h · 19% of week`），达到 90% 时显示为橙色；悬停在某一行上可看到各窗口何时重置。Codex 的数字在每次打开菜单时读取，最多每分钟一次，由一个短时运行的 codex 读取；Claude 的数字来自已加入且已回答过的会话。没有可显示内容的行不会出现；当 codex 报告不允许普通用量时，Codex 的那一行会显示 `blocked`。Codex 的上一次读数会立即显示，几秒后由新读数替换，所以菜单打开时数字可能变化；应用刚启动时，那一行在首次读数到达时才出现；如果读取失败，读数会在 15 分钟后消失。哪一项限额最先让语音停下，并未公布（[详情](../../docs/research/2026-11-05-gpt-live-limits.md)）。

## 隐私

LiveBridge 没有遥测，也不监听任何网络端口；模组通过一个只有你的用户才能打开的文件夹中的 Unix 套接字与应用通信。
通过 codex 的实时会话发送给 OpenAI 的内容有：

- 线路打开期间的麦克风音频，从你开始说话前 2 秒起（对于由 Claude 的答复、提问或权限请求打开的线路，则从线路打开时起），直到线路关闭（处于 Mute 时 LiveBridge 不采集任何内容，因此不会有音频发出；你在按下 Mute 之前、线路已在连接过程中说出的话仍可能发出）；
- 语音的指令：LiveBridge 自己的规则，其后是你在设置中写下的 **Prompt**（如果有）；
- 目标会话最近的对话（最多最后 64 行，且不超过 codex 接受的范围：连同上下文和未完成任务共 128 项、约 8,192 个 token），用于在新的实时会话中继续对话。其中包括你在该会话中输入的内容和 Claude 对每个非语音请求轮次的最终答复，无论这一轮由什么发起（你输入的、定时任务、其他代理、后台任务），以及模组的备注和你与语音所说的话，因此在某个会话中输入内容，会在线路以该会话打开时发送给 OpenAI。线路打开期间，目标的每一行新内容会立即进入。其他会话的同步行只有在线路以它为目标打开时才会发出；它的结果、问题和审批通知则会进入已打开的线路，无论是哪个会话；
- 目标会话中仍未完成的请求，以其单行简述的形式；
- 每条结果、问题、更新、审批通知、输入的文字、对非语音请求轮次的答复、被更新的请求取代的语音答复和模组的备注，各为一行，最多 2,000 个字符，已去除代码块和表格（只有代码或表格的输入文字，会替换为一句说明输入了代码的话）。模组的备注会写明被允许或已了结的权限提示所涉及的工具，并说明某个问题已关闭或某一轮没有答复就结束了。Claude 在一轮中途提出的问题，以及 Claude 主循环（而非子代理）请求权限时的审批通知，还会附带 Claude 在此之前刚写下的内容。更新是指后台任务通知所触发的后续一轮中 Claude 的答复，
  在一次语音请求之后最长 10 分钟内，且持续到会话中开始任何其他一轮为止；
- 目标会话的上下文摘要，为一行，最多 1,500 个字符。它在加载时保存，并且只要该会话是目标，每次线路打开时都会发送，
  Stop 和 Start 之间以及应用重启之后也是如此。菜单的 Conversation 子菜单会原样显示这一行的发送内容；
- 以上每一行都附带其会话的标签：Claude Code 会话标题（最多 80 个字符），没有标题时则为会话文件夹的名称。标签不经遮蔽，暂停也不影响它，因此根据被暂停的文字写成的标题会随每一行发出；
- WebRTC offer，其中以连接候选项的形式列出了这台 Mac 的本地网络地址。

开启 **Connect over TCP** 时，音频仍然发往 OpenAI 的媒体服务器，并可能走 TCP（已见到的应答中为 443 端口）而不是 UDP。

结果、问题、更新、摘要和输入轮次的各行会先经过一个针对已知凭据形态的遮蔽器（私钥、JWT、常见 API 令牌、URL 中的密码、`password=` 之类的字段）。
它只是一份模式列表，并不是保证：你输入的其他内容会原样发出。

承载语音的 codex 线程是临时的、只读的，除保存你的登录信息和使用你的代理的方式之外，codex 的所有功能都已关闭，所有 MCP 服务器也都已关闭；
它只用于对话。Claude 的工作则像你的 Claude Code 会话一贯的做法那样发往 Anthropic。

打开菜单时，LiveBridge 会启动一个短时运行的 codex，用你的 ChatGPT 登录向 OpenAI 查询你的 Codex 用量已用多少（每个窗口的已用百分比和重置时间）。此操作最多每分钟一次，通话关闭时也会发生，不会发送音频或文本。Claude 的数字由模组经套接字交给应用，不会发往别处；应用只把两者保存在内存中。

为了更新，应用会与 GitHub 通信。开启 **Check for updates automatically** 后，它每天一次（以及在它通知过的版本尚未安装时的每次启动）在不带任何凭据的情况下向 GitHub 的 API
询问最新的发布版本；GitHub 会看到你 Mac 的 IP 地址。点击 Settings 中的 **Check for update** 时也会发出同样的请求。
自动检查发现较新的版本时，应用会运行 `gh auth status`，以说明映像能否被验证。
只有在你点击 **Install** 时，它才会下载映像并运行 `gh attestation verify` 和 `claude plugin`，它们以你自己的登录身份访问 GitHub，
`gh` 还会访问 Sigstore 获取信任根。[SECURITY.md](../../SECURITY.md#what-leaves-the-mac) 列出了每一项请求。

在你的 Mac 上，应用把设置、用量计量、上次检查更新的时间和已通知过的版本、上一次更新做了什么，以及最近使用的 20 个会话各自的近期对话（最多 64 行，包括你在其中输入的内容；除非你开启 **Pause sync**，否则无需通话也会记录）和上次从中加载的上下文行，保存在
`~/Library/Application Support/LiveBridge`，该文件夹只有你的用户才能打开（[保存方式](../../SECURITY.md#residual-risk-by-design)）。当你以某个会话为目标按下 **New
conversation**，或用 × 移除它时，该会话的这些行就会被删除。已离开的会话会保留这些内容，
直到之后使用的 20 个会话将其挤出；若想更早地清除，请在其中再次运行 `/live` 并点击 **New conversation**。卸载会将它们全部移除；菜单中的 Uninstall LiveBridge 会把它们移到废纸篓，清倒废纸篓后才会消失。模组在 Claude Code 的插件存储中保留自己的快照（[其中有什么](../../SECURITY.md#residual-risk-by-design)）。**Debug mode** 默认关闭，开启后会在通话期间把语音的网络数据写入该文件夹中的一个文件，仅此而已（[设置](#设置)）。

[SECURITY.md](../../SECURITY.md) 给出了威胁模型：简而言之，凡是你的麦克风能听到的内容，都可能变成一条请求，由 Claude 在该会话自己的权限模式下执行。

## 已知限制

- **Connect over TCP** 只是优先 TCP，并不强制，通话期间也不显示线路实际用了哪种传输方式，所以退回 UDP 的线路仍可能断续。这条路线只测量过一次，是在一个移除了 UDP 候选项的调试版本中（10 分钟内没有丢失音频）；正式采用的方式，即降低其优先级，只观察到一次选择了 TCP。调试模式会记录传输方式（`onTcp`）（[CONTRIBUTING.md](../../CONTRIBUTING.md#reading-debug-modes-numbers)）。
- 语音有时会说它在查看（“On it”“Looking now”），却没有转交请求，于是什么也没有送到 Claude：按最初写下的规则，约五分之一的请求如此；按现在的规则为 20 次中 0 次，次数太少，无法与运气区分（[BR-001](../../docs/bugs/BR-001.md)）。它还可能声称做了它没有做的工作，例如 “I'll take a look.”，包括根据只作为上下文拥有的行（[ADR 0001 (n), (o)](../../docs/adr/0001-platform-findings.md)）。应用把请求放入 Claude 的队列时会播放一声短音，它不同于回答的声音；如果语音说它在查看却没有这声短音，请再说一遍。应用无法凭措辞区分这种承诺和回答，因为语音说的是你的语言。
- Claude 的提问或它正在等待的权限提示只是交给语音，语音可能不说；没有什么能强制它说。所以离开 Mac 时不要依赖语音来播报提示：Claude 可能在没有任何通知的情况下等待。提示仍在 Claude Code 中等待，它才是唯一的控制手段；语音不是控制手段，LiveBridge 也绝不回答提示。在检查中，打开的线路上来自输入轮次的权限通知，在键盘回答之前被说出的次数为 3 次运行中 0 次，这是计数，不是比率（[ADR 0001 (n)](../../docs/adr/0001-platform-findings.md)）。已关闭的线路只有在目标会话的对话中有你的一轮时才会为它们打开；否则应用发出提示音，通话关闭时则只做记录。
- Claude 桌面应用把输入的提示的来源报告成什么，尚未观察到（[ADR 0001 (m)](../../docs/adr/0001-platform-findings.md)）。模组只有在提示的来源是 `composer` 时才把它记录为你的。如果在那里输入的提示以其他来源到达，在那里输入的内容都不会被记录，也不会标记缺口，菜单显示 **Context up to date**，暂停的作用范围也会变小（[详情](../../SECURITY.md#what-session-text-can-do)）。
- 在线路等待期间到达的结果，会作为待说出的文本交给语音；codex 没有能让语音立即开口的调用，因此由模型决定何时说。
  测试中它在几秒内就说了。如果没有说，结果仍保持未听取：它会在你接下来说话时再次交给语音，或在线路关闭时发出提示音。
- 当 Claude 的答复重新打开线路时，语音可能保持沉默：实测的 14 次运行中有 4 次如此，样本较小（[ADR 0001 (n)](../../docs/adr/0001-platform-findings.md)）。
  此时线路会在等待第一句话的时间结束时关闭（[设置](#设置)），答复会像下文所述那样发出提示音并等待。语音开口时，都是在连接后约 2 秒内开始；若在这段等待之后才开始，则会被截断。
- 当你接下来说的话重新打开线路时，语音有时只回应这些话，而不说出等待中的结果。结果并没有丢失：它仍在等待，
  会在线路关闭时发出提示音并推送通知，并在线路下次打开时再次交给语音。
- 达到你的 ChatGPT 套餐的用量限额时，语音会停止，直到限额重置。菜单和状态条会说明这一点，使用 codex 的原句，并在 codex 给出时附上重置时间；通话随之结束，这样说话就不会再打开注定失败的线路。Claude Code 继续工作，答复继续等待，Start 会再试一次。应用只能靠 codex 的措辞或服务的错误代码识别限额，因为没有别的信号（[详情](../../docs/research/2026-11-05-gpt-live-limits.md)）。它无法识别的拒绝，例如没有说明原因就断开的线路（“The voice session closed (transport_closed).”），通话会保持开启，你接下来说的话会再次尝试；在限额重置之前请按 **Stop**。
- 不是在输入框中键入的提示（host 的消息、定时任务、其他代理，大概还有 Remote Control），不会作为你的话记录到语音的对话中，但 Claude 对它的答复会被记录，而且在暂停下它不会拒绝正在运行的一轮（哪些提示算作你的，见 [SECURITY.md](../../SECURITY.md#what-session-text-can-do)）。
- 若 Claude Code 的提供方（Bedrock、Vertex 或 Foundry）不提供 **Summary model** 中选择的模型，或组织不允许使用它，该模型会失败并由 Haiku 5.5 撰写摘要；若连 Haiku 5.5 也不提供，语音就得不到摘要，Settings 会说明。在此设置之前，摘要由会话自己的模型撰写，只要会话能用就能用。固定 id 能在这些提供方上解析，这一点来自 Claude Code 的文档，未经实际运行。
- 仍在使用此版本之前模组的会话，在重启之前不会同步：它会像缺少轮次的会话那样加载摘要，暂停也不会拒绝它的行（[其他差异](../../CHANGELOG.md)）。
- 在模组加载之前就已打开的 Claude Code 会话，可能需要重新打开，`/live` 才能在其中使用。
- 在 Claude 桌面应用中，如果在其 Claude Code 进程尚未启动的会话（新建的会话，或刚重新打开的会话）里输入 `/live`，
  可能会显示“/live isn't a command here.”，但命令仍会执行。桌面应用是通过一次关闭了 hooks 的检查来列出这类会话的命令的，
  因此声明了 `/live` 的模组代码不会在那里运行；会话运行起来之后，桌面应用就会从会话本身获取命令列表。模组对此没有修复办法：
  静态命令文件会被列为 `/livebridge:live` 而不是 `/live`，而且在 hooks 关闭时，它会把自己的文本发给模型，而不是运行模组。
- 一条答复是否已经说出了等待中的结果，是根据其用词来判断的，所用的常用词表只涵盖英语和俄语
  （[规则](../../docs/architecture/overview.md#a-result-while-the-line-is-closed)）。在其他语言中，
  语音只是提到了结果，也可能被算作已听取。
- 在由组织管理 Claude Code 的环境中，LiveBridge 不会告诉你有权限提示正在等待。Claude Code 的内置防护会在有托管设置的机器上，
  以及用 Team 或 Enterprise 套餐登录的会话中加载，此时模组的权限 hooks 不会运行。提示仍会出现在 Claude Code 中并等待你回应，
  但语音不会提到它，菜单也只显示 Claude 正在工作，所以如果答复迟迟不来，请查看 Claude Code。`/plugin` 会列出这些 hooks，
  较新版本的 Claude Code 还会打印一行文字说明某个 hook 被跳过。Claude 提出的问题仍会传到语音。这些 hooks 是在 Linux 容器中[实测](../../docs/adr/0001-platform-findings.md)的；
  语音和菜单栏的表现是从代码推断的，没有运行真实线路。Team 和 Enterprise 的情况来自 Claude Code 的文档。
- 如果托管设置中有 `allowManagedHooksOnly`、`allowManagedModsOnly` 或 `disableAllHooks`，模组不会加载，`/live` 也无法使用。
  管理员可以从每台机器上的一个文件夹[把模组安装为组织自己的模组](https://code.claude.com/docs/en/plugins/mods/admin#install-your-organizations-mods)，这样权限 hooks 就会运行，在前两项设置下也一样（[实测](../../docs/adr/0001-platform-findings.md)）。
  根据 Claude Code 的文档，在托管设置中启用 marketplace 副本是不够的。

## 工作原理

[docs/architecture/overview.md](../../docs/architecture/overview.md) 描述了各组件、模组与应用之间的通信协议以及消息流；
[ADR 0001](../../docs/adr/0001-platform-findings.md) 记录了该设计所依据的平台事实。

## 路线图与欢迎协助

目前的 LiveBridge 是一个 Mac 应用、一个执行者（Claude Code）和一个语音提供方（使用 ChatGPT 登录的 codex）。三者在狭窄的接缝处相接，
下面的每个方向都欢迎贡献者参与。相关议题带有
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
标签；[CONTRIBUTING.md](../../CONTRIBUTING.md#where-to-start) 指出了应先阅读的文件。

- **Windows 和 Linux。** 菜单栏应用、它的音频页面和套接字服务器都与 macOS 绑定；模组与应用之间的协议以及模组本身是可移植的。
  移植从为新平台编写一个使用同一协议的应用开始。
- **其他智能体作为执行者**，例如 Codex CLI、Hermes Agent 或 Gemini CLI：每一个都需要自己的适配器，使用与 Claude Code 模组相同的协议。
- **其他语音提供方**，例如使用你自己 API 密钥的 OpenAI Realtime API，或 Google 的 Gemini Live API：每一个都将是应用实时协议的另一种实现。

## 参与贡献

欢迎贡献。对于比一次修复更大的改动，请先开一个议题，以便在开工前商定方案。适合入手的地方有
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
议题、[已知限制](#已知限制)以及[上文](#路线图与欢迎协助)的各个方向。

- [CONTRIBUTING.md](../../CONTRIBUTING.md)：目录布局、工具链、检查（`scripts/check.sh`）和约定。
- [议题表单](https://github.com/getLiveBridge/LiveBridge/issues/new/choose)：报告缺陷或提出功能请求。
- [CODE_OF_CONDUCT.md](../../CODE_OF_CONDUCT.md)：我们在这里如何相互对待。
- [SECURITY.md](../../SECURITY.md)：请私下报告漏洞，不要发在公开议题中。
- [CHANGELOG.md](../../CHANGELOG.md)：每个发布版本的变更。

## 致谢

模组与应用之间的通信协议受到
[claude-code-voice-mod](https://github.com/ldk00315-jpg/claude-code-voice-mod) 的启发。没有复制它的任何代码或文字。

## 许可证

[MIT](../../LICENSE)。
