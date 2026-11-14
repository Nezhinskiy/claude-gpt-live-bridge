<p align="center"><a href="../../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <b>हिन्दी</b> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.ru.md">Русский</a> · <a href="README.uk.md">Українська</a></p>

<p align="center"><img src="../../site/assets/icon.png" alt="LiveBridge ऐप आइकन" width="144"></p>

<h1 align="center">LiveBridge</h1>

<p align="center"><strong>खुले Claude Code session से voice में बात करें।</strong></p>

<p align="center">
  <a href="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml"><img src="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/getLiveBridge/LiveBridge"><img src="https://api.scorecard.dev/projects/github.com/getLiveBridge/LiveBridge/badge" alt="OpenSSF Scorecard"></a>
  <a href="https://www.bestpractices.dev/projects/16502"><img src="https://www.bestpractices.dev/projects/16502/badge" alt="OpenSSF Best Practices"></a>
  <a href="../../LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="लाइसेंस: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B%20%C2%B7%20Apple%20Silicon-lightgrey.svg" alt="प्लेटफ़ॉर्म: Apple Silicon पर macOS 14+">
</p>

<p align="center">
  <a href="https://getlivebridge.com">getlivebridge.com</a> ·
  <a href="#त्वरित-शुरुआत">त्वरित शुरुआत</a> ·
  <a href="#इंस्टॉल-करना">इंस्टॉल</a> ·
  <a href="#उपयोग">उपयोग</a> ·
  <a href="#बिलिंग-का-ध्यान-रखने-वाला-डिज़ाइन">बिलिंग</a> ·
  <a href="#गोपनीयता">गोपनीयता</a> ·
  <a href="#ज्ञात-सीमाएँ">सीमाएँ</a> ·
  <a href="#रोडमैप-और-सहयोग-चाहिए">सहयोग चाहिए</a> ·
  <a href="#योगदान">योगदान</a>
</p>

LiveBridge एक macOS menu bar app है, जो आपके ChatGPT login पर `codex app-server` के ज़रिए GPT-Live
voice line तैयार रखता है (API key की ज़रूरत नहीं)। Voice फ्रंट डेस्क की तरह काम करता है: वह बातचीत
करता है, पूछता है कि आपका मतलब क्या है, और असली काम एक छोटे Claude Code mod, `livebridge`, के ज़रिए
आपके Claude Code session को सौंप देता है। Claude अपने model, tools और permission mode से काम करता
है, और voice आपको नतीजा बताता है। Claude के काम करते समय line खुली रखने की ज़रूरत नहीं: उसका जवाब
बंद line को फिर से खोलता है और voice को बोलने के लिए दिया जाता है। Voice यह भी जानता रहता है कि आप
session में क्या टाइप करते हैं और Claude क्या जवाब देता है, इसलिए आप बोलने और टाइप करने के बीच आ-जा
सकते हैं।

*मूल पाठ अंग्रेज़ी में है ([README.md](../../README.md)); यह अनुवाद पीछे रह सकता है।*

**बातचीत, डिक्टेशन नहीं।** GPT-Live बोलते समय भी सुनता रहता है: बीच में टोकें तो वह रुककर आपकी बात सुनता है; ज़ोर से सोचें तो वह छोटा-सा "हम्म" बोल सकता है। **ख़ामोशी के पैसे देना बंद:** OpenAI आवाज़ का शुल्क मिनट के हिसाब से लेता है, इसलिए [सेटिंग्स](#सेटिंग्स) में आपके तय किए गए समय तक चुप्पी रहने के बाद लाइन बंद हो जाती है और आपके बोलते ही फिर खुल जाती है, और बातचीत वहीं से आगे बढ़ती है जहाँ आपने छोड़ी थी ([बिलिंग](#बिलिंग-का-ध्यान-रखने-वाला-डिज़ाइन))।

<p align="center"><img src="../assets/readme-demo.gif" alt="LiveBridge के ज़रिए Claude Code session से बात करना" width="100%"></p>

**डिज़ाइन से ही लोकल।** कोई telemetry नहीं और अपना कोई server नहीं: LiveBridge आपके Mac पर आपके अपने
codex और आपके अपने Claude Code के बीच एक bridge है। App और mod सिर्फ़ एक Unix socket पर बात करते
हैं, जिसे केवल आपका user खोल सकता है, और app किसी network port पर listen नहीं करता। जो traffic ये
दोनों tools पहले से भेजते हैं (voice line का traffic आपके codex के ज़रिए OpenAI को, सिर्फ़ तब जब line खुली हो, साथ में जुड़े session में आपका टाइप किया text, और Claude का काम आपके Claude Code session के ज़रिए Anthropic को), उसके अलावा app का
अपना traffic सिर्फ़ ये है: menu खोलने पर थोड़ी देर चलने वाला एक codex OpenAI से आपके Codex usage के आँकड़े
माँगता है, call बंद हो तब भी; और [updates](#अपडेट-करना) का traffic: GitHub से नए release की अपने-आप होने वाली जाँच
(दिन में एक बार, और हर launch पर जब तक उसके बताए release को install न किया गया हो), जिसे आप बंद कर
सकते हैं; **Check for update** दबाने पर वही जाँच; नए release की सूचना देने पर `gh auth status`; और
**Install** click करने पर download, उसकी जाँच और mod का update। [गोपनीयता](#गोपनीयता) में ठीक-ठीक
लिखा है कि OpenAI तक क्या पहुँचता है, और GitHub को भेजे जाने वाले app के requests के नाम भी वहीं
हैं; [SECURITY.md](../../SECURITY.md) बताता है कि यह किस चीज़ से बचाता है और किस चीज़ से नहीं।

> **अनौपचारिक।** इसका Anthropic या OpenAI से कोई संबंध नहीं है, और न ही उनका समर्थन या सपोर्ट
> इसे हासिल है। यह codex के experimental realtime API पर निर्भर है, जो codex के किसी भी release
> के साथ बदल सकता है।

## त्वरित शुरुआत

आपको चाहिए: Apple Silicon पर macOS 14+, Claude Code 2.1.301+, और [codex](https://github.com/openai/codex),
जिसमें `codex login` से ऐसे ChatGPT plan पर sign in किया गया हो जिसके Codex में voice शामिल है;
app को खुद build करने के लिए Swift 6.0+ वाला Xcode भी। विवरण [आवश्यकताएँ](#आवश्यकताएँ) में हैं।

```sh
# 1. The mod, from this repository's marketplace
claude plugin marketplace add getLiveBridge/LiveBridge
claude plugin install livebridge@livebridge

# 2. The app, built from source, installed in /Applications and opened
git clone https://github.com/getLiveBridge/LiveBridge.git
cd livebridge
scripts/build-app.sh --release
```

3. जिस Claude Code session से बात करनी है, उसमें `/live` टाइप करें।
4. prompt के ऊपर वाले band में **Start** दबाएँ, microphone की अनुमति दें, और बोलें।

खुद build नहीं करना चाहते? हर [release](https://github.com/getLiveBridge/LiveBridge/releases/latest)
में app एक disk image के रूप में मिलता है, जिसे GitHub Actions ने build और attest किया है;
उसे कैसे जाँचें और खोलें, यह [डिस्क इमेज से](#डिस्क-इमेज-से) में है। mod दोनों तरीकों में एक ही
तरह install होता है।

अगर पहले से खुले session में `/live` नहीं मिलता, तो session दोबारा खोलें ([क्यों](#ज्ञात-सीमाएँ))।
Update, अनुमतियाँ, नए build के बाद भी microphone की अनुमति बनाए रखना और uninstall करना
[इंस्टॉल करना](#इंस्टॉल-करना) में हैं।

## आवश्यकताएँ

- Apple Silicon पर macOS 14 या उसके बाद का संस्करण।
- Claude Code 2.1.301 या उसके बाद का संस्करण।
- [Codex CLI](https://github.com/openai/codex) (`codex`, 0.166.0 के साथ टेस्ट किया गया), जो
  Homebrew (`brew install --cask codex`) या npm (`npm install -g @openai/codex`) से install हो,
  Terminal window में आपके shell द्वारा सेट किए गए `PATH` पर हो, और `codex login` से ऐसे ChatGPT plan
  पर sign in हो जिसके Codex में voice शामिल है (Plus, Pro, Business, Enterprise या Education,
  [OpenAI की Codex pricing](https://learn.chatgpt.com/docs/pricing) के अनुसार)। जिस codex की `codex features list` LiveBridge पढ़
  नहीं पाता, उसे वह अस्वीकार कर देता है, इसलिए कोई दूसरा संस्करण तब तक शुरू नहीं हो सकता जब तक
  LiveBridge अपडेट न हो।
- App build करने के लिए: Swift 6.0 या उसके बाद के toolchain वाला Xcode। टेस्ट किए गए संस्करण
  [CONTRIBUTING.md](../../CONTRIBUTING.md#toolchain) में हैं। Build किया हुआ app macOS 14 या उसके बाद के संस्करण पर चलता है।

## इंस्टॉल करना

mod इस repository के marketplace से आता है ([त्वरित शुरुआत](#त्वरित-शुरुआत) के commands), जो नवीनतम
release के tag की ओर इशारा करता है, इसलिए आप जो mod install करते हैं वह उसी release का होता है। App
दोनों तरीकों में `/Applications` में जाता है: disk image से, या source से build करके। 0.4.2 के बाद के पहले release से, डिस्क इमेज
LiveBridge की Developer ID से signed और Apple द्वारा notarized है; 0.4.2 और उससे पहले के releases ad hoc
signed थे और notarized नहीं हैं, और source से बना build न तो Developer ID से signed होता है और न notarized।

### डिस्क इमेज से

1. नवीनतम release से
   [LiveBridge.dmg](https://github.com/getLiveBridge/LiveBridge/releases/latest/download/LiveBridge.dmg)
   डाउनलोड करें।
2. उसे [GitHub CLI](https://cli.github.com) से जाँचें, उसी folder में जहाँ आपने उसे सेव किया है:

   ```sh
   gh attestation verify LiveBridge.dmg --repo getLiveBridge/LiveBridge \
     --signer-workflow getLiveBridge/LiveBridge/.github/workflows/release.yml \
     --source-ref refs/tags/vX.Y.Z --deny-self-hosted-runners
   ```

   जहाँ `vX.Y.Z` release का tag है, जैसा उसके page पर लिखा है। यह जाँच सिर्फ़ ऐसी image के लिए पास
   होती है जिसे इस repository के [release workflow](../../.github/workflows/release.yml) ने उसी tag से,
   GitHub के अपने (GitHub-hosted) runner पर, build किया हो और जो तब से बदली न हो। 0.4.2 के बाद के release पर Developer ID
   signature, जिसे macOS खुद जाँचता है, बताता है कि image पर किसने sign किया, और यह जाँच बताती है कि वह
   किससे build हुई थी; 0.4.2 और उससे पहले के releases पर, जिनका ad hoc signature किसी का नाम नहीं बताता,
   यह जाँच image के origin का इकलौता प्रमाण है। यह इस बात का प्रमाण नहीं है कि किसी ने code की समीक्षा की है।
3. उसे खोलें और LiveBridge को Applications में drag करें।
4. पहली बार launch करने पर, 0.4.2 के बाद के release पर macOS पूछता है कि internet से download किया गया
   app खोलना है या नहीं; **Open** पर click करें। 0.4.2 और उससे पहले के releases तब तक blocked रहते हैं जब तक
   आप उन्हें System Settings > Privacy & Security > **Open Anyway** में अनुमति नहीं देते।

### Homebrew से

```sh
brew install --cask getlivebridge/tap/livebridge
```

यह वही डिस्क इमेज [LiveBridge के अपने tap](https://github.com/getLiveBridge/homebrew-tap) से इंस्टॉल करता है, जो Homebrew का आधिकारिक cask नहीं
है। Homebrew पहले इस tap पर भरोसा करने को कह सकता है, और macOS पहली बार खोलने पर ऊपर बताए अनुसार पूछता
है। इसके बाद app खुद अपडेट होता है।

### सोर्स से

`scripts/build-app.sh --release` app को build करता है, उसे `/Applications` में install करता है (आपके
account को वहाँ लिखने का अधिकार होना चाहिए, जैसा administrator के पास होता है) और खोल देता है।
दोबारा build करने के लिए इसे फिर से चलाएँ। Build ad hoc signed होता है, इसलिए हर नए build के बाद
macOS microphone के लिए दोबारा पूछता है। अनुमति बनाए रखने के लिए
`scripts/build-app.sh --make-signing-identity` एक बार चलाएँ: यह पहले पूछता है, फिर आपके login
keychain में एक self-signed code-signing certificate बनाता है, और बाद के release builds उसी से sign
होते हैं।

marketplace mod को पिछले release के tag पर pin करता है, इसलिए default branch से बना app उसी release
के mod के साथ चलता है। दोनों को मिलाने के लिए release का tag build करें (`git checkout vX.Y.Z`), या
`claude --plugin-dir plugin` से working tree का mod load करें।

source से बना build updates की जाँच अपने-आप तभी करता है जब आप Settings में इसे चालू करें। Update
install करने पर वह release की image से बदल जाता है, जो LiveBridge की Developer ID से signed है,
आपके self-signed certificate से नहीं, इसलिए macOS microphone के लिए एक बार फिर पूछता है; **Install** यह
बताता है और पहले पूछता है।

### अपडेट करना

LiveBridge app और अपने mod को तभी update करता है जब आप **Install** click करें, अपने-आप कभी नहीं।
सिर्फ़ `/Applications/LiveBridge.app` वाली copy update होती है; कोई और copy Settings में यही बताती
है।

- **Check for updates automatically**, Settings में (डिफ़ॉल्ट रूप से चालू, source से बने build के
  लिए बंद): दिन में एक बार app GitHub से पूछता है कि नवीनतम release कौन-सा है। नए release की सूचना
  एक ही बार दी जाती है, एक notification से जिसका **Install** उसे install करता है, और menu bar menu
  में **Install LiveBridge X.Y.Z…** तब तक रहता है जब तक वह install न हो जाए; इस item को बनाए रखने के
  लिए app हर launch पर GitHub से फिर पूछता है। Settings का **Check for update** तुरंत पूछता है।
- **Install** के लिए [GitHub CLI](https://cli.github.com) में login होना चाहिए (`gh auth login`);
  इसके बिना Install कुछ भी download नहीं करता और release page का link देता है। यह release की image
  download करता है, उसे ऊपर वाले उसी `gh attestation verify` से जाँचता है, फिर उसके अंदर के app को
  जाँचता है, और जब तक हर जाँच पास न हो, कुछ install नहीं करता। जब तक Claude किसी voice request पर
  काम कर रहा हो, यह इंतज़ार करता है, `claude plugin marketplace update livebridge` और
  `claude plugin update livebridge@livebridge` से mod update करता है, call रोकता है, नए app को एक ही
  step में उसकी जगह रखता है और उसे खोलता है।
- इसके बाद Settings बताता है कि update किस version से हुआ। अगर mod update नहीं हो सका, तो वहाँ ये
  दोनों commands दिखते हैं ताकि आप इन्हें खुद चलाएँ। पहले से खुले Claude Code sessions restart होने
  तक पुराना mod ही रखते हैं; Settings उन जुड़े sessions को दिखाता है जो अब भी उसे चला रहे हैं।
- update का download कोई quarantine attribute नहीं लगाता, इसलिए macOS को updated app का पहला launch
  पूछने के लिए वैसे नहीं रोकना चाहिए जैसे पहले download के बाद रोका था; यह code से निकलता है और अभी असल
  में देखा नहीं गया है। उसकी जगह ऊपर वाली जाँचें लेती हैं
  ([SECURITY.md](../../SECURITY.md#what-an-update-installs))। 0.4.2 के बाद के releases LiveBridge की
  Developer ID से signed हैं, इसलिए microphone की अनुमति एक release से अगले में जानी चाहिए; यह इस पर आधारित है कि macOS
  अनुमति को कैसे जोड़ता है, और अभी तक देखा नहीं गया है। 0.4.2 और उससे
  पहले के releases ad hoc signed थे, इसलिए उनमें से किसी से पहला update पहले **Start** पर microphone के लिए
  एक बार फिर पूछता है।

हाथ से update करने के लिए, हर session में `/live off` चलाएँ (app जवाब देना बंद करते ही mod
`/Applications` वाला app फिर खोल देता है), LiveBridge बंद करें, नई image ऊपर बताए तरीके से install
करें और दोनों `claude plugin` commands चलाएँ।

### अनुमतियाँ

पहली बार Start करने पर macOS से microphone माँगा जाता है। अगर मना कर दिया गया, तो call एक वाक्य के
साथ रुक जाती है और menu bar menu का **Open Microphone Settings** Privacy & Security > Microphone खोल
देता है, जहाँ आप LiveBridge को अनुमति देते हैं। macOS किसी ad hoc release से पहले update के बाद, और source से बने हर ad hoc signed rebuild के बाद, पहले
Start पर फिर पूछता है (ऊपर देखें)। macOS यह भी पूछ सकता है कि क्या LiveBridge आपके local
network पर devices खोज सकता है। voice line को यह दूसरी अनुमति भी चाहिए; इसके बिना call एक वाक्य के
साथ रुक जाती है, जो बताता है कि इसे कहाँ allow करना है।

### अनइंस्टॉल करना

`/Applications` वाली copy में menu का **Feedback & Support ▸ Uninstall LiveBridge…** पहले
पूछता है और app को Trash में ले जाता है; अगर न ले जा सके, तो यह बताता है और कुछ और नहीं बदलता। फिर खुली call खत्म होती है और हर session LiveBridge छोड़ देता है, जैसे menu के × से,
इसलिए उसमें `/live` LiveBridge को फिर से खोलने के बजाय बंद हो जाता है; LiveBridge login item और
microphone permission हटाकर बंद हो जाता है, और उसके बंद होने के बाद उसकी files (नीचे दी गई)
Trash के एक folder में चली जाती हैं, जब तक आप उसे खाली न करें। Claude Code का mod बना
रहता है: उसे हटाने वाला command, `claude plugin uninstall livebridge@livebridge`, copy हो
जाता है ताकि आप उसे Terminal में चलाएँ। जो session तब खुला नहीं था, वह खुलने पर फिर से
LiveBridge ढूँढ सकता है; mod हटाने से यह रुक जाता है।

Homebrew से install किया था? `brew uninstall --cask getlivebridge/tap/livebridge` app और Homebrew का उसका record हटा देता
है; app की files के लिए नीचे के steps फिर भी लागू हैं।

किसी clone से, `scripts/build-app.sh --uninstall` `/Applications/LiveBridge.app` को हटा देता है,
चाहे वह जैसे भी install हुआ हो, साथ ही उसका login item और उसकी रखी हर फ़ाइल, और वे दो commands
प्रिंट करता है जो वह आपके लिए छोड़ देता है: `tccutil reset Microphone com.getlivebridge.livebridge` और
`claude plugin uninstall livebridge@livebridge`।

Clone के बिना, LiveBridge की Settings में **Open at login** बंद करें, LiveBridge को quit करें, और
Terminal में वही steps चलाएँ:

```sh
rm -rf /Applications/LiveBridge.app ~/Library/Application\ Support/LiveBridge \
  ~/Library/{Caches,WebKit}/com.getlivebridge.livebridge \
  ~/Library/HTTPStorages/com.getlivebridge.livebridge{,.binarycookies} \
  ~/Library/Preferences/com.getlivebridge.livebridge.plist
tccutil reset Microphone com.getlivebridge.livebridge
claude plugin uninstall livebridge@livebridge
```

इनमें से कोई भी तरीका `/Applications/.LiveBridge-update-….app` नाम की copy नहीं हटाता, जो install के
बीच में रुका update छोड़ सकता है। app ऐसी copies अगले launch पर हटा देता है; uninstall के बाद, अगर
ऐसी copy हो तो उसे हाथ से हटाएँ।

`claude plugin uninstall` शायद mod का snapshot, `~/.claude/plugins/store/livebridge_*.json`, छोड़
दे: Claude Code की documentation में जो हटता है उसकी सूची में यह file नहीं है, और यह चलाकर नहीं देखा
गया। अगर वह मौजूद हो तो उसे हाथ से मिटा दें।

## उपयोग

### कमांड

जिस Claude Code session से बात करनी है, उसमें:

| Command | क्या करता है |
|---|---|
| `/live` | session के title के नाम से LiveBridge से जुड़ता है, और app चल नहीं रहा हो तो उसे खोलता है। जुड़े हुए session में band वापस लाता है और एक पंक्ति में जवाब देता है: call, target, न सुने गए नतीजे, आज के मिनट। |
| `/live off` | LiveBridge से अलग हो जाता है। |

Command `/live` है, `/voice` नहीं, क्योंकि `/voice` Claude Code का अपना voice mode है। call रुकी होने पर session में टाइप किया
हुआ voice से बाहर रखा जाए या नहीं, यह कोई command नहीं है: यह सभी sessions के लिए एक
setting है, जो LiveBridge की [सेटिंग्स](#सेटिंग्स) window में है।

### बैंड और मेन्यू

**Start** दबाएँ, prompt के ऊपर वाले band में या menu bar menu में, और बोलें।

- **band का Start** अपने session को target बनाता है और call शुरू करता है; जो line वह खोलता है उसे
  session की conversation मिलती है, और सारांश वह तब भी load करती है जब voice के पास session का कुछ
  हिस्सा न होता (नीचे **Load context** देखें), पर **Pause sync** चालू रहते या pause के बाद सिर्फ़ तब जब उसका सारांश अभी न हो
  ([विवरण](../../docs/architecture/overview.md#components))। इस release के mod के साथ सारांश Start पर और
  call के दौरान target बदलने पर माँगा जाता है, और line जुड़ने से पहले उसका इंतज़ार करती है, माँगने से
  अधिकतम 10 सेकंड: इस बीच आप जो कहते हैं वह Mac पर रखा जाता है और line खुलने पर voice तक पहुँचता
  है। इंतज़ार के दौरान Stop या target बदलना रखी हुई बात को हटा देता है, और **Connect over TCP**
  बदलने के बाद का reconnect भी, जो दोबारा खुलने वाली line के लिए ज़्यादा से ज़्यादा
  आख़िरी 2 सेकंड रखता है। जब call किसी दूसरे session से बात कर रही हो,
  तब band **Talk here** दिखाता है। अगर जुड़े हुए session में band न दिखे, तो `/live` उसे वापस ले
  आता है।
- **Menu bar menu** में call, जुड़े हुए sessions (किसी पर click करके उसे target बनाएँ),
  **Load context**, target की **Conversation** (जैसी LiveBridge उसे रखता है, voice के Claude को सौंपे
  हर अनुरोध के लिए एक **Task** पंक्ति और जहाँ सारांश load हुआ वहाँ एक **Loaded context** पंक्ति के साथ), उपयोग की सीमाएँ, मिनट,
  **Quick Settings** (**Connect over TCP**, **Play sounds for requests and answers**, **Notify when a result is waiting**, **Pause sync while the call is stopped** और **Load a session's context on its first call** के checkmark items),
  **Settings…**, **Feedback & Support** (**Report a Bug…** repository का bug report form खोलता है,
  **LiveBridge Website** getlivebridge.com खोलता है, **Star LiveBridge on GitHub** repository का page
  खोलता है, फिर **Debug Mode** और **Show Debug Files…**, [debug mode](#सेटिंग्स) का switch और
  folder, और **Uninstall LiveBridge…** ([अनइंस्टॉल करना](#अनइंस्टॉल-करना))) और **Quit LiveBridge** होते हैं। जब menu में सिर्फ़ call दिखती है, तब भी Quick Settings
  वहाँ होता है। call के दौरान **Conversation** आपके और voice के शब्द
  वैसे-वैसे दिखाता है जैसे-जैसे codex उन्हें transcribe करता है, इसलिए आपके शब्द बोलने के थोड़ी देर बाद, और
  voice के शब्द सुनाई देने से थोड़ा पहले दिख सकते हैं। हर बात पूरी होने पर उसका अंतिम पाठ इन शब्दों की जगह
  ले लेता है। सिर्फ़ अंतिम पाठ रखा जाता है: line बंद होने तक जिन शब्दों को अंतिम पाठ नहीं मिला, वे चले जाते हैं।
- **Mute** (**Stop** के बगल में, band में और menu के call card में; muted होने पर **Unmute**) call
  चलते रहने के दौरान आपका microphone छोड़ देता है: Claude का जवाब फिर भी line खोलता है और voice को
  बोलने के लिए दिया जाता है। band phase वैसी ही रखता है और `· muted` जोड़ता है; जब कोई line खुली न
  हो, menu "Muted — line closed" कहता है। Mute line बंद नहीं करता: खुली line सामान्य चुप्पी के बाद
  बंद होती है, जो आप बोल रहे थे तो Mute से गिनी जाती है, और line पहले से शांत थी तो तब बंद होती है
  जब Mute के बिना होती; वह किसी भी चुप्पी की तरह billed होती है, इसलिए Mute से realtime minutes नहीं
  बचते। **Unmute** microphone फिर लेता है, और न ले पाए (मना किया गया, busy, मौजूद नहीं) तो call कारण
  के साथ ख़त्म हो जाती है। **Stop** call और mute दोनों ख़त्म करता है; अगला **Start** unmuted शुरू
  होता है। Mute कोई ताला नहीं है: आपके user के रूप में चल रहा कोई भी process उसे हटा सकता है
  ([SECURITY.md](../../SECURITY.md#who-can-drive-the-bridge))।
- **Load context** तभी चालू होता है जब voice के पास target का कुछ हिस्सा नहीं है: सारांश नहीं है और **Pause sync** अगली line को उसे load करने से रोकता है,
  कोई turn नहीं पहुँचा, कोई सवाल या permission notice app तक नहीं पहुँचा, mod बंद रहते turns चले,
  सारांश के बाद की पंक्तियाँ अब voice की क्षमता में पूरी नहीं समातीं (लंबी conversation इससे बढ़
  जाती है), session paused रहा है और उसका सारांश है, या उसका mod sync नहीं करता। नहीं तो यह item **Context up to
  date** दिखाता है और बंद रहता है, क्योंकि voice के पास conversation पहले से है। अगर कोई line खुली न हो, अगली line सारांश load करेगी और बाकी कुछ नहीं छूटा है, तो यह
  **Context loads with the line** दिखाता है और बंद रहता है, क्योंकि अगली line उसे खुद माँगती है। जब target का सारांश
  रास्ते में हो, उसे किसी ने भी माँगा हो, item **Loading context…** दिखाता है और बंद रहता है, ज़्यादा से ज़्यादा उन 60 सेकंड तक जो mod उसे देता है (पुराने mod पर वह **Load context** ही रहता है); आया हुआ
  सारांश कुछ पल **Context loaded** दिखाता है, और खाली जवाब वापस **Load context** पर ले आता है। सारांश पर कोई तारीख
  नहीं होती, इसलिए वह अनदेखा हो सकता है जबकि item चालू रहता है ([BR-002](../../docs/bugs/BR-002.md))।
- **New conversation…** target की conversation और उसका loaded context मिटा देता है, और किसी session
  का × उसे हटाता है और उसकी अपनी conversation मिटा देता है; दोनों पहले पूछते हैं। Voice अगली बार
  line खुलने से नए सिरे से शुरू होता है। जो नतीजे उसने अभी नहीं बोले वे रहते हैं और फिर से जोड़े
  जाते हैं; उन्हें सिर्फ़ **Stop** मिटाता है। Claude के इंतज़ार कर रहे सवालों के नियम अलग हैं
  ([विवरण](../../SECURITY.md#residual-risk-by-design))। **Load a session's context on its first call** चालू हो, या **Pause sync** बंद हो और session paused न हो, तो
  अगली line उसी session के transcript का सारांश अपने-आप load करती है, जिसमें बातचीत का text है (इस
  release का app और mod tool output, thinking और reminders हटा देते हैं, पर उन्हें quote करने वाला
  text नहीं, और पुराना app या mod पूरी request भेजता है); इससे बचने के लिए पहले session में `/clear` करें, फिर **New conversation** दबाएँ। हटाए गए
  session में `/live` उसे फिर से जोड़ देता है।

### सेटिंग्स

**Settings…** LiveBridge की Settings window खोलता है, जिसके toolbar में चार tabs हैं।
menu का **Quick Settings** इसके पाँच switches रखता है ([menu](#बैंड-और-मेन्यू)): हर item वही setting
है, इसलिए एक जगह का बदलाव दूसरी जगह तुरंत दिखता है, और वह वही पूछता है जो यहाँ का switch पूछता है।
**General** में notifications, login, updates और debug mode हैं:

- **Notify when a result is waiting** (डिफ़ॉल्ट रूप से चालू): line बंद रहने पर इंतज़ार कर रहे नतीजे की
  chime के साथ, एक macOS notification session का नाम बताता है ("Alpha has a new result — speak to
  hear it"), नतीजा खुद कभी नहीं। उस पर click करने से menu bar menu खुलता है।
- **Open at login** (डिफ़ॉल्ट रूप से बंद)।
- **Updates**: चल रहा version, **Check for update**, **Check for updates automatically** और पिछले
  update ने क्या किया ([अपडेट करना](#अपडेट-करना))।
- **Debug mode** (डिफ़ॉल्ट रूप से बंद): call के दौरान हर सेकंड voice के network आँकड़ों की एक row
  (खोए और फेंके गए packets, jitter, concealed samples, line TCP पर चल रही है या नहीं), हर call की एक
  CSV, `~/Library/Application Support/LiveBridge/debug/call-stats/` में; न audio, न transcript, न
  session के नाम। call के दौरान चालू करने पर यह खुली line को उसी पल से दर्ज करता है; बंद करने पर
  तुरंत रुक जाता है, और files तब तक रहती हैं जब तक आप उन्हें न हटाएँ। **Show Debug Files** folder
  खोलता है। menu में यह **Feedback & Support** में **Debug Mode** है
  ([आँकड़े कैसे पढ़ें](../../CONTRIBUTING.md#reading-debug-modes-numbers))।

**Voice** में वह है जो आप call के दौरान सुनते हैं:

- **Voice**: आपका codex जो realtime voices देता है उनमें से एक, जिनकी सूची codex यह tab खुलने पर
  देता है, या **Codex default**। यह अगली बार line खुलने से सुनाई देती है।
- **Prompt** (डिफ़ॉल्ट रूप से खाली): voice के लिए आपके अपने निर्देश, जैसे "मुझसे Spanish में बात
  करो", अधिकतम 2,000 अक्षर। ये LiveBridge के अपने voice नियमों के बाद जोड़े जाते हैं, और दोनों में
  टकराव होने पर उन्हीं नियमों की चलती है, और अगली बार line खुलने से लागू होते हैं।
- **Play sounds for requests and answers** (डिफ़ॉल्ट रूप से चालू): voice जो भी अनुरोध Claude को सौंपता है,
  हर एक के लिए एक छोटी आवाज़ ([क्यों](#ज्ञात-सीमाएँ)), और जब कोई बोल नहीं रहा हो तब खुली या खुलती
  line पर पहुँचने वाले Claude के हर जवाब, विफलता या सवाल के लिए भी एक। प्रतीक्षा कर रहे नतीजे की
  ध्वनि हर हाल में बजती है।

**Line** में यह है कि ख़ामोशी में line कितनी देर खुली रहती है और वह कैसे जुड़ती है:

- **Silence before the line closes** (डिफ़ॉल्ट रूप से 20 सेकंड), **Wait for a first word on a line
  a result opened** (5 सेकंड) और **Sound without words before the line closes** (90 सेकंड): हर तरह
  की चुप्पी खुली line को कितनी देर खुला रखती है, 0 से 300 सेकंड तक। 0 चुप्पी या शब्दों के बिना आवाज़
  वाले timer को बंद कर देता है, और पहले शब्द की प्रतीक्षा 0 पर हो तो वह चुप्पी जितनी ही देर चलती है।
  तीनों 0 हों तो चुप्पी line को कभी बंद नहीं करती: वह खुली रहती है, और पूरे समय उसका बिल बनता है
  ([बिलिंग](#बिलिंग-का-ध्यान-रखने-वाला-डिज़ाइन)), जब तक आप Stop न दबाएँ, target न बदलें या OpenAI उसे
  बंद न कर दे। छोटी चुप्पी सामान्य ठहरावों के बीच ही line बंद कर देती है, और हर बार line दोबारा खुलने
  पर voice के जवाब देने में कुछ सेकंड लगते हैं, इसलिए 1 से 9 सेकंड पर Settings चेतावनी देता है;
  शब्दों के बिना आवाज़ के लिए भी वह ऐसा ही करता है, क्योंकि पहचाने जाने तक आपकी बोली उसी में गिनी
  जाती है, और पहले शब्द के लिए 1 से 3 सेकंड पर, क्योंकि voice अक्सर line connect होने के लगभग 2 सेकंड
  बाद बोलना शुरू करता है। जो timer आप चालू करते हैं, वह शांत खुली line पर तुरंत शुरू हो जाता है; जो
  पहले से गिन रहा है, वह अपना समय बनाए रखता है।
- **Connect over TCP** (डिफ़ॉल्ट रूप से बंद): अगर खराब connection पर voice टूटती है, तो इसे चालू
  करें। तब line UDP के बजाय media server के दिए TCP रास्ते (देखे गए answers में port 443) को
  प्राथमिकता देती है, और फिर भी UDP पर लौट सकती है। packets खोने वाले connection पर इससे टूटन
  phrases के बीच छोटे ठहराव बन सकती है ([यह कितना परखा गया](#ज्ञात-सीमाएँ))। बदलते समय खुली line
  आपकी पुष्टि के बाद तुरंत बंद होकर फिर खुलती है; voice जो कह रही थी वह कट जाता है, और line जिस
  नतीजे का इंतज़ार कर रही थी वह फिर भी नई line में आता है।

**Context** में यह है कि आपके sessions voice तक कैसे पहुँचते हैं:

- **Pause sync while the call is stopped** (डिफ़ॉल्ट रूप से बंद): डिफ़ॉल्ट रूप से, जुड़े हुए session
  में आप जो टाइप करते हैं और उस पर Claude का अंतिम जवाब, call रुकी होने पर भी voice के साथ उस
  session की conversation में रखे जाते हैं, और अगली line खुलने पर voice के पास होते हैं। line खुलने
  तक इसमें से कुछ भी OpenAI तक नहीं पहुँचता। जिस text को आप OpenAI तक नहीं पहुँचाना चाहते, उसके लिए setting चालू
  करें, अगर session का सारांश शायद अभी न हो तो अगली setting बंद करें, Stop दबाएँ, फिर टाइप करें: call रुकी होने पर आप जो टाइप करते हैं वह दर्ज नहीं होता, और
  session paused चिह्नित हो जाता है। यह चालू रहते कोई line अपने-आप सारांश load नहीं करती, और pause
  के बाद भी नहीं, सिवाय ऐसे session के जिसका सारांश नहीं है (अगली setting); बाकी समय यह सिर्फ़ **Load context**
  करता है। वह सारांश
  transcript से लिखा जाता है, इसलिए उसमें वह आता है जिसे आपने pause किया था। जिस turn में voice
  अनुरोध चल रहा हो, उसमें टाइप करने से उसका जवाब विफल हो जाता है, उसका कुछ भी दर्ज या बोला नहीं
  जाता। यह पहले से दर्ज किसी चीज़ को नहीं हटाता, और Claude के बाद के जवाब paused text दोहरा सकते
  हैं; यह क्या करता है और क्या नहीं, यह [SECURITY.md](../../SECURITY.md#residual-risk-by-design) में है।
- **Load a session's context on its first call** (डिफ़ॉल्ट रूप से चालू; update के समय **Pause sync** चालू था तो बंद): जिस session का
  सारांश voice के पास नहीं है, उसके लिए Start, call के दौरान target बदलना या खुलने वाली line सारांश
  माँगती है, चाहे **Pause sync** चालू हो या
  session paused हो, पुरानी chat और **New conversation** के बाद की chat समेत। वह सारांश transcript से
  लिखा जाता है, इसलिए उसमें वह आता है जिसे आपने pause किया था, और वह OpenAI को जाता है। session का सारांश
  बन जाने के बाद जो आगे होता है उस पर pause लागू होता है। यह बंद हो तो pause में सिर्फ़ **Load context** सारांश
  load करता है।
- **Summary model** (डिफ़ॉल्ट Haiku 5.5, update के बाद भी; या Sonnet 5.5, Opus 5.5 या **Custom…**): वह model जो
  voice को context के रूप में मिलने वाला सारांश लिखता है, हमेशा low effort पर, आपके Claude usage से।
  कोई दूसरा model विफल हो तो Haiku 5.5 उसे लिखता है, जब तक उस model का समय खत्म न हुआ हो। इसके नीचे एक पंक्ति बताती है कि पिछला सारांश कब
  Haiku 5.5 से आया, या किसी model से नहीं आया, और क्यों। इस setting से पहले के mod पर चल रहा session इसे
  अनदेखा करता है और session के अपने model से लिखता है। **Custom…** एक model id और **Check and save** लेता है: कोई
  जुड़ा हुआ session उस model को आपके Claude usage से एक छोटा request ("Reply with OK.") भेजता है, और id
  तभी save होता है जब model जवाब दे; नहीं तो कारण field के पास दिखता है और पिछला चुनाव बना रहता है।
  इसके लिए इस version के mod वाला session चाहिए, और जाँच उसी session के Claude Code की बात कहती है: दूसरा
  session अलग हो सकता है, और save किया गया id दोबारा नहीं जाँचा जाता।

### वॉइस क्या करता है

- वह छोटी-मोटी बातचीत और स्पष्टीकरण खुद देता है, और जिस भी चीज़ के लिए repository या session चाहिए,
  उसे आगे सौंप देता है: tasks, code के बारे में सवाल, फ़ैसले, सुधार और रोकना।
- कुछ भी विनाशकारी या बाहर की ओर जाने वाला (delete, push, publish, send, deploy, pay) सौंपने से पहले
  वह अनुरोध दोहराता है और पूछता है "yes?"। यह voice को सिखाई गई एक आदत है, कोई सुरक्षा उपाय नहीं;
  [SECURITY.md](../../SECURITY.md) बताता है कि सुरक्षा उपाय क्या है।
- वह नतीजे session के नाम के साथ एक-दो वाक्यों में पढ़कर सुनाता है। Code blocks और tables session में
  ही रहते हैं, और जो credentials वह पहचान लेता है उन्हें छिपा (redact) दिया जाता है।
- Claude का काम पूरा होने पर वह लौट आता है। line खुली रखने की ज़रूरत नहीं: बातचीत शांत होने पर line
  बंद हो जाती है, और आपके अनुरोध पर Claude का जवाब उसे फिर से खोलता है और voice को बोलने के लिए दिया
  जाता है, इसलिए Claude के काम करते समय आप जा सकते हैं। यह उस session के लिए है जिससे आप बात कर रहे
  हैं; दूसरे session का नतीजा chime बजाकर इंतज़ार करता है ([billing कैसे होती
  है](#बिलिंग-का-ध्यान-रखने-वाला-डिज़ाइन))। अगर फिर से खुली line पर voice चुप रहे, तो जवाब भी chime
  बजाकर इंतज़ार करता है, इसलिए वह खोता नहीं। Claude का आपसे पूछा गया सवाल या जिस permission prompt
  का वह इंतज़ार कर रहा है, वह line को उसी तरह खोलता है, पर voice उसे शायद न बोले: Mac से दूर होने पर
  इस पर भरोसा न करें ([ज्ञात सीमाएँ](#ज्ञात-सीमाएँ))।
- जब Claude कोई सवाल पूछता है, तो वह voice को आपके सामने रखने के लिए दिया जाता है और आपका जवाब उसी
  session को वापस जाता है। Claude काम करते हुए जो सवाल पूछता है (विकल्पों वाला dialog), उसके साथ भी
  ऐसा ही होता है: voice को वह इसलिए दिया जाता है कि वह आपको उसके बारे में बताए, विकल्पों को अपने
  शब्दों में समझाए और जब तक आप चाहें आपसे उन पर बात करे, Claude से पूछे बिना। आप जो तय करते हैं, कोई
  विकल्प या Claude से वापस कोई सवाल, वही dialog का जवाब बनता है; आप चाहें तो keyboard पर भी जवाब दे
  सकते हैं। Claude जो काम बाद में background में पूरा करता है, वह update के रूप में voice को जाता
  है।
- जब Claude किसी permission prompt का इंतज़ार कर रहा हो, तो voice को एक notice दिया जाता है और वह यह
  बता सकता है, सिवाय [वहाँ जहाँ कोई organization Claude Code को manage करता है](#ज्ञात-सीमाएँ)।
  Prompt का जवाब आप Claude Code में देते हैं; LiveBridge उसका जवाब कभी आपकी जगह नहीं देता।
- आप जो टाइप करते हैं, वह उसे दिया जाता है। session के जुड़े रहते, आप उसमें जो टाइप करते हैं और हर
  उस turn पर Claude का अंतिम जवाब जो voice अनुरोध नहीं था, उस session की voice के साथ conversation
  में context के रूप में जाते हैं: उनके लिए chime नहीं बजता और वे बंद line नहीं खोलते ([इसकी
  सीमाएँ](#ज्ञात-सीमाएँ))। खुली line को वे तुरंत मिलते हैं; बाद में खुली line उनसे शुरू होती है। जिस
  voice जवाब को नए अनुरोध ने हटा दिया, वह बोला नहीं जाता, पर रखा जाता है और उसी तरह जोड़ा जाता है।
  turn के बीच का Claude का text sync नहीं होता, सिवाय उसके जो उसने सवाल या permission prompt से ठीक
  पहले लिखा, वह उसी के साथ जाता है; subagents और tools का output भी sync नहीं होते। target में
  Claude का सवाल या permission prompt voice को दिया जाता है, चाहे उसे किसी भी turn ने पैदा किया हो;
  किसी दूसरे session में वह वैसे ही जाता है जैसे वहाँ का नतीजा जाता, सिवाय इसके कि जो turn voice
  अनुरोध नहीं था, उसका सिर्फ़ दर्ज होता है। जिस turn को pause बाहर रखता है, उसमें इनमें से कुछ नहीं
  होता। जब कोई सवाल या prompt voice के बिना निपट जाता है, या कोई turn बिना जवाब के ख़त्म होता है, तो
  voice को यह बताने वाली पंक्ति दी जाती है ([कौन-सी
  पंक्तियाँ](../../SECURITY.md#what-session-text-can-do))।

## बिलिंग का ध्यान रखने वाला डिज़ाइन

Realtime voice session खुली रहने तक खर्च होता है, इसलिए LiveBridge उसे सिर्फ़ तभी खोलता है जब कोई
बोल रहा हो, जब आपके अभी किए गए अनुरोध पर Claude का जवाब आना बाकी हो, या उस जवाब, Claude के
सवाल या इस बात को सुनाने के लिए कि Claude आपकी अनुमति का इंतज़ार कर रहा है:

- जब call चालू हो और कोई बोल नहीं रहा, तब microphone सिर्फ़ आपके Mac पर चल रहे voice detector को
  audio देता है। कहीं कोई audio भेजा नहीं जाता।
  Muted रहते हुए LiveBridge के पास कोई microphone नहीं होता, और macOS का microphone indicator यह दिखाता है।
- जब आप बोलना शुरू करते हैं, line खुल जाती है। बोलना शुरू करने से पहले के 2 सेकंड रखे जाते हैं और
  सबसे पहले भेजे जाते हैं, ताकि आपके पहले शब्द न छूटें।
- कुछ देर की चुप्पी के बाद line बंद हो जाती है, और शब्दों के बिना आवाज़ (संगीत, TV) उसे अपनी अलग
  अवधि के बाद बंद करती है। दोनों [सेटिंग्स](#सेटिंग्स) में अलग-अलग तय होते हैं; जो 0 पर हो, वह उसे बंद नहीं करती।
- जब voice कोई अनुरोध Claude को सौंपता है (handoff), तो उस handoff के बाद line अधिकतम 2 मिनट तक खुली
  रहती है, जिसका बिल किसी भी खुली line की तरह बनता है, और जब कोई बोल नहीं रहा होता तब Claude का जवाब
  voice को सुनाने के लिए दिया जाता है। अगला handoff 2 मिनट फिर से शुरू करता है; जिस बातचीत में
  Claude को कुछ नहीं भेजा जाता, वह सामान्य चुप्पी के बाद बंद हो जाती है।
- जिस session से आप बात कर रहे हैं, उसे दिए गए अनुरोध पर Claude का जवाब, उसमें Claude का आपसे पूछा
  गया सवाल, या वह permission prompt जिसका वह इंतज़ार कर रहा है, line बंद होने के बाद आए तो line फिर
  से खोलता है और voice को सुनाने के लिए दिया जाता है; इसका खर्च किसी भी खुली line जैसा है। line बंद
  रहते आने वाली बाकी हर चीज़ (उस session से आई कोई भी चीज़ जिससे आप हट गए, बाद का update) chime
  बजाती है और इंतज़ार करती है: band और menu उसे न सुना हुआ दिखाते हैं, और जब आप अगली बार बोलते हैं
  तो वह voice को जाती है ([कब माना जाता है कि सुन लिया
  गया](../../docs/architecture/overview.md#a-result-while-the-line-is-closed))।
- हर Claude Code session की voice के साथ अपनी अलग conversation होती है। वह अगले realtime session में
  आगे ले जाई जाती है, और Stop और Start के पार भी, ताकि voice को याद रहे कि आपने एक मिनट पहले क्या
  कहा था। नया target conversation बदल देता है: खुली line बंद हो जाती है, और आपके अगले शब्द उसे नए target
  की conversation के साथ खोलते हैं।
- Menu वे मिनट दिखाता है जितनी देर line खुली रही, जिन्हें app voice के connect होने से गिनता है,
  इसलिए आपका plan थोड़ा ज़्यादा गिन सकता है। OpenAI desktop voice की कीमत आपके Codex usage budget के
  प्रति मिनट के हिसाब से तय करता है, और उसके API पर मॉडल का वही परिवार मौन का भी बिल बनाता है
  ([विवरण](../../docs/research/2026-11-04-gpt-live-billing.md),
  [सीमाएँ](../../docs/research/2026-11-05-gpt-live-limits.md)); आपके plan का अपना usage page ही प्रामाणिक
  है।
- Menu दिखाता है कि आपके Codex और Claude usage का कितना हिस्सा इस्तेमाल हो चुका है: हर एक की एक
  पंक्ति, plan जितनी windows बताता है उनमें से हर एक का इस्तेमाल हुआ प्रतिशत (हर पंक्ति में अधिकतम
  तीन, जैसे `7% of 5 h · 19% of week`), 90 % या उससे अधिक होने पर नारंगी; किसी पंक्ति पर hover करने
  से हर window के reset होने का समय दिखता है। Codex के आँकड़े हर बार menu खुलने पर, अधिकतम मिनट में
  एक बार, एक अल्पकालिक codex से पढ़े जाते हैं; Claude के आँकड़े किसी जुड़े हुए session से तब आते हैं जब
  वह जवाब दे चुका हो। जिस पंक्ति में दिखाने को कुछ न हो वह छोड़ दी जाती है, और codex जब बताता है कि
  सामान्य उपयोग की अनुमति नहीं है तब Codex की पंक्ति में `blocked` लिखा आता है। Codex की आख़िरी reading तुरंत दिखती है और कुछ सेकंड बाद नई reading उसकी जगह ले लेती है, इसलिए menu खुला
  रहते आँकड़े बदल सकते हैं; launch के ठीक बाद पंक्ति पहली reading आने पर दिखती है, और पढ़ना विफल होने पर
  reading 15 मिनट बाद हट जाती है।
  कौन-सी limit voice को
  सबसे पहले रोकती है, यह प्रकाशित नहीं है ([विवरण](../../docs/research/2026-11-05-gpt-live-limits.md))।

## गोपनीयता

LiveBridge में कोई telemetry नहीं है और वह किसी network port पर listen नहीं करता; mod, app से एक Unix
socket पर बात करता है, जो ऐसे folder में है जिसे केवल आपका user खोल सकता है। codex के realtime
session के ज़रिए OpenAI को यह जाता है:

- line खुली रहने के दौरान microphone audio, आपके बोलना शुरू करने से 2 सेकंड पहले से (या, Claude के
  जवाब, सवाल या permission prompt से खुली line के लिए, उसके खुलने से) लेकर line बंद होने तक (muted
  रहते LiveBridge कुछ capture नहीं करता, इसलिए कुछ नहीं जाता; Mute दबाने से पहले आपने जो बोला, जो
  line पहले से connect हो रही थी उस पर, वह फिर भी जा सकता है);
- voice के निर्देश: LiveBridge के अपने नियम, फिर आपकी Settings का **Prompt**, अगर आपने लिखा हो;
- target session की हाल की conversation (आख़िरी 64 पंक्तियों तक, और उससे ज़्यादा नहीं जितना codex
  लेता है: context और खुले कामों समेत 128 items और लगभग 8,192 tokens), ताकि उसे नए realtime session
  में जारी रखा जा सके। इसमें वह है जो आपने उस session में टाइप किया और हर उस turn पर Claude का अंतिम
  जवाब जो voice अनुरोध नहीं था, चाहे वह किसी से भी शुरू हुआ हो (आपका टाइप किया turn, कोई schedule,
  दूसरा agent, कोई background task), साथ में mod के notes और आपकी और voice की बोली, इसलिए किसी
  session में टाइप करना उसे OpenAI तक पहुँचा देता है जब उस session के साथ line खुलती है। line खुली
  रहते target की हर नई पंक्ति तुरंत उसमें जाती है। दूसरे session की sync की गई पंक्तियाँ तभी जाती
  हैं जब line उसके साथ target के रूप में खुलती है; उसके नतीजे, सवाल और approval notices खुली line
  में जाते हैं, चाहे वह कोई भी session हो;
- target session के अभी खुले अनुरोध, उनके एक-पंक्ति के सार (brief) के रूप में;
- हर नतीजा, सवाल, update, approval notice, टाइप किया गया text, ऐसे turn का जवाब जो voice अनुरोध नहीं
  था, नए अनुरोध से हटाया गया voice जवाब और mod का note, अधिकतम 2,000 अक्षरों की एक पंक्ति के रूप
  में, code blocks और tables हटाकर (टाइप किया गया text जो सिर्फ़ code या table है, उसकी जगह यह बताने
  वाला वाक्य रखा जाता है कि code टाइप किया गया)। mod के notes अनुमति दिए गए या निपटे हुए permission
  prompt के tool का नाम बताते हैं, और बताते हैं कि कोई सवाल बंद हुआ या कोई turn बिना जवाब के ख़त्म
  हुआ। Turn के बीच Claude का पूछा सवाल, और Claude के main loop (subagent नहीं) की permission prompt
  का approval notice, वह text भी साथ लाते हैं जो Claude ने पूछने से ठीक पहले लिखा। Update, Claude का
  जवाब है जो किसी background task के notification से शुरू हुए बाद के turn में आता है, voice अनुरोध
  के बाद 10 मिनट तक और तब तक जब तक session में कोई दूसरा turn शुरू न हो;
- target session का context सारांश, अधिकतम 1,500 अक्षरों की एक पंक्ति के रूप में। यह load होने पर सेव
  होता है और जब भी line खुलती है और वह session target होता है, तब भेजा जाता है, Stop और Start के
  पार और app के restart के बाद भी। Menu का Conversation submenu उस पंक्ति को ठीक वैसी ही दिखाता है
  जैसी वह भेजी जाती है;
- ऊपर की हर पंक्ति के साथ, उसके session का label: Claude Code session का title (80 अक्षरों तक), या
  अगर title न हो तो session folder का नाम। label redact नहीं होता और pause उसे नहीं छूता, इसलिए
  paused text से लिखा गया title हर पंक्ति के साथ जाता है;
- WebRTC offer, जो Mac के local network addresses को connection candidates के रूप में सूचीबद्ध करता है।

**Connect over TCP** चालू होने पर audio अब भी OpenAI के media server पर जाता है, और UDP के बजाय TCP
(देखे गए answers में port 443) से जा सकता है।

नतीजे, सवाल, updates, सारांश और टाइप किए गए turns की पंक्तियाँ पहले जानी-पहचानी credential आकृतियों (private keys, JWTs, आम API
tokens, URL में passwords, `password=` जैसे fields) के redactor से गुज़रते हैं। यह patterns की सूची है,
कोई गारंटी नहीं: आप जो और टाइप करते हैं वह जैसा है वैसा ही जाता है।

voice को ले जाने वाला codex thread अस्थायी (ephemeral) और read-only है, जिसमें हर codex feature बंद है
सिवाय उनके जहाँ वह आपका login रखता है और जहाँ वह आपके proxy का उपयोग करता है, और हर MCP server बंद
है; वह सिर्फ़ बात करने के लिए है। Claude का काम Anthropic को वैसे ही जाता है जैसे आपका Claude Code
session हमेशा भेजता है।

Menu खोलने पर LiveBridge एक अल्पकालिक codex शुरू करता है, जो आपके ChatGPT login से OpenAI से पूछता है कि
आपका Codex usage कितना इस्तेमाल हो चुका है (हर window का प्रतिशत और reset का समय)। यह अधिकतम मिनट में एक
बार होता है, call बंद होने पर भी, और इसमें कोई audio या text नहीं भेजा जाता। Claude के आँकड़े mod से socket
के ज़रिए app तक पहुँचते हैं और कहीं और नहीं जाते; app दोनों को सिर्फ़ memory में रखता है।

Updates के लिए app GitHub से बात करता है। **Check for updates automatically** चालू होने पर, दिन में
एक बार (और हर launch पर, जब तक उसके बताए release को install न किया गया हो) वह बिना credentials के
GitHub के API से पूछता है कि नवीनतम release कौन-सा है; GitHub आपके Mac का IP address देखता है।
Settings का **Check for update** दबाने पर वही request जाता है। अपने-आप होने वाली जाँच में नया
release मिलने पर app `gh auth status` चलाता है, यह बताने के लिए कि image जाँची जा सकती है या नहीं।
सिर्फ़ जब आप **Install** click करते हैं, तभी वह image download करता है और `gh attestation verify` व
`claude plugin` चलाता है, जो आपके अपने logins से GitHub तक, और `gh` के trust root के लिए Sigstore
तक, पहुँचते हैं। [SECURITY.md](../../SECURITY.md#what-leaves-the-mac) में हर request की सूची है।

आपके Mac पर app अपनी settings, usage meter, update की पिछली जाँच का समय और जिन versions की सूचना दी
गई, पिछले update ने क्या किया, और, सबसे हाल में इस्तेमाल हुए 20 sessions में से हर एक की, उसकी हाल
की conversation (64 पंक्तियों तक, जिसमें आपका उसमें टाइप किया हुआ भी है; call के बिना दर्ज होती है,
जब तक आप **Pause sync** चालू न करें) और उससे आख़िरी बार load की गई context पंक्ति `~/Library/Application Support/LiveBridge` में रखता है, ऐसे folder में जिसे केवल आपका user खोल सकता है
([यह कैसे रखी जाती है](../../SECURITY.md#residual-risk-by-design))। किसी session की पंक्तियाँ तब जाती हैं जब आप
उसे target रखकर **New conversation** दबाते हैं या उसे × से हटाते हैं। जो session चला गया है, उसकी
पंक्तियाँ तब तक रहती हैं जब तक उसके बाद इस्तेमाल हुए 20 sessions उन्हें बाहर न धकेल दें; उन्हें
जल्दी मिटाने के लिए, उसी session में फिर से `/live` चलाएँ और **New conversation** दबाएँ।
Uninstall करने से वे सब हट जाती हैं; menu का Uninstall LiveBridge उन्हें Trash में ले जाता
है, और Trash खाली करने पर वे चली जाती हैं। mod Claude Code के plugin store में अपना एक snapshot रखता है ([उसमें क्या है](../../SECURITY.md#residual-risk-by-design))।
**Debug mode**, जो डिफ़ॉल्ट रूप से बंद है, call के दौरान voice के network आँकड़े इसी folder की एक file
में लिखता है, और कुछ नहीं ([सेटिंग्स](#सेटिंग्स))।

[SECURITY.md](../../SECURITY.md) में threat model है: संक्षेप में, जो कुछ भी आपका microphone सुन सकता है
वह एक ऐसा अनुरोध बन सकता है जिसे Claude session के अपने permission mode के तहत चलाता है।

## ज्ञात सीमाएँ

- **Connect over TCP** TCP को प्राथमिकता देता है, उसे मजबूर नहीं करता, और call के दौरान कुछ नहीं दिखाता कि line
  ने कौन-सा transport लिया, इसलिए UDP पर लौटी line अब भी टूट सकती है। यह रास्ता एक बार मापा गया, एक
  debug build में जिसने UDP candidates हटा दिए थे (10 मिनट में कोई audio नहीं खोया); भेजा गया तरीका,
  उनकी priority घटाना, एक बार TCP चुनते देखा गया। debug mode transport दर्ज करता
  है (`onTcp`) ([CONTRIBUTING.md](../../CONTRIBUTING.md#reading-debug-modes-numbers))।
- voice कभी-कभी कहता है कि वह देख रहा है ("On it", "Looking now"), पर अनुरोध Claude को नहीं सौंपता,
  इसलिए Claude तक कुछ नहीं पहुँचता: पहले लिखे गए नियम के साथ लगभग पाँच में से एक अनुरोध, और अब के
  नियम के साथ 20 में से 0, जो किस्मत से अलग बताने के लिए बहुत कम है ([BR-001](../../docs/bugs/BR-001.md))।
  वह ऐसे काम का दावा भी कर सकता है जो उसने नहीं किया, जैसे "I'll take a look.", उन पंक्तियों पर भी
  जो उसके पास सिर्फ़ context के रूप में हैं ([ADR 0001 (n),
  (o)](../../docs/adr/0001-platform-findings.md))। जब app किसी अनुरोध को Claude की queue में डालता है, तो
  एक छोटी आवाज़ बजती है, जो जवाब की आवाज़ से अलग है; अगर voice कहे कि वह देख रहा है और यह आवाज़ न
  बजे, तो अनुरोध दोबारा कहें।
  app शब्दों से ऐसे वादे और जवाब में फ़र्क नहीं कर सकता, क्योंकि voice आपकी भाषा में बोलता है।
- Claude का सवाल, या वह permission prompt जिसका वह इंतज़ार कर रहा है, सिर्फ़ voice को दिया जाता है,
  और voice उसे शायद न बोले; उसे कोई मजबूर नहीं करता। इसलिए Mac से दूर होने पर voice के prompt बताने
  पर भरोसा न करें: Claude बिना किसी सूचना के इंतज़ार करता रह सकता है। Prompt फिर भी Claude Code में
  इंतज़ार करता है, और वही एकमात्र नियंत्रण है; voice नियंत्रण नहीं है, और LiveBridge prompt का जवाब
  कभी नहीं देता। जाँचों में, खुली line पर टाइप किए गए turn का permission notice keyboard के जवाब से
  पहले 3 में से 0 runs में बोला गया, यह गिनती है, दर नहीं ([ADR 0001
  (n)](../../docs/adr/0001-platform-findings.md))। बंद line इनके लिए तभी खुलती है जब target की
  conversation में आपका कोई turn हो; नहीं तो app chime बजाता है, और call बंद हो तो ये सिर्फ़ दर्ज
  होते हैं।
- Claude desktop app टाइप किए गए prompt का origin क्या बताता है, यह देखा नहीं गया ([ADR 0001
  (m)](../../docs/adr/0001-platform-findings.md))। mod किसी prompt को आपका तभी दर्ज करता है जब उसका origin
  `composer` हो। अगर वहाँ टाइप किया prompt किसी और रूप में आए, तो वहाँ टाइप किया कुछ भी दर्ज नहीं
  होता, कोई gap चिह्नित नहीं होता, menu **Context up to date** कहता है, और pause कम पहुँचता है
  ([विवरण](../../SECURITY.md#what-session-text-can-do))।
- जो नतीजा तब आता है जब line उसका इंतज़ार कर रही हो, वह voice को बोलने के लिए text के रूप में जाता
  है; codex में ऐसा कोई call नहीं है जो voice को तुरंत बुलवाए, इसलिए कब बोलना है यह model तय करता
  है। टेस्टिंग में वह कुछ सेकंड के भीतर बोल गया। अगर नहीं बोलता, तो नतीजा न सुना हुआ रहता है: वह
  आपके अगले शब्दों के साथ फिर voice को जाता है, या line बंद होने पर chime बजती है।
- जब Claude का जवाब line को फिर से खोलता है, तो voice चुप रह सकता है: मापे गए 14 में से 4 runs में
  ऐसा हुआ, जो छोटा नमूना है ([ADR 0001 (n)](../../docs/adr/0001-platform-findings.md))। तब line पहले शब्द की
  प्रतीक्षा ख़त्म होते ही बंद हो जाती है ([सेटिंग्स](#सेटिंग्स)), और जवाब chime बजाकर इंतज़ार करता है,
  जैसा नीचे बताया गया है। जहाँ voice बोला, वहाँ उसने connect के लगभग 2 सेकंड के भीतर बोलना शुरू किया;
  जो voice उस प्रतीक्षा के बाद शुरू होता, वह कट जाता है।
- जब आपके अगले शब्द line को फिर से खोलते हैं, तो voice कभी-कभी सिर्फ़ उन्हीं का जवाब देता है और
  इंतज़ार कर रहा नतीजा नहीं सुनाता। नतीजा खोता नहीं है: वह इंतज़ार में रहता है, line बंद होने पर chime
  बजाता है और notification भेजता है, और अगली बार line खुलने पर फिर से voice को जाता है।
- आपके ChatGPT plan की usage limit पर voice तब तक रुक जाता है जब तक limit reset न हो। Menu और band
  यह बताते हैं, codex के वाक्य में और जहाँ codex दे वहाँ reset के समय के साथ, और call खत्म हो जाती
  है, ताकि बोलने से विफल होने वाली lines न खुलें। Claude Code काम करता रहता है, जवाब इंतज़ार करते
  रहते हैं, और Start एक बार फिर कोशिश करता है। app किसी limit को सिर्फ़ codex के शब्दों या service
  के error code से पहचानता है, क्योंकि और कुछ यह नहीं बताता
  ([विवरण](../../docs/research/2026-11-05-gpt-live-limits.md))। जिस इनकार को वह नहीं पहचानता, जैसे बिना
  कारण बताए गिरी हुई line ("The voice session closed (transport_closed)."), उसमें call चालू रहती है,
  इसलिए आपके अगले शब्द फिर कोशिश करते हैं; limit reset होने तक **Stop** दबाएँ।
- जो prompt composer में टाइप नहीं किया गया (host का संदेश, schedule, दूसरा agent और शायद Remote
  Control), वह voice की conversation में आपके शब्दों के रूप में दर्ज नहीं होता, हालाँकि उस पर Claude
  का जवाब दर्ज होता है, और pause में वह चल रहे turn को अस्वीकार नहीं करता
  ([SECURITY.md](../../SECURITY.md#what-session-text-can-do) बताता है कि कौन-से prompt आपके माने जाते
  हैं)।
- जहाँ Claude Code का provider (Bedrock, Vertex या Foundry) **Summary model** में चुना model नहीं देता,
  या organisation उसकी अनुमति नहीं देता, वह model विफल होता है और Haiku 5.5 सारांश लिखता है; जहाँ Haiku 5.5
  भी नहीं मिलता, voice को सारांश नहीं मिलता, जो Settings बताती है। इस setting से पहले session का अपना model
  उसे लिखता था, जो हर उस जगह काम करता है जहाँ session करता है। pinned id का इन providers पर resolve होना
  Claude Code के documentation से लिया गया है और चलाकर नहीं देखा गया।
- विफल हुआ सारांश याद नहीं रखा जाता: जब तक session को अब भी सारांश चाहिए, Start, target बदलना और
  खुलने वाली हर line उसे फिर माँगती है, और mod वही transcript, अधिकतम 120,000 अक्षर, फिर भेजता है,
  जो हर बार billed हो सकता है, चाहे जवाब खाली लौटे या बहुत देर से। अगर session के band पर
  **Context failed** बना रहे, तो **Pause sync** चालू
  करें और **Load a session's context on its first call** बंद रहने दें।
- जो session अब भी इस release से पहले के mod पर है, वह restart होने तक sync नहीं होता: वह turns छूटे
  session की तरह सारांश load करता है, और कोई pause उसकी पंक्तियों को अस्वीकार नहीं करता ([और क्या
  अलग है](../../CHANGELOG.md))।
- जो Claude Code session mod के load होने से पहले ही खुला था, उसमें `/live` चलने से पहले उसे दोबारा
  खोलना पड़ सकता है।
- Claude desktop app में, ऐसे session में टाइप किया गया `/live` जिसका Claude Code process अभी शुरू
  नहीं हुआ है (नया session, या अभी-अभी दोबारा खोला गया), "/live isn't a command here." दिखा सकता है।
  Command फिर भी चलता है। Desktop ऐसे session के commands की सूची एक ऐसी जाँच से बनाता है जो hooks
  बंद करके चलती है, इसलिए mod का code, जो `/live` घोषित करता है, वहाँ नहीं चलता; session चलने लगने के
  बाद desktop सूची session से ही लेता है। mod के पास इसका कोई समाधान नहीं है: एक static command फ़ाइल
  `/livebridge:live` के रूप में सूचीबद्ध होती, `/live` के रूप में नहीं, और hooks बंद होने पर वह अपना text
  mod चलाने के बजाय model को भेज देती।
- किसी जवाब ने इंतज़ार कर रहे नतीजे को बताया या नहीं, इसका फ़ैसला उसके शब्दों से होता है, सिर्फ़
  अंग्रेज़ी और रूसी के आम शब्दों की सूची के साथ
  ([नियम](../../docs/architecture/overview.md#a-result-while-the-line-is-closed))। किसी दूसरी भाषा में, अगर
  voice ने नतीजे का सिर्फ़ ज़िक्र किया हो, तब भी वह सुना हुआ गिना जा सकता है।
- जहाँ कोई organization Claude Code को manage करता है, वहाँ LiveBridge में कुछ भी आपको नहीं बताता
  कि कोई permission prompt इंतज़ार कर रहा है। Claude Code का built-in guard managed settings वाली
  machine पर और Team या Enterprise plan से sign in की गई session में load होता है, और वहाँ mod के
  permission hooks नहीं चलते। Prompt फिर भी Claude Code में दिखता है और आपका इंतज़ार करता है,
  लेकिन voice उसके बारे में कुछ नहीं कहता और menu दिखाता है कि Claude काम कर रहा है, इसलिए अगर
  जवाब में देर लगे तो Claude Code देखें। `/plugin` उन hooks के नाम बताता है, और Claude Code के हाल
  के versions एक line भी दिखाते हैं कि hook छोड़ दिया गया। Claude के सवाल फिर भी voice तक पहुँचते
  हैं। Hooks को एक Linux container में [मापा गया](../../docs/adr/0001-platform-findings.md); voice और
  menu bar क्या करते हैं, यह code से निकलता है, और कोई असली line नहीं चलाई गई। Team और Enterprise
  का मामला Claude Code के documentation से लिया गया है।
- Managed settings में `allowManagedHooksOnly`, `allowManagedModsOnly` या `disableAllHooks` होने
  पर mod load नहीं होता और `/live` काम नहीं करता। Administrator [mod को organization के अपने mod
  के रूप में install कर सकता
  है](https://code.claude.com/docs/en/plugins/mods/admin#install-your-organizations-mods), हर
  machine के एक folder से: तब permission hooks चलते हैं, पहली दो settings के साथ भी ([मापा
  गया](../../docs/adr/0001-platform-findings.md))। Claude Code के documentation के अनुसार, managed
  settings में marketplace की copy चालू करना काफ़ी नहीं है।

## यह कैसे काम करता है

[docs/architecture/overview.md](../../docs/architecture/overview.md) components, mod और app के बीच की wire,
और message flows का वर्णन करता है; [ADR 0001](../../docs/adr/0001-platform-findings.md) उन platform तथ्यों को
दर्ज करता है जिन पर design टिका है।

## रोडमैप और सहयोग चाहिए

LiveBridge आज एक Mac app, एक worker (Claude Code) और एक voice provider (ChatGPT login पर codex) है।
ये तीनों संकरे जोड़ों (seams) पर मिलते हैं, और नीचे की हर दिशा contributors के लिए खुली है। उनके issues पर
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
label लगा होता है; [CONTRIBUTING.md](../../CONTRIBUTING.md#where-to-start) बताता है कि पहले कौन-सी फ़ाइलें पढ़ें।

- **Windows और Linux।** Menu bar app, उसका audio page और socket server macOS से बँधे हैं; mod और app के
  बीच की wire, और खुद mod, portable हैं। पोर्ट की शुरुआत नए platform के ऐसे app से होती है जो वही wire बोलता हो।
- **Worker के रूप में दूसरे agents**, जैसे Codex CLI, Hermes Agent या Gemini CLI: हर एक को अपना adapter
  चाहिए जो Claude Code mod जैसी ही wire बोले।
- **दूसरे voice providers**, जैसे आपकी अपनी API key के साथ OpenAI Realtime API या Google का Gemini Live API:
  हर एक app के realtime protocol का एक और implementation होगा।

## योगदान

योगदान का स्वागत है। किसी fix से बड़ी चीज़ के लिए पहले एक issue खोलें, ताकि काम शुरू होने से पहले उसका
स्वरूप तय हो सके। शुरू करने की अच्छी जगहें हैं
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
issues, [ज्ञात सीमाएँ](#ज्ञात-सीमाएँ) और [ऊपर](#रोडमैप-और-सहयोग-चाहिए) बताई गई दिशाएँ।

- [CONTRIBUTING.md](../../CONTRIBUTING.md): layout, toolchain, checks (`scripts/check.sh`) और conventions।
- [Issue forms](https://github.com/getLiveBridge/LiveBridge/issues/new/choose): bug की रिपोर्ट करें या कोई feature माँगें।
- [CODE_OF_CONDUCT.md](../../CODE_OF_CONDUCT.md): यहाँ हम एक-दूसरे के साथ कैसे पेश आते हैं।
- [SECURITY.md](../../SECURITY.md): vulnerability की रिपोर्ट निजी तौर पर करें, public issue में नहीं।
- [CHANGELOG.md](../../CHANGELOG.md): हर release में क्या बदला।

## श्रेय

mod और app के बीच के wire protocol की प्रेरणा
[claude-code-voice-mod](https://github.com/ldk00315-jpg/claude-code-voice-mod) से मिली। उससे कोई code या text
कॉपी नहीं किया गया।

## लाइसेंस

[MIT](../../LICENSE)।
