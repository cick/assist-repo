#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成越狱源（APT flat layout）所需的
    Packages / Packages.gz / Packages.bz2 / Release
纯 Python 实现，不依赖 dpkg-scanpackages。

用法：
    1. 把 .deb 文件放进 ./debs/ 目录
    2. 运行 `python3 gen_repo.py`
    3. 把整个目录（含 Packages*、Release、debs/、icon.png、index.html）上传到任意静态托管

说明：
    - 兼容 Cydia / Sileo / Zebra / Installer 的 flat layout
    - 自动解析每个 deb 的 control，计算 Filename / Size / MD5sum / SHA256
    - 去掉非标准的 Changelog 字段，保持 Packages 干净
"""
import os
import io
import gzip
import bz2
import hashlib
import tarfile
import datetime

REPO = os.path.dirname(os.path.abspath(__file__))
DEBS_DIR = os.path.join(REPO, "debs")
PKG_PATH = os.path.join(REPO, "Packages")

# ── 源的元信息（按需修改）──────────────────────────────────────────────
ORIGIN = "Assist Repo"
LABEL = "Assist"
SUITE = "stable"
CODENAME = "stable"
COMPONENTS = "main"
ARCHS = "iphoneos-arm64"
DESCRIPTION = "顶栏时间Assit（CallAssistStatusBar）、钉钉助手等越狱插件的分发源。"

# ── 详情页（Depiction）───────────────────────────────────────────────
# 地址要和最终托管的根 URL 一致（结尾不要带 /）。
# 客户端点开包详情时会加载这个 HTML，里面含截图、使用介绍、更新日志。
REPO_BASE_URL = "https://cick.github.io/assist-repo"

# 详情页按「包名」自动匹配，文件存在才会写进 Packages：
#   depictions/<package>.html        → Depiction（Cydia / Zebra）
#   depictions/<package>.sileo.json  → SileoDepiction（Sileo 原生，渲染更好）
# 这样新增包时不用改代码，丢一个 HTML 进去就行；没有详情页的包也不会
# 被错误地指到别的包的详情页上。
DEPICTION_DIR = "depictions"


def depiction_fields(pkg):
    """返回该包可用的详情页字段（没有对应文件则不返回对应键）。"""
    out = {}
    html = f"{DEPICTION_DIR}/{pkg}.html"
    sileo = f"{DEPICTION_DIR}/{pkg}.sileo.json"
    if os.path.exists(os.path.join(REPO, html)):
        out["Depiction"] = REPO_BASE_URL.rstrip("/") + "/" + html
    if os.path.exists(os.path.join(REPO, sileo)):
        out["SileoDepiction"] = REPO_BASE_URL.rstrip("/") + "/" + sileo
    return out


def read_ar(path):
    """极简 ar 解析，取出各成员字节。"""
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"!<arch>\n", "不是 .deb（ar）文件: " + path
    members = {}
    off = 8
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[0:16].decode("latin-1").strip().strip("/").strip()
        size = int(hdr[48:58].decode("latin-1").strip() or "0")
        off += 60
        content = data[off:off + size]
        off += size
        if size % 2 == 1:
            off += 1  # ar 奇数长度会补一个换行
        members[name] = content
    return members


def control_of_deb(deb_path):
    members = read_ar(deb_path)
    ctar = members.get("control.tar.gz") or members.get("control.tar.xz")
    if ctar is None:
        raise RuntimeError("deb 内没有 control 归档: " + deb_path)
    if ctar[:2] == b"\x1f\x8b":
        tf = tarfile.open(fileobj=io.BytesIO(ctar), mode="r:gz")
    else:
        tf = tarfile.open(fileobj=io.BytesIO(ctar), mode="r:xz")
    ctrl = None
    for m in tf.getmembers():
        if m.name in ("./control", "control"):
            ctrl = tf.extractfile(m).read().decode("utf-8")
            break
    if ctrl is None:
        raise RuntimeError("control 归档内没有 control 文件: " + deb_path)
    return ctrl


def parse_control(text):
    fields = {}
    order = []
    cur = None
    buf = []
    for line in text.split("\n"):
        if line == "":
            continue
        if line[0:1] in (" ", "\t"):          # 规范续行：以空格/tab 开头
            if cur:
                buf.append(line)              # 保留整行（含前导空格，符合 Debian 续行规范）
            continue
        if ":" in line:                       # 新字段
            if cur:
                fields[cur] = "\n".join(buf).strip("\n")
                order.append(cur)
            key, _, val = line.partition(":")
            cur = key.strip()
            buf = [val.strip()]
        else:
            # 容错：非空格开头、又不含冒号 → 当作当前字段的续行（补齐一个前导空格）。
            # 修复部分严格解析器（如 Sileo）把无前导空格的续行误判为新 stanza，
            # 从而把 Filename / Size / SHA256 等后续字段吞掉、导致 "Can't find a
            # source to download" 的问题。
            if cur:
                buf.append(" " + line)
    if cur:
        fields[cur] = "\n".join(buf).strip("\n")
        order.append(cur)
    return fields, order


def main():
    debs = sorted(f for f in os.listdir(DEBS_DIR) if f.endswith(".deb"))
    assert debs, "debs/ 目录里没有任何 .deb 文件"
    entries = []
    for fn in debs:
        full = os.path.join(DEBS_DIR, fn)
        fields, order = parse_control(control_of_deb(full))
        # 去掉非标准字段，保持 Packages 干净（Changelog 过长且各客户端不展示）
        for drop in ("Changelog",):
            if drop in fields:
                del fields[drop]
                order.remove(drop)
        raw = open(full, "rb").read()
        fields["Filename"] = "debs/" + fn
        fields["Size"] = str(len(raw))
        fields["MD5sum"] = hashlib.md5(raw).hexdigest()
        fields["SHA256"] = hashlib.sha256(raw).hexdigest()
        # 详情页：客户端点开包时加载的 HTML（含截图 / 使用介绍 / 更新日志）
        for k, v in depiction_fields(fields.get("Package", "")).items():
            fields[k] = v
            if k not in order:
                order.append(k)
        for extra in ("Filename", "Size", "MD5sum", "SHA256", "Depiction", "SileoDepiction"):
            if extra in fields and extra not in order:
                order.append(extra)
        entries.append((fields, order))

    # ── 写 Packages（明文）─────────────────────────────────────────────
    blocks = []
    for fields, order in entries:
        blocks.append("\n".join(f"{k}: {fields[k]}" for k in order))
    packages_text = "\n\n".join(blocks) + "\n"
    with open(PKG_PATH, "w", encoding="utf-8") as f:
        f.write(packages_text)
    with open(PKG_PATH, "rb") as f:
        raw_pkg = f.read()

    # ── 压缩 ───────────────────────────────────────────────────────────
    with gzip.open(os.path.join(REPO, "Packages.gz"), "wb") as f:
        f.write(raw_pkg)
    with open(os.path.join(REPO, "Packages.bz2"), "wb") as f:
        f.write(bz2.compress(raw_pkg, 9))

    # ── Release ────────────────────────────────────────────────────────
    now = datetime.datetime.now(datetime.timezone.utc)
    date = now.strftime("%a, %d %b %Y %H:%M:%S +0000")

    def hsh(p):
        r = open(p, "rb").read()
        return hashlib.md5(r).hexdigest(), hashlib.sha256(r).hexdigest(), len(r)

    files = [("Packages", PKG_PATH),
             ("Packages.gz", os.path.join(REPO, "Packages.gz")),
             ("Packages.bz2", os.path.join(REPO, "Packages.bz2"))]
    md5, sha, sz = [], [], []
    for name, p in files:
        m, s, n = hsh(p)
        md5.append(f" {m} {n} {name}")
        sha.append(f" {s} {n} {name}")
        sz.append(f" {n} {name}")

    release = (
        f"Origin: {ORIGIN}\n"
        f"Label: {LABEL}\n"
        f"Suite: {SUITE}\n"
        f"Codename: {CODENAME}\n"
        f"Architectures: {ARCHS}\n"
        f"Components: {COMPONENTS}\n"
        f"Description: {DESCRIPTION}\n"
        f"Date: {date}\n"
        f"MD5Sum:\n" + "\n".join(md5) + "\n"
        f"SHA256:\n" + "\n".join(sha) + "\n"
    )
    with open(os.path.join(REPO, "Release"), "w", encoding="utf-8") as f:
        f.write(release)

    print(f"OK：{len(entries)} 个包 → Packages / Packages.gz / Packages.bz2 / Release")
    for fn in debs:
        print("   ·", fn)


if __name__ == "__main__":
    main()
