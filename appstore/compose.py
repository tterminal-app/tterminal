#!/usr/bin/env python3
"""把 shoot.sh 拍的原始畫面合成 App Store 截圖:標語在上、裝置畫面在下。

    python3 appstore/compose.py [zh|en]

讀 appstore/raw/<機型>-<語系>/,寫到 appstore/screenshots/<語系>/<尺寸>/。
標語在 captions.json。輸出不含 alpha(App Store Connect 不收透明圖)。
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent

PINGFANG = '/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc'
SF = '/System/Library/Fonts/SFNS.ttf'

BG_TOP = (30, 34, 41)
BG_BOTTOM = (10, 11, 14)
GLOW = (74, 222, 128)
TITLE = (243, 244, 246)
SUBTITLE = (156, 163, 175)
BEZEL = (43, 47, 54)

# (原始畫面目錄, 輸出尺寸, 裝置寬佔畫布比例, 螢幕圓角佔裝置寬比例)
TARGETS = {
    'iphone-6.9': ('iphone', (1320, 2868), 0.84, 0.125),
    'iphone-6.3': ('iphone', (1206, 2622), 0.84, 0.125),
    'ipad-13': ('ipad', (2064, 2752), 0.84, 0.03),
    'duo-outer': ('duo-outer', (1398, 2034), 0.74, 0.07),
    'duo-inner': ('duo-inner', (2853, 2007), 0.74, 0.05),
    # 橫向(raw 目錄是 *-land-<語系>,shoot.sh 帶 landscape 參數拍的)
    'iphone-6.9-landscape': ('iphone-land', (2868, 1320), 0.70, 0.125),
    'iphone-6.3-landscape': ('iphone-land', (2622, 1206), 0.70, 0.125),
    'ipad-13-landscape': ('ipad-land', (2752, 2064), 0.74, 0.03),
    'duo-outer-landscape': ('duo-outer-land', (2034, 1398), 0.70, 0.07),
}


def font(locale, size, bold):
    if locale == 'zh':
        return ImageFont.truetype(PINGFANG, size, index=10 if bold else 2)
    f = ImageFont.truetype(SF, size)
    f.set_variation_by_name('Bold' if bold else 'Regular')
    return f


def background(size):
    w, h = size
    grad = Image.new('RGB', (1, h))
    for y in range(h):
        t = y / (h - 1)
        grad.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))
    return grad.resize((w, h))


PUNCT = ',、。;:!?)」'


def wrap(draw, text, fnt, max_width, locale):
    """放得下就一行;放不下就找兩行最平均、又斷在好位置的斷點。

    中文優先斷在標點後面,不拆開英數字(tmux、14 這種);英文只在空白斷。
    """
    width = lambda t: draw.textlength(t, font=fnt)
    if width(text) <= max_width:
        return [text]
    candidates = []  # (罰分, 斷點)
    for i in range(1, len(text)):
        a, b = text[:i].rstrip(), text[i:].lstrip()
        if not a or not b:
            continue
        if locale == 'zh':
            prev, nxt = text[i - 1], text[i]
            if prev.isascii() and prev.isalnum() and nxt.isascii() and nxt.isalnum():
                continue  # 英數字中間
            if nxt in PUNCT:
                continue  # 標點不放行首
            bonus = 0 if prev in PUNCT else width('中') * 2  # 斷在標點後最自然
        else:
            if text[i - 1] != ' ':
                continue
            bonus = 0
        wa, wb = width(a), width(b)
        if max(wa, wb) > max_width:
            continue
        candidates.append((abs(wa - wb) + bonus, a, b))
    if candidates:
        _, a, b = min(candidates)
        return [a, b]
    # 兩行塞不下:退回逐字/逐詞貪婪斷行
    units = list(text) if locale == 'zh' else text.split(' ')
    sep = '' if locale == 'zh' else ' '
    lines, cur = [], ''
    for u in units:
        trial = cur + sep + u if cur else u
        if width(trial) <= max_width:
            cur = trial
        else:
            lines.append(cur)
            cur = u
    lines.append(cur)
    return [l for l in lines if l]


def compose(raw, size, device_ratio, corner_ratio, title, subtitle, locale):
    w, h = size
    canvas = background(size).convert('RGBA')
    draw = ImageDraw.Draw(canvas)
    landscape = w > h
    unit = h if landscape else w

    # 標語
    title_font = font(locale, round(unit * (0.074 if not landscape else 0.07)), True)
    sub_font = font(locale, round(unit * (0.037 if not landscape else 0.036)), False)
    max_text = w * (0.88 if not landscape else 0.7)
    y = round(h * (0.055 if not landscape else 0.06))
    for line in wrap(draw, title, title_font, max_text, locale):
        tw = draw.textlength(line, font=title_font)
        draw.text(((w - tw) / 2, y), line, font=title_font, fill=TITLE)
        y += round(title_font.size * 1.28)
    y += round(sub_font.size * 0.35)
    for line in wrap(draw, subtitle, sub_font, max_text, locale):
        tw = draw.textlength(line, font=sub_font)
        draw.text(((w - tw) / 2, y), line, font=sub_font, fill=SUBTITLE)
        y += round(sub_font.size * 1.45)
    top = y + round(unit * 0.05)

    # 裝置:原始畫面 + 外框,底部可以超出畫布
    shot = Image.open(raw).convert('RGB')
    dev_w = round(w * device_ratio)
    bezel = max(6, round(dev_w * 0.018))
    screen_w = dev_w - 2 * bezel
    screen_h = round(shot.height * screen_w / shot.width)
    shot = shot.resize((screen_w, screen_h), Image.LANCZOS)
    radius = round(min(screen_w, screen_h) * corner_ratio)  # 橫向也以短邊算圓角
    dev_h = screen_h + 2 * bezel
    left = (w - dev_w) // 2

    # 背後的綠色光暈與陰影
    glow = Image.new('RGBA', size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([left - dev_w * 0.15, top + dev_h * 0.05, left + dev_w * 1.15, top + dev_h * 0.75],
               fill=GLOW + (38,))
    canvas = Image.alpha_composite(canvas, glow.filter(ImageFilter.GaussianBlur(unit * 0.09)))
    shadow = Image.new('RGBA', size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [left, top + unit * 0.012, left + dev_w, top + dev_h + unit * 0.012],
        radius + bezel, fill=(0, 0, 0, 170))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(unit * 0.02)))

    frame = Image.new('RGBA', (dev_w, dev_h), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle([0, 0, dev_w - 1, dev_h - 1], radius + bezel, fill=BEZEL + (255,))
    fd.rounded_rectangle([1, 1, dev_w - 2, dev_h - 2], radius + bezel, outline=(78, 84, 94, 255), width=2)
    mask = Image.new('L', (screen_w, screen_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, screen_w - 1, screen_h - 1], radius, fill=255)
    frame.paste(shot, (bezel, bezel), mask)
    canvas.alpha_composite(frame, (left, top)) if top + dev_h <= h else canvas.alpha_composite(
        frame.crop((0, 0, dev_w, h - top)), (left, top))
    return canvas.convert('RGB')


def main():
    locale = sys.argv[1] if len(sys.argv) > 1 else 'zh'
    captions = json.loads((ROOT / 'captions.json').read_text())
    order, text = captions['order'], captions[locale]
    for target, (raw_dir, size, device_ratio, corner_ratio) in TARGETS.items():
        src = ROOT / 'raw' / f'{raw_dir}-{locale}'
        if not src.is_dir():
            print(f'略過 {target}:沒有 {src.relative_to(ROOT)}')
            continue
        out = ROOT / 'screenshots' / locale / target
        out.mkdir(parents=True, exist_ok=True)
        for old in out.glob('*.png'):
            old.unlink()
        # 大螢幕上設定頁這類畫面大片空白,可以在 captions.json 依尺寸挑張數
        for i, name in enumerate(captions.get('order_by_target', {}).get(target, order), 1):
            raw = src / f'{name}.png'
            if not raw.exists():
                continue
            with Image.open(raw) as im:
                if (im.width > im.height) != (size[0] > size[1]):
                    # 例:Duo 外螢幕不讓 app 自己轉方向,拍出來還是直的
                    print(f'  略過 {raw.relative_to(ROOT)}:方向跟 {target} 不同')
                    continue
            title, subtitle = text[name]
            compose(raw, size, device_ratio, corner_ratio, title, subtitle, locale).save(
                out / f'{i:02d}-{name[3:]}.png')
        print(f'{target}: {out.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
