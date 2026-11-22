# int-8 Windows normal-path probe. Runs inside the RDP session as the interactive scheduled task
# I8Probe (registered by run-i8.sh). Commands reach it through the session clipboard itself: the
# Mac harness copies a text "I8CMD <verb> <args>" (Mac->Windows text path), the probe acts on it
# and answers by copying text or files (Windows->Mac path). Verbs:
#   settext <b64 utf8>        copy that text
#   burst <n> <b64 tag>       copy "<tag>-1" ... "<tag>-n" back to back (30 ms apart)
#   files <b64 utf8 a|b|c>    copy those paths as a file drop list
#   paste <leaf>              open C:\i8\dst\<leaf> in Explorer, wait for the next clipboard
#                             change that carries FileGroupDescriptorW, focus the empty file list,
#                             Ctrl+V, then wait until the tree is stable for 8 s, log it with
#                             sizes and SHA-256, and copy "I8DONE <leaf> n=<entries> bytes=<sum>"
#   sound <seconds>           play a 440 Hz tone that long
# int-11 verbs (one-shot WinForms timers, so the owner window keeps pumping while waiting):
#   mix <k> <delayMs> [<dir> <prefix>]  drop list C:\i8\src\gw1A\f00..f39.bin, then after delayMs
#                             the same names from C:\i8\src\gw1B (same sizes, other bytes), or
#                             C:\i8\src\<dir>\<prefix>00..39.bin
#   fileimg <b64 path> <ms>   drop list that path, then Clipboard.SetImage after ms
#   flip <ft|tf> <k> <ms>     files(small.txt) then text "M4-<k>" after ms, or the reverse
#   hold <b64 path> <ms> <holdMs>  drop list that file, after ms open it with FileShare.None for holdMs
#   del <b64 path> <ms>       drop list that file, after ms delete it (logs the exception if it fails)
#   trunc <b64 path> <ms> <bytes>  drop list that file, after ms set its length to bytes
# int-13 X-7 verbs (copies made by other apps, not by .NET; the previous window is closed first):
#   settext2 <b64 a> <ms> <b64 b>  copy a, then b after ms (X-3)
#   notepad <b64 text>        write the text to C:\i8\x7.txt, open it in Notepad, Ctrl+A, Ctrl+C
#   excopy <b64 path>         open Explorer with that file selected (/select), Ctrl+C
# Every clipboard change also logs the owner process; the tree line lists visible dialogs.
# Every clipboard change, wheel message (WM_MOUSEWHEEL / WM_MOUSEHWHEEL on the form) and command
# is logged to C:\i8\out\<run>.log (run id from C:\i8\runid.txt). On start it copies
# "I8READY <run>". A borderless topmost form sits at the origin (600x300 physical pixels). The
# probe exits by itself after 20 minutes. No Korean literals here: PowerShell 5.1 reads scripts
# without a BOM as ANSI.
$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

public class I8Form : Form {
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x020A || m.Msg == 0x020E) {
            int delta = (short)((m.WParam.ToInt64() >> 16) & 0xFFFF);
            I8Probe.Log("wheel " + (m.Msg == 0x020A ? "v" : "h") + " d=" + delta);
            if (m.Msg == 0x020E) { m.Result = new IntPtr(1); return; }
        }
        base.WndProc(ref m);
    }
}

public static class I8Probe {
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }

    static StreamWriter log;
    static Stopwatch clock = Stopwatch.StartNew();
    static uint lastSeq;
    static string run;
    // paste state: 0 idle, 1 waiting for the explorer window, 2 waiting for files on the
    // clipboard, 3 settle before Ctrl+V, 4 watching the tree
    static int pasteState;
    static string pasteDir, pasteLeaf;
    static IntPtr pasteWindow;
    static long stateSince, lastChange;
    static string lastSignature;
    static bool pasteRetried;
    static SoundPlayer player;
    static Process x7Notepad;
    static IntPtr x7Explorer;
    static long soundUntil;

    public static void Log(string line) {
        log.WriteLine(clock.ElapsedMilliseconds + " " + line);
        log.Flush();
    }

    static string Sha(byte[] data) {
        using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "").ToLowerInvariant();
    }

    static string FileSha(string path) {
        using (var sha = SHA256.Create()) using (var f = File.OpenRead(path))
            return BitConverter.ToString(sha.ComputeHash(f)).Replace("-", "").ToLowerInvariant();
    }

    static string B64(string s) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(s)); }
    static string UnB64(string s) { return Encoding.UTF8.GetString(Convert.FromBase64String(s)); }

    static void Copy(string text) {
        for (int i = 0; i < 10; i++) {
            try { Clipboard.SetText(text); return; } catch (ExternalException) { System.Threading.Thread.Sleep(50); }
        }
        Log("copy-failed");
    }

    static byte[] Tone(int seconds) {
        int rate = 44100, n = rate * seconds;
        var ms = new MemoryStream();
        var w = new BinaryWriter(ms);
        w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + n * 2); w.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write(Encoding.ASCII.GetBytes("data")); w.Write(n * 2);
        for (int i = 0; i < n; i++) w.Write((short)(Math.Sin(2 * Math.PI * 440 * i / rate) * 8000));
        return ms.ToArray();
    }

    static void Later(int ms, Action action) {
        var t = new Timer { Interval = Math.Max(1, ms) };
        t.Tick += delegate { t.Stop(); t.Dispose(); try { action(); } catch (Exception ex) { Log("later error " + ex.GetType().Name + " " + ex.Message); } };
        t.Start();
    }

    static void SetFiles(IEnumerable<string> paths) {
        var list = new StringCollection();
        foreach (string p in paths) list.Add(p);
        for (int i = 0; i < 10; i++) {
            try { Clipboard.SetFileDropList(list); return; } catch (ExternalException) { System.Threading.Thread.Sleep(20); }
        }
        Log("files-failed");
    }

    static void Chord(byte vk, byte scan) {
        keybd_event(0x11, 0x1D, 0, IntPtr.Zero); keybd_event(vk, scan, 0, IntPtr.Zero);
        keybd_event(vk, scan, 2, IntPtr.Zero); keybd_event(0x11, 0x1D, 2, IntPtr.Zero);
    }

    // Polls every 100 ms for up to 8 s until find() returns a window, then focuses it and runs keys.
    static void WhenWindow(string what, Func<IntPtr> find, Action<IntPtr> keys, int tries = 80) {
        IntPtr h = find();
        if (h == IntPtr.Zero) {
            if (tries <= 0) { Log(what + " window missing"); return; }
            Later(100, delegate { WhenWindow(what, find, keys, tries - 1); });
            return;
        }
        SetForegroundWindow(h);
        Later(400, delegate { SetForegroundWindow(h); keys(h); Log(what + " copied"); });
    }

    static void X7Close() {
        if (x7Notepad != null) { try { if (!x7Notepad.HasExited) x7Notepad.Kill(); } catch (Exception) { } x7Notepad = null; }
        if (x7Explorer != IntPtr.Zero) { PostMessage(x7Explorer, 0x0010, IntPtr.Zero, IntPtr.Zero); x7Explorer = IntPtr.Zero; }
    }

    static string Owner() {
        IntPtr h = GetClipboardOwner();
        if (h == IntPtr.Zero) return "none";
        uint pid; GetWindowThreadProcessId(h, out pid);
        string name = "?";
        try { name = Process.GetProcessById((int)pid).ProcessName; } catch (Exception) { }
        return pid + ":" + name;
    }

    static string Dialogs() {
        var found = new List<string>();
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            var cls = new StringBuilder(256); GetClassName(h, cls, 256);
            if (cls.ToString() == "#32770") { var t = new StringBuilder(256); GetWindowText(h, t, 256); found.Add(B64(t.ToString())); }
            return true;
        }, IntPtr.Zero);
        return found.Count == 0 ? "none" : string.Join(",", found);
    }

    static List<string> Set40(string dir, string prefix = "f") {
        var l = new List<string>();
        for (int i = 0; i < 40; i++) l.Add(dir + "\\" + prefix + i.ToString("00") + ".bin");
        return l;
    }

    static void Command(string text) {
        string[] f = text.Split(new[] { ' ' }, 3);
        string verb = f.Length > 1 ? f[1] : "";
        string arg = f.Length > 2 ? f[2] : "";
        Log("cmd " + verb);
        if (verb == "settext") {
            Copy(UnB64(arg));
        } else if (verb == "burst") {
            string[] a = arg.Split(' ');
            int n = int.Parse(a[0]);
            string tag = UnB64(a[1]);
            for (int i = 1; i <= n; i++) { Copy(tag + "-" + i); System.Threading.Thread.Sleep(30); }
            Log("burst done n=" + n);
        } else if (verb == "files") {
            var list = new StringCollection();
            foreach (string p in UnB64(arg).Split('|')) list.Add(p);
            for (int i = 0; i < 10; i++) {
                try { Clipboard.SetFileDropList(list); break; } catch (ExternalException) { System.Threading.Thread.Sleep(50); }
            }
            Log("files set n=" + list.Count);
        } else if (verb == "paste") {
            pasteLeaf = arg;
            pasteDir = @"C:\i8\dst\" + arg;
            Directory.CreateDirectory(pasteDir);
            Process.Start("explorer.exe", pasteDir);
            pasteState = 1; stateSince = clock.ElapsedMilliseconds; pasteRetried = false;
        } else if (verb == "settext2") {
            string[] a = arg.Split(' ');
            string second = UnB64(a[2]);
            Copy(UnB64(a[0])); Log("settext2 first");
            Later(int.Parse(a[1]), delegate { Copy(second); Log("settext2 second"); });
        } else if (verb == "notepad") {
            X7Close();
            File.WriteAllText(@"C:\i8\x7.txt", UnB64(arg), new UTF8Encoding(false));
            var p = Process.Start("notepad.exe", @"C:\i8\x7.txt");
            x7Notepad = p;
            WhenWindow("notepad", delegate { p.Refresh(); return p.MainWindowHandle; }, delegate (IntPtr h) {
                RECT r;
                if (GetWindowRect(h, out r)) {
                    SetCursorPos(r.left + (r.right - r.left) / 2, r.top + (r.bottom - r.top) / 2);
                    mouse_event(2, 0, 0, 0, IntPtr.Zero); mouse_event(4, 0, 0, 0, IntPtr.Zero);
                }
                System.Threading.Thread.Sleep(150);
                Chord(0x41, 0x1E); System.Threading.Thread.Sleep(100); Chord(0x43, 0x2E);
            });
        } else if (verb == "excopy") {
            X7Close();
            string path = UnB64(arg);
            string leaf = Path.GetFileName(Path.GetDirectoryName(path));
            Process.Start("explorer.exe", "/select,\"" + path + "\"");
            WhenWindow("excopy", delegate { return FindWindow("CabinetWClass", leaf); }, delegate (IntPtr h) {
                x7Explorer = h; Chord(0x43, 0x2E);
            });
        } else if (verb == "mix") {
            string[] a = arg.Split(' ');
            int ms = int.Parse(a[1]);
            SetFiles(Set40(@"C:\i8\src\gw1A"));
            Log("mix " + a[0] + " A set");
            // Optional third/fourth argument: another B folder and file prefix (other names).
            string dirB = a.Length > 3 ? @"C:\i8\src\" + a[2] : @"C:\i8\src\gw1B", prefixB = a.Length > 3 ? a[3] : "f";
            Later(ms, delegate { SetFiles(Set40(dirB, prefixB)); Log("mix " + a[0] + " B set after=" + ms + " dir=" + dirB); });
        } else if (verb == "fileimg") {
            string[] a = arg.Split(' ');
            SetFiles(new[] { UnB64(a[0]) });
            Log("fileimg files set");
            Later(int.Parse(a[1]), delegate {
                var bmp = new Bitmap(64, 64);
                using (var g = Graphics.FromImage(bmp)) g.Clear(Color.OrangeRed);
                Clipboard.SetImage(bmp);
                Log("fileimg image set");
            });
        } else if (verb == "flip") {
            string[] a = arg.Split(' ');
            string t = "M4-" + a[1];
            int ms = int.Parse(a[2]);
            if (a[0] == "ft") {
                SetFiles(new[] { @"C:\i8\src\multi\small.txt" }); Log("flip ft files");
                Later(ms, delegate { Copy(t); Log("flip ft text " + t); });
            } else {
                Copy(t); Log("flip tf text " + t);
                Later(ms, delegate { SetFiles(new[] { @"C:\i8\src\multi\small.txt" }); Log("flip tf files"); });
            }
        } else if (verb == "hold") {
            string[] a = arg.Split(' ');
            string path = UnB64(a[0]);
            SetFiles(new[] { path });
            Log("hold files set");
            int hold = int.Parse(a[2]);
            Later(int.Parse(a[1]), delegate {
                try {
                    var held = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
                    Log("hold opened");
                    Later(hold, delegate { held.Close(); Log("hold closed"); });
                } catch (Exception ex) { Log("hold failed " + ex.GetType().Name + " " + B64(ex.Message)); }
            });
        } else if (verb == "del") {
            string[] a = arg.Split(' ');
            string path = UnB64(a[0]);
            SetFiles(new[] { path });
            Log("del files set");
            Later(int.Parse(a[1]), delegate {
                try { File.Delete(path); Log("del ok exists=" + File.Exists(path)); }
                catch (Exception ex) { Log("del failed " + ex.GetType().Name + " " + B64(ex.Message)); }
            });
        } else if (verb == "trunc") {
            string[] a = arg.Split(' ');
            string path = UnB64(a[0]);
            SetFiles(new[] { path });
            Log("trunc files set");
            long bytes = long.Parse(a[2]);
            Later(int.Parse(a[1]), delegate {
                try {
                    using (var cut = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) cut.SetLength(bytes);
                    Log("trunc ok len=" + new FileInfo(path).Length);
                } catch (Exception ex) { Log("trunc failed " + ex.GetType().Name + " " + B64(ex.Message)); }
            });
        } else if (verb == "sound") {
            int seconds = int.Parse(arg);
            player = new SoundPlayer(new MemoryStream(Tone(2)));
            player.PlayLooping();
            soundUntil = clock.ElapsedMilliseconds + seconds * 1000L;
            Log("sound start s=" + seconds);
        }
    }

    static string Tree(string root, bool hashes, out int count, out long bytes) {
        var sb = new StringBuilder();
        count = 0; bytes = 0;
        var entries = new List<string>(Directory.GetFileSystemEntries(root, "*", SearchOption.AllDirectories));
        entries.Sort(StringComparer.Ordinal);
        foreach (string e in entries) {
            count++;
            string rel = e.Substring(root.Length + 1);
            if (Directory.Exists(e)) { sb.Append(" d:" + B64(rel)); continue; }
            long len = new FileInfo(e).Length;
            bytes += len;
            sb.Append(" f:" + B64(rel) + ":" + len);
            if (hashes) {
                try { sb.Append(":" + FileSha(e)); } catch (IOException) { sb.Append(":locked"); }
            }
        }
        return sb.ToString();
    }

    static void Tick() {
        try { TickBody(); } catch (Exception ex) { Log("tick error " + ex.GetType().Name + " " + ex.Message); pasteState = 0; }
    }

    static void TickBody() {
        long now = clock.ElapsedMilliseconds;
        uint seq = GetClipboardSequenceNumber();
        if (seq != lastSeq) {
            lastSeq = seq;
            Log("seq " + seq + " owner=" + Owner());
            try {
                IDataObject d = Clipboard.GetDataObject();
                string formats = d == null ? "" : string.Join(",", d.GetFormats(false));
                if (Clipboard.ContainsText()) {
                    string t = Clipboard.GetText();
                    byte[] u = Encoding.UTF8.GetBytes(t);
                    Log("clip text len=" + t.Length + " sha=" + Sha(u) + " head=" + B64(t.Length > 200 ? t.Substring(0, 200) : t));
                    if (t.StartsWith("I8CMD ")) Command(t);
                } else {
                    Log("clip formats=" + formats);
                    if (pasteState == 2 && formats.Contains("FileGroupDescriptorW")) { pasteState = 3; stateSince = now; }
                }
            } catch (Exception ex) { Log("clip error " + ex.GetType().Name); }
        }
        if (pasteState == 1) {
            pasteWindow = FindWindow("CabinetWClass", pasteLeaf);
            if (pasteWindow != IntPtr.Zero) { ShowWindow(pasteWindow, 3); Log("explorer ready"); pasteState = 2; stateSince = now; }
            else if (now - stateSince > 15000) { Log("explorer missing"); pasteState = 0; }
        } else if (pasteState == 2 && now - stateSince > 120000) {
            Log("paste no files"); pasteState = 0;
        } else if (pasteState == 3 && now - stateSince > 1500) {
            IntPtr h = FindWindow("CabinetWClass", pasteLeaf);
            RECT r;
            if (h != IntPtr.Zero && GetWindowRect(h, out r)) {
                SetForegroundWindow(h);
                System.Threading.Thread.Sleep(300);
                SetCursorPos(r.left + (r.right - r.left) * 3 / 4, r.top + (r.bottom - r.top) * 3 / 4);
                mouse_event(2, 0, 0, 0, IntPtr.Zero); mouse_event(4, 0, 0, 0, IntPtr.Zero);
                System.Threading.Thread.Sleep(300);
                // keybd_event, not SendKeys.SendWait: SendWait did not return while Explorer pasted.
                keybd_event(0x11, 0x1D, 0, IntPtr.Zero); keybd_event(0x56, 0x2F, 0, IntPtr.Zero);
                keybd_event(0x56, 0x2F, 2, IntPtr.Zero); keybd_event(0x11, 0x1D, 2, IntPtr.Zero);
                Log("paste sent");
            } else Log("paste window lost");
            pasteState = 4; stateSince = now; lastChange = now; lastSignature = "";
        } else if (pasteState == 4 && now - stateSince >= 1000 && (now / 1000) != ((now - 100) / 1000)) {
            int count; long bytes;
            string sig = Tree(pasteDir, false, out count, out bytes);
            if (sig != lastSignature) { lastSignature = sig; lastChange = now; }
            // Ctrl+V sometimes does not reach Explorer (nothing appears): send it once more.
            if (count == 0 && !pasteRetried && now - stateSince > 20000) { pasteRetried = true; Log("paste retry"); pasteState = 3; stateSince = now - 1500; return; }
            bool hasDialog = Dialogs() != "none";
            if ((count > 0 && now - lastChange > 8000) || (hasDialog && now - stateSince > 10000 && now - lastChange > 8000) || now - stateSince > 900000) {
                string tree = Tree(pasteDir, true, out count, out bytes);
                // Explorer sets the full length up front and keeps the file open while it copies:
                // a stable size is not the end of the copy while a file is still locked.
                if (tree.Contains(":locked") && now - stateSince <= 900000) { lastChange = now; return; }
                Log("dialogs " + Dialogs());
                Log("tree " + pasteLeaf + " n=" + count + " bytes=" + bytes + tree);
                Copy("I8DONE " + pasteLeaf + " n=" + count + " bytes=" + bytes);
                pasteState = 0;
            }
        }
        if (player != null && now > soundUntil) { player.Stop(); player = null; Log("sound stop"); }
        if (now > 20 * 60 * 1000) Application.Exit();
    }

    public static void Main() {
        SetProcessDPIAware();
        run = File.Exists(@"C:\i8\runid.txt") ? File.ReadAllText(@"C:\i8\runid.txt").Trim() : "none";
        Directory.CreateDirectory(@"C:\i8\out");
        log = new StreamWriter(@"C:\i8\out\" + run + ".log", true, new UTF8Encoding(false));
        Log("start run=" + run);
        var form = new I8Form { FormBorderStyle = FormBorderStyle.None, TopMost = true, StartPosition = FormStartPosition.Manual,
                                Location = new Point(0, 0), Size = new Size(600, 300), BackColor = Color.LightSteelBlue, Text = "I8 Probe" };
        form.Controls.Add(new Label { Text = "I8 probe " + run, AutoSize = true, Location = new Point(10, 10) });
        var timer = new Timer { Interval = 100 };
        timer.Tick += delegate { Tick(); };
        form.Shown += delegate { lastSeq = GetClipboardSequenceNumber(); Copy("I8READY " + run); timer.Start(); };
        Application.Run(form);
        Log("exit");
        log.Close();
    }
}
'@
[I8Probe]::Main()
