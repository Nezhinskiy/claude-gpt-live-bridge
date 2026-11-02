<p align="center"><a href="README.md">English</a> · <a href="README.ru.md">Русский</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <b>हिन्दी</b> · <a href="README.uk.md">Українська</a></p>

<p align="center"><img src="site/assets/icon.png" alt="LiveBridge ऐप आइकन" width="144"></p>

<h1 align="center">LiveBridge</h1>

<p align="center"><strong>खुले Claude Code session से voice में बात करें।</strong></p>

<p align="center">
  <a href="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml"><img src="https://github.com/getLiveBridge/LiveBridge/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="लाइसेंस: MIT"></a>
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

LiveBridge एक macOS menu bar app है, जो आपके ChatGPT login पर `codex app-server` के ज़रिए
GPT-Live voice line तैयार रखता है (API key की ज़रूरत नहीं)। Voice फ्रंट डेस्क की तरह काम करता है:
वह बातचीत करता है, पूछता है कि आपका मतलब क्या है, और असली काम एक छोटे Claude Code mod,
`livebridge`, के ज़रिए आपके Claude Code session को सौंप देता है। Claude अपने model, tools और
permission mode से काम करता है, और voice आपको नतीजा बताता है।

*मूल पाठ अंग्रेज़ी में है ([README.md](README.md)); यह अनुवाद पीछे रह सकता है।*

<p align="center"><img src="site/assets/demo.gif" alt="LiveBridge के ज़रिए Claude Code session से बात करना" width="100%"></p>

**डिज़ाइन से ही लोकल।** कोई telemetry नहीं और अपना कोई server नहीं: LiveBridge आपके Mac पर
आपके अपने codex और आपके अपने Claude Code के बीच एक bridge है। App और mod सिर्फ़ एक Unix socket
पर बात करते हैं, जिसे केवल आपका user खोल सकता है, और app किसी network port पर listen नहीं करता।
आपके Mac से सिर्फ़ वही traffic बाहर जाता है जो ये दोनों tools पहले से भेजते हैं: voice line का
traffic आपके codex के ज़रिए OpenAI को, सिर्फ़ तब जब line खुली हो, और Claude का काम आपके Claude Code
session के ज़रिए Anthropic को। [गोपनीयता](#गोपनीयता) में ठीक-ठीक लिखा है कि OpenAI तक क्या पहुँचता
है; [SECURITY.md](SECURITY.md) बताता है कि यह किस चीज़ से बचाता है और किस चीज़ से नहीं।

> **अनौपचारिक।** इसका Anthropic या OpenAI से कोई संबंध नहीं है, और न ही उनका समर्थन या सपोर्ट
> इसे हासिल है। यह codex के experimental realtime API पर निर्भर है, जो codex के किसी भी release
> के साथ बदल सकता है।

## त्वरित शुरुआत

आपको चाहिए: Apple Silicon पर macOS 14+, Claude Code 2.1.289+, और [codex](https://github.com/openai/codex),
जिसमें `codex login` से ऐसे ChatGPT plan पर sign in किया गया हो जिसमें realtime voice शामिल है;
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

3. जिस Claude Code session से बात करनी है, उसमें `/live on` टाइप करें।
4. prompt के ऊपर वाले band में **Start** दबाएँ, microphone की अनुमति दें, और बोलें।

खुद build नहीं करना चाहते? हर [release](https://github.com/getLiveBridge/LiveBridge/releases/latest)
में app एक disk image के रूप में मिलता है, जिसे GitHub Actions ने build और attest किया है;
उसे कैसे जाँचें और खोलें, यह [डिस्क इमेज से](#डिस्क-इमेज-से) में है। mod दोनों तरीकों में एक ही
तरह install होता है।

अगर पहले से खुले session में `/live` नहीं मिलता, तो session दोबारा खोलें
([क्यों](#ज्ञात-सीमाएँ))। Upgrade, अनुमतियाँ, upgrade के बाद भी microphone की अनुमति बनाए रखना और
uninstall करना [इंस्टॉल करना](#इंस्टॉल-करना) में हैं।

## आवश्यकताएँ

- Apple Silicon पर macOS 14 या उसके बाद का संस्करण।
- Claude Code 2.1.289 या उसके बाद का संस्करण (mods)।
- [Codex CLI](https://github.com/openai/codex) (`codex`, 0.166.0 के साथ टेस्ट किया गया), जो
  Homebrew (`brew install --cask codex`) या npm (`npm install -g @openai/codex`) से install हो,
  Terminal window में आपके shell द्वारा सेट किए गए `PATH` पर हो, और `codex login` से ऐसे ChatGPT plan
  पर sign in हो जिसमें realtime voice शामिल है। जिस codex की `codex features list` LiveBridge पढ़
  नहीं पाता, उसे वह अस्वीकार कर देता है, इसलिए कोई दूसरा संस्करण तब तक शुरू नहीं हो सकता जब तक
  LiveBridge अपडेट न हो।
- App build करने के लिए: Swift 6.0 या उसके बाद के toolchain वाला Xcode। टेस्ट किए गए संस्करण
  [CONTRIBUTING.md](CONTRIBUTING.md#toolchain) में हैं। Build किया हुआ app macOS 14 या उसके बाद के संस्करण पर चलता है।

## इंस्टॉल करना

mod इस repository के marketplace से आता है ([त्वरित शुरुआत](#त्वरित-शुरुआत) के commands)।
App दोनों तरीकों में `/Applications` में जाता है: disk image से, या source से build करके।
दोनों में वह ad hoc signed होता है और notarized नहीं होता।

### डिस्क इमेज से

1. नवीनतम release से
   [LiveBridge.dmg](https://github.com/getLiveBridge/LiveBridge/releases/latest/download/LiveBridge.dmg)
   डाउनलोड करें।
2. उसे [GitHub CLI](https://cli.github.com) से जाँचें, उसी folder में जहाँ आपने उसे सेव किया है:

   ```sh
   gh attestation verify LiveBridge.dmg --repo getLiveBridge/LiveBridge
   ```

   यह जाँच सिर्फ़ ऐसी image के लिए पास होती है जिसे इस repository के
   [release workflow](.github/workflows/release.yml) ने release के tag से build किया हो। image के
   स्रोत का यही एकमात्र प्रमाण है: ad hoc signature किसी का नाम नहीं बताता।
3. उसे खोलें और LiveBridge को Applications में drag करें।
4. पहली बार launch करने पर macOS app को तब तक block रखता है जब तक आप उसे System Settings > Privacy &
   Security > **Open Anyway** में अनुमति न दें।

Upgrade करने के लिए, app को किसी नए release वाले app से बदल दें। हर upgrade के बाद macOS
microphone के लिए दोबारा पूछता है।

### सोर्स से

`scripts/build-app.sh --release` app को build करता है, उसे `/Applications` में install करता है
(आपके account को वहाँ लिखने का अधिकार होना चाहिए, जैसा administrator के पास होता है) और खोल देता है।
Upgrade के लिए इसे फिर से चलाएँ। Build ad hoc signed होता है, इसलिए हर upgrade के बाद macOS
microphone के लिए दोबारा पूछता है। अनुमति बनाए रखने के लिए `scripts/build-app.sh --make-signing-identity`
एक बार चलाएँ: यह पहले पूछता है, फिर आपके login keychain में एक self-signed code-signing certificate
बनाता है, और बाद के release builds उसी से sign होते हैं।

### अनुमतियाँ

पहली बार Start करने पर macOS से microphone माँगा जाता है। अगर मना कर दिया गया, तो call एक वाक्य के
साथ रुक जाती है और menu bar menu का **Open Microphone Settings** Privacy & Security > Microphone खोल
देता है, जहाँ आप LiveBridge को अनुमति देते हैं। ad hoc signature के साथ macOS हर upgrade के बाद फिर
पूछता है (ऊपर देखें)। macOS यह भी पूछ सकता है कि क्या LiveBridge आपके local network पर devices खोज
सकता है। voice line को यह दूसरी अनुमति भी चाहिए; इसके बिना call एक वाक्य के साथ रुक जाती है, जो
बताता है कि इसे कहाँ allow करना है।

### अनइंस्टॉल करना

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

## उपयोग

### कमांड

जिस Claude Code session से बात करनी है, उसमें:

| Command | क्या करता है |
|---|---|
| `/live on` | session के title के नाम से LiveBridge से जुड़ता है, और app चल नहीं रहा हो तो उसे खोलता है। |
| `/live off` | LiveBridge से अलग हो जाता है। |
| `/live target` | इस session को वह session बनाता है जिसे voice काम सौंपता है। |
| `/live status` (या सिर्फ़ `/live`) | एक पंक्ति: call, target, न सुने गए नतीजे, आज के मिनट। |
| `/live context` | voice को इस session का नया सारांश भेजता है, जिसे session का model लिखता है। |

Command `/live` है, `/voice` नहीं, क्योंकि `/voice` Claude Code का अपना voice mode है। किसी session के
target बनने पर उसका सारांश भी भेजा जाए या नहीं, यह कोई command नहीं है: यह सभी sessions के लिए एक
setting है, जो LiveBridge की [सेटिंग्स](#सेटिंग्स) window में है।

### बैंड और मेन्यू

**Start** दबाएँ, prompt के ऊपर वाले band में या menu bar menu में, और बोलें।

- **band का Start** अपने session को target बनाता है, call शुरू करता है और voice को session का
  सारांश भेजता है ([विवरण](docs/architecture/overview.md#components))। जब call किसी दूसरे session से
  बात कर रही हो, तब band **Talk here** दिखाता है।
- **Menu bar menu** में call, जुड़े हुए sessions (किसी पर click करके उसे target बनाएँ),
  **Load context**, target की **Conversation** (जैसी LiveBridge उसे रखता है), मिनट,
  **Settings…** और **Quit LiveBridge** होते हैं।
- **New conversation…** target की conversation और उसका loaded context मिटा देता है, और किसी session
  का × उसे हटाता है और उसकी अपनी conversation मिटा देता है; दोनों पहले पूछते हैं। Voice अगली बार
  line खुलने से नए सिरे से शुरू होता है, और हटाए गए session में `/live on` उसे फिर से जोड़ देता है।

### सेटिंग्स

**Settings…** LiveBridge की Settings window खोलता है:

- **Voice**: आपका codex जो realtime voices देता है उनमें से एक, जिनकी सूची codex window खुलने पर
  देता है, या **Codex default**। यह अगली बार line खुलने से सुनाई देती है।
- **Prompt** (डिफ़ॉल्ट रूप से खाली): voice के लिए आपके अपने निर्देश, जैसे "मुझसे Spanish में बात
  करो", अधिकतम 2,000 अक्षर। ये LiveBridge के अपने voice नियमों के बाद जोड़े जाते हैं, और दोनों में
  टकराव होने पर उन्हीं नियमों की चलती है, और अगली बार line खुलने से लागू होते हैं।
- **Load a session's context automatically when it becomes the target** (डिफ़ॉल्ट रूप से बंद): सभी
  sessions के लिए एक setting, जिसे app सँभालकर रखता है।
- **Notify when a result is waiting** (डिफ़ॉल्ट रूप से चालू): line बंद रहने पर इंतज़ार कर रहे नतीजे की
  chime के साथ, एक macOS notification session का नाम बताता है ("Alpha has a new result — speak to
  hear it"), नतीजा खुद कभी नहीं। उस पर click करने से menu bar menu खुलता है।
- **Open at login** (डिफ़ॉल्ट रूप से बंद)।

### वॉइस क्या करता है

- वह छोटी-मोटी बातचीत और स्पष्टीकरण खुद देता है, और जिस भी चीज़ के लिए repository या session चाहिए,
  उसे आगे सौंप देता है: tasks, code के बारे में सवाल, फ़ैसले, सुधार और रोकना।
- कुछ भी विनाशकारी या बाहर की ओर जाने वाला (delete, push, publish, send, deploy, pay) सौंपने से पहले
  वह अनुरोध दोहराता है और पूछता है "yes?"। यह voice को सिखाई गई एक आदत है, कोई सुरक्षा उपाय नहीं;
  [SECURITY.md](SECURITY.md) बताता है कि सुरक्षा उपाय क्या है।
- वह नतीजे session के नाम के साथ एक-दो वाक्यों में पढ़कर सुनाता है। Code blocks और tables session में
  ही रहते हैं, और जो credentials वह पहचान लेता है उन्हें छिपा (redact) दिया जाता है।
- जब Claude कोई सवाल पूछता है, तो voice उसे आपके सामने रखता है और आपका जवाब उसी session को वापस
  भेजता है। Claude जो काम बाद में background में पूरा करता है, उसकी रिपोर्ट update के रूप में दी जाती है।
- जब Claude किसी permission prompt का इंतज़ार कर रहा हो, तो voice यह बताता है। Prompt का जवाब आप
  Claude Code में देते हैं; LiveBridge उसका जवाब कभी आपकी जगह नहीं देता।

## बिलिंग का ध्यान रखने वाला डिज़ाइन

Realtime voice session खुली रहने तक खर्च होता है, इसलिए LiveBridge उसे सिर्फ़ तभी खोलता है जब कोई
बोल रहा हो, या जब आपके अभी किए गए अनुरोध पर Claude का जवाब आना बाकी हो:

- जब call चालू हो और कोई बोल नहीं रहा, तब microphone सिर्फ़ आपके Mac पर चल रहे voice detector को
  audio देता है। कहीं कुछ भेजा नहीं जाता।
- जब आप बोलना शुरू करते हैं, line खुल जाती है। बोलना शुरू करने से पहले के 2 सेकंड रखे जाते हैं और
  सबसे पहले भेजे जाते हैं, ताकि आपके पहले शब्द न छूटें।
- 20 सेकंड की चुप्पी के बाद line बंद हो जाती है। शब्दों के बिना आवाज़ (संगीत, TV) उसे 90 सेकंड बाद
  बंद करती है।
- जब voice कोई अनुरोध Claude को सौंपता है (handoff), तो उस handoff के बाद line अधिकतम 2 मिनट तक
  खुली रहती है, जिसका बिल किसी भी खुली line की तरह बनता है, और जब कोई बोल नहीं रहा होता तब voice
  Claude का जवाब सुनाता है। अगला handoff 2 मिनट फिर से शुरू करता है; जिस बातचीत में Claude को कुछ
  नहीं भेजा जाता, वह सामान्य 20 सेकंड की चुप्पी के बाद बंद हो जाती है।
- जो नतीजा बाद में आता है, जब line बंद हो, वह chime बजाता है और इंतज़ार करता है: band और menu उसे
  न सुना हुआ दिखाते हैं, और जब आप अगली बार बोलते हैं तो voice आपको बताता है
  ([कब माना जाता है कि सुन लिया गया](docs/architecture/overview.md#a-result-while-the-line-is-closed))।
- हर Claude Code session की voice के साथ अपनी अलग conversation होती है। वह अगले realtime session में
  आगे ले जाई जाती है, और Stop और Start के पार भी, ताकि voice को याद रहे कि आपने एक मिनट पहले क्या
  कहा था। नया target conversation बदल देता है: खुली line बंद हो जाती है, और आपके अगले शब्द उसे नए target
  की conversation के साथ खोलते हैं।
- Menu वे मिनट दिखाता है जितनी देर line खुली रही, जैसा app ने नापा; आपका plan realtime voice को कैसे
  मीटर करता है, यह प्रकाशित नहीं है।

## गोपनीयता

LiveBridge में कोई telemetry नहीं है और वह किसी network port पर listen नहीं करता; mod, app से एक Unix
socket पर बात करता है, जो ऐसे folder में है जिसे केवल आपका user खोल सकता है। codex के realtime
session के ज़रिए OpenAI को यह जाता है:

- line खुली रहने के दौरान microphone audio, आपके बोलना शुरू करने से 2 सेकंड पहले से लेकर line बंद
  होने तक;
- voice के निर्देश: LiveBridge के अपने नियम, फिर आपकी Settings का **Prompt**, अगर आपने लिखा हो;
- target session की हाल की conversation (आख़िरी 24 पंक्तियों तक), ताकि उसे नए realtime session में
  जारी रखा जा सके;
- target session के अभी खुले अनुरोध, उनके एक-पंक्ति के सार (brief) के रूप में;
- हर नतीजा, सवाल, update और approval notice, अधिकतम 2,000 अक्षरों की एक पंक्ति के रूप में, code
  blocks और tables हटाकर। Update, Claude का जवाब है जो किसी background task के notification से शुरू हुए
  बाद के turn में आता है, voice अनुरोध के बाद 10 मिनट तक और तब तक जब तक session में कोई दूसरा turn
  शुरू न हो;
- target session का context सारांश, अधिकतम 1,500 अक्षरों की एक पंक्ति के रूप में। यह load होने पर सेव
  होता है और जब भी line खुलती है और वह session target होता है, तब भेजा जाता है, Stop और Start के
  पार और app के restart के बाद भी। Menu का Conversation submenu उस पंक्ति को ठीक वैसी ही दिखाता है
  जैसी वह भेजी जाती है;
- ऊपर की हर पंक्ति के साथ, उसके session का label: Claude Code session का title, या अगर title न हो तो
  session folder का नाम;
- WebRTC offer, जो Mac के local network addresses को connection candidates के रूप में सूचीबद्ध करता है।

नतीजे, सवाल, updates और सारांश पहले जानी-पहचानी credential आकृतियों (private keys, JWTs, आम API
tokens, URL में passwords, `password=` जैसे fields) के redactor से गुज़रते हैं। यह patterns की सूची है,
कोई गारंटी नहीं।

voice को ले जाने वाला codex thread अस्थायी (ephemeral) और read-only है, जिसमें हर codex feature बंद है
सिवाय उनके जहाँ वह आपका login रखता है और जहाँ वह आपके proxy का उपयोग करता है, और हर MCP server बंद
है; वह सिर्फ़ बात करने के लिए है। Claude का काम Anthropic को वैसे ही जाता है जैसे आपका Claude Code
session हमेशा भेजता है।

आपके Mac पर app अपनी settings, usage meter और, सबसे हाल में इस्तेमाल हुए 20 sessions में से हर एक की,
उसकी हाल की conversation और उससे आख़िरी बार load की गई context पंक्ति `~/Library/Application Support/LiveBridge`
में रखता है। किसी session की पंक्तियाँ तब जाती हैं जब आप उसे target रखकर **New conversation** दबाते हैं
या उसे × से हटाते हैं। जो session चला गया है, उसकी पंक्तियाँ तब तक रहती हैं जब तक उसके बाद इस्तेमाल हुए
20 sessions उन्हें बाहर न धकेल दें; उन्हें जल्दी मिटाने के लिए, उसी session में फिर से `/live on` चलाएँ
और **New conversation** दबाएँ। Uninstall करने से वे सब हट जाती हैं।

[SECURITY.md](SECURITY.md) में threat model है: संक्षेप में, जो कुछ भी आपका microphone सुन सकता है
वह एक ऐसा अनुरोध बन सकता है जिसे Claude session के अपने permission mode के तहत चलाता है।

## ज्ञात सीमाएँ

- जो नतीजा तब आता है जब line उसका इंतज़ार कर रही हो, वह voice को बोलने के लिए text के रूप में जाता है;
  codex में ऐसा कोई call नहीं है जो voice को तुरंत बुलवाए, इसलिए कब बोलना है यह model तय करता है।
  टेस्टिंग में वह कुछ सेकंड के भीतर बोल गया। अगर नहीं बोलता, तो नतीजा न सुना हुआ रहता है: voice उसे आपके
  अगले शब्दों के बाद सुनाता है, या line बंद होने पर chime बजती है।
- जब आपके अगले शब्द line को फिर से खोलते हैं, तो voice कभी-कभी सिर्फ़ उन्हीं का जवाब देता है और
  इंतज़ार कर रहा नतीजा नहीं सुनाता। नतीजा खोता नहीं है: वह इंतज़ार में रहता है, line बंद होने पर chime
  बजाता है और notification भेजता है, और अगली बार line खुलने पर फिर से voice को जाता है।
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
  ([नियम](docs/architecture/overview.md#a-result-while-the-line-is-closed))। किसी दूसरी भाषा में, अगर
  voice ने नतीजे का सिर्फ़ ज़िक्र किया हो, तब भी वह सुना हुआ गिना जा सकता है।

## यह कैसे काम करता है

[docs/architecture/overview.md](docs/architecture/overview.md) components, mod और app के बीच की wire,
और message flows का वर्णन करता है; [ADR 0001](docs/adr/0001-platform-findings.md) उन platform तथ्यों को
दर्ज करता है जिन पर design टिका है।

## रोडमैप और सहयोग चाहिए

LiveBridge आज एक Mac app, एक worker (Claude Code) और एक voice provider (ChatGPT login पर codex) है।
ये तीनों संकरे जोड़ों (seams) पर मिलते हैं, और नीचे की हर दिशा contributors के लिए खुली है। उनके issues पर
[help wanted](https://github.com/getLiveBridge/LiveBridge/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
label लगा होता है; [CONTRIBUTING.md](CONTRIBUTING.md#where-to-start) बताता है कि पहले कौन-सी फ़ाइलें पढ़ें।

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

- [CONTRIBUTING.md](CONTRIBUTING.md): layout, toolchain, checks (`scripts/check.sh`) और conventions।
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md): यहाँ हम एक-दूसरे के साथ कैसे पेश आते हैं।
- [SECURITY.md](SECURITY.md): vulnerability की रिपोर्ट निजी तौर पर करें, public issue में नहीं।
- [CHANGELOG.md](CHANGELOG.md): हर release में क्या बदला।

## श्रेय

mod और app के बीच के wire protocol की प्रेरणा
[claude-code-voice-mod](https://github.com/ldk00315-jpg/claude-code-voice-mod) से मिली। उससे कोई code या text
कॉपी नहीं किया गया।

## लाइसेंस

[MIT](LICENSE)।
