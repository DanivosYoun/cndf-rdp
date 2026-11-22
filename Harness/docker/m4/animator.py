#!/usr/bin/env python3
"""M4 H.264 acceptance screen (design m4-h264-design A1/A2) for B2 shadow and B3 xrdp.

Fills the whole X screen. Two keys drive it, so the harness knows what the server encodes:

  a  colour change: COLOR_FRAMES full-screen fills, one every COLOR_INTERVAL_MS (about 8 s,
     the h264-result 0.611 s method: 97 frames), ending on the last fill. The harness measures
     client CPU over this window with no frame tap attached.
  b  final picture: the deterministic reference pattern below. The harness attaches its tap,
     presses b and keeps the last frame; the run script captures the same screen with xwd.

The pattern is smooth gradients plus large saturated blocks in both halves (16-aligned):
two independent lossy encodes of it stay close, while a chroma misplacement (design's first
falsification point: the AVC444v2 V2 view on a 1104-wide surface) shifts whole colour areas.
"""
import os

COLOR_FRAMES = 97
COLOR_INTERVAL_MS = 82


def screen_size(root):
    width = int(os.environ.get("SCREEN_WIDTH", "0")) or root.winfo_screenwidth()
    height = int(os.environ.get("SCREEN_HEIGHT", "0")) or root.winfo_screenheight()
    return width, height


def color_at(index):
    """Fill colour of colour-change frame `index` (0-based); full-saturation hue walk."""
    hue = (index * 37) % 360
    sector, rest = divmod(hue, 60)
    rising = rest * 255 // 60
    falling = 255 - rising
    r, g, b = [
        (255, rising, 0), (falling, 255, 0), (0, 255, rising),
        (0, falling, 255), (rising, 0, 255), (255, 0, falling),
    ][sector]
    return f"#{r:02x}{g:02x}{b:02x}"


BLOCK_COLORS = [(230, 30, 40), (30, 200, 60), (40, 60, 230), (240, 220, 30), (220, 40, 210), (20, 210, 220)]


def reference_ppm(width, height):
    """The final picture as binary PPM (P6). Same function for every server and run."""
    rows = []
    block = 64
    for y in range(height):
        g = y * 255 // max(height - 1, 1)
        row = bytearray(width * 3)
        for x in range(width):
            r = x * 255 // max(width - 1, 1)
            b = 255 - (r + g) // 2
            by, bx = divmod(y, block * 2), divmod(x, block * 2)
            # Saturated 64x64 blocks on a 128 grid, rows offset so both halves get every colour.
            if by[1] >= 32 and by[1] < 32 + block and bx[1] >= 32 and bx[1] < 32 + block:
                r, g2, b = BLOCK_COLORS[(bx[0] + by[0] * 5) % len(BLOCK_COLORS)]
            else:
                g2 = g
            row[x * 3:x * 3 + 3] = bytes((r, g2, b))
        rows.append(bytes(row))
    return b"P6\n%d %d\n255\n" % (width, height) + b"".join(rows)


def main():
    import tkinter as tk  # here, so judge.py can import reference_ppm without Tk

    root = tk.Tk()
    width, height = screen_size(root)
    root.overrideredirect(True)
    root.geometry(f"{width}x{height}+0+0")
    canvas = tk.Canvas(root, width=width, height=height, highlightthickness=0, bg="#406080")
    canvas.pack()
    picture = tk.PhotoImage(data=reference_ppm(width, height), format="ppm")
    image_item = canvas.create_image(0, 0, image=picture, anchor="nw")
    fill_item = canvas.create_rectangle(0, 0, width, height, fill="#406080", width=0, state="hidden")
    state = {"index": None, "job": None}

    def show_picture():
        canvas.itemconfigure(fill_item, state="hidden")
        canvas.itemconfigure(image_item, state="normal")

    def step():
        index = state["index"]
        if index is None or index >= COLOR_FRAMES:
            state["index"] = state["job"] = None
            return
        canvas.itemconfigure(image_item, state="hidden")
        canvas.itemconfigure(fill_item, state="normal", fill=color_at(index))
        state["index"] = index + 1
        state["job"] = root.after(COLOR_INTERVAL_MS, step)

    def cancel():
        if state["job"] is not None:
            root.after_cancel(state["job"])
        state["index"] = state["job"] = None

    def on_key(event):
        key = event.keysym.lower()
        if key == "a":
            cancel()
            state["index"] = 0
            step()
        elif key == "b":
            cancel()
            show_picture()

    root.bind_all("<KeyPress>", on_key)
    root.after(500, root.focus_force)
    root.mainloop()


if __name__ == "__main__":
    main()
