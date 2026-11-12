# Draws the app icon: a black tile with a pink-to-orange loop ring and a play triangle.
from PIL import Image, ImageDraw
import math

S = 2048
img = Image.new("RGB", (S, S), (0, 0, 0))
ring = Image.new("RGB", (S, S), (0, 0, 0))
d = ImageDraw.Draw(ring)
c, r, w = S / 2, S * 0.33, S * 0.085
# Gradient ring: draw short arcs, colour going from pink to orange around the circle.
steps = 360
for i in range(steps - 30):   # leave a gap at the top right, like a repeat arrow
    a0 = -60 + i
    t = i / (steps - 30)
    col = (255, int(69 + (140 - 69) * t), int(120 + (90 - 120) * t))
    d.arc([c - r, c - r, c + r, c + r], a0, a0 + 1.5, fill=col, width=int(w))
# Arrow head at the end of the ring.
end = math.radians(-60 + steps - 30)
ex, ey = c + r * math.cos(end), c + r * math.sin(end)
tang = end + math.pi / 2
size = w * 1.35
pts = [
    (ex + size * math.cos(tang), ey + size * math.sin(tang)),
    (ex + size * 0.95 * math.cos(end), ey + size * 0.95 * math.sin(end)),
    (ex - size * 0.95 * math.cos(end), ey - size * 0.95 * math.sin(end)),
]
d.polygon(pts, fill=(255, 140, 90))
img.paste(ring)
d = ImageDraw.Draw(img)
# Play triangle in the middle.
p = S * 0.15
d.polygon([(c - p * 0.75, c - p), (c - p * 0.75, c + p), (c + p * 1.05, c)], fill=(255, 255, 255))
img.resize((1024, 1024), Image.LANCZOS).save("LoopPlayer/Assets.xcassets/AppIcon.appiconset/icon.png")
