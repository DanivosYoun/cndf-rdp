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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);
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
    static SoundPlayer player;
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
            pasteState = 1; stateSince = clock.ElapsedMilliseconds;
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
        long now = clock.ElapsedMilliseconds;
        uint seq = GetClipboardSequenceNumber();
        if (seq != lastSeq) {
            lastSeq = seq;
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
                SendKeys.SendWait("^v");
                Log("paste sent");
            } else Log("paste window lost");
            pasteState = 4; stateSince = now; lastChange = now; lastSignature = "";
        } else if (pasteState == 4 && now - stateSince >= 1000 && (now / 1000) != ((now - 100) / 1000)) {
            int count; long bytes;
            string sig = Tree(pasteDir, false, out count, out bytes);
            if (sig != lastSignature) { lastSignature = sig; lastChange = now; }
            if ((count > 0 && now - lastChange > 8000) || now - stateSince > 900000) {
                string tree = Tree(pasteDir, true, out count, out bytes);
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
