<div align="center">

# MoodyVid — دليل المطوّر

**Building MoodyVid from source**

هذا الملف للمطوّرين. للمستخدم العادي راجع [README.md](README.md).

</div>

---

# 🇸🇦 العربية

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

## 🔢 الإصدار

لتغيير رقم الإصدار، عدّل `CFBundleShortVersionString` في `Resources/Info.plist`.
رقم البناء (`CFBundleVersion`) يتغيّر تلقائيًا مع كل بناء.

## 🧪 الاختبارات

اختبارات بايثون تعمل بدون آيفون ولا محاكي:

```bash
python3 -m unittest discover -s tests -v
```

تغطي:

- `test_downloader.py` — منطق التنزيل داخل `app/`.
- `test_make_source.py` — حقول ملف AltStore.
- `test_make_screenshots.py` — رسم صور المتجر وحدود التخطيط.

## 🖼️ صور المتجر

`scripts/make_screenshots.py` يرسم صور صفحة AltStore بالكود، لأن سيرفر البناء
لا يملك محاكيًا. النصوص والألوان مأخوذة من الكود الحقيقي، فعند تغيير الواجهة
أعد التشغيل:

```bash
python3 scripts/make_screenshots.py --out-dir Resources/screenshots
```

يحتاج Pillow وخط عربي. ينتج `Resources/screenshots/index.json` الذي يقرأه
`scripts/make_source.py`.

## 📁 بنية المشروع

```
Sources/          كود Objective-C (الواجهات + المحرّكات)
Resources/        Info.plist والأيقونات وصور المتجر
scripts/          البناء والتجميع والأدوات
tests/            اختبارات بايثون (تعمل بدون آيفون)
app/              كود بايثون الذي يعمل داخل التطبيق
source.json       ملف مصدر AltStore (يُحدَّث تلقائيًا)
```

---

# 🇬🇧 English

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

## 🔢 Versioning

Change `CFBundleShortVersionString` in `Resources/Info.plist` to set the version.
The build number (`CFBundleVersion`) increases on its own with every build.

## 🧪 Tests

The Python tests run without a device or a simulator:

```bash
python3 -m unittest discover -s tests -v
```

They cover:

- `test_downloader.py` — the download logic in `app/`.
- `test_make_source.py` — the AltStore source fields.
- `test_make_screenshots.py` — the store images and their layout bounds.

## 🖼️ Store screenshots

`scripts/make_screenshots.py` draws the AltStore page images in code, because the
CI runner has no simulator. The strings and colours are taken from the real
source, so re-run it whenever the UI changes:

```bash
python3 scripts/make_screenshots.py --out-dir Resources/screenshots
```

It needs Pillow and an Arabic font. It writes
`Resources/screenshots/index.json`, which `scripts/make_source.py` reads.

## 📁 Project layout

```
Sources/          Objective-C (UI + engines)
Resources/        Info.plist, icons and store screenshots
scripts/          Build, assembly and tooling
tests/            Python tests (run without a device)
app/              Python that runs inside the app
source.json       AltStore source file (updated by CI)
```
