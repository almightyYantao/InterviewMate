"""从 Swift 源码提取界面文字，按 i18n/en.json 生成 en.lproj/Localizable.strings。

用法：python3 i18n/gen_strings.py <输出目录>
- Text("第 \\(n) 题") 这类插值，SwiftUI 查表时整数用 %lld、字符串用 %@，这里按表达式猜类型，另外再生成一份全 %@ 的给 L() 兜底匹配；
- en.json 里没有的文字会打印出来，界面上保持中文。
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from extract import literals  # noqa: E402

INT = re.compile(r"count|minutes|Minutes|index|version|Days|Weight|^h$|^m$|^d$|scored|total")


def esc(s: str) -> str:
    return s.replace('"', '\\"')


def main(out: Path):
    en = json.loads((HERE / "en.json").read_text(encoding="utf-8"))
    src = HERE.parent / "Sources" / "ResumeScreener"
    pairs, missing = {}, []
    for f in sorted(src.glob("*.swift")):
        for k, exprs in literals(f.read_text(encoding="utf-8")):
            if not re.search(r"[一-鿿]", k) or "\\\\s" in k:
                continue
            if k not in en:
                if k not in missing:
                    missing.append(k)
                continue
            specs = ["%lld" if INT.search(e) else "%@" for e in exprs]
            for variant in {tuple(specs), tuple("%@" for _ in specs)}:
                kk, vv = k, en[k]
                for s in variant:
                    kk, vv = kk.replace("{}", s, 1), vv.replace("{}", s, 1)
                pairs[kk] = vv
    out.mkdir(parents=True, exist_ok=True)
    (out / "en.lproj").mkdir(exist_ok=True)
    (out / "zh-Hans.lproj").mkdir(exist_ok=True)
    (out / "en.lproj" / "Localizable.strings").write_text(
        "".join(f'"{esc(k)}" = "{esc(v)}";\n' for k, v in pairs.items()), encoding="utf-8")
    (out / "zh-Hans.lproj" / "Localizable.strings").write_text("", encoding="utf-8")
    print(f"生成 {len(pairs)} 条英文翻译")
    if missing:
        print("缺翻译：", *missing, sep="\n  ")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
