# App icon / splash source art

- `logo_source.jpeg` -- as supplied (Gemini-generated), 2048×2048, no alpha.
- `logo.png` -- the same image, losslessly re-encoded to PNG. Used directly
  as the iOS icon, the Android legacy icon, and the splash image (see
  `flutter_launcher_icons.yaml` / `flutter_native_splash.yaml`).
- `icon_foreground.png` -- `logo.png` scaled to 60% and centered on a
  2048×2048 canvas filled with `#F5F8FD` (sampled from the card's own
  background). Used for the Android **adaptive** icon foreground and the
  Android 12+ splash icon, both of which enforce their own mask/container
  and only guarantee roughly the inner 66% of the layer survives it. Padding
  with the same color as `adaptive_icon_background` means whatever a given
  launcher's mask shape crops away is invisible -- it's cropping more of the
  same flat color, never a corner of the card.

Regenerated with:

```python
from PIL import Image

SIZE = 2048
BG = (245, 248, 253)  # #F5F8FD

src = Image.open("logo.png").convert("RGB")
inner = round(SIZE * 0.60)
resized = src.resize((inner, inner), Image.LANCZOS)

canvas = Image.new("RGB", (SIZE, SIZE), BG)
offset = ((SIZE - inner) // 2, (SIZE - inner) // 2)
canvas.paste(resized, offset)
canvas.save("icon_foreground.png", "PNG")
```

If the source art ever changes, regenerate `icon_foreground.png` the same
way, re-sample `BG` from the new art, and update the hex color in both
`flutter_launcher_icons.yaml` (`adaptive_icon_background`) and
`flutter_native_splash.yaml` (`color`) to match.

After changing anything here:

```sh
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```
