# Share verification probe (iron-share-verify). Runs inside the RDP session as an interactive
# scheduled task, like Harness/windows-ime/probe.ps1, and only observes:
#   - a WH_KEYBOARD_LL hook logs every key (vk, scan, extended, injected)
#   - a WH_MOUSE_LL hook logs button presses and releases and wheel turns with the physical
#     screen point
#   - a 20 ms timer logs the set of keys and buttons GetAsyncKeyState reports held whenever it
#     changes ("held ..."), and the primary screen size whenever it changes ("screen WxH")
# A borderless, DPI-aware, topmost form covers the primary screen (and follows display changes) so
# typed keys land in its text box (x 20..820, y 20..60, click 100,40) and clicks land on the form.
# A 30 fps animated bar (y 80..120) keeps the screen changing, so the server keeps sending frames.
# Output: C:\k5share\out\<run>.log, run id from C:\k5share\runid.txt. Exits after the number of
# seconds in C:\k5share\limit.txt (default 1500).
$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class ShareProbe {
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public uint vk, scan, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public int x, y; public uint data, flags, time; public IntPtr extra; }

    static StreamWriter log;
    static HookProc keyProc = KeyHook, mouseProc = MouseHook;
    static Stopwatch clock = Stopwatch.StartNew();
    static string lastHeld = null, lastScreen = null, lastFg = null;
    static Form form;
    static TextBox tb;
    static int frame;

    static void Log(string line) {
        log.WriteLine(String.Format("{0,8} {1} {2}", clock.ElapsedMilliseconds,
            DateTime.UtcNow.ToString("HH:mm:ss.fff"), line));
        log.Flush();
    }

    static IntPtr KeyHook(int code, IntPtr w, IntPtr l) {
        if (code >= 0) {
            var k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(KBDLLHOOKSTRUCT));
            int msg = w.ToInt32();
            Log(String.Format("key {0} vk=0x{1:x2} scan=0x{2:x2} ext={3} injected={4}",
                (msg == 0x100 || msg == 0x104) ? "down" : "up", k.vk, k.scan,
                (k.flags & 1) != 0 ? 1 : 0, (k.flags & 0x10) != 0 ? 1 : 0));
        }
        return CallNextHookEx(IntPtr.Zero, code, w, l);
    }

    static IntPtr MouseHook(int code, IntPtr w, IntPtr l) {
        if (code >= 0) {
            int msg = w.ToInt32();
            string kind = null;
            switch (msg) {
                case 0x201: kind = "ldown"; break; case 0x202: kind = "lup"; break;
                case 0x204: kind = "rdown"; break; case 0x205: kind = "rup"; break;
                case 0x207: kind = "mdown"; break; case 0x208: kind = "mup"; break;
                case 0x20A: kind = "wheel"; break; case 0x20E: kind = "hwheel"; break;
            }
            if (kind != null) {
                var m = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(MSLLHOOKSTRUCT));
                Log(String.Format("mouse {0} x={1} y={2} delta={3} injected={4}", kind, m.x, m.y,
                    (short)(m.data >> 16), (m.flags & 1) != 0 ? 1 : 0));
            }
        }
        return CallNextHookEx(IntPtr.Zero, code, w, l);
    }

    static void Poll() {
        var held = new StringBuilder();
        for (int vk = 1; vk < 0xFF; vk++) {
            if (vk == 0x10 || vk == 0x11 || vk == 0x12) continue; // generic Shift/Ctrl/Alt mirror L/R
            if ((GetAsyncKeyState(vk) & 0x8000) != 0) held.Append(held.Length == 0 ? "" : ",").Append(vk.ToString("x2"));
        }
        string h = held.Length == 0 ? "-" : held.ToString();
        if (h != lastHeld) { Log("held " + h); lastHeld = h; }
        string screen = GetSystemMetrics(0) + "x" + GetSystemMetrics(1);
        if (screen != lastScreen) {
            Log("screen " + screen);
            lastScreen = screen;
            form.Bounds = new Rectangle(0, 0, GetSystemMetrics(0), GetSystemMetrics(1));
        }
        var sb = new StringBuilder(128);
        GetWindowText(GetForegroundWindow(), sb, 128);
        string fg = sb.ToString();
        if (fg != lastFg) { Log("foreground " + fg); lastFg = fg; }
    }

    public static void Run(string dir, string run, int limitSeconds) {
        SetProcessDPIAware();
        Directory.CreateDirectory(dir);
        log = new StreamWriter(Path.Combine(dir, run + ".log"), true, new UTF8Encoding(false));
        Application.EnableVisualStyles();
        form = new Form {
            Text = "Share Probe", FormBorderStyle = FormBorderStyle.None, TopMost = true,
            StartPosition = FormStartPosition.Manual, Bounds = new Rectangle(0, 0, GetSystemMetrics(0), GetSystemMetrics(1)),
            AutoScaleMode = AutoScaleMode.None, BackColor = Color.White
        };
        tb = new TextBox { Location = new Point(20, 20), Size = new Size(800, 40), Multiline = true,
            Font = new Font("Consolas", 14f, GraphicsUnit.Pixel) };
        form.Controls.Add(tb);
        form.Paint += (s, e) => {
            int x = (frame * 8) % Math.Max(1, form.ClientSize.Width - 40);
            e.Graphics.FillRectangle(Brushes.DarkBlue, x, 80, 40, 40);
            for (int gx = 0; gx < form.ClientSize.Width; gx += 100) e.Graphics.DrawLine(Pens.LightGray, gx, 130, gx, form.ClientSize.Height);
            for (int gy = 200; gy < form.ClientSize.Height; gy += 100) e.Graphics.DrawLine(Pens.LightGray, 0, gy, form.ClientSize.Width, gy);
        };
        form.Shown += (s, e) => { form.Activate(); tb.Focus(); };
        var poll = new Timer { Interval = 20 };
        poll.Tick += (s, e) => {
            Poll();
            if (clock.ElapsedMilliseconds > limitSeconds * 1000L) form.Close();
        };
        var anim = new Timer { Interval = 33 };
        anim.Tick += (s, e) => { frame++; form.Invalidate(new Rectangle(0, 80, form.ClientSize.Width, 40)); };
        IntPtr kh = SetWindowsHookEx(13, keyProc, GetModuleHandle(null), 0);
        IntPtr mh = SetWindowsHookEx(14, mouseProc, GetModuleHandle(null), 0);
        Log("start run=" + run + " keyhook=" + (kh != IntPtr.Zero ? 1 : 0) + " mousehook=" + (mh != IntPtr.Zero ? 1 : 0));
        poll.Start();
        anim.Start();
        Application.Run(form);
        Log("exit");
        log.Close();
    }
}
'@
$run = (Get-Content -Raw C:\k5share\runid.txt).Trim()
$limit = 1500
if (Test-Path C:\k5share\limit.txt) { $limit = [int](Get-Content -Raw C:\k5share\limit.txt).Trim() }
[ShareProbe]::Run('C:\k5share\out', $run, $limit)
