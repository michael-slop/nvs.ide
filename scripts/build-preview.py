"""Build docs/preview/index.html from docs/preview/src.html.

The preview answers Ask questions and runs the lessons from the same files the
editor uses (runtime/kb/ask.json, runtime/tutor/nvs-ide.tutor), and shows the
icon from assets/nvs.ide.png, so run this after changing any of them.

    python scripts/build-preview.py [--fragment OUT]

--fragment also writes the page without <!doctype>/<head>, for hosts that
supply their own skeleton.
"""
import base64
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def tutor_data():
    src = (ROOT / "runtime/tutor/nvs-ide.tutor").read_text(encoding="utf-8")
    meta = json.loads((ROOT / "runtime/tutor/nvs-ide.tutor.json").read_text(encoding="utf-8"))
    raw = src.split("\n")
    expect = [{"orig": raw[int(n) - 1], "want": want} for n, want in meta["expect"].items() if want != -1]
    # Strip the tutor markup Neovim conceals: `x`{normal} -> x, [text](link) -> text, `x` -> x.
    text = re.sub(r"`([^`]+)`\{\w+\}", r"\1", src)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    return {"text": text.rstrip("\n"), "expect": expect}


def embed(value):
    return json.dumps(value, ensure_ascii=False).replace("</", "<\\/")


def main():
    page = (ROOT / "docs/preview/src.html").read_text(encoding="utf-8")
    kb = json.loads((ROOT / "runtime/kb/ask.json").read_text(encoding="utf-8"))
    for marker in ("/*@KB@*/null", "/*@TUTOR@*/null", "__NVS_ICON__"):
        if marker not in page:
            sys.exit(f"marker {marker} missing from src.html")
    icon = "data:image/png;base64," + base64.b64encode((ROOT / "assets/nvs.ide.png").read_bytes()).decode()
    page = (
        page.replace("/*@KB@*/null", embed(kb))
        .replace("/*@TUTOR@*/null", embed(tutor_data()))
        .replace("__NVS_ICON__", icon)
    )

    full = (
        '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
        f'<link rel="icon" type="image/png" href="{icon}">\n'
        "</head>\n<body>\n" + page + "\n</body>\n</html>\n"
    )
    (ROOT / "docs/preview/index.html").write_text(full, encoding="utf-8")
    print("wrote docs/preview/index.html")
    if "--fragment" in sys.argv:
        out = Path(sys.argv[sys.argv.index("--fragment") + 1])
        out.write_text(page, encoding="utf-8")
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
