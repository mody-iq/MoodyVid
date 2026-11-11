#!/usr/bin/env python3
"""Renders the store screenshots for source.json.

These are mockups, not device captures: CI has no simulator, and an AltStore
listing with no images converts far worse than one with images. Every string,
colour and layout here is copied from the real screens, so the pictures cannot
promise anything the app does not do. When the UI changes, re-run this.

Not part of the build. Needs Pillow and an Arabic font:

    python3 scripts/make_screenshots.py --out-dir Resources/screenshots

Writes 1290x2796 PNGs (iPhone 6.7") plus Resources/screenshots/index.json,
which make_source.py reads.
"""
import argparse
import json
import math
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("Pillow is required: pip install Pillow")

# iPhone 15 Pro Max: 430x932pt at 3x. Everything below is in DEVICE PIXELS,
# written through pt() so the mockup uses the app's own point scale.
W, H, S = 1290, 2796, 3


def pt(x):
    """Points to device pixels."""
    return round(x * S)


STATUS_H = pt(59)
NAV_H = pt(44)
TAB_H = pt(83)
CONTENT_TOP = STATUS_H + NAV_H
CONTENT_BOTTOM = H - TAB_H

# MVTheme palette, dark mode. Kept in step with Sources/MVTheme.m by hand.
BG = (0, 0, 0)
CARD = (28, 28, 31)
CARD_HI = (38, 38, 42)
TEXT = (255, 255, 255)
SECONDARY = (142, 142, 148)
ACCENT = (10, 133, 255)
ACCENT_SOFT = (99, 209, 255)
SUCCESS = (48, 209, 90)
WARNING = (255, 158, 10)
DANGER = (255, 69, 58)
PURPLE = (115, 77, 217)
HAIRLINE = (58, 58, 60)
CHROME = (18, 18, 20)
SELECTED = (18, 56, 104)

FONT_CANDIDATES = [
    "/tmp/fonts/NotoSansArabic.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]

_fonts = {}


def load_font(size, weight="regular"):
    key = (size, weight)
    if key in _fonts:
        return _fonts[key]
    path = next((p for p in FONT_CANDIDATES if os.path.isfile(p)), None)
    if not path:
        sys.exit("No Arabic-capable font found; add one to FONT_CANDIDATES.")
    font = ImageFont.truetype(path, size)
    if weight in ("bold", "heavy"):
        try:
            font.set_variation_by_name("Bold" if weight == "bold" else "Black")
        except (OSError, ValueError):
            bold = path.replace("DejaVuSans.ttf", "DejaVuSans-Bold.ttf")
            if os.path.isfile(bold):
                font = ImageFont.truetype(bold, size)
    _fonts[key] = font
    return font


class Screen:
    TAB_H = TAB_H

    def __init__(self, name="?"):
        self.name = name
        self.img = Image.new("RGB", (W, H), BG)
        self.d = ImageDraw.Draw(self.img)
        self.y = CONTENT_TOP
        # Content may not run under the tab bar — except for a modal sheet, which
        # is drawn over it. Those screens raise `limit` to the home indicator.
        self.limit = CONTENT_BOTTOM

    # -- primitives ---------------------------------------------------------
    def rect(self, x, y, w, h, fill, radius=0):
        if radius:
            self.d.rounded_rectangle([x, y, x + w, y + h], radius=radius, fill=fill)
        else:
            self.d.rectangle([x, y, x + w, y + h], fill=fill)

    def text(self, x, y, s, size, color=TEXT, weight="regular", rtl=True, anchor="la"):
        self.d.text((x, y), s, font=load_font(size, weight), fill=color, anchor=anchor,
                    direction="rtl" if rtl else "ltr", language="ar" if rtl else "en")

    def text_w(self, s, size, weight="regular", rtl=True):
        return load_font(size, weight).getlength(
            s, direction="rtl" if rtl else "ltr", language="ar" if rtl else "en")

    def gradient_text(self, x, y, s, size, c1, c2, weight="heavy"):
        mask = Image.new("L", (W, H), 0)
        ImageDraw.Draw(mask).text((x, y), s, font=load_font(size, weight), fill=255)
        grad = Image.new("RGB", (W, H), c1)
        gd = ImageDraw.Draw(grad)
        for i in range(W):
            t = i / W
            gd.line([(i, 0), (i, H)],
                    fill=tuple(round(a + (b - a) * t) for a, b in zip(c1, c2)))
        self.img.paste(grad, (0, 0), mask)
        self.d = ImageDraw.Draw(self.img)

    # -- vertical budget ----------------------------------------------------
    # Screens advance self.y and call need(); running into the tab bar is a
    # layout bug that is invisible in a diff, so it is asserted, not trusted.
    def at(self, y):
        self.y = y
        return y

    def need(self, height):
        bottom = self.y + height
        if bottom > self.limit:
            raise AssertionError(
                "%s: content reaches %dpx, limit is %dpx (over by %dpx)"
                % (self.name, bottom, self.limit, bottom - self.limit))
        self.y = bottom
        return self.y

    def gap(self, height):
        self.y += height
        return self.y

    # -- icons, drawn as vectors so no SF Symbols are needed ----------------
    def icon_play(self, cx, cy, size, color):
        self.d.polygon([(cx - size * 0.30, cy - size * 0.42),
                        (cx - size * 0.30, cy + size * 0.42),
                        (cx + size * 0.42, cy)], fill=color)

    def icon_play_box(self, cx, cy, size, color):
        self.d.rounded_rectangle([cx - size / 2, cy - size / 2, cx + size / 2, cy + size / 2],
                                 radius=size * 0.24, outline=color, width=max(2, size // 12))
        self.icon_play(cx + size * 0.04, cy, size * 0.60, color)

    def icon_down(self, cx, cy, size, color, ring=False):
        fg = BG if ring else color
        if ring:
            self.d.ellipse([cx - size / 2, cy - size / 2, cx + size / 2, cy + size / 2],
                           fill=color)
        w = max(2, size // 10)
        self.d.line([(cx, cy - size * 0.26), (cx, cy + size * 0.16)], fill=fg, width=w)
        self.d.polygon([(cx - size * 0.17, cy + size * 0.07),
                        (cx + size * 0.17, cy + size * 0.07),
                        (cx, cy + size * 0.28)], fill=fg)

    def icon_folder(self, cx, cy, size, color):
        w, h = size * 0.92, size * 0.64
        self.d.rounded_rectangle([cx - w / 2, cy - h / 2 + size * 0.08,
                                  cx + w / 2, cy + h / 2], radius=size * 0.10, fill=color)
        self.d.rounded_rectangle([cx - w / 2, cy - h / 2 - size * 0.12,
                                  cx - w / 2 + w * 0.48, cy - h / 2 + size * 0.10],
                                 radius=size * 0.07, fill=color)

    def icon_gear(self, cx, cy, size, color):
        pts = []
        for i in range(16):
            ang = math.pi * i / 8
            r = size * 0.46 if i % 2 == 0 else size * 0.35
            pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
        self.d.polygon(pts, fill=color)
        r = size * 0.17
        self.d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=BG)

    def icon_search(self, cx, cy, size, color):
        w = max(2, size // 9)
        r = size * 0.30
        self.d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=color, width=w)
        self.d.line([(cx + r * 0.70, cy + r * 0.70), (cx + r * 1.25, cy + r * 1.25)],
                    fill=color, width=w)

    def icon_camera(self, cx, cy, size, color):
        w, h = size * 0.88, size * 0.64
        self.d.rounded_rectangle([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2],
                                 radius=size * 0.17, fill=color)
        r = size * 0.21
        self.d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=BG)

    def icon_note(self, cx, cy, size, color):
        st = max(2, size // 8)
        self.d.ellipse([cx - size * 0.34, cy + size * 0.12,
                        cx - size * 0.06, cy + size * 0.40], fill=color)
        self.d.ellipse([cx + size * 0.08, cy - size * 0.02,
                        cx + size * 0.36, cy + size * 0.26], fill=color)
        self.d.line([(cx - size * 0.06, cy + size * 0.28),
                     (cx - size * 0.06, cy - size * 0.34)], fill=color, width=st)
        self.d.line([(cx + size * 0.36, cy + size * 0.16),
                     (cx + size * 0.36, cy - size * 0.44)], fill=color, width=st)
        self.d.line([(cx - size * 0.06, cy - size * 0.34),
                     (cx + size * 0.36, cy - size * 0.44)], fill=color,
                    width=max(2, size // 6))

    def icon_x(self, cx, cy, size, color):
        w = max(2, size // 8)
        h = size * 0.40
        self.d.line([(cx - h, cy - h), (cx + h, cy + h)], fill=color, width=w)
        self.d.line([(cx - h, cy + h), (cx + h, cy - h)], fill=color, width=w)

    def icon_chat(self, cx, cy, size, color):
        w, h = size * 0.88, size * 0.62
        self.d.rounded_rectangle([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2],
                                 radius=size * 0.22, fill=color)
        self.d.polygon([(cx - w * 0.24, cy + h * 0.40), (cx - w * 0.02, cy + h * 0.40),
                        (cx - w * 0.22, cy + h * 0.82)], fill=color)

    def icon_wave(self, cx, cy, size, color):
        w = max(2, size // 10)
        for i in range(5):
            h = size * (0.16 + 0.11 * abs(math.sin(i * 1.3)))
            x = cx - size * 0.36 + i * size * 0.18
            self.d.line([(x, cy - h), (x, cy + h)], fill=color, width=w)

    def icon_check(self, cx, cy, size, color):
        w = max(2, size // 8)
        self.d.line([(cx - size * 0.30, cy), (cx - size * 0.06, cy + size * 0.24)],
                    fill=color, width=w)
        self.d.line([(cx - size * 0.06, cy + size * 0.24),
                     (cx + size * 0.32, cy - size * 0.26)], fill=color, width=w)

    def icon_wand(self, cx, cy, size, color):
        w = max(2, size // 10)
        self.d.line([(cx - size * 0.36, cy + size * 0.36),
                     (cx + size * 0.12, cy - size * 0.12)], fill=color, width=w)
        for dx, dy in ((0.30, -0.30), (0.06, -0.42), (0.42, -0.06)):
            self.d.line([(cx + size * dx, cy + size * dy - size * 0.09),
                         (cx + size * dx, cy + size * dy + size * 0.09)],
                        fill=color, width=w)
            self.d.line([(cx + size * dx - size * 0.09, cy + size * dy),
                         (cx + size * dx + size * 0.09, cy + size * dy)],
                        fill=color, width=w)

    def icon_film(self, cx, cy, size, color):
        w, h = size * 0.66, size * 0.88
        self.d.rounded_rectangle([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2],
                                 radius=size * 0.11, outline=color, width=max(2, size // 12))
        self.icon_play(cx + size * 0.02, cy, size * 0.44, color)

    # -- chrome -------------------------------------------------------------
    def status_bar(self, time_text="٩:٤١"):
        # iOS mirrors the status bar in Arabic: clock right, indicators left.
        self.text(W - 48, pt(16), time_text, pt(17), TEXT, "bold", anchor="ra")
        x, y = 52, pt(18)
        self.d.rounded_rectangle([x, y, x + pt(25), y + pt(13)], radius=pt(4),
                                 outline=TEXT, width=max(2, pt(1)))
        self.d.rounded_rectangle([x + pt(3), y + pt(3), x + pt(18), y + pt(10)],
                                 radius=pt(2), fill=TEXT)
        self.d.rounded_rectangle([x + pt(26), y + pt(5), x + pt(29), y + pt(9)],
                                 radius=pt(1), fill=TEXT)
        for i in range(3):
            h = pt(4 + i * 3)
            self.d.rounded_rectangle([x + pt(40) + i * pt(7), y + pt(13) - h,
                                      x + pt(44) + i * pt(7), y + pt(13)],
                                     radius=pt(1), fill=TEXT)

    def nav_bar(self, title):
        self.rect(0, STATUS_H, W, NAV_H, BG)
        self.text(W // 2, STATUS_H + pt(9), title, pt(17), TEXT, "bold", anchor="ma")

    def tab_bar(self, active=0):
        top = H - TAB_H
        self.rect(0, top, W, TAB_H, CHROME)
        self.rect(0, top, W, 2, HAIRLINE)
        tabs = [("الرئيسية", self.icon_play_box), ("التنزيلات", self.icon_down),
                ("الملفات", self.icon_folder), ("المزيد", self.icon_gear)]
        step = W / 4
        for i, (name, fn) in enumerate(tabs):   # RTL: first tab on the right
            cx = W - step * (i + 0.5)
            color = ACCENT if i == active else SECONDARY
            fn(cx, top + pt(24), pt(28), color)
            self.text(cx, top + pt(50), name, pt(10), color, anchor="ma")

    def home_indicator(self):
        self.d.rounded_rectangle([W / 2 - pt(70), H - pt(10), W / 2 + pt(70), H - pt(5)],
                                 radius=pt(3), fill=(255, 255, 255))

    def save(self, path):
        self.img.save(path, "PNG", optimize=True)
        return path


# --------------------------------------------------------------------------
# Screens
# --------------------------------------------------------------------------

CARD_X, CARD_W = pt(16), W - pt(32)


def screen_home():
    s = Screen("home")
    s.status_bar()
    s.nav_bar("الرئيسية")

    # Brand header.
    s.at(CONTENT_TOP + pt(8))
    tile = pt(48)
    s.rect(CARD_X, s.y, tile, tile, CARD_HI, radius=pt(14))
    s.icon_play_box(CARD_X + tile / 2, s.y + tile / 2, pt(28), ACCENT)
    s.gradient_text(CARD_X + tile + pt(12), s.y + pt(2), "MoodyVid", pt(26), ACCENT, PURPLE)
    s.text(CARD_X + tile + pt(12), s.y + pt(32), "حمّل الفيديوهات من أي مكان",
           pt(12), SECONDARY)
    s.need(tile)

    # Link card: field, paste, download, quality.
    s.gap(pt(16))
    card_top = s.y
    s.rect(CARD_X, card_top, CARD_W, pt(240), CARD, radius=pt(18))
    fx, fw = CARD_X + pt(12), CARD_W - pt(24)
    fy = card_top + pt(14)
    s.rect(fx, fy, fw, pt(46), CARD_HI, radius=pt(12))
    s.text(fx + fw - pt(14), fy + pt(15), "الصق رابط الفيديو هنا...",
           pt(13), SECONDARY, anchor="ra")
    pw = s.text_w("لصق", pt(13), "bold") + pt(24)
    s.rect(fx + pt(6), fy + pt(8), pw, pt(30), ACCENT, radius=pt(9))
    s.text(fx + pt(6) + pw / 2, fy + pt(16), "لصق", pt(13), TEXT, "bold", anchor="ma")

    s.rect(fx, fy + pt(62), fw, 2, HAIRLINE)

    by = fy + pt(74)
    s.rect(fx, by, fw, pt(50), ACCENT, radius=pt(14))
    s.icon_down(fx + fw - pt(34), by + pt(25), pt(22), TEXT)
    s.text(fx + fw / 2 - pt(8), by + pt(15), "تحميل", pt(17), TEXT, "bold", anchor="ma")

    qy = by + pt(62)
    s.rect(fx, qy, fw, pt(44), CARD_HI, radius=pt(12))
    s.text(fx + fw - pt(14), qy + pt(13), "الجودة: أفضل جودة متاحة", pt(13),
           SECONDARY, anchor="ra")
    s.at(card_top + pt(240))

    # Quick access: one scrolling row of tiles.
    s.gap(pt(18))
    s.text(W - CARD_X, s.y, "وصول سريع", pt(15), TEXT, "bold", anchor="ra")
    s.need(pt(20))
    s.gap(pt(10))
    ty = s.y
    tiles = [("YouTube", s.icon_play_box, (255, 59, 48)),
             ("Instagram", s.icon_camera, (225, 48, 108)),
             ("Facebook", s.icon_chat, (24, 119, 242)),
             ("TikTok", s.icon_note, (37, 244, 238)),
             ("X", s.icon_x, (142, 142, 147)),
             ("Reddit", s.icon_chat, (255, 69, 0)),
             ("SoundCloud", s.icon_wave, (255, 85, 0))]
    tw, th, g = pt(66), pt(66), pt(10)
    for i, (name, fn, color) in enumerate(tiles):
        cx = W - CARD_X - tw / 2 - i * (tw + g)
        if cx < tw / 2:
            break
        s.rect(cx - tw / 2, ty, tw, th, CARD, radius=pt(14))
        fn(cx, ty + pt(24), pt(24), color)
        s.text(cx, ty + pt(45), name, pt(9), SECONDARY, rtl=False, anchor="ma")
    s.at(ty + th)

    # Active download, the same card the home screen shows while one is running.
    s.gap(pt(18))
    s.text(W - CARD_X, s.y, "قيد التنزيل الآن", pt(15), TEXT, "bold", anchor="ra")
    s.need(pt(20))
    s.gap(pt(10))
    h = pt(92)
    s.rect(CARD_X, s.y, CARD_W, h, CARD, radius=pt(16))
    s.text(W - CARD_X - pt(16), s.y + pt(14), "حلقة تعليم البرمجة", pt(15), TEXT,
           "bold", anchor="ra")
    s.text(W - CARD_X - pt(16), s.y + pt(38), "جارٍ التنزيل · 68%", pt(12), ACCENT,
           "bold", anchor="ra")
    s.text(CARD_X + pt(16), s.y + pt(38), "45.2 من 120 MB", pt(11), SECONDARY)
    bar_y = s.y + h - pt(22)
    s.rect(CARD_X + pt(16), bar_y, CARD_W - pt(32), pt(8), CARD_HI, radius=pt(4))
    s.rect(CARD_X + pt(16), bar_y, (CARD_W - pt(32)) * 0.68, pt(8), ACCENT, radius=pt(4))
    s.need(h)

    s.tab_bar(0)
    s.home_indicator()
    return s


def screen_sniffer():
    """The core screen: the browser, with the single download sheet open."""
    s = Screen("quality")
    s.limit = H - pt(20)   # the sheet covers the tab bar
    s.img.paste(Image.new("RGB", (W, H), (14, 14, 16)), (0, 0))
    s.d = ImageDraw.Draw(s.img)
    s.status_bar()

    s.rect(CARD_X, CONTENT_TOP + pt(8), CARD_W, pt(34), CARD, radius=pt(10))
    s.text(W - CARD_X - pt(14), CONTENT_TOP + pt(18), "m.youtube.com", pt(13),
           SECONDARY, rtl=False, anchor="ra")
    s.rect(CARD_X, CONTENT_TOP + pt(50), CARD_W, pt(150), CARD, radius=pt(12))
    s.icon_play(W / 2, CONTENT_TOP + pt(125), pt(50), (58, 58, 62))

    # Sheet: a large detent, so it starts a little past halfway.
    top = pt(494)
    s.rect(0, top, W, H - top, (20, 20, 23), radius=pt(22))
    s.rect(0, top + pt(16), W, H - top - pt(16), (20, 20, 23))
    s.d.rounded_rectangle([W / 2 - pt(18), top + pt(8), W / 2 + pt(18), top + pt(13)],
                          radius=pt(3), fill=(92, 92, 97))

    s.text(CARD_X + pt(4), top + pt(26), "YouTube", pt(22), TEXT, "bold", rtl=False)
    s.rect(W - CARD_X - pt(34), top + pt(28), pt(30), pt(30), CARD_HI, radius=pt(15))
    s.icon_x(W - CARD_X - pt(19), top + pt(43), pt(15), SECONDARY)

    s.at(top + pt(76))
    s.text(W - CARD_X, s.y, "جودة الفيديو", pt(12), SECONDARY, "bold", anchor="ra")
    s.need(pt(16))
    s.gap(pt(8))

    rows = [("أفضل جودة متاحة", s.icon_wand, ACCENT),
            ("1080p عالية الدقة", s.icon_film, ACCENT_SOFT),
            ("حتى 720p", s.icon_film, ACCENT_SOFT),
            ("حتى 480p", s.icon_film, ACCENT_SOFT),
            ("صوت فقط (M4A)", s.icon_note, SUCCESS),
            ("MP3 (صوت فقط)", s.icon_note, SUCCESS)]
    for name, fn, color in rows:
        s.rect(CARD_X, s.y, CARD_W, pt(40), CARD, radius=pt(12))
        fn(W - CARD_X - pt(24), s.y + pt(20), pt(20), color)
        s.text(W - CARD_X - pt(44), s.y + pt(12), name, pt(14), TEXT, anchor="ra")
        s.need(pt(41))

    s.gap(pt(10))
    s.text(W - CARD_X, s.y, "ملفات في هذه الصفحة", pt(12), SECONDARY, "bold", anchor="ra")
    s.need(pt(16))
    s.gap(pt(8))
    s.rect(CARD_X, s.y, CARD_W, pt(40), CARD, radius=pt(12))
    s.icon_film(W - CARD_X - pt(24), s.y + pt(20), pt(20), SECONDARY)
    s.text(W - CARD_X - pt(44), s.y + pt(12), "video.mp4 · 18.4 MB", pt(13), TEXT,
           rtl=False, anchor="ra")
    s.need(pt(38))

    s.home_indicator()
    return s


def screen_downloads():
    s = Screen("downloads")
    s.status_bar()
    s.nav_bar("التنزيلات")

    s.at(CONTENT_TOP + pt(10))
    s.rect(CARD_X, s.y, CARD_W, pt(36), CARD, radius=pt(10))
    s.icon_search(CARD_X + pt(18), s.y + pt(18), pt(15), SECONDARY)
    s.text(W - CARD_X - pt(14), s.y + pt(11), "ابحث في التنزيلات", pt(13),
           SECONDARY, anchor="ra")
    s.need(pt(36))

    s.gap(pt(12))
    chips = [("الكل", True), ("نشط", False), ("مكتمل", False), ("متوقف", False)]
    cx = W - CARD_X
    for name, active in chips:
        w = s.text_w(name, pt(12), "bold") + pt(28)
        cx -= w
        s.rect(cx, s.y, w, pt(28), ACCENT if active else CARD, radius=pt(14))
        s.text(cx + w / 2, s.y + pt(7), name, pt(12), TEXT if active else SECONDARY,
               "bold", anchor="ma")
        cx -= pt(6)
    s.need(pt(28))

    s.gap(pt(14))
    rows = [("حلقة تعليم البرمجة", "جارٍ التنزيل", 0.68, ACCENT, "45.2 من 120 MB", True),
            ("مقطع من إنستغرام", "في الانتظار", 0.0, SECONDARY, "في قائمة الانتظار", False),
            ("أغنية.mp3", "مكتمل", 1.0, SUCCESS, "8.4 MB", False),
            ("فيديو قديم.mp4", "فشل", 0.22, DANGER, "انقطع الاتصال", False),
            ("محاضرة كاملة.mp4", "مكتمل", 1.0, SUCCESS, "212.0 MB", False),
            ("مقابلة.mp3", "متوقف موقتاً", 0.45, WARNING, "12.1 من 26.8 MB", True)]
    for title, status, prog, color, detail, show_bar in rows:
        h = pt(78) if show_bar else pt(68)
        s.rect(CARD_X, s.y, CARD_W, h, CARD, radius=pt(14))
        s.text(W - CARD_X - pt(14), s.y + pt(11), title, pt(15), TEXT, "bold", anchor="ra")
        s.text(W - CARD_X - pt(14), s.y + pt(32), status, pt(12), color, "bold", anchor="ra")
        s.text(CARD_X + pt(14), s.y + pt(32), detail, pt(11), SECONDARY)
        if show_bar:
            by = s.y + h - pt(20)
            s.rect(CARD_X + pt(14), by, CARD_W - pt(28), pt(6), CARD_HI, radius=pt(3))
            s.rect(CARD_X + pt(14), by, (CARD_W - pt(28)) * prog, pt(6), color, radius=pt(3))
        s.need(h + pt(10))

    s.tab_bar(1)
    s.home_indicator()
    return s


def screen_files():
    s = Screen("files")
    s.status_bar()
    s.nav_bar("الملفات")

    s.at(CONTENT_TOP + pt(10))
    s.rect(CARD_X, s.y, CARD_W, pt(36), CARD, radius=pt(10))
    s.icon_search(CARD_X + pt(18), s.y + pt(18), pt(15), SECONDARY)
    s.text(W - CARD_X - pt(14), s.y + pt(11), "ابحث في الملفات", pt(13),
           SECONDARY, anchor="ra")
    s.need(pt(36))

    s.gap(pt(12))
    s.text(W - CARD_X, s.y, "12.4 GB متاح", pt(12), SECONDARY, anchor="ra")
    s.need(pt(16))

    s.gap(pt(10))
    s.rect(CARD_X, s.y, CARD_W, pt(52), CARD, radius=pt(14))
    s.icon_note(W - CARD_X - pt(26), s.y + pt(26), pt(22), ACCENT_SOFT)
    s.text(W - CARD_X - pt(48), s.y + pt(9), "جارٍ التشغيل", pt(11), SECONDARY, anchor="ra")
    s.text(W - CARD_X - pt(48), s.y + pt(26), "أغنية.mp3", pt(14), TEXT, "bold", anchor="ra")
    s.icon_play(CARD_X + pt(30), s.y + pt(26), pt(20), ACCENT)
    s.need(pt(52))

    s.gap(pt(14))
    chips = [("الكل", True), ("فيديو", False), ("صوت", False), ("أخرى", False)]
    cx = W - CARD_X
    for name, active in chips:
        w = s.text_w(name, pt(12), "bold") + pt(28)
        cx -= w
        s.rect(cx, s.y, w, pt(28), ACCENT if active else CARD, radius=pt(14))
        s.text(cx + w / 2, s.y + pt(7), name, pt(12), TEXT if active else SECONDARY,
               "bold", anchor="ma")
        cx -= pt(6)
    s.need(pt(28))

    s.gap(pt(14))
    files = [("حلقة تعليم البرمجة.mp4", "120.0 MB · فيديو", ACCENT),
             ("أغنية.mp3", "8.4 MB · صوت", SUCCESS),
             ("مقطع من إنستغرام.mp4", "24.7 MB · فيديو", PURPLE),
             ("فيديو قديم.mp4", "58.1 MB · فيديو", SECONDARY),
             ("محاضرة.mp4", "212.0 MB · فيديو", ACCENT_SOFT)]
    for name, meta, color in files:
        h = pt(62)
        s.rect(CARD_X, s.y, CARD_W, h, CARD, radius=pt(14))
        s.rect(W - CARD_X - pt(70), s.y + pt(9), pt(56), h - pt(18), CARD_HI, radius=pt(9))
        s.icon_play(W - CARD_X - pt(42), s.y + h / 2, pt(20), color)
        s.text(W - CARD_X - pt(80), s.y + pt(13), name, pt(14), TEXT, "bold", anchor="ra")
        s.text(W - CARD_X - pt(80), s.y + pt(33), meta, pt(11), SECONDARY, anchor="ra")
        s.need(h + pt(9))

    s.tab_bar(2)
    s.home_indicator()
    return s


def screen_settings():
    s = Screen("settings")
    s.status_bar()
    s.nav_bar("الإعدادات")

    s.at(CONTENT_TOP + pt(14))
    groups = [
        ("المظهر", [("داكن", True), ("فاتح", False), ("النظام", False)]),
        ("اللغة", [("العربية", True), ("English", False)]),
        ("التنزيل", [("حفظ في الملفات", False), ("التحميل في الخلفية", False)]),
        ("حول", [("الإصدار 0.2.0", False), ("iOS 15 أو أحدث · آيفون", False)]),
    ]
    for title, rows in groups:
        s.text(W - CARD_X, s.y, title, pt(12), SECONDARY, "bold", anchor="ra")
        s.need(pt(16))
        s.gap(pt(7))
        h = pt(38) * len(rows) + pt(8)
        s.rect(CARD_X, s.y, CARD_W, h, CARD, radius=pt(14))
        for i, (name, selected) in enumerate(rows):
            ry = s.y + pt(4) + i * pt(38)
            if selected:
                s.rect(CARD_X + pt(6), ry + pt(2), CARD_W - pt(12), pt(34), SELECTED,
                       radius=pt(10))
            s.text(W - CARD_X - pt(16), ry + pt(9), name, pt(14), TEXT, anchor="ra")
            if selected:
                s.icon_check(CARD_X + pt(24), ry + pt(19), pt(17), ACCENT)
            if i < len(rows) - 1:
                s.rect(CARD_X + pt(14), ry + pt(38) - 1, CARD_W - pt(28), 2, HAIRLINE)
        s.need(h)
        s.gap(pt(14))

    s.tab_bar(3)
    s.home_indicator()
    return s


SCREENS = [
    ("01-home.png", screen_home, "الشاشة الرئيسية — الصق الرابط وحمّل"),
    ("02-quality.png", screen_sniffer, "اختر الجودة من 480p حتى 1080p"),
    ("03-downloads.png", screen_downloads, "تابع التنزيلات والتقدم"),
    ("04-files.png", screen_files, "كل الملفات في مكان واحد"),
    ("05-settings.png", screen_settings, "عربي وإنجليزي، وضع ليلي"),
]


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="Resources/screenshots")
    args = ap.parse_args(argv)

    os.makedirs(args.out_dir, exist_ok=True)
    index = []
    for name, fn, caption in SCREENS:
        path = os.path.join(args.out_dir, name)
        fn().save(path)
        print("wrote %s (%d KB)" % (path, os.path.getsize(path) // 1024))
        index.append({"file": name, "caption": caption})

    with open(os.path.join(args.out_dir, "index.json"), "w", encoding="utf-8") as fh:
        json.dump(index, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print("index written with %d screenshots" % len(index))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
