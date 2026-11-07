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
