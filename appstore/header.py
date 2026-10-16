#!/usr/bin/env python3
"""產品頁標題橫幅(App Store 的 product page header,21:9、3840×1646)。

    python3 appstore/header.py [zh|en]

中央是 icon、名稱和標語;兩側放 iPhone(注音/鍵盤那張)和橫放的 iPad 當裝飾。
不同裝置會從兩側裁切,所以文字都留在中央,裝置被裁掉也沒關係。
讀 appstore/raw/,寫到 appstore/screenshots/<語系>/header/header.png(不含 alpha)。
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

from compose import BEZEL, GLOW, SUBTITLE, TITLE, background, font

ROOT = Path(__file__).resolve().parent
SIZE = (3840, 1646)

TAGLINE = {
    'zh': '打中文不出包的 SSH 終端機',
    'en': 'SSH terminal that handles IMEs',
}
DEVICES = {
    'zh': ('iphone-zh/03-notes.png', 'ipad-land-zh/02-git.png'),
    'en': ('iphone-en/03-notes.png', 'ipad-land-en/02-git.png'),
}


def device(raw, width, corner_ratio):
    """原始畫面加外框;回傳 RGBA。"""
    shot = Image.open(raw).convert('RGB')
    bezel = max(6, round(width * 0.02))
    screen_w = width - 2 * bezel
    screen_h = round(shot.height * screen_w / shot.width)
    shot = shot.resize((screen_w, screen_h), Image.LANCZOS)
    radius = round(min(screen_w, screen_h) * corner_ratio)
    frame = Image.new('RGBA', (width, screen_h + 2 * bezel), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle([0, 0, frame.width - 1, frame.height - 1], radius + bezel, fill=BEZEL + (255,))
    fd.rounded_rectangle([1, 1, frame.width - 2, frame.height - 2], radius + bezel,
                         outline=(78, 84, 94, 255), width=3)
    mask = Image.new('L', (screen_w, screen_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, screen_w - 1, screen_h - 1], radius, fill=255)
    frame.paste(shot, (bezel, bezel), mask)
    return frame


def paste_with_shadow(canvas, img, pos, blur=40, offset=24, alpha=170):
    shadow = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    a = img.getchannel('A').point(lambda v: alpha if v else 0)
    shadow.paste((0, 0, 0, 255), (pos[0], pos[1] + offset), a)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(img, pos)
    return canvas


def app_icon(size):
    """iOS 圓角方形 icon,加一圈細亮邊,深色背景上才看得出輪廓。"""
    icon = Image.open(ROOT / 'icon' / 'icon-1024.png').convert('RGB').resize((size, size), Image.LANCZOS)
    radius = round(size * 0.2237)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius, fill=255)
    out.paste(icon, (0, 0), mask)
    ImageDraw.Draw(out).rounded_rectangle([1, 1, size - 2, size - 2], radius,
                                          outline=(255, 255, 255, 46), width=3)
    return out


def header(locale):
    w, h = SIZE
    canvas = background(SIZE).convert('RGBA')

    # 中央的綠色光暈
    glow = Image.new('RGBA', SIZE, (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([w * 0.28, h * 0.12, w * 0.72, h * 0.95], fill=GLOW + (34,))
    canvas = Image.alpha_composite(canvas, glow.filter(ImageFilter.GaussianBlur(h * 0.16)))

    # 兩側裝置:左邊 iPhone,右邊橫放的 iPad(右緣超出畫布)。
    # 中央留 1500px 給文字,兩側裝置都不進來
    phone_raw, tablet_raw = (ROOT / 'raw' / p for p in DEVICES[locale])
    phone = device(phone_raw, 600, 0.125)
    canvas = paste_with_shadow(canvas, phone, (330, 270))
    tablet = device(tablet_raw, 1260, 0.03)
    canvas = paste_with_shadow(canvas, tablet, (2800, 400))

    # 中央:icon、名稱、標語,整組垂直置中。iPad 橫放只露出中間一條,
    # 上緣還疊著浮動的分頁列(約在 y 350~460),太靠上 icon 會被蓋住
    top = 460
    icon = app_icon(330)
    canvas = paste_with_shadow(canvas, icon, ((w - icon.width) // 2, top), blur=30, offset=16, alpha=150)
    draw = ImageDraw.Draw(canvas)
    name_font = font('en', 190, True)
    name = 'tterminal'
    nw = draw.textlength(name, font=name_font)
    draw.text(((w - nw) / 2, top + 390), name, font=name_font, fill=TITLE)
    tag_font = font(locale, 84 if locale == 'zh' else 80, False)
    tag = TAGLINE[locale]
    tw = draw.textlength(tag, font=tag_font)
    draw.text(((w - tw) / 2, top + 650), tag, font=tag_font, fill=SUBTITLE)
    return canvas.convert('RGB')


def main():
    locale = sys.argv[1] if len(sys.argv) > 1 else 'zh'
    out = ROOT / 'screenshots' / locale / 'header'
    out.mkdir(parents=True, exist_ok=True)
    header(locale).save(out / 'header.png')
    print(f'header: {(out / "header.png").relative_to(ROOT)}')


if __name__ == '__main__':
    main()
