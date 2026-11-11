<div align="center">

<img src="Resources/icon-source.png" width="120" alt="MoodyVid">

# MoodyVid

**تنزيل الفيديو من أي موقع — على الآيفون**

متصفّح مدمج يكشف روابط الفيديو والصوت والملفات، وينزّلها بسرعة،
ويعمل مع يوتيوب وتيك توك وإنستغرام وأكثر من ١٨٠٠ موقع.

![iOS](https://img.shields.io/badge/iOS-15.0%2B-12ACBA)
![License](https://img.shields.io/badge/license-MIT-12ACBA)
![Build](https://github.com/mody-iq/MoodyVid/actions/workflows/build.yml/badge.svg)

[التثبيت](#-التثبيت) · [المزايا](#-المزايا) · [البناء](#-البناء-من-المصدر) · [الأسئلة](#-أسئلة-شائعة)

</div>

---

## 📥 التثبيت

> ⚠️ آيفون لا يسمح بتثبيت التطبيقات من رابط مثل أندرويد.
> تحتاج أحد البرامج التالية — وهي مجانية وموثوقة.

### الطريقة الأسهل: AltStore أو SideStore

هذه الطريقة تجعل التطبيق **يتحدّث تلقائيًا** بعد التثبيت.

1. ثبّت [AltStore](https://altstore.io) أو [SideStore](https://sidestore.io) على جهازك.
2. افتحه ← تبويب **Sources** ← اضغط **+**.
3. أضف هذا الرابط:

```
https://raw.githubusercontent.com/mody-iq/MoodyVid/main/source.json
```

4. ابحث عن **MoodyVid** واضغط **Install**. انتهى ✅

### الطريقة الثانية: تحميل ملف IPA

إن كنت تعرف التوقيع بنفسك:

1. حمّل أحدث ملف من صفحة [**Releases**](../../releases).
2. وقّعه بأداة مثل **Sideloadly** أو **Esign** أو **GBox**.

> 💡 بعد التثبيت الأول، **لا تحتاج إعادة التثبيت** — AltStore يخبرك بالتحديث الجديد.

---

## 📱 هل يعمل على جهازك؟

**افحص جهازك الآن:** الإعدادات ← عام ← حول ← إصدار النظام.

| البند | المطلوب | ملاحظة |
|---|---|---|
| **الجهاز** | **آيفون فقط** | ❌ لا يعمل على آيباد |
| **إصدار النظام** | **iOS 15.0 أو أحدث** | أقدم إصدار مدعوم |
| **المعالج** | **arm64** | أي آيفون من iPhone 6s (2015) وأحدث |
| **الأجهزة المدعومة** | iPhone 6s · SE (1st & 2nd & 3rd) · 7 · 8 · X · XR · XS · 11 · 12 · 13 · 14 · 15 · 16 · SE 4 | كلها ✅ |

> 🔎 **كيف تعرف إصدارك؟** الإعدادات ← عام ← حول ← «إصدار النظام» أو «iOS Version».
>
> ✅ إذا كان **iOS 15 أو أحدث** وعلى **آيفون** → التطبيق يعمل.
> ❌ إذا كان **iOS 14 أو أقدم**، أو على **آيباد** → لن يعمل.

> 💡 التطبيق يمنع التثبيت تلقائيًا على جهاز غير مدعوم، فلن تخسر شيئًا إن جرّبت.

---

## ✨ المزايا

| | |
|---|---|
| 🧭 **متصفّح مدمج** | يتصفّح أي موقع ويحقن زر التنزيل تلقائيًا |
| 🔍 **مكشّف ذكي** | يلتقط الفيديو والصوت والملفات وروابط m3u8 |
| 🎬 **اختيار الجودة** | من 480p حتى 1080p، أو صوت M4A/MP3 فقط |
| 🌐 **أكثر من ١٨٠٠ موقع** | يوتيوب، تيك توك، إنستغرام، تويتر، فيسبوك… |
| 🧲 **التورنت** | يدعم ملفات .torrent وروابط magnet |
| 📥 **تحميل سريع** | مقسّم على عدة اتصالات، ويستكمل بعد الانقطاع |
| 🎵 **المشغّل** | تشغيل مصغّر داخل التطبيق مع خلفية صوتية |
| 📂 **الملفات** | حفظ في مجلد الملفات، وفتح مباشر من تطبيق الملفات |
| 🌙 **الواجهة** | عربي/إنجليزي، وضع ليلي، وخلفيات متعددة |

---

## 🔧 البناء من المصدر

البناء يجري على GitHub Actions تلقائيًا عند كل رفع إلى `main`.
الملف الناتج يظهر في تبويب **Actions**، ويُنشر تلقائيًا في **Releases**.

للتنفيذ محليًا على macOS:

```bash
bash scripts/build.sh
```

**المتطلبات:** macOS + Xcode Command Line Tools + Python 3.14.

ما يفعله السكربت:

1. ينزّل CPython و yt-dlp الرسميين.
2. يبني مكتبة LAME (لتحويل MP3) للآيفون.
3. يترجم كود Objective-C بـ `clang`.
4. يجمّع الحزمة ويوقّعها بـ `ldid`.
5. ينتج `build/MoodyVid.ipa` جاهزًا.

### الإصدار

لتغيير رقم الإصدار، عدّل `CFBundleShortVersionString` في `Resources/Info.plist`.
رقم البناء (`CFBundleVersion`) يتغيّر تلقائيًا مع كل بناء.

---

## 📁 بنية المشروع

```
Sources/          كود Objective-C (الواجهات + المحرّكات)
Resources/        Info.plist والأيقونات
scripts/          البناء والتجميع والأدوات
tests/            اختبارات بايثون (تعمل بدون آيفون)
app/              كود بايثون الذي يعمل داخل التطبيق
source.json       ملف مصدر AltStore (يُحدَّث تلقائيًا)
```

---

## ❓ أسئلة شائعة

**التطبيق اختفى بعد فترة؟**
توقيع التطبيقات المجانية ينتهي بعد **٧ أيام**. أعد التثبيت من AltStore، أو استخدم حساب مطوّر (٩٩$/سنة) للتوقيع لسنة كاملة.

**هل يحتاج جيلبريك؟**
لا. يعمل على أي آيفون بنظام iOS 15 أو أحدث.

**لماذا لا يوجد في App Store؟**
لأن آبل تمنع تطبيقات التورنت، وتمنع تشغيل محرّكات تنزيل عامة (البند 2.5.2).

**هل يعمل على أندرويد؟**
لا، هذا التطبيق للآيفون فقط.

---

## ⚖️ تنبيه قانوني

هذا التطبيق أداة تقنية للاستخدام الشخصي. أنت المسؤول عن احترام حقوق النشر
وشروط استخدام المواقع التي تزورها. لا تستخدمه لتنزيل محتوى لا تملك حق تنزيله.
المطوّر غير مسؤول عن أي استخدام مخالف.

---

## 📄 الترخيص

[MIT](LICENSE) — يمكنك الاستخدام والتعديل والتوزيع بحرية مع ذكر المصدر.

<div align="center">

صُنع بـ ❤️ للمستخدم العربي

</div>

---

# 🇬🇧 English

<div align="center">

**Download videos from any site — on iPhone**

A built-in browser that sniffs out video, audio and file links, then downloads
them fast. Works with YouTube, TikTok, Instagram and 1800+ other sites.

![iOS](https://img.shields.io/badge/iOS-15.0%2B-12ACBA)
![Device](https://img.shields.io/badge/device-iPhone-12ACBA)
![License](https://img.shields.io/badge/license-MIT-12ACBA)

</div>

## 📥 Installation

> ⚠️ iOS does not allow installing an app from a link the way Android does.
> You need one of the helpers below. Both are free and widely used.

### Easiest: AltStore or SideStore

This way the app **updates itself** after the first install.

1. Install [AltStore](https://altstore.io) or [SideStore](https://sidestore.io) on your device.
2. Open it → **Sources** tab → tap **+**.
3. Add this URL:

```
https://raw.githubusercontent.com/mody-iq/MoodyVid/main/source.json
```

4. Find **MoodyVid** and tap **Install**. Done ✅

### Alternative: download the IPA

If you already know how to sign apps:

1. Download the latest build from the [**Releases**](../../releases) page.
2. Sign it with a tool such as **Sideloadly**, **Esign** or **GBox**.

> 💡 After the first install you do **not** need to reinstall — AltStore tells you
> when an update is ready.

## 📱 Will it run on my device?

**Check yours:** Settings → General → About → Software Version.

| Item | Requirement | Note |
|---|---|---|
| **Device** | **iPhone only** | ❌ Does not run on iPad |
| **iOS version** | **15.0 or newer** | Oldest supported |
| **CPU** | **arm64** | Any iPhone from the 6s (2015) onwards |
| **Supported models** | iPhone 6s · SE (1st, 2nd, 3rd gen) · 7 · 8 · X · XR · XS · 11 · 12 · 13 · 14 · 15 · 16 · SE 4 | all ✅ |

> ✅ **iOS 15 or newer on an iPhone** → it runs.
> ❌ **iOS 14 or older**, or an **iPad** → it will not run.

> 💡 The app refuses to install on an unsupported device, so trying costs you nothing.

## ✨ Features

| | |
|---|---|
| 🧭 **Built-in browser** | Browse any site; a download button is injected automatically |
| 🔍 **Smart sniffer** | Catches video, audio, files and m3u8 streams |
| 🎬 **Quality picker** | 480p up to 1080p, or audio-only M4A/MP3 |
| 🌐 **1800+ sites** | YouTube, TikTok, Instagram, Twitter, Facebook… |
| 🧲 **Torrents** | `.torrent` files and magnet links |
| 📥 **Fast downloader** | Multi-connection, resumes after an interruption |
| 🎵 **Player** | Mini player in-app with background audio |
| 📂 **Files** | Saves to the Files app; open directly from there |
| 🌙 **Interface** | Arabic/English, dark mode, multiple themes |

## 🔧 Building from source

CI builds on every push to `main`. The result appears under **Actions** and is
published to **Releases** automatically.

To build locally on macOS:

```bash
bash scripts/build.sh
```

**Requirements:** macOS + Xcode Command Line Tools + Python 3.14.

What the script does:

1. Downloads official CPython and yt-dlp.
2. Builds LAME (for MP3) for iOS.
3. Compiles the Objective-C code with `clang`.
4. Assembles the bundle and signs it with `ldid`.
5. Produces `build/MoodyVid.ipa`.

### Versioning

Change `CFBundleShortVersionString` in `Resources/Info.plist` to set the version.
The build number (`CFBundleVersion`) increases on its own with every build.

## 📁 Project layout

```
Sources/          Objective-C (UI + engines)
Resources/        Info.plist and icons
scripts/          Build, assembly and tooling
tests/            Python tests (run without a device)
app/              Python that runs inside the app
source.json       AltStore source file (updated by CI)
```

## ❓ FAQ

**The app disappeared after a while?**
A free signing certificate lasts **7 days**. Reinstall it from AltStore, or use a
developer account ($99/year) to sign for a full year.

**Does it need a jailbreak?**
No. It runs on any iPhone with iOS 15 or newer.

**Why is it not on the App Store?**
Because Apple bans torrent apps and bans running general-purpose download engines
(guideline 2.5.2).

**Does it work on Android?**
No, this app is for iPhone only.

## ⚖️ Legal notice

This app is a technical tool for personal use. You are responsible for respecting
copyright and the terms of service of the sites you visit. Do not use it to
download content you have no right to download. The developer is not responsible
for misuse.

## 📄 License

[MIT](LICENSE) — free to use, modify and redistribute with attribution.
