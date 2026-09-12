#!/usr/bin/env python3
"""Render README.md into report/report.html and a print-ready PDF.

    python3 report/build_report.py

Uses the Chromium that ships with this container to print the HTML, so the PDF
matches what a browser shows.
"""
import os
import pathlib
import shutil
import subprocess
import sys

import markdown

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent

CSS = """
@page { size: A4; margin: 18mm 16mm 20mm 16mm; }
* { box-sizing: border-box; }
body {
  font: 10.5pt/1.55 "Charter", "Georgia", "Times New Roman", serif;
  color: #16181d; margin: 0; -webkit-print-color-adjust: exact; print-color-adjust: exact;
}
h1 {
  font-size: 21pt; line-height: 1.25; margin: 0 0 .15em; letter-spacing: -.01em;
  font-family: "Helvetica Neue", Arial, sans-serif; font-weight: 700;
}
h2 {
  font-size: 14pt; margin: 1.9em 0 .55em; padding-bottom: .28em;
  border-bottom: 1.5px solid #d6dae1; font-family: "Helvetica Neue", Arial, sans-serif;
  font-weight: 700; page-break-after: avoid; break-after: avoid;
}
h3 {
  font-size: 11.5pt; margin: 1.4em 0 .4em; font-family: "Helvetica Neue", Arial, sans-serif;
  font-weight: 700; color: #2b3038; page-break-after: avoid; break-after: avoid;
}
p, ul, ol { margin: 0 0 .75em; }
li { margin-bottom: .3em; }
hr { border: 0; border-top: 1px solid #e2e6ec; margin: 1.8em 0; }
a { color: #1a4f8a; text-decoration: none; }
code {
  font-family: "SF Mono", "DejaVu Sans Mono", Menlo, Consolas, monospace;
  font-size: 8.6pt; background: #f2f4f7; padding: .1em .32em; border-radius: 3px;
  border: 1px solid #e4e8ee;
}
pre {
  background: #f7f9fb; border: 1px solid #e0e5ec; border-left: 3px solid #8b95a5;
  border-radius: 4px; padding: .7em .85em; overflow-x: auto;
  page-break-inside: avoid; break-inside: avoid; margin: 0 0 .9em;
}
pre code {
  background: none; border: 0; padding: 0; font-size: 8.1pt; line-height: 1.45;
  white-space: pre-wrap; word-break: break-all;
}
table {
  border-collapse: collapse; width: 100%; margin: .5em 0 1.1em; font-size: 9pt;
  page-break-inside: avoid; break-inside: avoid;
}
th, td { border: 1px solid #d8dde4; padding: .4em .55em; text-align: left; vertical-align: middle; }
th { background: #eef1f5; font-family: "Helvetica Neue", Arial, sans-serif; font-weight: 600; }
tbody tr:nth-child(even) { background: #fafbfc; }
td code, th code { font-size: 7.6pt; }
img { max-width: 100%; display: block; margin: 0 auto; border: 1px solid #ccd2da; }
blockquote {
  margin: 0 0 .9em; padding: .5em .9em; border-left: 3px solid #b9c1cc;
  background: #f7f9fb; color: #3a4049; font-style: italic;
}
strong { color: #0d0f13; }
.subtitle { color: #5b6470; font-size: 9.5pt; margin-bottom: 1.4em;
            font-family: "Helvetica Neue", Arial, sans-serif; }
"""

TEMPLATE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>SEED Lab - Secret-Key Encryption</title>
<style>{css}</style></head><body>{body}</body></html>"""


def main():
    md_text = (ROOT / "README.md").read_text(encoding="utf-8")
    # Inside report/ the images sit one level closer.
    md_text = md_text.replace("report/img/", "img/")

    body = markdown.markdown(
        md_text,
        extensions=["tables", "fenced_code", "sane_lists", "attr_list"],
    )
    html = TEMPLATE.format(css=CSS, body=body)
    out_html = HERE / "report.html"
    out_html.write_text(html, encoding="utf-8")
    print(f"wrote {out_html.relative_to(ROOT)}")

    chrome = None
    for candidate in ("/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
                      shutil.which("chromium"), shutil.which("google-chrome")):
        if candidate and os.path.exists(candidate):
            chrome = candidate
            break
    if not chrome:
        print("no chromium found; open report.html and print to PDF from the browser")
        return

    pdf = HERE / "SEED_Secret_Key_Encryption_Report.pdf"
    cmd = [chrome, "--headless", "--disable-gpu", "--no-sandbox",
           "--no-pdf-header-footer", "--run-all-compositor-stages-before-draw",
           "--virtual-time-budget=10000",
           f"--print-to-pdf={pdf}", out_html.as_uri()]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if pdf.exists():
        print(f"wrote {pdf.relative_to(ROOT)} ({pdf.stat().st_size:,} bytes)")
    else:
        print("chromium failed:\n", res.stderr[-2000:], file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
