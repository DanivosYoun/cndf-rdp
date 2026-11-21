# K5 Windows IME probe (Korean input design V4). Runs inside the RDP session as an interactive
# scheduled task. A borderless, DPI-aware, topmost form at the screen origin holds three text
# boxes at fixed physical pixel positions so the Mac harness can click them:
#   tb1 normal   x 20..820  y  20..60   (click 100,40)
#   tb2 password x 20..820  y  80..120  (click 100,100)
#   tb3 normal   x 20..820  y 140..180  (click 100,160)
# A WH_KEYBOARD_LL hook logs every key (vk, scan, LLKHF flags) with the IME conversion mode of
# the focused box; a 100 ms timer logs IME mode changes and rewrites the state file with the box
# contents as UTF-8. F11 / F12 (seen by the hook) start cmd.exe / powershell.exe at x 0 y 300
# (click 200,400); the state file also carries the cursor line of each console's screen buffer.
# Output: C:\k5\out\<run>.keys.log and <run>.state.txt, run id from C:\k5\runid.txt. The probe
# exits by itself after 10 minutes and closes the consoles it started.
$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class K5Probe {
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr GetFocus();
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [DllImport("imm32.dll")] static extern IntPtr ImmGetContext(IntPtr h);
    [DllImport("imm32.dll")] static extern bool ImmReleaseContext(IntPtr h, IntPtr c);
    [DllImport("imm32.dll")] static extern bool ImmGetConversionStatus(IntPtr c, out int conv, out int sent);
    [DllImport("imm32.dll")] static extern bool ImmGetOpenStatus(IntPtr c);
    [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool ReadConsoleOutputCharacter(IntPtr h, StringBuilder text, uint length, uint coord, out uint read);
    [StructLayout(LayoutKind.Sequential)] struct CSBI { public short sizeX, sizeY, cursorX, cursorY; public ushort attributes; public short left, top, right, bottom, maxX, maxY; }
    delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public uint vk, scan, flags, time; public IntPtr extra; }

    static StreamWriter keys;
    static string statePath;
    static HookProc proc = Hook;
    static TextBox tb1, tb2, tb3;
    static string lastIme = "";
    static Stopwatch clock = Stopwatch.StartNew();
    static Process cmd, powershell;
    static Form form;

    static Process StartConsole(string file) {
        var p = Process.Start(new ProcessStartInfo(file) { UseShellExecute = true, WorkingDirectory = @"C:\k5" });
        for (int i = 0; i < 50 && p.MainWindowHandle == IntPtr.Zero; i++) { System.Threading.Thread.Sleep(100); p.Refresh(); }
        MoveWindow(p.MainWindowHandle, 0, 300, 900, 400, true);
        Log("console " + file + " pid=" + p.Id + " hwnd=" + (p.MainWindowHandle != IntPtr.Zero ? 1 : 0));
        return p;
    }

    // The cursor line of a console's screen buffer. The hidden powershell.exe host's own console
    // is given up first: a process can be attached to one console only.
    static string ConsoleLine(Process p) {
        if (p == null || p.HasExited) return "";
        FreeConsole();
        if (!AttachConsole(p.Id)) return "attach-failed";
        string line = "";
        IntPtr h = CreateFile("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        CSBI info;
        if (h != new IntPtr(-1) && GetConsoleScreenBufferInfo(h, out info)) {
            var sb = new StringBuilder(info.sizeX + 1);
            uint read;
            if (ReadConsoleOutputCharacter(h, sb, (uint)info.sizeX, (uint)(info.cursorY << 16), out read)) line = sb.ToString(0, (int)read).TrimEnd();
        }
        if (h != new IntPtr(-1)) CloseHandle(h);
        FreeConsole();
        return line;
    }

    static string Ime() {
        IntPtr focus = GetFocus();
        if (focus == IntPtr.Zero) return "nofocus";
        IntPtr ctx = ImmGetContext(focus);
        if (ctx == IntPtr.Zero) return "noctx";
        int conv, sent;
        bool ok = ImmGetConversionStatus(ctx, out conv, out sent);
        bool open = ImmGetOpenStatus(ctx);
        ImmReleaseContext(focus, ctx);
        return ok ? String.Format("open={0} conv=0x{1:x} native={2}", open ? 1 : 0, conv, conv & 1) : "noconv";
    }

    static string Focused() {
        IntPtr f = GetFocus();
        if (f == tb1.Handle) return "tb1";
        if (f == tb2.Handle) return "tb2";
        if (f == tb3.Handle) return "tb3";
        var sb = new StringBuilder(128);
        GetWindowText(GetForegroundWindow(), sb, 128);
        return "other:" + sb;
    }

    static void Log(string line) {
        keys.WriteLine(String.Format("{0,8} {1}", clock.ElapsedMilliseconds, line));
        keys.Flush();
    }

    static IntPtr Hook(int code, IntPtr w, IntPtr l) {
        if (code >= 0) {
            var k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(KBDLLHOOKSTRUCT));
            int msg = w.ToInt32();
            string kind = (msg == 0x100 || msg == 0x104) ? "down" : "up";
            Log(String.Format("key {0} vk=0x{1:x2} scan=0x{2:x2} ext={3} injected={4} focus={5} {6}",
                kind, k.vk, k.scan, (k.flags & 1) != 0 ? 1 : 0, (k.flags & 0x10) != 0 ? 1 : 0, Focused(), Ime()));
            if (kind == "down" && k.vk == 0x7A && cmd == null) form.BeginInvoke((Action)(() => { cmd = StartConsole("cmd.exe"); }));
            if (kind == "down" && k.vk == 0x7B && powershell == null) form.BeginInvoke((Action)(() => { powershell = StartConsole("powershell.exe"); }));
        }
        return CallNextHookEx(IntPtr.Zero, code, w, l);
    }

    static void WriteState() {
        var sb = new StringBuilder();
        sb.AppendLine("tb1=" + tb1.Text);
        sb.AppendLine("tb2=" + tb2.Text);
        sb.AppendLine("tb3=" + tb3.Text);
        sb.AppendLine("focus=" + Focused());
        sb.AppendLine("ime=" + Ime());
        sb.AppendLine("hkl=0x" + GetKeyboardLayout(0).ToInt64().ToString("x"));
        sb.AppendLine("cmd=" + ConsoleLine(cmd));
        sb.AppendLine("powershell=" + ConsoleLine(powershell));
        File.WriteAllText(statePath + ".tmp", sb.ToString(), new UTF8Encoding(false));
        File.Copy(statePath + ".tmp", statePath, true);
    }

    public static void Run(string dir, string run) {
        SetProcessDPIAware();
        Directory.CreateDirectory(dir);
        keys = new StreamWriter(Path.Combine(dir, run + ".keys.log"), true, new UTF8Encoding(false));
        statePath = Path.Combine(dir, run + ".state.txt");
        Application.EnableVisualStyles();
        form = new Form {
            Text = "K5 IME Probe", FormBorderStyle = FormBorderStyle.None, TopMost = true,
            StartPosition = FormStartPosition.Manual, Location = new Point(0, 0), Size = new Size(840, 200),
            AutoScaleMode = AutoScaleMode.None, BackColor = Color.LightYellow
        };
        Font font = new Font("Malgun Gothic", 14f, GraphicsUnit.Pixel);
        tb1 = new TextBox { Name = "tb1", Location = new Point(20, 20), Size = new Size(800, 40), Font = font };
        tb2 = new TextBox { Name = "tb2", Location = new Point(20, 80), Size = new Size(800, 40), Font = font, UseSystemPasswordChar = true };
        tb3 = new TextBox { Name = "tb3", Location = new Point(20, 140), Size = new Size(800, 40), Font = font };
        foreach (var tb in new[] { tb1, tb2, tb3 }) { tb.Multiline = true; form.Controls.Add(tb); }
        form.Shown += (s, e) => { form.Activate(); tb1.Focus(); };
        var timer = new Timer { Interval = 100 };
        timer.Tick += (s, e) => {
            string ime = Focused() + " " + Ime();
            if (ime != lastIme) { Log("ime " + ime); lastIme = ime; }
            WriteState();
            if (clock.ElapsedMilliseconds > 600000) form.Close();
        };
        timer.Start();
        IntPtr hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0);
        Log("start run=" + run + " hook=" + (hook != IntPtr.Zero ? 1 : 0) + " hkl=0x" + GetKeyboardLayout(0).ToInt64().ToString("x"));
        Application.Run(form);
        foreach (var p in new[] { cmd, powershell }) { if (p != null && !p.HasExited) p.Kill(); }
        Log("exit");
        keys.Close();
    }
}
'@
$run = (Get-Content -Raw C:\k5\runid.txt).Trim()
[K5Probe]::Run('C:\k5\out', $run)
