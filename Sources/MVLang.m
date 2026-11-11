#import "MVLang.h"

NSString *const MVLangDidChangeNotification = @"MVLangDidChangeNotification";

static NSString *const kLangKey = @"MVLanguageCode";

@implementation MVLang

+ (instancetype)shared {
    static MVLang *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [MVLang new];
        NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kLangKey];
        instance->_code = saved.length ? saved : @"ar";
    });
    return instance;
}

- (void)setCode:(NSString *)code {
    if (![code isEqualToString:@"ar"] && ![code isEqualToString:@"en"]) return;
    if ([_code isEqualToString:code]) return;
    _code = [code copy];
    [NSUserDefaults.standardUserDefaults setObject:_code forKey:kLangKey];
    [NSNotificationCenter.defaultCenter postNotificationName:MVLangDidChangeNotification object:nil];
}

- (BOOL)isRTL { return [_code isEqualToString:@"ar"]; }

// Keys are the English wording, so the table reads as a translation list and a
// lookup for an unknown key falls back to readable English.
static NSDictionary<NSString *, NSString *> *MVTable(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            // Tabs
            // Browser download panel
            @"Reading link...": @"جارٍ قراءة الرابط...",
            @"Could not read the details; pick a quality.": @"تعذّرت قراءة التفاصيل، اختر جودة.",
            @"4K": @"4K",
            @"1440p": @"1440p",
            @"Reading": @"قراءة",
            @"Home": @"الرئيسية",
            @"Downloads": @"التنزيلات",
            @"Files": @"الملفات",
            @"Settings": @"الإعدادات",
            @"More": @"المزيد",
            @"Clipboard is empty": @"الحافظة فارغة",
            @"Remove ads and unlock more": @"أزل الإعلانات وافتح المزيد",
            @"Saved to Files but not to Photos": @"تم الحفظ في الملفات لكن ليس في الصور",
            @"Saved to Files but not to Photos: permission denied": @"تم الحفظ في الملفات لكن ليس في الصور: الإذن مرفوض",
            @"No favorites yet": @"لا توجد مفضلة بعد",
            @"Music": @"موسيقى",
            @"Movies": @"أفلام",
            @"Sports": @"رياضة",
            @"News": @"أخبار",
            @"Gaming": @"ألعاب",
            @"Tech": @"تقنية",
            @"Premium": @"بريميوم",
            @"Search": @"بحث",
            @"Suggested for you": @"مقترح لك",
            @"Paste your video link here...": @"الصق رابط الفيديو هنا...",
            @"Fetch": @"جلب",
            @"Paste and fetch": @"لصق وجلب",
            @"downloading": @"جارٍ التنزيل",
            @"waiting": @"في الانتظار",
            @"Merging…": @"جارٍ دمج...",
            @"Merge failed": @"فشل الدمج",
            @"Converting…": @"جارٍ التحويل...",
            @"1080p HD": @"1080p عالية الدقة",
            @"MP3 (audio)": @"MP3 (صوت فقط)",
            @"Convert to MP3": @"تحويل إلى MP3",
            @"Merging video and audio…": @"جارٍ دمج الفيديو والصوت...",
            @"Preparing audio…": @"جارٍ تحضير الصوت...",
            @"Active downloads": @"التحميلات النشطة",
            @"Completed downloads": @"التحميلات المكتملة",
            @"No active downloads": @"لا توجد تحميلات نشطة",
            @"No completed downloads": @"لا توجد تحميلات مكتملة",
            @"Open in Files": @"فتح في الملفات",
            @"Remove from history": @"إزالة من السجل",
            @"Browser": @"المتصفح",
            @"Search or enter address": @"ابحث أو أدخل عنواناً",
            @"Download this video": @"حمّل هذا الفيديو",
            @"Favorites": @"المفضلة",
            @"History": @"السجل",
            @"No history yet": @"لا يوجد سجل بعد",
            @"Back": @"رجوع",
            @"Forward": @"تقدّم",
            @"Refresh": @"تحديث",
            @"Close": @"إغلاق",
            @"Minimize": @"تصغير",
            @"Tap to return to the page": @"اضغط للعودة إلى الصفحة",
            @"Add to favorites": @"أضف إلى المفضلة",
            @"Media found": @"تم إيجاد وسائط",
            @"Downloading to": @"يُحمَّل إلى",
            @"Cancel all": @"إلغاء الكل",
            @"Retry": @"إعادة المحاولة",
            @"Queued": @"في الانتظار",
            @"Connecting…": @"جارٍ الاتصال…",
            @"Tap a site to browse it inside the app": @"اضغط على موقع لتصفحه داخل التطبيق",
            @"Your downloads will keep running while you use the app": @"ستستمر تحميلاتك أثناء استخدامك للتطبيق",

            // Home
            @"Paste video link here...": @"الصق رابط الفيديو هنا...",
            @"Paste": @"لصق",
            @"Download": @"تحميل",
            @"Quality": @"الجودة",
            @"Best available": @"أفضل جودة متاحة",
            @"Up to 720p": @"حتى 720p",
            @"Up to 480p": @"حتى 480p",
            @"Audio only (M4A)": @"صوت فقط (M4A)",
            @"1080p": @"1080p",
            @"720p": @"720p",
            @"480p": @"480p",
            @"Now playing": @"جارٍ التشغيل",
            @"Saved": @"تم الحفظ",
            @"Saved to Photos": @"تم الحفظ في تطبيق الصور",
            @"Save to Photos": @"حفظ في الصور",
            @"Reload": @"إعادة التحميل",
            @"Choose quality": @"اختر الجودة",
            @"Please paste a link first": @"الرجاء لصق رابط أولاً",
            @"Downloading...": @"جاري التحميل...",
            @"Downloaded successfully": @"تم التحميل بنجاح",
            @"Failed": @"فشل",
            @"Unknown error": @"خطأ غير معروف",
            @"Cancel": @"إلغاء",
            @"Quick access": @"وصول سريع",
            @"Recent": @"الأخيرة",
            @"No recent downloads": @"لا توجد تنزيلات حديثة",

            // Downloads
            @"Search downloads": @"ابحث في التنزيلات",
            @"Active": @"نشط",
            @"Completed": @"مكتمل",
            @"Edit": @"تعديل",
            @"Done": @"تم",
            @"Playing": @"جارٍ التشغيل",
            @"Paused": @"متوقف موقتاً",
            @"Waiting": @"في الانتظار",
            @"No downloads yet": @"لا توجد تنزيلات بعد",
            @"Cancel download": @"إلغاء التحميل",
            @"Play": @"تشغيل",
            @"Share": @"مشاركة",
            @"Rename": @"إعادة تسمية",
            @"Delete": @"حذف",
            @"Delete this file?": @"حذف هذا الملف؟",
            @"This cannot be undone.": @"لا يمكن التراجع عن هذا الإجراء.",

            // Files
            @"Search files": @"ابحث في الملفات",
            @"New folder": @"مجلد جديد",
            @"Folder name": @"اسم المجلد",
            @"Create": @"إنشاء",
            @"Sort by": @"ترتيب حسب",
            @"Name": @"الاسم",
            @"Date": @"التاريخ",
            @"Size": @"الحجم",
            @"available": @"متاح",
            @"Empty folder": @"مجلد فارغ",
            @"1 file": @"ملف واحد",
            @"files": @"ملف",
            @"No files": @"لا توجد ملفات",
            @"Move to folder": @"نقل إلى مجلد",
            @"Nothing to move to": @"لا توجد مجلدات",

            // Settings
            @"Language": @"اللغة",
            @"Arabic": @"العربية",
            @"English": @"الإنجليزية",
            @"Appearance": @"المظهر",
            @"Theme": @"السمة",
            @"Dark": @"داكن",
            @"Light": @"فاتح",
            @"System": @"النظام",
            @"Download engine": @"محرك التحميل",
            @"Engine status": @"حالة المحرك",
            @"Storage": @"التخزين",
            @"Clear cache": @"مسح الذاكرة المؤقتة",
            @"Cache cleared": @"تم مسح الذاكرة المؤقتة",
            @"Tap to clear": @"اضغط للمسح",
            @"Security": @"الأمان",
            @"Passcode lock": @"قفل برمز",
            @"About": @"حول",
            @"Version": @"الإصدار",
            @"Engine": @"المحرك",
            @"JavaScript engine": @"محرك جافاسكربت",
            @"Photos permission": @"إذن الصور",
            @"Photos permission needed": @"يحتاج التطبيق إذن الصور",
            @"Open Settings": @"فتح الإعدادات",
            @"Not available": @"غير متاح",
            @"Available": @"متاح",
            @"Copied": @"تم النسخ",
            @"Link copied": @"تم نسخ الرابط",
            @"Developer": @"المطور",
            @"Contact": @"التواصل",
            @"Follow me on social media": @"تابعني على مواقع التواصل",
            @"Made with love": @"صُنع بـحب 🧡",
            @"Can't play this file": @"لا يمكن تشغيل هذا الملف",
            @"WebM and MKV aren't supported. You can still share or export it.": @"صيغتا WebM وMKV غير مدعومتين. يمكنك مع ذلك مشاركته أو تصديره.",
            @"Convert to playable": @"تحويل إلى صيغة قابلة للتشغيل",
            @"This file's format isn't supported. Convert it to MP4 to play it here.": @"صيغة هذا الملف غير مدعومة. حوّله إلى MP4 لتشغيله هنا.",
            @"Convert": @"تحويل",
            @"Could not convert this file": @"تعذّر تحويل هذا الملف",
            @"Could not read this file": @"تعذّر قراءة هذا الملف",
            @"No video track": @"لا يوجد مسار فيديو",
            @"OK": @"حسناً",

            // Wallpapers
            @"Wallpaper": @"الخلفية",
            @"Classic": @"كلاسيكية",
            @"Midnight": @"منتصف الليل",
            @"Aurora": @"الشفق القطبي",
            @"Sunset": @"الغروب",
            @"Ocean": @"المحيط",
            @"Forest": @"الغابة",
            @"Graphite": @"الجرافيت",
            @"Neon": @"نيون",
            @"Cosmic": @"الكونية",
            @"Waves": @"الأمواج",

            // Browser & sniffer (Phase 1)
            @"Found media": @"الوسائط المكتشفة",
            @"Nothing found yet": @"لم يتم العثور على شيء بعد",
            @"Tap to download, long press for more": @"اضغط للتنزيل، واضغط مطولاً للمزيد",
            @"Download all": @"تنزيل الكل",
            @"Download page with yt-dlp": @"تنزيل الصفحة عبر yt-dlp",
            @"Download this file?": @"تنزيل هذا الملف؟",
            @"Copy link": @"نسخ الرابط",
            @"Checking…": @"جارٍ الفحص…",
            @"Video": @"فيديو",
            @"Audio": @"صوت",
            @"Image": @"صورة",
            @"Document": @"مستند",
            @"Archive": @"أرشيف",
            @"App": @"تطبيق",
            @"File": @"ملف",
            @"Torrent": @"تورنت",
            @"Stream (HLS)": @"بث (HLS)",
            @"Stream (DASH)": @"بث (DASH)",
            @"Video page": @"صفحة فيديو",
            @"Later update": @"تحديث لاحق",
            @"Stream downloads arrive in a later update": @"تنزيل البث يصل في تحديث لاحق",
            @"DASH streams arrive in a later update": @"بث DASH يصل في تحديث لاحق",
            @"Downloading segments": @"جارٍ تنزيل المقاطع",
            @"Joining segments": @"جارٍ دمج المقاطع",
            @"Live streams can't be downloaded": @"لا يمكن تنزيل البث المباشر",
            @"This stream is protected and can't be downloaded": @"هذا البث محمي ولا يمكن تنزيله",
            @"Could not open the stream": @"تعذّر فتح البث",
            @"Connection timed out": @"انتهت مهلة الاتصال",
            @"Could not save the file": @"تعذّر حفظ الملف",
            @"Torrent downloads arrive in a later update": @"تنزيل التورنت يصل في تحديث لاحق",
            @"Finding peers": @"جارٍ البحث عن الأقران",
            @"Could not open the torrent": @"تعذّر فتح ملف التورنت",
            @"This torrent file could not be read": @"تعذّرت قراءة ملف التورنت",
            @"Could not create the torrent files": @"تعذّر إنشاء ملفات التورنت",
            @"Could not write the torrent to disk": @"تعذّرت الكتابة إلى القرص",
            @"This torrent has no HTTP tracker to find peers": @"لا يوجد متتبّع HTTP لهذا التورنت للعثور على الأقران",
            @"No peers were found for this torrent": @"لم يتم العثور على أقران لهذا التورنت",
            @"Could not be reached": @"تعذّر الوصول إليه",
            @"Returned no peers": @"لم يُرجع أي أقران",
            @"Already in downloads": @"موجود بالفعل في التنزيلات",
            @"Magnet links need the metadata exchange, coming in a later update": @"روابط المغناط تحتاج تبادل البيانات الوصفية، ويأتي ذلك في تحديث لاحق",
            @"Download incomplete": @"التنزيل غير مكتمل",
            @"Tabs": @"التبويبات",
            @"New tab": @"تبويب جديد",
            @"Shortcuts": @"الاختصارات",
            @"Bookmarks": @"المفضلة",
            @"Search history": @"ابحث في السجل",
            @"Clear history": @"مسح السجل",
            @"No bookmarks yet": @"لا توجد مفضلة بعد",
            @"Add bookmark": @"أضف إلى المفضلة",
            @"Remove bookmark": @"إزالة من المفضلة",
            @"Desktop site": @"نسخة سطح المكتب",
            @"Mobile site": @"نسخة الجوال",
            @"Find on page": @"بحث في الصفحة",
            @"Not found": @"غير موجود",
            @"A link is on the clipboard — tap to open it": @"يوجد رابط في الحافظة — اضغط لفتحه",
            @"Ad and popup blocking": @"حجب الإعلانات والنوافذ المنبثقة",
            @"Share logs": @"مشاركة السجلات",
            @"Clear browser data": @"مسح بيانات المتصفح",
            @"Browser data cleared": @"تم مسح بيانات المتصفح",
            @"Connections per download": @"الاتصالات لكل تنزيل",
            @"Concurrent downloads": @"التنزيلات المتزامنة",
            @"Speed limit": @"حد السرعة",
            @"Unlimited": @"غير محدود",
            @"Wi-Fi only": @"عبر Wi-Fi فقط",
            @"Downloading": @"جارٍ التنزيل",
            @"Pause": @"إيقاف مؤقت",
            @"Resume": @"استئناف",
            @"Pause all": @"إيقاف الكل مؤقتاً",
            @"Resume all": @"استئناف الكل",
            @"Retry all": @"إعادة محاولة الكل",
            @"All": @"الكل",
            @"Videos": @"فيديوهات",
            @"Documents": @"مستندات",
            @"Archives": @"أرشيف",
            @"Apps": @"تطبيقات",
            @"Torrents": @"تورنت",
            @"Other": @"أخرى",
            @"Download failed": @"فشل التنزيل",
            @"Connections": @"اتصالات",
            @"Direct file": @"ملف مباشر",
            @"On": @"مفعّل",
            @"Off": @"معطّل",
            @"Send the log to the developer": @"أرسل السجل إلى المطوّر",
        };
    });
    return table;
}

+ (NSString *)t:(NSString *)key {
    if (!key.length) return @"";
    // English wording is the key itself, so English never needs a table lookup.
    // (The table holds Arabic only; forgetting this check made the switch look
    // broken because Arabic came back for every language.)
    if (![MVLang.shared.code isEqualToString:@"ar"]) return key;
    return MVTable()[key] ?: key;
}

+ (NSArray<NSString *> *)availableCodes { return @[@"ar", @"en"]; }

+ (NSString *)displayNameForCode:(NSString *)code {
    if ([code isEqualToString:@"ar"]) return MVTable()[@"Arabic"] ?: @"العربية";
    return @"English";
}

+ (NSString *)t:(NSString *)key args:(NSArray *)args {
    NSString *format = [self t:key];
    if (!args.count) return format;
    return [NSString stringWithFormat:format, args.count > 0 ? args[0] : @"",
            args.count > 1 ? args[1] : @"", args.count > 2 ? args[2] : @""];
}

@end
