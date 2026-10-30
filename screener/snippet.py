"""把简历 PDF 里指定行所在的区域截成图片，高亮这几行，给界面当「原文截图」用。"""
from __future__ import annotations

import io
import threading
from pathlib import Path

from rapidfuzz import fuzz

from .parsing import Doc, clean_page

PAD = 28        # 高亮行上下留的上下文（pt）
SCALE = 2.4     # 渲染倍率，Retina 下清晰
_PDFIUM = threading.Lock()   # pdfium 不是线程安全的，接口在线程池里并发调用时必须串行


def render(path: Path, doc: Doc, line_nos: list[int]) -> bytes | None:
    """line_nos 为 1 起的行号；只截第一行所在页里的那几行。非 PDF 返回 None。"""
    if path.suffix.lower() != ".pdf" or not doc.pages:
        return None
    nos = sorted({n for n in line_nos if 1 <= n <= len(doc.lines)})
    if not nos:
        return None
    page_no = doc.pages[nos[0] - 1]
    nos = [n for n in nos if doc.pages[n - 1] == page_no]
    same_page = [i + 1 for i, p in enumerate(doc.pages) if p == page_no]

    import pdfplumber
    from PIL import Image, ImageDraw

    with pdfplumber.open(path) as pdf:
        page = pdf.pages[page_no - 1]
        rows = clean_page(page).extract_text_lines(
            x_tolerance=1.5, y_tolerance=7, strip=True)
        boxes = []
        for n in nos:
            target, k = doc.lines[n - 1].strip(), same_page.index(n)
            best, best_s = None, -1e9
            for j, r in enumerate(rows):
                s = fuzz.ratio(target, r["text"].strip()) - 0.5 * abs(j - k)
                if s > best_s:
                    best, best_s = r, s
            if best is not None:
                boxes.append((best["x0"], best["top"], best["x1"], best["bottom"]))
        if not boxes:
            return None
        top = max(0, min(b[1] for b in boxes) - PAD)
        bottom = min(page.height, max(b[3] for b in boxes) + PAD)
        left = max(0, min(r["x0"] for r in rows) - 16)
        right = min(page.width, max(r["x1"] for r in rows) + 16)
        with _PDFIUM:
            img = page.crop((left, top, right, bottom)).to_image(resolution=72 * SCALE).original.convert("RGBA")

    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    for x0, t, x1, b in boxes:
        d.rounded_rectangle(((x0 - left - 4) * SCALE, (t - top - 3) * SCALE, (x1 - left + 4) * SCALE, (b - top + 3) * SCALE),
                            radius=6, fill=(255, 214, 10, 90), outline=(245, 166, 35, 255), width=3)
    out = io.BytesIO()
    Image.alpha_composite(img, overlay).save(out, "PNG")
    return out.getvalue()


def locate(path: Path, doc: Doc, line_nos: list[int]) -> list[dict]:
    """返回每行在原 PDF 里的位置：{line, page(1 起), x0, top, x1, bottom, page_width, page_height}，坐标单位 pt、原点左上。"""
    if path.suffix.lower() != ".pdf" or not doc.pages:
        return []
    import pdfplumber

    out = []
    with pdfplumber.open(path) as pdf:
        rows_cache: dict[int, list] = {}
        for n in sorted({n for n in line_nos if 1 <= n <= len(doc.lines)}):
            pno = doc.pages[n - 1]
            page = pdf.pages[pno - 1]
            if pno not in rows_cache:
                rows_cache[pno] = clean_page(page).extract_text_lines(
                    x_tolerance=1.5, y_tolerance=7, strip=True)
            rows = rows_cache[pno]
            same_page = [i + 1 for i, p in enumerate(doc.pages) if p == pno]
            target, k = doc.lines[n - 1].strip(), same_page.index(n)
            best = max(rows, key=lambda r: fuzz.ratio(target, r["text"].strip()) - 0.5 * abs(rows.index(r) - k), default=None)
            if best:
                out.append({"line": n, "page": pno, "x0": best["x0"], "top": best["top"], "x1": best["x1"],
                            "bottom": best["bottom"], "page_width": page.width, "page_height": page.height})
    return out


def page_sizes(path: Path) -> list[dict]:
    if path.suffix.lower() != ".pdf":
        return []
    import pdfplumber
    with pdfplumber.open(path) as pdf:
        return [{"width": float(p.width), "height": float(p.height)} for p in pdf.pages]


def render_page(path: Path, page_no: int, scale: float = 2.0) -> bytes:
    """整页渲染成 PNG，字体按 PDF 原样画（PDFKit 对部分嵌入字体会把数字画成点）。"""
    import pdfplumber
    with pdfplumber.open(path) as pdf:
        with _PDFIUM:
            img = pdf.pages[page_no - 1].to_image(resolution=72 * scale).original
    out = io.BytesIO()
    img.save(out, "PNG")
    return out.getvalue()
