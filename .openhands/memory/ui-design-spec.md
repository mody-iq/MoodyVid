# UI design spec from user's mockups (2026-11-06)

Two ImgBB mockups (1408x768 each, three phone panels side by side):
- https://ibb.co/cXX12mHG -> full size https://i.ibb.co/JFFKrh4f/IMG-5630.jpg
- https://ibb.co/nVWhpzP -> full size https://i.ibb.co/YKrvgp0/IMG-5631.jpg
(The `i.ibb.co/<id>/IMG-5630.jpg` form is only 180x180; the page's big `<a href>`
is the 1408x768 original. The direct embed `i.ibb.co/933NyMLF/...` is 640x349.)

## Reading the images
No vision tool is exposed, so OCR via tesseract (`sudo apt-get install tesseract-ocr
tesseract-ocr-ara`, `pip3 install pillow numpy`), cropping each phone panel out and
upscaling 2-3x, then `--psm 4/6`. Colours via numpy on the same crops.

## Layout (both mockups agree)
Bottom tab bar: **Home | Downloads | Files | More** (4 tabs; "More" not "Settings").
So the in-app browser is NOT a tab: the QUICK ACCESS tiles open it.

Home, top to bottom:
1. Header: brand "DownGrab" + a **"Premium"** pill badge.
2. **QUICK ACCESS** - horizontally scrollable brand tiles: YouTube, TikTok,
   Instagram, Twitch, Facebook, ...
3. Link field ("Quick Link Paste").
4. **MY DOWNLOADS** - media cards: thumbnail, title, size ("345 MB"), date
   ("Jun 18, 2023"), "Status" affordance.
5. **MY STREAM** - a second list of the same kind of cards.
6. **SUGGESTED** / **RECOMMENDED FOR YOU** - more cards.
7. Active download card: "75% Complete", "ETA 4s", "Download 15.2 MB/s".

Downloads tab: "MY DOWNLOADS" title, a segmented control **Active | Downloaded**,
the active card line "Active: 75% | 15.2 MB/s | ETA: 4s", then **COMPLETED
DOWNLOADS** rows with thumbnail, "285 MB", "Jun 18, 2023 15.2 MB/s", and two
buttons: "Download File" and "File".

Files tab: a file row "Al Revolution - Part 1", "12 min, 10 MB".

## Palette (sampled)
- Background near-black with a navy cast: `#000018` / `#181818` cards.
- **Accent is teal/cyan**, dominant `#10A0B0` (~#0FA0B0), used for progress/active.
- Pink/purple glow behind the header (blurred gradient, `#602040`/`#904040`).

## Delta vs what we built in Phase 1
- 4th tab should be "More", not "Settings".
- Home needs: brand header + Premium pill, horizontal QUICK ACCESS tiles that open
  the browser, link field, and card lists (thumbnail/size/date/Status).
- Downloads needs an Active|Downloaded segmented control and completed rows with
  two action buttons.
- Accent should be teal, not the violet we shipped.
- "Premium" badge: the user earlier declined in-app purchase (no dev account), so
  the badge is decorative only unless they say otherwise.
