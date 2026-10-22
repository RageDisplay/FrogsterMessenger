"""Draws Frogster's app icon and writes every size the platforms need.

The mark is the lily pad from lib/ui/widgets/brand_mark.dart -- a disc with a
wedge cut towards the upper right -- in white on the brand's purple, with a
mint dot where the frog sits and a ripple around it.

    python tool/make_icons.py        (needs Pillow: pip install pillow)

Writes:
  assets/icon/icon.png                          1024 px master
  android/app/src/main/res/mipmap-*/ic_launcher.png, ic_launcher_round.png
  android/app/src/main/res/mipmap-*/ic_launcher_foreground.png (adaptive)
  android/app/src/main/res/drawable-*/ic_stat_frogster.png (notifications)
  android/app/src/main/res/mipmap-anydpi-v26/ic_launcher*.xml
  android/app/src/main/res/values/ic_launcher_background.xml
  windows/runner/resources/app_icon.ico
  assets/icon/tray.ico                          Windows tray
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')

TOP = (0x86, 0x5A, 0xF5)      # light purple, top left
BOTTOM = (0x3B, 0x17, 0x9C)   # deep purple, bottom right
BACKGROUND = '#5B2BD1'        # flat fallback for the adaptive background
PAD = (0xFF, 0xFF, 0xFF)
MINT = (0x4F, 0xD8, 0xA2)

S = 4096  # drawn large, then scaled down for smooth edges


def gradient(size):
    img = Image.new('RGB', (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
    return img


def fast_gradient(size):
    # The diagonal gradient computed small and scaled up: identical to the
    # eye, and seconds instead of minutes at 4096 px.
    return gradient(256).resize((size, size), Image.BICUBIC)


def pad_mask(size, scale, cx, cy):
    """A lily pad on a 32-unit grid, radius 14: a disc with a narrow notch
    running from the rim to the centre, pointing up and to the right."""
    mask = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(mask)
    r = 14 * scale
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    centre_angle = math.radians(-52)
    half = math.radians(11)
    far = r * 1.5
    d.polygon([
        (cx, cy),
        (cx + far * math.cos(centre_angle - half), cy + far * math.sin(centre_angle - half)),
        (cx + far * math.cos(centre_angle + half), cy + far * math.sin(centre_angle + half)),
    ], fill=0)
    return mask


def frog(canvas, scale, cx, cy, colour, pupil):
    """A frog seen from above, sitting on the pad: a rounded body and two
    eyes standing proud of it."""
    d = ImageDraw.Draw(canvas)
    def ellipse(x, y, rx, ry, fill):
        d.ellipse([cx + (x - rx) * scale, cy + (y - ry) * scale,
                   cx + (x + rx) * scale, cy + (y + ry) * scale], fill=fill)
    ellipse(0, 1.2, 5.2, 4.4, colour)        # body
    for side in (-1, 1):
        ellipse(side * 3.0, -2.6, 2.1, 2.1, colour)       # eye bump
        ellipse(side * 3.0, -2.8, 1.25, 1.25, (255, 255, 255, 255))
        ellipse(side * 3.25, -2.8, 0.62, 0.62, pupil)     # pupil, looking ahead


def draw_mark(canvas, size, scale, cx, cy, with_ripples=True):
    """Paints ripples, the pad and the frog onto an RGBA canvas."""
    if with_ripples:
        ripples = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        rd = ImageDraw.Draw(ripples)
        for k, alpha in ((17.0, 64), (20.2, 34)):
            r = k * scale
            w = max(2, round(0.5 * scale))
            rd.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, alpha), width=w)
        canvas.alpha_composite(ripples)

    # A soft shadow lifts the pad off the water.
    shadow_mask = pad_mask(size, scale, cx, cy + 0.7 * scale)
    shadow = Image.new('RGBA', (size, size), (20, 6, 60, 0))
    shadow.putalpha(shadow_mask.point(lambda v: v * 95 // 255).filter(ImageFilter.GaussianBlur(scale * 0.9)))
    canvas.alpha_composite(shadow)

    pad = Image.new('RGBA', (size, size), PAD + (255,))
    pad.putalpha(pad_mask(size, scale, cx, cy))
    canvas.alpha_composite(pad)

    frog(canvas, scale, cx - 3.4 * scale, cy + 3.6 * scale, MINT + (255,), (0x2A, 0x10, 0x70, 255))


def squircle_mask(size, radius_ratio=0.225):
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=round(size * radius_ratio), fill=255)
    return mask


def master():
    """The full icon: gradient squircle with the mark."""
    canvas = fast_gradient(S).convert('RGBA')
    draw_mark(canvas, S, S / 32 * 0.78, S / 2, S / 2)
    canvas.putalpha(squircle_mask(S))
    return canvas


def round_icon():
    canvas = fast_gradient(S).convert('RGBA')
    draw_mark(canvas, S, S / 32 * 0.72, S / 2, S / 2)
    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, S - 1, S - 1], fill=255)
    canvas.putalpha(mask)
    return canvas


def foreground():
    """The adaptive icon's foreground: the mark alone, inside the safe zone
    (the middle 66 of 108 dp), on transparent."""
    canvas = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    draw_mark(canvas, S, S / 32 * 0.5, S / 2, S / 2)
    return canvas


def background():
    return fast_gradient(S).convert('RGBA')


def notification_icon():
    """Android draws notification icons from their alpha alone: the pad in
    white with the frog cut out of it."""
    scale = S / 32 * 0.95
    mask = pad_mask(S, scale, S / 2, S / 2)
    cut = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    frog(cut, scale, S / 2 - 3.4 * scale, S / 2 + 3.6 * scale, (0, 0, 0, 255), (0, 0, 0, 255))
    mask = Image.composite(Image.new('L', (S, S), 0), mask, cut.getchannel('A'))
    white = Image.new('RGBA', (S, S), (255, 255, 255, 255))
    white.putalpha(mask)
    return white


def save(img, path, px):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((px, px), Image.LANCZOS).save(path)


def main():
    full, rnd, fg, bg, note = master(), round_icon(), foreground(), background(), notification_icon()

    save(full, os.path.join(ROOT, 'assets', 'icon', 'icon.png'), 1024)

    launcher = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
    for density, px in launcher.items():
        folder = os.path.join(RES, f'mipmap-{density}')
        save(full, os.path.join(folder, 'ic_launcher.png'), px)
        save(rnd, os.path.join(folder, 'ic_launcher_round.png'), px)
        # Adaptive layers are 108 dp, where the legacy icon is 48 dp.
        save(fg, os.path.join(folder, 'ic_launcher_foreground.png'), px * 108 // 48)
        save(bg, os.path.join(folder, 'ic_launcher_background.png'), px * 108 // 48)

    status = {'mdpi': 24, 'hdpi': 36, 'xhdpi': 48, 'xxhdpi': 72, 'xxxhdpi': 96}
    for density, px in status.items():
        save(note, os.path.join(RES, f'drawable-{density}', 'ic_stat_frogster.png'), px)

    anydpi = os.path.join(RES, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    adaptive = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_stat_frogster"/>
</adaptive-icon>
'''
    for name in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        with open(os.path.join(anydpi, name), 'w', encoding='utf-8', newline='\n') as f:
            f.write(adaptive)
    with open(os.path.join(RES, 'values', 'ic_launcher_background.xml'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{BACKGROUND}</color>
</resources>
''')

    # The tray icon is a Flutter asset, read by tray_manager at run time.
    tray = full.resize((64, 64), Image.LANCZOS)
    os.makedirs(os.path.join(ROOT, 'assets', 'icon'), exist_ok=True)
    tray.save(os.path.join(ROOT, 'assets', 'icon', 'tray.ico'), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64)])

    ico = full.resize((256, 256), Image.LANCZOS)
    ico.save(os.path.join(ROOT, 'windows', 'runner', 'resources', 'app_icon.ico'),
             sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print('icons written')


if __name__ == '__main__':
    main()
