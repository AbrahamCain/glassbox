"""Generate the starter scenes: simple synthetic images whose answers are unambiguous,
so you can tell exactly what an intervention did. Paired scenes share a prompt (and so
a token layout), which is what lets you patch between them.

Drop your own photos into scenes/ and add entries to scenes.json to play with them.
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parents[2] / "scenes"
SIZE = 512
BG = (245, 242, 235)
COLORS = {"red": (220, 40, 40), "blue": (40, 80, 220), "green": (40, 170, 70), "yellow": (240, 200, 30)}

COLOR_Q = "What color is the shape? Answer with one word."
LEFT_Q = "What color is the shape on the left? Answer with one word."
WORD_Q = "What word is written in the image? Answer with one word."
COUNT_Q = "How many dots are in the image? Answer with a number."


def canvas():
    img = Image.new("RGB", (SIZE, SIZE), BG)
    return img, ImageDraw.Draw(img)


def circle(color):
    img, d = canvas()
    d.ellipse((136, 136, 376, 376), fill=COLORS[color])
    return img


def two_shapes(left, right):
    img, d = canvas()
    d.ellipse((40, 176, 220, 356), fill=COLORS[left])
    d.rectangle((300, 176, 470, 346), fill=COLORS[right])
    return img


def word(text):
    img, d = canvas()
    font = ImageFont.load_default(size=170)
    box = d.textbbox((0, 0), text, font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text(((SIZE - w) / 2 - box[0], (SIZE - h) / 2 - box[1]), text, fill=(20, 20, 20), font=font)
    return img


def dots(n):
    img, d = canvas()
    spots = [(128, 128), (384, 384), (384, 128), (128, 384), (256, 256)]
    for x, y in spots[:n]:
        d.ellipse((x - 45, y - 45, x + 45, y + 45), fill=(20, 20, 20))
    return img


SCENES = [
    ("red circle", "red_circle.png", circle("red"), COLOR_Q),
    ("blue circle", "blue_circle.png", circle("blue"), COLOR_Q),
    ("green circle", "green_circle.png", circle("green"), COLOR_Q),
    ("red left, blue right", "red_left.png", two_shapes("red", "blue"), LEFT_Q),
    ("blue left, red right", "blue_left.png", two_shapes("blue", "red"), LEFT_Q),
    ("word CAT", "word_cat.png", word("CAT"), WORD_Q),
    ("word DOG", "word_dog.png", word("DOG"), WORD_Q),
    ("three dots", "dots_3.png", dots(3), COUNT_Q),
    ("four dots", "dots_4.png", dots(4), COUNT_Q),
]


def main():
    OUT.mkdir(exist_ok=True)
    manifest = []
    for name, file, img, prompt in SCENES:
        img.save(OUT / file)
        manifest.append({"name": name, "image": file, "prompt": prompt})
    (OUT / "scenes.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(manifest)} scenes to {OUT}")


if __name__ == "__main__":
    main()
