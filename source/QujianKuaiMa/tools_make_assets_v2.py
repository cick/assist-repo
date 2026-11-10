#!/usr/bin/env python3
# 取件快码 Assit v2.0.0 — 详情页配图（按原帖截图风格重画，非原帖素材）
from PIL import Image, ImageDraw, ImageFont
import os

FONT = '/System/Library/Fonts/PingFang.ttc'
OUT = 'assist-repo/depictions/assets'
os.makedirs(OUT, exist_ok=True)

def F(sz):
    return ImageFont.truetype(FONT, sz)

BG    = (245, 249, 247, 255)
WHITE = (255, 255, 255, 255)
INK   = (26, 46, 44, 255)
GRAY  = (140, 153, 151, 255)
GREEN = (77, 191, 170, 255)
MINT  = (168, 224, 206, 255)

BRANDS = {
    '淘': (255, 90, 20, 255), '拼': (226, 46, 31, 255), '京': (225, 37, 27, 255),
    '抖': (28, 28, 30, 255), '快': (255, 105, 30, 255), '得': (28, 28, 30, 255),
}

def badge(d, ch, cx, cy, r):
    c = BRANDS[ch]
    d.ellipse([cx-r, cy-r, cx+r, cy+r], fill=c)
    f = F(int(r * 0.95))
    d.text((cx, cy-1), ch, font=f, fill=WHITE, anchor='mm')

def card(d, box, radius=16):
    d.rounded_rectangle(box, radius=radius, fill=WHITE)

def section(d, x, y, text):
    d.rounded_rectangle([x, y+2, x+4, y+18], radius=2, fill=GREEN)
    d.text((x+12, y), text, font=F(15), fill=(56, 89, 85, 255))

def shot_main():
    W, H = 390, 960
    im = Image.new('RGBA', (W, H), BG)
    d = ImageDraw.Draw(im)
    # 状态栏
    d.text((24, 12), '17:04', font=F(14), fill=INK)
    d.text((W-24, 12), '5G  ▮▮▮  45', font=F(11), fill=GRAY, anchor='ra')
    # 标题
    d.rounded_rectangle([22, 60, 27, 96], radius=2, fill=GREEN)
    d.text((38, 56), '取件快码', font=F(30), fill=INK)
    d.text((24, 106), '三个身份码 · 六个查件入口', font=F(14), fill=GRAY)

    y = 152
    section(d, 22, y, '身份码')
    y += 30
    ids = [('淘', '淘宝身份码', '驿站扫码出示 ›'),
           ('拼', '拼多多身份码', '驿站扫码出示 ›'),
           ('京', '京东身份码', '订单内查看 ›')]
    for ch, title, sub in ids:
        card(d, [22, y, W-22, y+76])
        badge(d, ch, 22+16+22, y+38, 22)
        d.text((22+76, y+26), title, font=F(17), fill=INK)
        d.text((W-38, y+29), sub, font=F(13), fill=GRAY, anchor='ra')
        y += 76 + 14

    y += 8
    section(d, 22, y, '查询快递')
    y += 30
    qs = [('淘','淘宝待取','查看待取包裹'), ('拼','拼多多待取','查看待取包裹'),
          ('京','京东待取','查看订单物流'), ('抖','抖音待取','查看订单物流'),
          ('快','快手待取','查看订单物流'), ('得','得物待取','查看订单物流')]
    cw = (W - 44 - 12) / 2
    ch_h = 100
    for i, (ch, title, sub) in enumerate(qs):
        x = 22 + (i % 2) * (cw + 12)
        cy = y + (i // 2) * (ch_h + 12)
        card(d, [x, cy, x+cw, cy+ch_h])
        badge(d, ch, x+cw/2, cy+28, 14)
        d.text((x+cw/2, cy+49), title, font=F(14), fill=INK, anchor='ma')
        d.text((x+cw/2, cy+72), sub, font=F(11), fill=GRAY, anchor='ma')
    y += 3 * (ch_h + 12) + 12

    d.rounded_rectangle([(W-110)/2, y, (W+110)/2, y+44], radius=22, fill=MINT)
    d.text((W/2, y+22), '设置', font=F(15), fill=(33, 82, 76, 255), anchor='mm')
    d.text((W/2, y+66), 'v2.0.0 · Author AssitDev · Assist Repo',
           font=F(10), fill=(184, 197, 194, 255), anchor='mm')
    im.convert('RGB').save(f'{OUT}/qujiankuaima-shot-1.png')
    print('shot-1', im.size)

def shot_settings():
    W, H = 390, 844
    im = Image.new('RGBA', (W, H), BG)
    d = ImageDraw.Draw(im)
    d.text((24, 12), '17:04', font=F(14), fill=INK)
    d.rounded_rectangle([0, 0, W, 88], radius=0, fill=WHITE)
    d.text((W/2, 56), '设置', font=F(17), fill=INK, anchor='mm')
    y = 112
    d.text((22, y), '运行状态', font=F(13), fill=GRAY); y += 24
    card(d, [16, y, W-16, y+52], radius=12)
    d.text((30, y+16), '桌面悬浮球', font=F(15), fill=INK)
    d.rounded_rectangle([W-76, y+12, W-26, y+42], radius=15, fill=GREEN)
    d.ellipse([W-48, y+13, W-28, y+41], fill=WHITE)
    y += 52
    card(d, [16, y, W-16, y+52], radius=12)
    d.text((30, y+9), '插件注入：正常', font=F(15), fill=GREEN)
    d.text((30, y+30), '悬浮球可显示', font=F(11), fill=GRAY)
    y += 72

    d.text((22, y), '入口链接（点按可自定义）', font=F(13), fill=GRAY); y += 24
    rows = [('淘宝身份码','taobao://'), ('拼多多身份码','pinduoduo://'),
            ('京东身份码','openapp.jdmobile://'), ('淘宝待取','taobao://'),
            ('拼多多待取','pinduoduo://'), ('京东待取','openapp.jdmobile://'),
            ('抖音待取','snssdk1128://'), ('快手待取','kwai://'), ('得物待取','dewu://')]
    card(d, [16, y, W-16, y+44*len(rows)], radius=12)
    for i, (t, u) in enumerate(rows):
        ry = y + i*44
        d.text((30, ry+7), t, font=F(14), fill=INK)
        d.text((30, ry+25), u, font=F(10), fill=GRAY)
        d.text((W-30, ry+15), '›', font=F(18), fill=GRAY, anchor='ra')
        if i < len(rows)-1:
            d.line([(30, ry+44), (W-30, ry+44)], fill=(238, 242, 240, 255), width=1)
    y += 44*len(rows) + 22
    d.text((22, y), '留空即使用默认值，可填各 App 内「身份码 / 待取包裹」页的完整深链。',
           font=F(10), fill=GRAY)
    im.convert('RGB').save(f'{OUT}/qujiankuaima-shot-2.png')
    print('shot-2', im.size)

def banner():
    W, H = 1920, 1080
    im = Image.new('RGBA', (W, H), (0,0,0,0))
    d = ImageDraw.Draw(im)
    for yy in range(H):
        t = yy / H
        d.line([(0, yy), (W, yy)], fill=(int(70-30*t), int(196-46*t), int(172-40*t), 255))
    # 右侧三张示意卡
    for i, (ch, t1, t2) in enumerate([('淘','淘宝身份码','驿站扫码出示'),
                                      ('拼','拼多多身份码','驿站扫码出示'),
                                      ('京','京东身份码','订单内查看')]):
        y = 250 + i*200
        d.rounded_rectangle([1180, y, 1780, y+160], radius=32, fill=WHITE)
        badge(d, ch, 1260, y+80, 42)
        d.text((1330, y+52), t1, font=F(42), fill=INK)
        d.text((1330, y+106), t2, font=F(28), fill=GRAY)
    d.text((120, 330), '取件快码 Assit', font=F(110), fill=WHITE)
    d.text((128, 490), '三个身份码 · 六个查件入口', font=F(46), fill=(226, 250, 244, 255))
    d.text((128, 610), '桌面 App + 悬浮球双入口  ·  点一下直达对应 App', font=F(34), fill=(226, 250, 244, 255))
    d.text((128, 900), 'v2.0.0   ·   Author AssitDev   ·   Assist Repo', font=F(28), fill=(210, 242, 234, 255))
    im.convert('RGB').save(f'{OUT}/qujiankuaima-banner.jpg', quality=92)
    print('banner', im.size)

shot_main()
shot_settings()
banner()
