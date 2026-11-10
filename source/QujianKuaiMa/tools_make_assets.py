#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「取件快码 Assit」的图标与详情页配图（纯 PIL，无外部素材）。"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = "/Users/mac/WorkBuddy/2026-11-10-22-02-29/assist-repo"
ICONS = os.path.join(ROOT, "icons")
ASSETS = os.path.join(ROOT, "depictions", "assets")
os.makedirs(ICONS, exist_ok=True)
os.makedirs(ASSETS, exist_ok=True)

PING = "/System/Library/Fonts/PingFang.ttc"
HEI = "/System/Library/Fonts/STHeiti Medium.ttc"


def font(size, bold=False):
    try:
        return ImageFont.truetype(HEI if bold else PING, size)
    except Exception:
        return ImageFont.truetype(PING, size)


def grad(size, top, bottom):
    """不透明 RGB 渐变，之后所有绘制都用不透明颜色，避免 alpha 被丢弃变白。"""
    w, h = size
    strip = Image.new("RGB", (1, h))
    d = ImageDraw.Draw(strip)
    for y in range(h):
        t = y / max(h - 1, 1)
        d.point((0, y), fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return strip.resize((w, h), Image.LANCZOS)


def composite_layer(base, layer):
    out = base.convert("RGBA")
    out.alpha_composite(layer)
    return out.convert("RGB")


def glow(base, box, color, blur, alpha):
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse(box, fill=color[:3] + (alpha,))
    return composite_layer(base, layer.filter(ImageFilter.GaussianBlur(blur)))


def shadow(base, box, radius, blur, alpha=70, offset=(0, 10)):
    x0, y0, x1, y1 = box
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        (x0 + offset[0], y0 + offset[1], x1 + offset[0], y1 + offset[1]),
        radius=radius, fill=(4, 18, 52, alpha))
    return composite_layer(base, layer.filter(ImageFilter.GaussianBlur(blur)))


def dim(base, color, alpha):
    layer = Image.new("RGBA", base.size, color + (alpha,))
    return composite_layer(base, layer)


def icon(size=512, roothide=False):
    S = 3
    W = size * S
    img = grad((W, W), (58, 138, 255), (12, 48, 158))
    img = glow(img, (-int(W * 0.35), -int(W * 0.55), int(W * 0.78), int(W * 0.48)),
               (255, 255, 255), W * 0.12, 55)
    d = ImageDraw.Draw(img)
    # 斜切色块（不透明，直接用混合后的实色）
    d.polygon([(0, W * 0.82), (W, W * 0.58), (W, W), (0, W)], fill=(38, 100, 222))

    for i, y in enumerate((0.22, 0.28, 0.34)):
        d.rounded_rectangle((W * 0.07, W * y, W * (0.22 + i * 0.015), W * y + W * 0.014),
                            radius=int(W * 0.007), fill=(168, 207, 255))

    box = (W * 0.20, W * 0.35, W * 0.80, W * 0.79)
    img = shadow(img, box, int(W * 0.07), W * 0.030, alpha=62, offset=(0, int(W * 0.018)))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(box, radius=int(W * 0.07), fill=(255, 255, 255))
    d.rounded_rectangle((W * 0.20, W * 0.35, W * 0.80, W * 0.475),
                        radius=int(W * 0.045), fill=(226, 239, 255))
    d.rectangle((W * 0.20, W * 0.44, W * 0.80, W * 0.48), fill=(208, 228, 255))
    d.rectangle((W * 0.455, W * 0.35, W * 0.545, W * 0.79), fill=(150, 199, 255))
    d.rectangle((W * 0.455, W * 0.35, W * 0.545, W * 0.475), fill=(126, 182, 255))

    label = (W * 0.565, W * 0.545, W * 0.755, W * 0.725)
    d.rounded_rectangle(label, radius=int(W * 0.015), fill=(248, 251, 255),
                        outline=(205, 222, 245), width=max(1, int(W * 0.004)))
    x = label[0] + W * 0.024
    for wd in (3, 2, 5, 2, 3, 6, 2, 4, 2, 3, 5, 2):
        bw = W * 0.006 * wd / 3
        if x + bw > label[2] - W * 0.02:
            break
        d.rectangle((x, label[1] + W * 0.026, x + bw, label[3] - W * 0.048), fill=(24, 52, 105))
        x += bw + W * 0.010
    d.text((label[0] + W * 0.025, label[3] - W * 0.050), "3-2-1056",
           font=font(int(W * 0.031), True), fill=(40, 78, 150))

    cx, cy, r = W * 0.78, W * 0.28, W * 0.135
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 176, 32),
              outline=(255, 255, 255), width=max(2, int(W * 0.012)))
    d.polygon([
        (cx + r * 0.10, cy - r * 0.62), (cx - r * 0.40, cy + r * 0.08),
        (cx - r * 0.04, cy + r * 0.08), (cx - r * 0.16, cy + r * 0.64),
        (cx + r * 0.42, cy - r * 0.10), (cx + r * 0.04, cy - r * 0.10)
    ], fill=(255, 255, 255))

    if roothide:
        pill = (W * 0.14, W * 0.845, W * 0.86, W * 0.945)
        d.rounded_rectangle(pill, radius=int((pill[3] - pill[1]) / 2), fill=(8, 30, 86))
        d.text((W * 0.5, (pill[1] + pill[3]) / 2), "ROOTHIDE 隐根",
               font=font(int(W * 0.046), True), fill=(255, 255, 255), anchor="mm")

    return img.resize((size, size), Image.LANCZOS)


def banner(path, icon_img):
    W, H = 1920, 1080
    img = grad((W, H), (16, 42, 112), (9, 20, 58))
    img = glow(img, (int(W * 0.52), -int(H * 0.5), int(W * 1.25), int(H * 1.15)),
               (60, 130, 255), 90, 70)
    d = ImageDraw.Draw(img)
    for x in range(0, W, 80):
        d.line((x, 0, x, H), fill=(26, 54, 122), width=1)
    for y in range(0, H, 80):
        d.line((0, y, W, y), fill=(26, 54, 122), width=1)

    d.rounded_rectangle((120, 150, 490, 210), radius=30, fill=(32, 78, 180),
                        outline=(90, 150, 255), width=2)
    d.text((305, 180), "ASSIST REPO  ·  V1.0.0", font=font(30, True),
           fill=(196, 224, 255), anchor="mm")
    d.text((120, 320), "取件快码 Assit", font=font(112, True), fill=(255, 255, 255))
    d.text((124, 470), "取件码，一只悬浮球就够了", font=font(52), fill=(170, 205, 255))

    for text, x in (("自动抓码", 120), ("按驿站归类", 370), ("一键复制", 620), ("无根 / 隐根", 870)):
        tw = d.textlength(text, font=font(34, True))
        d.rounded_rectangle((x, 590, x + tw + 56, 662), radius=36, fill=(36, 74, 158))
        d.text((x + 28, 626), text, font=font(34, True), fill=(228, 240, 255), anchor="lm")

    d.text((124, 780), "本机解析 · 不联网 · 不上传", font=font(38), fill=(140, 178, 235))
    d.text((124, 850), "Author  AssitDev", font=font(34), fill=(110, 148, 210))

    big = icon_img.convert("RGB").resize((600, 600), Image.LANCZOS)
    mask = Image.new("L", (600, 600), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 599, 599), radius=132, fill=255)
    img.paste(big, (1200, 210), mask)
    img.save(path, quality=90)


def screenshot(path, variant=1):
    W, H = 750, 1334
    img = grad((W, H), (224, 238, 255), (166, 197, 246))
    img = glow(img, (-220, -340, 720, 470), (255, 255, 255), 150, 95)
    img = glow(img, (340, 880, 1060, 1620), (86, 146, 255), 150, 65)
    d = ImageDraw.Draw(img)
    d.text((40, 32), "9:41", font=font(28, True), fill=(30, 45, 75))
    d.text((710, 32), "●  ▮", font=font(24), fill=(30, 45, 75), anchor="ra")

    names = ["信息", "微信", "菜鸟", "相机", "设置", "相册", "地图", "时钟"]
    cols = [(255, 140, 60), (70, 195, 105), (60, 140, 255), (120, 130, 150),
            (140, 150, 170), (245, 175, 60), (80, 190, 220), (40, 50, 70)]
    for i in range(8):
        col, row = i % 4, i // 4
        x, y = 70 + col * 165, 120 + row * 200
        d.rounded_rectangle((x, y, x + 120, y + 120), radius=28, fill=cols[i])
        d.text((x + 60, y + 60), names[i][:1], font=font(52, True),
               fill=(255, 255, 255), anchor="mm")
        d.text((x + 60, y + 140), names[i], font=font(22), fill=(45, 60, 90), anchor="mm")

    if variant == 1:
        bx, by, br = 655, 620, 46
        d.ellipse((bx - br - 6, by - br - 6, bx + br + 6, by + br + 6), fill=(28, 60, 120))
        d.ellipse((bx - br, by - br, bx + br, by + br), fill=(36, 118, 245))
        d.text((bx, by - 2), "码", font=font(40, True), fill=(255, 255, 255), anchor="mm")
        d.text((bx, by + 24), "取件", font=font(16), fill=(230, 240, 255), anchor="mm")
        d.ellipse((bx + 20, by - 52, bx + 62, by - 10), fill=(255, 92, 72))
        d.text((bx + 41, by - 31), "3", font=font(26, True), fill=(255, 255, 255), anchor="mm")

        img = dim(img, (8, 20, 45), 118)
        card = (36, 250, 714, 1110)
        img = shadow(img, card, 36, 34, alpha=85)
        d = ImageDraw.Draw(img)
        d.rounded_rectangle(card, radius=36, fill=(255, 255, 255))
        d.text((70, 305), "取件快码 Assit", font=font(38, True), fill=(24, 38, 66))
        d.text((680, 305), "✕", font=font(34), fill=(120, 135, 160), anchor="ra")

        d.rounded_rectangle((70, 370, 680, 424), radius=14, fill=(238, 243, 251))
        d.rounded_rectangle((76, 376, 278, 418), radius=11, fill=(255, 255, 255))
        d.text((177, 397), "待取 3", font=font(25, True), fill=(36, 118, 245), anchor="mm")
        d.text((380, 397), "已取", font=font(25), fill=(120, 135, 160), anchor="mm")
        d.text((580, 397), "设置", font=font(25), fill=(120, 135, 160), anchor="mm")

        rows = [("3-2-1056", "菜鸟驿站 · 今天 14:32", "望江路 12 号"),
                ("A8274", "丰巢快递柜 · 今天 11:08", "取件码 A8274"),
                ("668812", "取餐码 · 昨天 18:20", "美团外卖")]
        for i, (code, meta, extra) in enumerate(rows):
            y = 455 + i * 158
            d.rounded_rectangle((60, y, 690, y + 142), radius=20, fill=(246, 249, 254))
            d.text((86, y + 46), code, font=font(46, True), fill=(30, 105, 235))
            d.text((86, y + 104), meta, font=font(23), fill=(110, 125, 150))
            d.text((664, y + 46), extra, font=font(22), fill=(150, 162, 182), anchor="ra")
            d.rounded_rectangle((600, y + 92, 672, y + 126), radius=12, fill=(225, 238, 255))
            d.text((636, y + 109), "复制", font=font(21, True), fill=(36, 118, 245), anchor="mm")

        d.rounded_rectangle((60, 1000, 690, 1082), radius=20, fill=(238, 246, 255))
        d.text((180, 1041), "＋ 添加", font=font(27, True), fill=(36, 118, 245), anchor="mm")
        d.text((375, 1041), "粘贴识别", font=font(27, True), fill=(36, 118, 245), anchor="mm")
        d.text((570, 1041), "清理已取", font=font(27, True), fill=(36, 118, 245), anchor="mm")
        d.text((375, 1200), "点一下复制 · 左滑标记已取", font=font(26),
               fill=(70, 95, 135), anchor="mm")
    else:
        bn = (36, 110, 714, 226)
        img = shadow(img, bn, 28, 26, alpha=75)
        d = ImageDraw.Draw(img)
        d.rounded_rectangle(bn, radius=28, fill=(255, 255, 255))
        d.text((70, 152), "新取件码 · 菜鸟驿站", font=font(26), fill=(120, 135, 160))
        d.text((68, 186), "3-2-1056", font=font(52, True), fill=(36, 118, 245))

        card = (36, 300, 714, 1120)
        img = shadow(img, card, 36, 34, alpha=85)
        d = ImageDraw.Draw(img)
        d.rounded_rectangle(card, radius=36, fill=(255, 255, 255))
        d.text((70, 355), "设置", font=font(40, True), fill=(24, 38, 66))
        items = [("启用插件", "关闭后停止抓码并隐藏悬浮球", True),
                 ("桌面悬浮球", "长按悬浮球可临时隐藏", True),
                 ("自动抓取通知", "从短信 / 微信 / 菜鸟等通知里解析", True),
                 ("新码横幅提醒", "抓到新码时在屏幕顶部弹提示", True),
                 ("记录保留天数", "7 天，可 1–90 天调整", False),
                 ("自定义匹配关键词", "逗号分隔，例如：包裹码,柜号", False)]
        for i, (t, s, on) in enumerate(items):
            y = 440 + i * 108
            d.text((70, y), t, font=font(28, True), fill=(30, 45, 75))
            d.text((70, y + 40), s, font=font(21), fill=(130, 145, 170))
            if on:
                d.rounded_rectangle((608, y, 680, y + 40), radius=20, fill=(52, 199, 89))
                d.ellipse((650, y + 4, 676, y + 36), fill=(255, 255, 255))
            else:
                d.text((672, y + 18), "›", font=font(34), fill=(160, 172, 192), anchor="ra")
        d.text((375, 1190), "全部设置保存在本机 · 支持 rootless / roothide",
               font=font(24), fill=(70, 95, 135), anchor="mm")

    img.save(path, quality=92)


if __name__ == "__main__":
    ico = icon(512)
    ico.save(os.path.join(ICONS, "com.assitdev.qujiankuaima.png"), optimize=True)
    icon(512, roothide=True).save(os.path.join(ICONS, "com.assitdev.qujiankuaima.roothide.png"), optimize=True)
    banner(os.path.join(ASSETS, "qujiankuaima-banner.jpg"), ico)
    screenshot(os.path.join(ASSETS, "qujiankuaima-shot-1.png"), 1)
    screenshot(os.path.join(ASSETS, "qujiankuaima-shot-2.png"), 2)
    print("generated:")
    for f in ["icons/com.assitdev.qujiankuaima.png", "icons/com.assitdev.qujiankuaima.roothide.png",
              "depictions/assets/qujiankuaima-banner.jpg", "depictions/assets/qujiankuaima-shot-1.png",
              "depictions/assets/qujiankuaima-shot-2.png"]:
        p = os.path.join(ROOT, f)
        print(" ", f, Image.open(p).size, os.path.getsize(p), "B")
