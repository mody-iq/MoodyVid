<div align="center">

# MoodyVid — دليل المطوّر

**Building MoodyVid from source**

هذا الملف للمطوّرين. للمستخدم العادي راجع [README.md](README.md).

</div>

---

# 🇸🇦 العربية

## 🔧 البناء من المصدر

البناء يجري على GitHub Actions عند رفع تغييرات الكود إلى أي فرع أو تشغيله يدويًا.
كل بناء ناجح يوفّر ملف IPA في **Actions**؛ وحده بناء `main` غير التجريبي
ينشر الإصدار الرسمي في **Releases** ويحدّث `source.json`. النسخ التجريبية
والفروع الأخرى لا تنشر. لا يملك بناء الفروع صلاحية تعديل الإصدارات.
يُعاد فحص أحدث مراجعة قبل النشر، لكن رفع ملف Release وتحديث `main` ليسا عملية
ذرية واحدة؛ قد يبقى ملف قديم إذا تغيّر `main` أثناء الرفع حتى ينجح نشر أحدث.

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

الاختبارات التالية تعمل دون آيفون أو محاكي:

```bash
python3 -m pip install Pillow
python3 -m unittest discover -s tests -v
bash scripts/http-policy-tests.sh  # Linux أو macOS، يحتاج مترجم C
bash scripts/transfer-policy-tests.sh  # استعادة الطابور والنطاقات والسرعة والتورنت
node tests/video_button_test.js     # محاكاة DOM لزر الفيديو
python3 scripts/check-strings.py
```

تحتاج اختبارات الصور إلى Pillow مع دعم RAQM وFriBiDi وخط عربي؛ غياب Pillow
يؤدي إلى تخطيها. ويمكن فحص الدعم عبر
`python3 -c 'from PIL import features; print(features.check_feature("raqm"))'`.
تغطي اختبارات بايثون التنزيل وملف AltStore والصور وحماية النشر وقواعد تنقيح
السجلات (الأخيرة تتطلب مكتبة ICU، وتُتخطى إذا لم تتوفر).

اختبارات Foundation الإضافية تحتاج macOS وclang، ولا تتطلب جهازًا:

```bash
bash scripts/privacy-tests.sh  # الكوكيز والتحويلات والسجلات؛ خادم محلي مؤقت
bash scripts/torrent-tests.sh  # بيانات التورنت والتخزين وتراسل النظير
bash scripts/queue-tests.sh    # استعادة السجلات المحفوظة
bash scripts/player-tests.sh   # مواضع التشغيل والترجمة المحلية
bash scripts/storage-tests.sh  # فحص الملفات والسلة في مجلد مؤقت
bash scripts/transfer-tests.sh # قوائم HLS/DASH ونقل HTTP عبر خادم محلي
```

هذه الاختبارات لا تثبت سلوك WebKit أو تنزيل المواقع على الآيفون؛ يلزم اختبار
فعلي على جهاز، خصوصًا تسجيل الدخول وHLS والتنزيل المباشر والمسح أثناء التنزيل.

## ⏯️ الاستئناف وحدود النقل

- تُعاد المهام التي انقطع تشغيلها إلى الطابور بعد إعادة التشغيل، بينما يبقى
  الإيقاف المؤقت والإلغاء كما اختارهما المستخدم. في محرك yt-dlp يعتمد
  الاستئناف الفعلي على دعم المصدر وyt-dlp، والإيقاف تعاوني وليس فوريًا دائمًا.
- ملفات yt-dlp الجزئية الجديدة معزولة لكل مهمة. الملفات الجزئية القديمة في
  `Documents/MoodyVid` لا تُنقل أو تُستأنف تلقائيًا، لتجنب إلحاق ملف بمهمة
  خاطئة؛ تبقى في مكانها ويمكن للمستخدم حذفها يدويًا بعد التأكد منها.
- تُفحص مراجع المهام والملفات الجزئية المنفردة قبل حذفها، وتُترك المسارات
  المشتركة أو غير الآمنة احتياطيًا؛ قد يبقى بعضها للتنظيف اليدوي. لا يمنع
  ذلك جميع حالات تغيير نظام الملفات بالتزامن، واختيار اسم الملف النهائي
  غير ذري عند حدوث تعارض متزامن.
- عند تفعيل Wi-Fi ينتظر الطابور شبكة مناسبة ويحاول إيقاف المهام النشطة ثم
  إعادتها للطابور عند الاتصال. تمنع جلسات HTTP الأصلية البيانات الخلوية،
  وتُربط مقابس التورنت بواجهة Wi-Fi المرصودة. إيقاف yt-dlp تعاوني وقد تنتقل
  بيانات قبل توقفه؛ لا يشمل الخيار التصفح أو جميع طلبات التطبيق، وسلوك تبديل
  الشبكات لم يُختبر على جهاز. حد السرعة تقريبي لكل تنزيل مباشر، وليس حدًا
  إجماليًا للتطبيق؛ تفعيله أثناء النقل يتطلب إعادة تشغيل المهمة.
- لا توجد جلسة تنزيل خلفية يديرها iOS حاليًا؛ يحاول التطبيق الاستمرار بوقت
  خلفية مؤقت وصوت صامت، ولا يضمن التنزيل بعد إنهاء التطبيق أو تعليقه من النظام.
- يدعم التورنت بيانات v1 وروابط magnet عبر متتبّعات HTTP(S) وBEP 9، لا DHT أو
  UDP أو v2. تُرفض البيانات التي تتجاوز 16 MiB للـ metadata أو القطعة، أو
  100,000 قطعة أو 4,096 ملفًا. يحدّ المحرك مساحة مخازن القطع المفتوحة لكل
  مهمة؛ توافق المواقع والتورنت على الجهاز لا تثبته الاختبارات المحلية. عند
  استيراد ملف تورنت محلي تُحفظ نسخة خاصة لاستئناف المهمة، ولا يُحذف الأصل.

## 🧪 إضافات الفرع التجريبي

- زر الفيديو يفتح كشف الروابط ولا يبدأ التنزيل تلقائيًا؛ قد لا يظهر في كل موقع.
  فحص الجودة والقوائم عبر yt-dlp لا يستورد كوكيز المتصفح. تعرض القوائم حتى
  100 رابط فريد وتضيف المحدد فقط.
- يحفظ المشغّل موضع الملفات المحلية والسرعة، ويستورد SRT/WebVTT. لم تُختبر
  الواجهة أو المواقع أو تشغيل الترجمات على آيفون بعد.
- يفحص مدير المساحة حتى 5,000 ملف وبميزانية بصمة 4 GiB، ولا يحذف تلقائيًا.
  يمكن نقل ملف عادي إلى السلة واستعادته دون الكتابة فوق ملف موجود، لكن سجل
  تنزيله المكتمل يُزال ولا يعود مع الاستعادة. حذف المجلدات وبعض مسارات الحذف
  الأخرى نهائي، والسلة لا تُفرغ تلقائيًا وليست خزنة مشفّرة.

## 🔐 الخصوصية

- تُختار كوكيز المتصفح لكل رابط وفق النطاق والمسار والصلاحية وHTTPS؛ ويُشترط
  أن يشمل نطاق الكوكي صفحة المصدر والوجهة. هذا تحفظ مقصود قد يمنع التنزيل
  من بعض الخدمات المعتمدة على كوكيز طرف ثالث. لا تُنسخ الكوكيز التي تكشف عن
  مفتاح تقسيم، ولا يمثّل هذا محاكاة كاملة لسياسات WebKit وSameSite. عند إدخال
  رابط بث يدويًا، يبقى رابط القائمة الأصلية سياقًا لطلب المقاطع والمفاتيح.
  محرك yt-dlp مستقل ولا يستورد كوكيز المتصفح.
- «مسح بيانات المتصفح» يمسح بيانات WebKit وكوكيز وذاكرة HTTP المشتركة
  للتطبيق والروابط المكتشفة وسجل التصفح عدا المفضلة. تبقى المفضلة بعناوينها،
  والتنزيلات وملفاتها وسجلات مهامها
  (وقد تتضمن روابط أو ترويسات أخرى غير الكوكيز)، وعلامات التبويب المفتوحة
  وسجلات التشخيص. الطلبات الجارية لا تُلغى وقد تظهر بيانات جديدة.
- تُنقّح الروابط وبعض الحقول الحساسة في السجلات الجديدة والقديمة قبل المشاركة؛
  التنقيح تقريبي، وقد تبقى أسماء ملفات أو تفاصيل شخصية. يُستبدل السجل القديم
  غير القابل للقراءة بنص تنبيه، ولا تُشارك الملفات الخام.

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

CI builds code pushes to any branch and manual runs. Every successful build
uploads an IPA under **Actions**, but only a non-variant build of `main` can
publish **Releases** or update `source.json`. Branch and test-variant builds
cannot publish and the build job has read-only repository permissions. Main is
rechecked before publication, but updating main and uploading a release asset
are not atomic; a main change during upload can leave an older asset until a
newer build publishes successfully.

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

These tests run without a device or simulator:

```bash
python3 -m pip install Pillow
python3 -m unittest discover -s tests -v
bash scripts/http-policy-tests.sh  # Linux or macOS; requires a C compiler
bash scripts/transfer-policy-tests.sh  # recovery, ranges, throttle, torrent limits
node tests/video_button_test.js     # simulated DOM for the video shortcut
python3 scripts/check-strings.py
```

The screenshot tests need Pillow with RAQM, FriBiDi, and an Arabic font; they
are skipped when Pillow is absent. Check RAQM with
`python3 -c 'from PIL import features; print(features.check_feature("raqm"))'`.
The Python suite covers downloads, AltStore metadata, screenshots, release
protection, and log-redaction patterns (the last is skipped if ICU is absent).

Foundation tests need macOS and clang, but no device:

```bash
bash scripts/privacy-tests.sh  # cookies, redirects, logs; local temporary server
bash scripts/torrent-tests.sh  # torrent metadata, storage and peer protocol
bash scripts/queue-tests.sh   # persisted queue recovery
bash scripts/player-tests.sh  # playback history and subtitle models
bash scripts/storage-tests.sh # scanner and trash in a disposable directory
bash scripts/transfer-tests.sh # HLS/DASH manifests and local HTTP transfers
```

These do not verify WebKit or actual downloads on iOS. Test sign-in, HLS, direct
downloads, and clearing data while a download is active on an iPhone as well.

## ⏯️ Recovery and transfer limits

- Interrupted running jobs return to the queue after restart; explicit pauses and
  cancellations remain in effect. Actual yt-dlp continuation depends on yt-dlp
  and the server, and cooperative cancellation is not always immediate.
- New yt-dlp partials are isolated per record. Older partials in
  `Documents/MoodyVid` are left in place and are not migrated or resumed
  automatically, because their ownership cannot be determined reliably. They
  can be removed manually after checking them.
- Cleanup checks saved references for individual partials as well as folders;
  shared or unsafe paths are conservatively left behind. This does not prevent
  every concurrent filesystem replacement, and final-name selection is not
  atomic when multiple publishers choose the same name simultaneously.
- Wi-Fi-only holds new tasks until a suitable path is observed and attempts to
  pause/requeue active work on a path change. Native HTTP sessions disallow
  cellular and torrent sockets bind to the observed Wi-Fi interface. Python
  stops cooperatively, so some bytes may still transfer before it pauses. This
  does not restrict browsing or all app requests, and transitions need device
  testing. The speed limit is approximate per direct transfer, not global, and
  enabling it mid-transfer requires restarting that task.
- There is currently no iOS-managed background download session. The app uses
  limited background time and silent audio to try to keep work running; iOS may
  suspend it, and a force-quit or suspension does not guarantee completion.
- The torrent engine supports v1 metadata and tracker-backed BEP 9 magnets, not
  DHT, UDP trackers or v2. Metadata and individual pieces are capped at 16 MiB,
  with at most 100,000 pieces and 4,096 files; open piece buffers are also
  bounded per task. Local tests do not establish on-device swarm compatibility.
  A locally imported torrent is copied privately so the task can resume; the
  original selected file is never deleted.

## 🧪 Experimental branch features

- The on-video shortcut opens link detection rather than downloading immediately;
  it may not appear on every site. yt-dlp quality/playlist inspection does not
  import browser cookies. Playlist previews contain at most 100 unique links and
  queue only the chosen entries.
- The player saves local-file position and rate and imports SRT/WebVTT. The UI,
  real sites and subtitle playback have not yet been verified on an iPhone.
- Storage analysis scans up to 5,000 files with a 4 GiB hashing budget and never
  deletes automatically. A regular file can be moved to Trash and restored
  without overwriting an existing file; its completed download history is removed
  and is not restored. Folder deletion and some other deletion paths are
  permanent. Trash is not emptied automatically and is not an encrypted vault.

## 🔐 Privacy

- Browser cookies are selected per URL by domain, path, expiry and HTTPS; the
  cookie's domain must cover both the source page and destination. This
  conservative rule may block services requiring third-party cookies. Cookies
  exposing a partition key are excluded; this is not a full implementation of
  WebKit's partitioning or SameSite policies. For a manually entered stream, the
  original manifest remains the context for its segments and keys. The yt-dlp
  engine is independent and does not import browser cookies.
- Clear browser data removes WebKit website data, the app's shared Foundation
  cookies and HTTP cache, detected links and browsing history except favorites.
  Favorites and their URLs, downloads, files and task
  records (which may contain URLs or other non-cookie headers), open tabs and
  diagnostic logs remain. In-flight requests are not cancelled and may create
  new data.
- New and legacy logs have URLs and common credential fields redacted before
  sharing. Redaction is best-effort: file names and other personal information
  may remain. An unreadable old log is replaced with a notice rather than
  exported, and raw log files are never handed to the share sheet.

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
