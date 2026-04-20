#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path

from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[1]
SAMPLES_PATH = ROOT / "fixtures" / "claim-letter-samples.txt"
OUT_DIR = ROOT / "fixtures" / "generated"

MARKER_RE = re.compile(r"^<<<SAMPLE\s+(\d+)>>>\s*$", re.MULTILINE)


def split_samples(text: str) -> list[tuple[int, str]]:
    markers = list(MARKER_RE.finditer(text))
    if len(markers) != 5:
        raise ValueError(f"Expected 5 <<<SAMPLE nn>>> markers, found {len(markers)}")

    samples: list[tuple[int, str]] = []
    for i, m in enumerate(markers):
        sample_id = int(m.group(1))
        start = m.end()
        end = markers[i + 1].start() if i + 1 < len(markers) else len(text)
        body = text[start:end].strip()
        samples.append((sample_id, body))
    return samples


def write_pdf(sample_id: int, body: str, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    c = canvas.Canvas(str(out_path), pagesize=letter)
    width, height = letter

    left_x = 72
    top_y = height - 72
    max_width = width - 2 * 72
    line_height = 14

    c.setFont("Helvetica", 11)
    c.drawString(left_x, top_y, f"Synthetic claim letter sample {sample_id:02d}")
    top_y -= line_height * 2

    paragraphs = [p.strip() for p in body.split("\n\n") if p.strip()]
    for para in paragraphs:
        words = para.replace("\n", " ").split()
        line = ""
        for w in words:
            trial = (line + " " + w).strip()
            if c.stringWidth(trial, "Helvetica", 11) <= max_width:
                line = trial
            else:
                if line:
                    c.drawString(left_x, top_y, line)
                    top_y -= line_height
                    if top_y < 72:
                        c.showPage()
                        c.setFont("Helvetica", 11)
                        top_y = height - 72
                line = w
        if line:
            c.drawString(left_x, top_y, line)
            top_y -= line_height
            if top_y < 72:
                c.showPage()
                c.setFont("Helvetica", 11)
                top_y = height - 72
        top_y -= line_height * 0.6

    c.save()


def main() -> None:
    text = SAMPLES_PATH.read_text(encoding="utf-8")
    try:
        samples = split_samples(text)
    except ValueError as e:
        raise SystemExit(str(e)) from e

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for sid, body in sorted(samples, key=lambda x: x[0]):
        out = OUT_DIR / f"sample-{sid:02d}.pdf"
        write_pdf(sid, body, out)
        print(f"Wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
