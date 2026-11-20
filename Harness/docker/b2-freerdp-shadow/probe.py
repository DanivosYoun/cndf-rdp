#!/usr/bin/env python3
"""Input-latency probe for the B2 shadow server.

Fills the whole X screen. The square at PROBE_RECT changes colour on every key press,
so the harness can time "key sent" -> "first frame where the square's colour changed".
The rest of the screen is a static, non-black pattern so the first frame is never empty.
"""
import os
import tkinter as tk

WIDTH = int(os.environ.get("SCREEN_WIDTH", "1280"))
HEIGHT = int(os.environ.get("SCREEN_HEIGHT", "800"))
PROBE_RECT = (0, 0, 200, 200)  # x, y, w, h — keep in sync with the harness scenario
COLORS = ["#ff0000", "#00ff00", "#0000ff", "#ffff00", "#ff00ff", "#00ffff"]

root = tk.Tk()
root.overrideredirect(True)
root.geometry(f"{WIDTH}x{HEIGHT}+0+0")
canvas = tk.Canvas(root, width=WIDTH, height=HEIGHT, highlightthickness=0, bg="#406080")
canvas.pack()
for i in range(0, WIDTH, 80):
    canvas.create_line(i, 0, i, HEIGHT, fill="#a0c0e0")
canvas.create_text(WIDTH // 2, HEIGHT // 2, text="cndf engine harness B2 probe", fill="white",
                   font=("TkDefaultFont", 24))
x, y, w, h = PROBE_RECT
square = canvas.create_rectangle(x, y, x + w, y + h, fill=COLORS[0], width=0)
state = {"index": 0}


def on_key(_event):
    state["index"] = (state["index"] + 1) % len(COLORS)
    canvas.itemconfigure(square, fill=COLORS[state["index"]])


root.bind_all("<KeyPress>", on_key)
root.after(500, root.focus_force)
root.mainloop()
