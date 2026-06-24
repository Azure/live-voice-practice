"""Build a guided tour animated GIF from screenshots with caption overlays."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "docs" / "images" / "tour"
OUT = SRC / "guided-tour.gif"

# Target frame size (downscale-friendly, GitHub-friendly)
W, H = 1100, 660
FRAME_MS = 4200  # per-slide duration

slides = [
    ("01-pick-scenario.png",
     "1. Pick a scenario",
     "Trainee reads the brief, picks a Live Voice Agent persona, and starts the session."),
    ("02-live-conversation.png",
     "2. Practice live",
     "The avatar speaks and listens in real time while the transcript builds on the right."),
    ("03-overall-score.png",
     "3. See the score",
     "A rubric-driven Performance Assessment opens with an overall score and pass / fail."),
    ("04-recommendations.png",
     "4. Drill into feedback",
     "Recommendations highlight the weakest criteria with evidence quoted from the conversation."),
    ("05-trainer-stats.png",
     "5. Trainer dashboard",
     "Admin stats show practices over time, average score, pass rate, and drop-off by scenario."),
    ("06-scenario-editor.png",
     "6. Author scenarios",
     "Trainers create or edit scenarios with the customer's role, background, and guidelines."),
]


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for name in ("seguisb.ttf", "segoeui.ttf", "arialbd.ttf", "arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def wrap(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont, max_w: int) -> list[str]:
    words = text.split()
    lines: list[str] = []
    cur = ""
    for w in words:
        candidate = f"{cur} {w}".strip()
        if draw.textlength(candidate, font=font) <= max_w:
            cur = candidate
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def build_frame(image_path: Path, title: str, caption: str) -> Image.Image:
    img = Image.open(image_path).convert("RGB")
    # Fit into frame with letterboxing (cover the canvas with a blurred bg)
    bg = img.copy().resize((W, H)).filter(ImageFilter.GaussianBlur(25))
    bg = bg.point(lambda p: int(p * 0.55))  # darken

    iw, ih = img.size
    scale = min((W - 80) / iw, (H - 80) / ih)
    nw, nh = int(iw * scale), int(ih * scale)
    fg = img.resize((nw, nh), Image.LANCZOS)
    canvas = bg.copy()
    canvas.paste(fg, ((W - nw) // 2, (H - nh) // 2))

    # Bottom caption bar — light translucent gray over the image
    title_font = load_font(28)
    body_font = load_font(19)
    tmp_draw = ImageDraw.Draw(canvas)
    body_lines = wrap(tmp_draw, caption, body_font, W - 80)
    line_h = 24
    bar_h = 14 + 32 + 4 + line_h * len(body_lines) + 12

    overlay = Image.new("RGBA", (W, bar_h), (235, 238, 245, 140))
    canvas.paste(overlay, (0, H - bar_h), overlay)

    draw = ImageDraw.Draw(canvas, "RGBA")
    y = H - bar_h + 12
    draw.text((40, y), title, font=title_font, fill=(20, 28, 42, 255))
    y += 34
    for line in body_lines:
        draw.text((40, y), line, font=body_font, fill=(45, 55, 72, 255))
        y += line_h

    # Step indicator dots (top-right)
    return canvas


def add_dots(frame: Image.Image, active: int) -> Image.Image:
    draw = ImageDraw.Draw(frame, "RGBA")
    n = len(slides)
    dot_r = 6
    gap = 14
    total_w = n * (dot_r * 2) + (n - 1) * gap
    x0 = W - 30 - total_w
    y = 24
    for i in range(n):
        cx = x0 + i * (dot_r * 2 + gap) + dot_r
        color = (255, 255, 255, 240) if i == active else (255, 255, 255, 90)
        draw.ellipse((cx - dot_r, y - dot_r, cx + dot_r, y + dot_r), fill=color)
    return frame


def main() -> None:
    frames = []
    for i, (fname, title, caption) in enumerate(slides):
        f = build_frame(SRC / fname, title, caption)
        f = add_dots(f, i)
        # Quantize to palette for smaller GIF
        frames.append(f.convert("P", palette=Image.ADAPTIVE, colors=192))

    frames[0].save(
        OUT,
        save_all=True,
        append_images=frames[1:],
        duration=FRAME_MS,
        loop=0,
        optimize=True,
        disposal=2,
    )
    print(f"Wrote {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
