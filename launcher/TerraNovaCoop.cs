// Terra Nova Coop: one window, two buttons. It installs what each player needs in its own folder (Uplink's coop
// branch, Godot, the TN+ coop build, an embedded Python for the host's bridge), keeps both PCs on the same version
// and starts everything in the right order:
//   HOST: the game through TN+ Coop (no menu), then the bridge, which opens Uplink with the Steam lobby.
//   JOIN: Uplink's guest window, where the friends hosting a game show up with a JOIN button.
// Built with the C# compiler that comes with Windows (.NET Framework 4.5+): build.bat.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

static class Coop
{
    const string TITLE = "Terra Nova Coop";
    const string VERSION = "0.1";
    const string UPLINK_REPO = "skw-1337/terra-nova-uplink", TNPLUS_REPO = "skw-1337/terra-nova-plus", BRANCH = "coop";
    const string GODOT_VER = "4.7.2";
    const string GODOT_URL = "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip";
    const string PY_URL = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip";
    static readonly string[][] WHEELS = {           // pinned: the bridge's only two packages, as wheels for Python 3.12 x64
        new[] { "numpy", "2.5.4", "-cp312-cp312-win_amd64.whl" },
        new[] { "psutil", "7.2.2", "-cp37-abi3-win_amd64.whl" } };
    const string DISCORD = "https://discord.gg/AHpqNeT7s";
    const string GOG_ID = "1434984562";
    const string GAME_SUB = "Terra Nova Strike Force Centauri";

    static readonly Color CBack = Color.FromArgb(9, 17, 16), CPanel = Color.FromArgb(22, 41, 38), CField = Color.FromArgb(12, 26, 24);
    static readonly Color CText = Color.FromArgb(214, 226, 220), CDim = Color.FromArgb(122, 150, 142), CAmber = Color.FromArgb(240, 178, 48);
    static readonly Color CGreen = Color.FromArgb(56, 214, 92), CRed = Color.FromArgb(236, 72, 60), CBlue = Color.FromArgb(38, 76, 178);

    static string Root, Comp, Ini, LogPath;
    static Dictionary<string, string> cfg = new Dictionary<string, string>();
    static Form form;
    static Label gameLabel, statusLabel, verLabel;
    static Label[] checks;
    static Button hostBtn, joinBtn, stopBtn, gameBtn;
    static ProgressBar bar;
    static TextBox logBox;
    static volatile bool busy, stopping;
    static readonly List<Process> mine = new List<Process>();

    [STAThread]
    static void Main()
    {
        Root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        Comp = Path.Combine(Root, "components");
        Ini = Path.Combine(Root, "TerraNovaCoop.ini");
        Directory.CreateDirectory(Path.Combine(Comp, "logs"));
        LogPath = Path.Combine(Comp, "logs", "launcher.log");
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;   // TLS 1.2 (GitHub, python.org, PyPI)
        LoadCfg();
        string[] args = Environment.GetCommandLineArgs();
        if (args.Length > 2 && args[1] == "--install")    // checks: install / update only, no window (exit code 0 = ok)
        {
            try { Install(args[2] == "host"); Console.WriteLine("installed"); Environment.Exit(0); }
            catch (Exception e) { Log(e.ToString()); Environment.Exit(1); }
        }
        Application.EnableVisualStyles();
        Build();
        form.Shown += delegate { Refresh(); new Thread(CheckUpdates) { IsBackground = true }.Start(); };
        form.FormClosing += delegate { stopping = true; };
        Application.Run(form);
    }

    // ------------------------------------------------------------------ window
    static void Build()
    {
        form = new Form();
        form.Text = TITLE;
        form.ClientSize = new Size(640, 560);
        form.FormBorderStyle = FormBorderStyle.FixedSingle;
        form.MaximizeBox = false;
        form.StartPosition = FormStartPosition.CenterScreen;
        form.BackColor = CBack;
        form.ForeColor = CText;
        form.Font = new Font("Segoe UI", 10f);
        try { form.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        Label t = new Label { Text = "TERRA NOVA  ·  COOP", Font = new Font("Segoe UI", 22f, FontStyle.Bold), ForeColor = CAmber,
            AutoSize = true, Location = new Point(22, 16) };
        form.Controls.Add(t);
        Label sub = new Label { Text = "Two players, one mission, over Steam. The host plays the game, the guest drives a squadmate.",
            ForeColor = CDim, AutoSize = true, Location = new Point(25, 60) };
        form.Controls.Add(sub);

        Panel gp = new Panel { Location = new Point(22, 92), Size = new Size(596, 34), BackColor = CField };
        form.Controls.Add(gp);
        gameLabel = new Label { Location = new Point(8, 7), Size = new Size(480, 22), ForeColor = CText };
        gp.Controls.Add(gameLabel);
        gameBtn = Flat("Change...", CPanel);
        gameBtn.Location = new Point(494, 3); gameBtn.Size = new Size(98, 28);
        gameBtn.Click += delegate { PickGame(); };
        gp.Controls.Add(gameBtn);

        hostBtn = Flat("HOST A GAME", Color.FromArgb(20, 80, 74));
        hostBtn.Font = new Font("Segoe UI", 15f, FontStyle.Bold);
        hostBtn.Location = new Point(22, 140); hostBtn.Size = new Size(290, 86);
        hostBtn.Click += delegate { Start(true); };
        form.Controls.Add(hostBtn);
        joinBtn = Flat("JOIN A FRIEND", CBlue);
        joinBtn.Font = new Font("Segoe UI", 15f, FontStyle.Bold);
        joinBtn.Location = new Point(328, 140); joinBtn.Size = new Size(290, 86);
        joinBtn.Click += delegate { Start(false); };
        form.Controls.Add(joinBtn);
        Label hh = new Label { Text = "You play the game. Your friend joins you.", ForeColor = CDim, AutoSize = true, Location = new Point(24, 230) };
        Label jh = new Label { Text = "You drive one of your friend's squadmates.", ForeColor = CDim, AutoSize = true, Location = new Point(330, 230) };
        form.Controls.Add(hh); form.Controls.Add(jh);

        string[] names = { "Uplink (coop)", "Godot " + GODOT_VER, "TN+ Coop (host)", "Python (host)" };
        checks = new Label[names.Length];
        for (int i = 0; i < names.Length; i++)
        {
            checks[i] = new Label { AutoSize = true, Location = new Point(24 + (i % 2) * 306, 262 + (i / 2) * 22), ForeColor = CDim };
            checks[i].Tag = names[i];
            form.Controls.Add(checks[i]);
        }
        verLabel = new Label { AutoSize = true, Location = new Point(24, 308), ForeColor = CDim };
        form.Controls.Add(verLabel);

        statusLabel = new Label { Location = new Point(22, 334), Size = new Size(596, 44), ForeColor = CAmber,
            Font = new Font("Segoe UI", 11f, FontStyle.Bold) };
        form.Controls.Add(statusLabel);
        bar = new ProgressBar { Location = new Point(22, 380), Size = new Size(596, 10), Style = ProgressBarStyle.Continuous };
        form.Controls.Add(bar);
        logBox = new TextBox { Location = new Point(22, 398), Size = new Size(596, 112), Multiline = true, ReadOnly = true,
            ScrollBars = ScrollBars.Vertical, BackColor = CField, ForeColor = CDim, BorderStyle = BorderStyle.None,
            Font = new Font("Consolas", 8.5f) };
        form.Controls.Add(logBox);
        stopBtn = Flat("Stop", CPanel);
        stopBtn.Location = new Point(518, 518); stopBtn.Size = new Size(100, 30);
        stopBtn.Click += delegate { StopAll(); };
        form.Controls.Add(stopBtn);
        Label help = new Label { Text = "Both players: Steam running, each other in your friends list, your own copy of the game (English).",
            ForeColor = CDim, AutoSize = true, Location = new Point(22, 516), Font = new Font("Segoe UI", 8.5f) };
        form.Controls.Add(help);
        LinkLabel dc = new LinkLabel { Text = "Help, bugs, finding a partner: Discord", AutoSize = true, Location = new Point(22, 535),
            Font = new Font("Segoe UI", 8.5f), LinkColor = CAmber, ActiveLinkColor = Color.White, VisitedLinkColor = CAmber };
        dc.LinkArea = new LinkArea(dc.Text.IndexOf("Discord"), 7);
        dc.LinkClicked += delegate { try { Process.Start(DISCORD); } catch { } };
        form.Controls.Add(dc);
    }

    static Button Flat(string text, Color back)
    {
        Button b = new Button { Text = text, FlatStyle = FlatStyle.Flat, BackColor = back, ForeColor = Color.White, Cursor = Cursors.Hand };
        b.FlatAppearance.BorderSize = 0;
        b.FlatAppearance.MouseOverBackColor = ControlPaint.Light(back, 0.25f);
        return b;
    }

    static void Ui(Action a)
    {
        if (form == null || form.IsDisposed) return;
        try { if (form.InvokeRequired) form.BeginInvoke(a); else a(); } catch { }
    }

    static void Status(string s, Color c) { Ui(delegate { statusLabel.Text = s; statusLabel.ForeColor = c; }); Log("== " + s); }
    static void Progress(int pct) { Ui(delegate { bar.Value = Math.Max(0, Math.Min(100, pct)); }); }

    static void Log(string s)
    {
        string line = DateTime.Now.ToString("HH:mm:ss") + "  " + s;
        try { File.AppendAllText(LogPath, line + "\r\n"); } catch { }
        Ui(delegate {
            logBox.AppendText(line + "\r\n");
            if (logBox.Lines.Length > 400) logBox.Lines = logBox.Lines;   // the box keeps scrolling to the end
        });
    }

    static void Refresh()
    {
        string g = Game();
        bool en = g != null && IsEnglish(g);
        gameLabel.Text = g == null ? "Game: not found - click Change... and pick the folder that contains TNOVA" :
            (en ? "Game: " : "Not the English game (co-op needs it): ") + g;
        gameLabel.ForeColor = en ? CText : CRed;
        bool[] have = { File.Exists(Path.Combine(UplinkDir, "project.godot")), File.Exists(GodotExe), File.Exists(TnpExe), File.Exists(PythonExe) };
        for (int i = 0; i < checks.Length; i++)
        {
            checks[i].Text = (have[i] ? "●  " : "○  ") + checks[i].Tag + (have[i] ? "" : "  (installed when needed)");
            checks[i].ForeColor = have[i] ? CGreen : CDim;
        }
        hostBtn.Enabled = joinBtn.Enabled = gameBtn.Enabled = !busy;
        if (statusLabel.Text == "")
        {
            statusLabel.Text = "Ready. One of you clicks HOST A GAME, the other JOIN A FRIEND.";
            statusLabel.ForeColor = CText;
        }
    }

    // ------------------------------------------------------------------ settings
    static void LoadCfg()
    {
        if (!File.Exists(Ini)) return;
        foreach (string l in File.ReadAllLines(Ini))
        {
            int e = l.IndexOf('=');
            if (e > 0 && !l.StartsWith(";")) cfg[l.Substring(0, e).Trim()] = l.Substring(e + 1).Trim();
        }
    }

    static void SaveCfg()
    {
        StringBuilder sb = new StringBuilder("; Terra Nova Coop\r\n");
        foreach (KeyValuePair<string, string> kv in cfg) sb.Append(kv.Key + " = " + kv.Value + "\r\n");
        try { File.WriteAllText(Ini, sb.ToString()); } catch { }
    }

    static string Cfg(string k) { string v; return cfg.TryGetValue(k, out v) ? v : ""; }

    static string UplinkDir { get { return Path.Combine(Comp, "uplink"); } }
    static string GodotExe { get { return Path.Combine(Comp, "godot", "Godot_v" + GODOT_VER + "-stable_win64.exe"); } }
    static string TnpDir { get { return Path.Combine(Comp, "tnplus"); } }
    static string TnpExe { get { return Path.Combine(TnpDir, "TNPlus.exe"); } }
    static string PythonExe { get { return Path.Combine(Comp, "python", "python.exe"); } }

    // ------------------------------------------------------------------ the game folder (GOG, Steam, or picked)
    static bool IsGame(string d) { return d != "" && File.Exists(Path.Combine(d, "TNOVA", "DATA", "RESMISS.RES")); }

    const long EN_EXE = 1856641;      // __FF.EXE v1.09 English (Steam, GOG); the French one is 1856813
    static bool IsEnglish(string d)
    {   // the co-op code only knows the English exe; TN+ keeps the original next to its patched copy
        foreach (string f in new[] { "__FF.EXE.tnplus-original", "__FF.EXE" })
        {
            string p = Path.Combine(d, "TNOVA", f);
            if (File.Exists(p)) return new FileInfo(p).Length == EN_EXE;
        }
        return false;
    }

    static string Game()
    {
        string g = Cfg("game_dir");
        if (IsGame(g)) return g;
        string any = null;
        foreach (string c in Candidates())
            if (IsGame(c))
            {
                if (IsEnglish(c)) { cfg["game_dir"] = c; SaveCfg(); return c; }
                if (any == null) any = c;
            }
        return any;                      // not English: shown in red, the user can pick another one
    }

    static IEnumerable<string> Candidates()
    {
        List<string> l = new List<string>();
        foreach (string k in new[] { @"SOFTWARE\WOW6432Node\GOG.com\Games\" + GOG_ID, @"SOFTWARE\GOG.com\Games\" + GOG_ID })
            try { using (RegistryKey r = Registry.LocalMachine.OpenSubKey(k)) if (r != null && r.GetValue("path") != null) l.Add((string)r.GetValue("path")); }
            catch { }
        try
        {
            using (RegistryKey r = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam"))
                if (r != null && r.GetValue("SteamPath") != null)
                {
                    string sp = ((string)r.GetValue("SteamPath")).Replace('/', '\\');
                    l.Add(Path.Combine(sp, "steamapps", "common", GAME_SUB));
                    string vdf = Path.Combine(sp, "steamapps", "libraryfolders.vdf");
                    if (File.Exists(vdf))
                        foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                            l.Add(Path.Combine(m.Groups[1].Value.Replace("\\\\", "\\"), "steamapps", "common", GAME_SUB));
                }
        }
        catch { }
        l.Add(@"C:\Program Files (x86)\GOG Galaxy\Games\" + GAME_SUB);
        l.Add(@"C:\GOG Games\" + GAME_SUB);
        return l;
    }

    static void PickGame()
    {
        using (FolderBrowserDialog d = new FolderBrowserDialog())
        {
            d.Description = "Pick the Terra Nova folder (the one that contains TNOVA)";
            if (d.ShowDialog(form) != DialogResult.OK) return;
            string p = d.SelectedPath;
            if (!IsGame(p) && IsGame(Path.GetDirectoryName(p) ?? "")) p = Path.GetDirectoryName(p);
            if (!IsGame(p)) { MessageBox.Show(form, "No TNOVA\\DATA\\RESMISS.RES in that folder.", TITLE); return; }
            cfg["game_dir"] = p; SaveCfg(); Refresh();
        }
    }

    // ------------------------------------------------------------------ host / join
    static void Start(bool host)
    {
        if (busy) return;
        if (Game() == null) { PickGame(); if (Game() == null) return; }
        busy = true; stopping = false;
        Refresh();
        new Thread(delegate () {
            try { if (host) Host(); else Join(); }
            catch (Exception e) { Status("Stopped: " + e.Message, CRed); Log(e.ToString()); }
            busy = false;
            Ui(Refresh);
        }) { IsBackground = true }.Start();
    }

    static void Host()
    {
        Status("Getting things ready...", CAmber);
        Install(true);
        if (!SteamUp()) return;
        string game = Game();
        WriteTnpIni(game);
        Process tnp = null;
        if (Process.GetProcessesByName("dosbox-staging").Length > 0)
            Log("DOSBox is already running: TN+ Coop attaches to it");
        Status("Starting the game (TN+ Coop)...", CAmber);
        tnp = Run(TnpExe, "--launch", TnpDir, null, false);
        // the bridge needs the game's code loaded: tried every few seconds until it stays up
        Status("Waiting for the game to load...", CAmber);
        Process bridge = null;
        DateTime t0 = DateTime.Now;
        while (!stopping)
        {
            if (tnp.HasExited && Process.GetProcessesByName("dosbox-staging").Length == 0)
            { Status("The game was closed.", CText); return; }
            if ((DateTime.Now - t0).TotalMinutes > 5) { Status("The game didn't load in 5 minutes: see the log below.", CRed); return; }
            Thread.Sleep(3000);
            bridge = Bridge();
            DateTime b0 = DateTime.Now;
            while (!bridge.HasExited && (DateTime.Now - b0).TotalSeconds < 12) Thread.Sleep(250);
            if (!bridge.HasExited) break;
            Log("bridge not ready yet (" + bridge.ExitCode + "), trying again");
        }
        if (stopping || bridge == null) return;
        Status("Uplink is open. Invite your friend from the list at the top right of its window, " +
               "then go to Mission Outfitting and wait for him to press READY.", CGreen);
        while (!stopping && !bridge.HasExited) Thread.Sleep(500);
        if (!stopping) Status(tnp.HasExited ? "The game was closed. Session over." : "Uplink was closed. Click HOST A GAME to open it again.", CText);
    }

    static Process Bridge()
    {
        Dictionary<string, string> env = Env();
        env["PYTHONIOENCODING"] = "utf-8";
        env["PYTHONUNBUFFERED"] = "1";
        return Run(PythonExe, "-u \"" + Path.Combine(UplinkDir, "live", "live_bridge.py") +
            "\" --launch --hud --play --guest-remote --fov 91.5 --res 1696x960", UplinkDir, env, true);
    }

    static void Join()
    {
        Status("Getting things ready...", CAmber);
        Install(false);
        if (!SteamUp()) return;
        Status("Opening Uplink...", CAmber);
        Process g = Run(GodotExe, "--path \"" + UplinkDir + "\" --resolution 1280x720 -- --live --coop-guest --live-port 47831 --play --play-port 47834",
            UplinkDir, Env(), true);
        Status("Uplink is open. Click JOIN next to your friend's name in its window (he must have clicked HOST A GAME).", CGreen);
        while (!stopping && !g.HasExited) Thread.Sleep(500);
        if (!stopping) Status("Uplink was closed.", CText);
    }

    static Dictionary<string, string> Env()
    {
        Dictionary<string, string> env = new Dictionary<string, string>();
        env["GODOT"] = GodotExe;
        env["TN_GAME_DIR"] = Game();
        return env;
    }

    static bool SteamUp()
    {
        if (Process.GetProcessesByName("steam").Length > 0) return true;
        Status("Starting Steam...", CAmber);
        try { Process.Start("steam://open/main"); } catch { }
        for (int i = 0; i < 60 && !stopping; i++)
        {
            Thread.Sleep(1000);
            if (Process.GetProcessesByName("steam").Length > 0) { Thread.Sleep(8000); return true; }
        }
        Status("Steam isn't running: start it, log in, then click again.", CRed);
        return false;
    }

    static Process Run(string exe, string args, string dir, Dictionary<string, string> env, bool capture)
    {
        ProcessStartInfo psi = new ProcessStartInfo(exe, args);
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = false;
        if (env != null) foreach (KeyValuePair<string, string> kv in env) psi.EnvironmentVariables[kv.Key] = kv.Value;
        if (capture)
        {
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = psi.StandardErrorEncoding = Encoding.UTF8;
        }
        Log("> " + Path.GetFileName(exe) + " " + args);
        Process p = Process.Start(psi);
        if (capture)
        {
            string tag = Path.GetFileNameWithoutExtension(exe).Split('_')[0];
            p.OutputDataReceived += (s, e) => { if (e.Data != null && Useful(e.Data)) Log(tag + ": " + e.Data); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null && e.Data.Trim() != "") Log(tag + "! " + e.Data); };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
        }
        lock (mine) mine.Add(p);
        return p;
    }

    static bool Useful(string l)
    {   // the bridge prints its camera every frame: only the coop and start-up lines
        return !(l.StartsWith("x ") || l.Trim() == "" || l.StartsWith("Godot Engine") || l.StartsWith("Vulkan"));
    }

    static void StopAll()
    {
        stopping = true;
        lock (mine)
        {
            foreach (Process p in mine)
                try { if (!p.HasExited) { p.CloseMainWindow(); if (!p.WaitForExit(1500)) p.Kill(); } } catch { }
            mine.Clear();
        }
        Status("Stopped.", CText);
    }

    // ------------------------------------------------------------------ TN+ Coop settings: HD 848x480 (the live mode's)
    static void WriteTnpIni(string game)
    {
        string ini = Path.Combine(TnpDir, "TNPlus.ini");
        Dictionary<string, string> want = new Dictionary<string, string> {
            { "display", "HD" }, { "widescreen", "2" }, { "update_check", "0" }, { "game_dir", game } };
        List<string> lines = File.Exists(ini) ? new List<string>(File.ReadAllLines(ini)) : new List<string> { "; Terra Nova Plus settings (written by Terra Nova Coop)" };
        foreach (KeyValuePair<string, string> kv in want)
        {
            int at = lines.FindIndex(l => Regex.IsMatch(l, "^\\s*" + kv.Key + "\\s*="));
            string line = kv.Key + " = " + kv.Value;
            if (at >= 0) lines[at] = line; else lines.Add(line);
        }
        File.WriteAllLines(ini, lines);
    }

    // ------------------------------------------------------------------ install and update
    static void Install(bool host)
    {
        Dictionary<string, string> heads = Heads();
        string up = Get(heads, UPLINK_REPO);
        if (!File.Exists(Path.Combine(UplinkDir, "project.godot")) || (up != null && up != Cfg("uplink_sha")))
        {
            Status("Downloading Uplink (coop)...", CAmber);
            Repo(UPLINK_REPO, UplinkDir);
            if (up != null) cfg["uplink_sha"] = up;
            SaveCfg();
        }
        if (!File.Exists(GodotExe))
        {
            Status("Downloading Godot " + GODOT_VER + " (about 90 MB, once)...", CAmber);
            string z = Download(GODOT_URL, "godot.zip");
            Unzip(z, Path.GetDirectoryName(GodotExe));
            File.Delete(z);
        }
        if (host)
        {
            string tp = Get(heads, TNPLUS_REPO);
            if (!File.Exists(TnpExe) || (tp != null && tp != Cfg("tnplus_sha")))
            {
                Status("Downloading and building TN+ Coop...", CAmber);
                BuildTnp();
                if (tp != null) cfg["tnplus_sha"] = tp;
                SaveCfg();
            }
            if (!File.Exists(PythonExe) || !File.Exists(Path.Combine(Comp, "python", "Lib", "site-packages", "psutil", "__init__.py")))
            {
                Status("Downloading Python for the bridge (about 30 MB, once)...", CAmber);
                InstallPython();
            }
        }
        Ui(Refresh);
        Progress(0);
    }

    static Dictionary<string, string> Heads()
    {   // the coop branches' last commits: both PCs must run the same files
        Dictionary<string, string> d = new Dictionary<string, string>();
        foreach (string r in new[] { UPLINK_REPO, TNPLUS_REPO })
            try
            {
                string j = Text("https://api.github.com/repos/" + r + "/commits/" + BRANCH);
                Match m = Regex.Match(j, "\"sha\"\\s*:\\s*\"([0-9a-f]{40})\"");
                if (m.Success) d[r] = m.Groups[1].Value;
            }
            catch (Exception e) { Log("GitHub not reachable (" + e.Message + "): keeping the installed files"); }
        return d;
    }

    static string Get(Dictionary<string, string> d, string k) { string v; return d.TryGetValue(k, out v) ? v : null; }

    static void CheckUpdates()
    {
        Dictionary<string, string> h = Heads();
        string up = Get(h, UPLINK_REPO);
        Ui(delegate {
            if (up == null) verLabel.Text = "Couldn't check for updates (offline?).";
            else if (Cfg("uplink_sha") == "") verLabel.Text = "Uplink coop " + up.Substring(0, 7) + " will be installed.";
            else if (up == Cfg("uplink_sha")) verLabel.Text = "Up to date (Uplink coop " + up.Substring(0, 7) + ").";
            else verLabel.Text = "Update available: it's installed when you click HOST or JOIN (both PCs need the same).";
            verLabel.ForeColor = up != null && up != Cfg("uplink_sha") && Cfg("uplink_sha") != "" ? CAmber : CDim;
        });
    }

    static void Repo(string repo, string dest)
    {
        string z = Download("https://github.com/" + repo + "/archive/refs/heads/" + BRANCH + ".zip", "repo.zip");
        string tmp = Path.Combine(Comp, "tmp");
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        Unzip(z, tmp);
        File.Delete(z);
        string top = Directory.GetDirectories(tmp)[0];
        if (Directory.Exists(dest)) Directory.Delete(dest, true);
        Directory.Move(top, dest);
        Directory.Delete(tmp, true);
    }

    static void BuildTnp()
    {
        string src = Path.Combine(Comp, "tnplus_src");
        Repo(TNPLUS_REPO, src);
        string bat = Path.Combine(src, "src", "build.bat");
        string cmd = File.ReadAllText(bat);
        Match m = Regex.Match(cmd, "(?m)^\"%CSC%\"([^\\r\\n]+)");   // build.bat's compiler line, without its pause
        if (!m.Success) throw new Exception("TN+ build.bat not understood");
        string csc = Path.Combine(Environment.GetEnvironmentVariable("WINDIR"), @"Microsoft.NET\Framework64\v4.0.30319\csc.exe");
        if (!File.Exists(csc)) csc = Path.Combine(Environment.GetEnvironmentVariable("WINDIR"), @"Microsoft.NET\Framework\v4.0.30319\csc.exe");
        Process p = Run(csc, m.Groups[1].Value.Trim(), Path.Combine(src, "src"), null, true);
        p.WaitForExit();
        string built = Path.Combine(src, "src", "TNPlus.exe");
        if (p.ExitCode != 0 || !File.Exists(built)) throw new Exception("TN+ Coop didn't build (see the log)");
        Directory.CreateDirectory(TnpDir);
        File.Copy(built, TnpExe, true);       // TNPlus.ini and its coop copy of the game's exe stay in tnplus\
        foreach (string f in new[] { "awe32.raw" })
            if (File.Exists(Path.Combine(src, f))) File.Copy(Path.Combine(src, f), Path.Combine(TnpDir, f), true);
    }

    static void InstallPython()
    {
        string dir = Path.Combine(Comp, "python");
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
        string z = Download(PY_URL, "python.zip");
        Unzip(z, dir);
        File.Delete(z);
        string site = Path.Combine(dir, "Lib", "site-packages");
        Directory.CreateDirectory(site);
        foreach (string pth in Directory.GetFiles(dir, "python*._pth"))   // the embedded Python: add site-packages
            File.WriteAllText(pth, File.ReadAllText(pth).Replace("#import site", "import site") + "\r\nLib\\site-packages\r\n");
        foreach (string[] w in WHEELS)
        {
            string j = Text("https://pypi.org/pypi/" + w[0] + "/" + w[1] + "/json");
            Match m = Regex.Match(j, "\"url\"\\s*:\\s*\"(https://[^\"]+" + Regex.Escape(w[2]) + ")\"");
            if (!m.Success) throw new Exception(w[0] + " " + w[1] + ": no wheel for this Python");
            string wf = Download(m.Groups[1].Value, w[0] + ".whl");
            Unzip(wf, site);                   // a wheel is a zip of the package
            File.Delete(wf);
        }
        Process t = Run(PythonExe, "-c \"import numpy, psutil; print('python ok', numpy.__version__, psutil.__version__)\"", dir, null, true);
        t.WaitForExit();
        if (t.ExitCode != 0) throw new Exception("the embedded Python doesn't import numpy / psutil");
    }

    static string Text(string url)
    {
        using (WebClient c = new WebClient())
        {
            c.Headers[HttpRequestHeader.UserAgent] = TITLE + "/" + VERSION;
            c.Encoding = Encoding.UTF8;
            return c.DownloadString(url);
        }
    }

    static string Download(string url, string name)
    {
        string dest = Path.Combine(Comp, name);
        Log("download " + url);
        HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
        rq.UserAgent = TITLE + "/" + VERSION;
        using (WebResponse rs = rq.GetResponse())
        using (Stream s = rs.GetResponseStream())
        using (FileStream f = File.Create(dest))
        {
            long total = rs.ContentLength, got = 0;
            byte[] buf = new byte[1 << 16];
            int n, last = -1;
            while ((n = s.Read(buf, 0, buf.Length)) > 0)
            {
                if (stopping) throw new Exception("stopped");
                f.Write(buf, 0, n);
                got += n;
                int pct = total > 0 ? (int)(got * 100 / total) : (int)(got / 1000000 % 100);
                if (pct != last) { last = pct; Progress(pct); }
            }
        }
        return dest;
    }

    static void Unzip(string zip, string dest)
    {
        Directory.CreateDirectory(dest);
        using (ZipArchive a = ZipFile.OpenRead(zip))
            foreach (ZipArchiveEntry e in a.Entries)
            {
                string to = Path.GetFullPath(Path.Combine(dest, e.FullName));
                if (!to.StartsWith(Path.GetFullPath(dest), StringComparison.OrdinalIgnoreCase)) continue;   // no way out of dest
                if (e.FullName.EndsWith("/")) { Directory.CreateDirectory(to); continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(to));
                e.ExtractToFile(to, true);
            }
    }
}
