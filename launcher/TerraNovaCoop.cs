// Terra Nova Coop: one window, two buttons. It installs what each player needs in its own folder (Uplink's coop
// branch, Godot, the TN+ coop build, an embedded Python for the host's bridge), keeps both PCs on the same version
// (itself included: a newer launcher in Uplink's files is built and swapped in) and starts everything in order:
//   HOST: the game through TN+ Coop (no menu), then the bridge, which opens Uplink with the Steam lobby.
//   JOIN: Uplink's guest window, where the friends hosting a game show up with a JOIN button.
// What Uplink prints (its coop lines come through the bridge on the host) is turned into the session line.
// Built with the C# compiler that comes with Windows (.NET Framework 4.5+): build.bat.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Management;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

static class Coop
{
    const string TITLE = "Terra Nova Coop";
    const string VERSION = "0.8";
    const string UPLINK_REPO = "skw-1337/terra-nova-uplink", TNPLUS_REPO = "skw-1337/terra-nova-plus", BRANCH = "coop";
    const string DISCORD = "https://discord.gg/AHpqNeT7s";
    const string GODOT_VER = "4.7.2";
    const string GODOT_URL = "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip";
    const string PY_URL = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip";
    static readonly string[][] WHEELS = {           // pinned: the bridge's only two packages, as wheels for Python 3.12 x64
        new[] { "numpy", "2.5.4", "-cp312-cp312-win_amd64.whl" },
        new[] { "psutil", "7.2.2", "-cp37-abi3-win_amd64.whl" } };
    const string GOG_ID = "1434984562";
    const string GAME_SUB = "Terra Nova Strike Force Centauri";
    const long EN_EXE = 1856641;      // __FF.EXE v1.09 English (Steam, GOG); the French one is 1856813
    static readonly string[] SIZES = { "1280x720", "1696x960", "1920x1080", "native" };
    // campaign order (mission 1..37) -> MISSn.RES (as Uplink's tn_data.gd)
    static readonly int[] CAMPAIGN = { 37, 38, 1, 2, 3, 4, 5, 6, 7, 8, 9, 32, 33, 10, 11, 12, 13, 34, 29, 15, 17, 16, 36,
        14, 20, 39, 21, 35, 22, 23, 19, 24, 27, 25, 26, 30, 31 };
    const string COOP_SAVE = "COOP Mission ";

    static readonly Color CBack = Color.FromArgb(9, 17, 16), CPanel = Color.FromArgb(22, 41, 38), CField = Color.FromArgb(12, 26, 24);
    static readonly Color CText = Color.FromArgb(214, 226, 220), CDim = Color.FromArgb(122, 150, 142), CAmber = Color.FromArgb(240, 178, 48);
    static readonly Color CGreen = Color.FromArgb(56, 214, 92), CRed = Color.FromArgb(236, 72, 60), CBlue = Color.FromArgb(38, 76, 178);

    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out WRect r);
    [StructLayout(LayoutKind.Sequential)] struct WRect { public int Left, Top, Right, Bottom; }

    static string Root, Comp, Ini, LogPath;
    static Dictionary<string, string> cfg = new Dictionary<string, string>();
    static Form form;
    static Label gameLabel, statusLabel, verLabel, sessionLabel, sessionLed, sensLabel;
    static Label[] checks;
    static Button hostBtn, joinBtn, stopBtn, gameBtn, toolsBtn, reportBtn;
    static RadioButton modeCoop, modeVs;
    static ComboBox sizeBox, missionBox;
    static TrackBar sensBar;
    static CheckBox invertBox, padBox;
    static ProgressBar bar;
    static TextBox logBox;
    static volatile bool busy, stopping;
    static readonly List<Process> mine = new List<Process>();
    static string sessionName = "", sessionPing = "";

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
        if (args.Length > 1 && args[1] == "--report") { Report(); Environment.Exit(0); }   // the report, without the window
        if (args.Length > 3 && args[1] == "--roundtrip")   // checks: an LG Res file read and written back
        { Res.Load(args[2]).Save(args[3]); Environment.Exit(0); }
        if (args.Length > 3 && args[1] == "--makesave")    // checks: the COOP save of mission N into a copy of a TNOVA folder
        { Set("game_dir", args[3]); Console.WriteLine(MakeSave(args[3], int.Parse(args[2]) - 1) ?? "failed"); Environment.Exit(0); }
        try { File.Delete(Path.Combine(Root, "update.bat")); } catch { }
        Application.EnableVisualStyles();
        Build();
        form.Shown += delegate { RefreshUi(); new Thread(CheckUpdates) { IsBackground = true }.Start(); };
        form.FormClosing += delegate { SaveOptions(); stopping = true; };
        Application.Run(form);
    }

    // ------------------------------------------------------------------ window
    static void Build()
    {
        form = new Form();
        form.Text = TITLE + " " + VERSION;
        form.ClientSize = new Size(660, 754);
        form.FormBorderStyle = FormBorderStyle.FixedSingle;
        form.MaximizeBox = false;
        form.StartPosition = FormStartPosition.CenterScreen;
        form.BackColor = CBack;
        form.ForeColor = CText;
        form.Font = new Font("Segoe UI", 10f);
        try { form.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        int W = 616, X = 22;

        form.Controls.Add(new Label { Text = "TERRA NOVA  ·  COOP", Font = new Font("Segoe UI", 22f, FontStyle.Bold), ForeColor = CAmber,
            AutoSize = true, Location = new Point(X, 14) });
        form.Controls.Add(new Label { Text = "Two players, one mission, over Steam. The host plays the game, the guest drives a squadmate.",
            ForeColor = CDim, AutoSize = true, Location = new Point(X + 3, 58) });
        toolsBtn = Flat("Tools ▾", CPanel);
        toolsBtn.Location = new Point(X + W - 96, 20); toolsBtn.Size = new Size(96, 30);
        toolsBtn.Click += delegate { ToolsMenu().Show(toolsBtn, new Point(0, toolsBtn.Height)); };
        form.Controls.Add(toolsBtn);

        Panel gp = new Panel { Location = new Point(X, 88), Size = new Size(W, 34), BackColor = CField };
        form.Controls.Add(gp);
        gameLabel = new Label { Location = new Point(8, 7), Size = new Size(W - 116, 22), ForeColor = CText };
        gp.Controls.Add(gameLabel);
        gameBtn = Flat("Change...", CPanel);
        gameBtn.Location = new Point(W - 102, 3); gameBtn.Size = new Size(98, 28);
        gameBtn.Click += delegate { PickGame(); };
        gp.Controls.Add(gameBtn);

        hostBtn = Flat("HOST A GAME", Color.FromArgb(20, 80, 74));
        hostBtn.Font = new Font("Segoe UI", 15f, FontStyle.Bold);
        hostBtn.Location = new Point(X, 134); hostBtn.Size = new Size(300, 80);
        hostBtn.Click += delegate { Start(true); };
        form.Controls.Add(hostBtn);
        joinBtn = Flat("JOIN A FRIEND", CBlue);
        joinBtn.Font = new Font("Segoe UI", 15f, FontStyle.Bold);
        joinBtn.Location = new Point(X + W - 300, 134); joinBtn.Size = new Size(300, 80);
        joinBtn.Click += delegate { Start(false); };
        form.Controls.Add(joinBtn);
        form.Controls.Add(new Label { Text = "You play the game. Your friend joins you.",
            ForeColor = CDim, AutoSize = true, Location = new Point(X + 2, 218) });
        form.Controls.Add(new Label { Text = "You drive one of your friend's squadmates.",
            ForeColor = CDim, AutoSize = true, Location = new Point(X + W - 298, 218) });

        // options
        Panel op = new Panel { Location = new Point(X, 246), Size = new Size(W, 142), BackColor = CField };
        form.Controls.Add(op);
        op.Controls.Add(new Label { Text = "Mode (host)", ForeColor = CDim, AutoSize = true, Location = new Point(10, 10) });
        modeCoop = new RadioButton { Text = "Co-op", AutoSize = true, Location = new Point(124, 8), ForeColor = CText };
        modeVs = new RadioButton { Text = "1v1 (versus)", AutoSize = true, Location = new Point(200, 8), ForeColor = CText };
        op.Controls.Add(modeCoop); op.Controls.Add(modeVs);
        op.Controls.Add(new Label { Text = "Uplink window", ForeColor = CDim, AutoSize = true, Location = new Point(330, 10) });
        sizeBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Location = new Point(460, 6), Size = new Size(146, 24),
            BackColor = CPanel, ForeColor = CText, FlatStyle = FlatStyle.Flat };
        sizeBox.Items.AddRange(new object[] { "1280 x 720", "1696 x 960", "1920 x 1080", "Fullscreen" });
        op.Controls.Add(sizeBox);
        op.Controls.Add(new Label { Text = "Mouse", ForeColor = CDim, AutoSize = true, Location = new Point(10, 44) });
        sensBar = new TrackBar { Minimum = 2, Maximum = 30, TickFrequency = 2, Location = new Point(118, 38), Size = new Size(200, 30),
            BackColor = CField, AutoSize = false };
        sensBar.ValueChanged += delegate { sensLabel.Text = "x " + (sensBar.Value / 10.0).ToString("0.0", CultureInfo.InvariantCulture); };
        op.Controls.Add(sensBar);
        sensLabel = new Label { ForeColor = CText, AutoSize = true, Location = new Point(322, 44) };
        op.Controls.Add(sensLabel);
        invertBox = new CheckBox { Text = "Invert vertical", AutoSize = true, Location = new Point(400, 42), ForeColor = CText };
        op.Controls.Add(invertBox);
        padBox = new CheckBox { Text = "Use a gamepad (guest)", AutoSize = true, Location = new Point(10, 76), ForeColor = CText };
        op.Controls.Add(padBox);
        op.Controls.Add(new Label { Text = "Mission (host)", ForeColor = CDim, AutoSize = true, Location = new Point(10, 110) });
        missionBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Location = new Point(124, 106), Size = new Size(482, 24),
            BackColor = CPanel, ForeColor = CText, FlatStyle = FlatStyle.Flat, MaxDropDownItems = 20 };
        op.Controls.Add(missionBox);
        FillMissions();
        LoadOptions();

        string[] names = { "Uplink (coop)", "Godot " + GODOT_VER, "TN+ Coop (host)", "Python (host)" };
        checks = new Label[names.Length];
        for (int i = 0; i < names.Length; i++)
        {
            checks[i] = new Label { AutoSize = true, Location = new Point(X + 2 + (i % 2) * 310, 398 + (i / 2) * 21), ForeColor = CDim, Tag = names[i] };
            form.Controls.Add(checks[i]);
        }
        verLabel = new Label { AutoSize = true, Location = new Point(X + 2, 442), ForeColor = CDim };
        form.Controls.Add(verLabel);

        // the session: what Uplink says (lobby open, friend connected, ping...)
        Panel sp = new Panel { Location = new Point(X, 466), Size = new Size(W, 34), BackColor = CPanel };
        form.Controls.Add(sp);
        sessionLed = new Label { Text = "●", ForeColor = CDim, AutoSize = true, Location = new Point(8, 5), Font = new Font("Segoe UI", 12f) };
        sp.Controls.Add(sessionLed);
        sessionLabel = new Label { Location = new Point(32, 8), Size = new Size(W - 40, 22), ForeColor = CText, Text = "No session." };
        sp.Controls.Add(sessionLabel);

        statusLabel = new Label { Location = new Point(X, 508), Size = new Size(W, 42), ForeColor = CAmber, Font = new Font("Segoe UI", 10.5f, FontStyle.Bold) };
        form.Controls.Add(statusLabel);
        bar = new ProgressBar { Location = new Point(X, 552), Size = new Size(W, 8), Style = ProgressBarStyle.Continuous };
        form.Controls.Add(bar);
        logBox = new TextBox { Location = new Point(X, 566), Size = new Size(W, 120), Multiline = true, ReadOnly = true,
            ScrollBars = ScrollBars.Vertical, BackColor = CField, ForeColor = CDim, BorderStyle = BorderStyle.None, Font = new Font("Consolas", 8.5f) };
        form.Controls.Add(logBox);

        reportBtn = Flat("Report a bug", CPanel);
        reportBtn.Location = new Point(X + W - 270, 698); reportBtn.Size = new Size(160, 32);
        reportBtn.Click += delegate { Report(); };
        form.Controls.Add(reportBtn);
        stopBtn = Flat("Stop", CPanel);
        stopBtn.Location = new Point(X + W - 100, 698); stopBtn.Size = new Size(100, 32);
        stopBtn.Click += delegate { new Thread(StopAll) { IsBackground = true }.Start(); };
        form.Controls.Add(stopBtn);
        form.Controls.Add(new Label { Text = "Both: Steam running, friends on Steam, your own game (English).",
            ForeColor = CDim, AutoSize = true, Location = new Point(X, 696), Font = new Font("Segoe UI", 8.5f) });
        LinkLabel dc = new LinkLabel { Text = "Help, bugs, finding a partner: Discord",
            AutoSize = true, Location = new Point(X, 715), Font = new Font("Segoe UI", 8.5f), LinkColor = CAmber, ActiveLinkColor = Color.White, VisitedLinkColor = CAmber };
        dc.LinkArea = new LinkArea(dc.Text.IndexOf("Discord"), 7);
        dc.LinkClicked += delegate { try { Process.Start(DISCORD); } catch { } };
        form.Controls.Add(dc);
    }

    static ContextMenuStrip ToolsMenu()
    {
        ContextMenuStrip m = new ContextMenuStrip();
        m.Items.Add("Open the folder", null, delegate { Process.Start("explorer.exe", "\"" + Root + "\""); });
        m.Items.Add("Check for updates now", null, delegate {
            Background(delegate { Install(true); Status("Up to date.", CGreen); CheckUpdates(); }); });
        m.Items.Add("Repair (download everything again)", null, delegate { Repair(); });
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add("Uninstall...", null, delegate { Uninstall(); });
        return m;
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

    static void Session(string s, Color c)
    {
        Ui(delegate {
            sessionLabel.Text = s + (sessionPing != "" && c == CGreen ? "   ·   " + sessionPing : "");
            sessionLed.ForeColor = c;
        });
    }

    static void Log(string s)
    {
        string line = DateTime.Now.ToString("HH:mm:ss") + "  " + s;
        try { lock (mine) File.AppendAllText(LogPath, line + "\r\n"); } catch { }
        Ui(delegate { if (logBox != null) logBox.AppendText(line + "\r\n"); });
    }

    static void RefreshUi()
    {
        string g = Game();
        bool en = g != null && IsEnglish(g);
        gameLabel.Text = g == null ? "Game: not found - click Change... and pick the folder that contains TNOVA" :
            (en ? "Game: " : "Not the English game (the host needs it): ") + g;
        gameLabel.ForeColor = en ? CText : CRed;
        bool[] have = { File.Exists(Path.Combine(UplinkDir, "project.godot")), File.Exists(GodotExe), File.Exists(TnpExe), File.Exists(PythonExe) };
        for (int i = 0; i < checks.Length; i++)
        {
            checks[i].Text = (have[i] ? "●  " : "○  ") + checks[i].Tag + (have[i] ? "" : "  (installed when needed)");
            checks[i].ForeColor = have[i] ? CGreen : CDim;
        }
        hostBtn.Enabled = joinBtn.Enabled = gameBtn.Enabled = toolsBtn.Enabled = !busy;
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
        lock (cfg) foreach (KeyValuePair<string, string> kv in cfg) sb.Append(kv.Key + " = " + kv.Value + "\r\n");
        try { File.WriteAllText(Ini, sb.ToString()); } catch { }
    }

    static string Cfg(string k) { string v; lock (cfg) return cfg.TryGetValue(k, out v) ? v : ""; }
    static void Set(string k, string v) { lock (cfg) cfg[k] = v; }

    static void LoadOptions()
    {
        (Cfg("mode") == "versus" ? modeVs : modeCoop).Checked = true;
        int s = Array.IndexOf(SIZES, Cfg("window"));
        sizeBox.SelectedIndex = s >= 0 ? s : 1;
        double sens;
        sensBar.Value = double.TryParse(Cfg("mouse"), NumberStyles.Float, CultureInfo.InvariantCulture, out sens) ?
            Math.Max(2, Math.Min(30, (int)Math.Round(sens * 10))) : 10;
        sensLabel.Text = "x " + (sensBar.Value / 10.0).ToString("0.0", CultureInfo.InvariantCulture);
        invertBox.Checked = Cfg("invert_y") == "1";
        padBox.Checked = Cfg("gamepad") != "0";
        int mi;
        missionBox.SelectedIndex = int.TryParse(Cfg("mission"), out mi) && mi >= 0 && mi < missionBox.Items.Count ? mi : 0;
    }

    static void SaveOptions()
    {
        if (modeVs == null) return;
        Set("mode", modeVs.Checked ? "versus" : "coop");
        Set("window", SIZES[Math.Max(0, sizeBox.SelectedIndex)]);
        Set("mouse", (sensBar.Value / 10.0).ToString("0.0", CultureInfo.InvariantCulture));
        Set("invert_y", invertBox.Checked ? "1" : "0");
        Set("gamepad", padBox.Checked ? "1" : "0");
        Set("mission", Math.Max(0, missionBox.SelectedIndex).ToString());
        SaveCfg();
    }

    static string UplinkDir { get { return Path.Combine(Comp, "uplink"); } }
    static string GodotExe { get { return Path.Combine(Comp, "godot", "Godot_v" + GODOT_VER + "-stable_win64.exe"); } }
    static string TnpDir { get { return Path.Combine(Comp, "tnplus"); } }
    static string TnpExe { get { return Path.Combine(TnpDir, "TNPlus.exe"); } }
    static string PythonExe { get { return Path.Combine(Comp, "python", "python.exe"); } }
    static string GodotData { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Godot", "app_userdata", "Terra Nova Uplink"); } }

    // ------------------------------------------------------------------ the game folder (GOG, Steam, or picked)
    static bool IsGame(string d) { return !string.IsNullOrEmpty(d) && File.Exists(Path.Combine(d, "TNOVA", "DATA", "RESMISS.RES")); }

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
                if (IsEnglish(c)) { Set("game_dir", c); SaveCfg(); return c; }
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
            Set("game_dir", p); SaveCfg(); RefreshUi();
        }
    }

    static bool Ask(string q)
    {
        bool yes = false;
        Action a = delegate { yes = MessageBox.Show(form, q, TITLE, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes; };
        if (form.InvokeRequired) form.Invoke(a); else a();
        return yes;
    }

    static void Background(Action a)
    {
        if (busy) return;
        busy = true; stopping = false;
        RefreshUi();
        new Thread(delegate () {
            try { a(); }
            catch (Exception e) { Status("Stopped: " + e.Message, CRed); Log(e.ToString()); }
            busy = false;
            Progress(0);
            Ui(RefreshUi);
        }) { IsBackground = true }.Start();
    }

    // ------------------------------------------------------------------ host / join
    static void Start(bool host)
    {
        if (busy) return;
        SaveOptions();
        if (Game() == null) { PickGame(); if (Game() == null) return; }
        if (host && !IsEnglish(Game()))
        {
            MessageBox.Show(form, "The host needs the English game (the co-op code only knows its exe). Pick an English install with Change...", TITLE);
            return;
        }
        sessionName = sessionPing = "";
        Background(delegate { if (host) Host(); else Join(); });
    }

    static void Host()
    {
        Status("Getting things ready...", CAmber);
        Install(true);
        if (!Preflight(true) || !SteamUp()) return;
        WriteTnpIni(Game());
        string load = null;
        int pick;
        if (int.TryParse(Cfg("mission"), out pick) && pick > 0)
        {
            load = MakeSave(Game(), pick - 1);
            if (load == null) return;
        }
        Status("Starting the game (TN+ Coop)...", CAmber);
        Session("Starting the game...", CAmber);
        // the game windowed (the editions start DOSBox fullscreen, and a fullscreen DOSBox comes back over Uplink at
        // each video mode change): one more DOSBox config, after the edition's and TN+'s
        string conf = Path.Combine(TnpDir, "coop_host.conf");
        File.WriteAllLines(conf, new[] { "# Terra Nova Coop: the host's game in a small window, kept minimized (Uplink draws it)",
            "[sdl]", "fullscreen = false", "windowresolution = 640x400" });
        Process tnp = Run(TnpExe, "--launch --conf \"" + conf + "\"", TnpDir, null, false);
        // the bridge needs the game's code loaded: tried every few seconds until it stays up
        Status("Waiting for the game to load...", CAmber);
        Process bridge = null;
        DateTime t0 = DateTime.Now;
        while (!stopping)
        {
            if (tnp.HasExited && Process.GetProcessesByName("dosbox-staging").Length == 0)
            { Status("The game was closed.", CText); Session("No session.", CDim); return; }
            if ((DateTime.Now - t0).TotalMinutes > 5)
            { Status("The game didn't load in 5 minutes: see the log below.", CRed); return; }
            Thread.Sleep(3000);
            bridge = Bridge();
            DateTime b0 = DateTime.Now;
            while (!bridge.HasExited && (DateTime.Now - b0).TotalSeconds < 12) Thread.Sleep(250);
            if (!bridge.HasExited) break;
            Log("bridge not ready yet (" + bridge.ExitCode + "), trying again");
        }
        if (stopping || bridge == null) return;
        Status(load != null ? "Uplink is open. In the game: Load Game, then \"" + load + "\". Invite your friend from Uplink's list (top right)." :
            "Uplink is open: invite your friend from its list (top right), go to Mission Outfitting, wait for READY.", CGreen);
        int n = 0;
        while (!stopping && !bridge.HasExited)
        {
            Thread.Sleep(500);
            if (++n % 4 == 0) KeepGameMinimized();
        }
        if (!stopping)
        {
            Status(tnp.HasExited ? "The game was closed. Session over." :
                "Uplink was closed. Click HOST A GAME to open it again.", CText);
            Session("No session.", CDim);
        }
    }

    // the game's window tucked right behind Uplink's: out of sight, but not minimized (on the menus the bridge
    // photographs it, PrintWindow, which a minimized window can't give). Left alone while it is in front (the host
    // brought it up); put back behind when it comes up by itself
    static void KeepGameMinimized()
    {
        IntPtr up = IntPtr.Zero;
        foreach (Process g in Process.GetProcesses())
            try { if (g.ProcessName.StartsWith("Godot") && g.MainWindowHandle != IntPtr.Zero) { up = g.MainWindowHandle; break; } } catch { }
        if (up == IntPtr.Zero) return;
        WRect ur;
        if (!GetWindowRect(up, out ur)) return;
        foreach (Process d in Process.GetProcessesByName("dosbox-staging"))
            try
            {
                d.Refresh();
                IntPtr h = d.MainWindowHandle;
                if (h == IntPtr.Zero || GetForegroundWindow() == h) continue;
                if (IsIconic(h)) ShowWindow(h, 4);                 // restored without taking the focus
                WRect r;
                GetWindowRect(h, out r);
                int x = ur.Left + 40, y = ur.Top + 40;
                if (r.Left != x || r.Top != y) Log("game window behind Uplink");
                SetWindowPos(h, up, x, y, 0, 0, 0x0001 | 0x0010);    // under Uplink's window, no size change, no activation
            }
            catch { }
    }

    static Process Bridge()
    {
        Dictionary<string, string> env = Env();
        env["PYTHONIOENCODING"] = "utf-8";
        env["PYTHONUNBUFFERED"] = "1";
        return Run(PythonExe, "-u \"" + Path.Combine(UplinkDir, "live", "live_bridge.py") + "\" --launch --hud --play --guest-remote --fov 91.5 --res " +
            Cfg("window") + (Cfg("mode") == "versus" ? " --versus" : ""), UplinkDir, env, true);
    }

    static void Join()
    {
        Status("Getting things ready...", CAmber);
        Install(false);
        if (!Preflight(false) || !SteamUp()) return;
        Status("Opening Uplink...", CAmber);
        string size = Cfg("window");
        string win = size == "native" ? "" : "--resolution " + size + " ";
        Process g = Run(GodotExe, "--path \"" + UplinkDir + "\" " + win + "-- --live --coop-guest --live-port 47831 --play --play-port 47834" +
            (size == "native" ? " --native" : ""), UplinkDir, Env(), true);
        Status("Uplink is open: click JOIN next to your friend (he must have clicked HOST A GAME).", CGreen);
        while (!stopping && !g.HasExited) Thread.Sleep(500);
        if (!stopping) { Status("Uplink was closed.", CText); Session("No session.", CDim); }
    }

    static Dictionary<string, string> Env()
    {
        Dictionary<string, string> env = new Dictionary<string, string>();
        env["GODOT"] = GodotExe;
        env["TN_GAME_DIR"] = Game();
        env["TN_MOUSE_SENS"] = Cfg("mouse");
        env["TN_INVERT_Y"] = Cfg("invert_y");
        env["TN_NO_PAD"] = Cfg("gamepad") == "0" ? "1" : "0";
        return env;
    }

    // ------------------------------------------------------------------ mission selector
    // A campaign mission is picked by a save: the most advanced one of the game (its squad, pilots and equipment) is
    // copied into a free slot as "COOP Mission NN", its header (resource 1776, read by the game into 0x359708 = the
    // mission's MISSn.RES and 0x35D0EC = the campaign position + 3) set on the picked mission. The host loads it.
    static void FillMissions()
    {
        missionBox.Items.Clear();
        missionBox.Items.Add("From the game's menus (no change)");
        string g = Game();
        string[] names = g != null ? MissionNames(g) : null;
        for (int i = 0; i < CAMPAIGN.Length; i++)
        {
            int n = CAMPAIGN[i];
            string nm = names != null && n - 1 < names.Length && names[n - 1].Trim() != "" ? names[n - 1].Trim() : "MISS" + n;
            missionBox.Items.Add((i + 1).ToString("00") + "   " + nm);
        }
    }

    static string[] MissionNames(string game)
    {
        try
        {
            Res r = Res.Load(Path.Combine(game, "TNOVA", "DATA", "RESMISS.RES"));
            List<string> l = new List<string>();
            foreach (byte[] f in Res.Frames(r.Data(1706)))
            {
                int z = Array.IndexOf(f, (byte)0);
                l.Add(Encoding.GetEncoding(850).GetString(f, 0, z < 0 ? f.Length : z));
            }
            return l.ToArray();
        }
        catch { return null; }
    }

    static string MakeSave(string game, int index)
    {
        string dir = Path.Combine(game, "TNOVA");
        Res best = null;
        int bestPos = -1, coopSlot = -1, free = -1;
        for (int slot = 1; slot <= 9; slot++)
        {
            string f = Path.Combine(dir, "SAVE" + slot.ToString("00") + ".RES");
            if (!File.Exists(f)) { if (free < 0) free = slot; continue; }
            try
            {
                Res r = Res.Load(f);
                string name = Encoding.ASCII.GetString(r.Data(1775)).TrimEnd('\0');
                if (name.StartsWith(COOP_SAVE)) { if (coopSlot < 0) coopSlot = slot; continue; }
                byte[] h = r.Data(1776);
                int pos = BitConverter.ToInt32(h, 8);
                if (BitConverter.ToInt32(h, 0) == 0x06EF0018 && pos > bestPos) { bestPos = pos; best = r; }
            }
            catch (Exception e) { Log("SAVE" + slot.ToString("00") + ": " + e.Message); }
        }
        if (best == null)
        {
            Status("To pick a mission, the game needs at least one save of yours (play the first mission and save).", CRed);
            return null;
        }
        int target = coopSlot > 0 ? coopSlot : free;      // our own COOP slot again, else a free one: never a save of yours
        if (target < 0)
        {
            Status("The 9 save slots are all used: free one in the game (or pick \"From the game's menus\").", CRed);
            return null;
        }
        string label = COOP_SAVE + (index + 1).ToString("00");
        byte[] head = (byte[])best.Data(1776).Clone();
        Array.Copy(BitConverter.GetBytes(CAMPAIGN[index]), 0, head, 4, 4);
        Array.Copy(BitConverter.GetBytes(index + 3), 0, head, 8, 4);
        best.Set(1775, Encoding.ASCII.GetBytes(label + "\0"));
        best.Set(1776, head);
        string path = Path.Combine(dir, "SAVE" + target.ToString("00") + ".RES");
        best.Save(path);
        Log("mission " + (index + 1) + " (MISS" + CAMPAIGN[index] + ".RES) -> " + Path.GetFileName(path) + ", from the save at campaign position " + bestPos);
        return label;
    }

    // ------------------------------------------------------------------ checks before starting
    class Proc { public int Id; public string Name, Cmd; }

    static List<Proc> Procs()
    {
        List<Proc> l = new List<Proc>();
        try
        {
            using (ManagementObjectSearcher s = new ManagementObjectSearcher("SELECT ProcessId, Name, CommandLine FROM Win32_Process " +
                "WHERE Name = 'python.exe' OR Name LIKE 'Godot%' OR Name = 'dosbox-staging.exe' OR Name = 'TNPlus.exe'"))
                foreach (ManagementObject o in s.Get())
                    l.Add(new Proc { Id = Convert.ToInt32(o["ProcessId"]), Name = (string)o["Name"], Cmd = (string)o["CommandLine"] ?? "" });
        }
        catch (Exception e) { Log("process list: " + e.Message); }
        return l;
    }

    static bool Preflight(bool host)
    {
        List<Proc> ps = Procs();
        // an Uplink or bridge already open (another launch, a .bat): same ports, the new one would not get its packets
        List<Proc> old = ps.FindAll(p => (p.Name.StartsWith("Godot") && p.Cmd.Contains("--live")) ||
                                         (p.Name == "python.exe" && p.Cmd.Contains("live_bridge.py")));
        if (old.Count > 0)
        {
            if (!Ask("An Uplink session is already open (" + old.Count + " program(s)). Close it and start a new one?"))
            { Status("Close the other Uplink first.", CRed); return false; }
            foreach (Proc p in old) Kill(p.Id);
            Thread.Sleep(1000);
        }
        if (host)
        {   // a game started without the co-op build has no co-op code: it must be started again from here
            List<Proc> games = ps.FindAll(p => p.Name == "dosbox-staging.exe");
            bool ours = games.Exists(p => p.Cmd.IndexOf(TnpDir, StringComparison.OrdinalIgnoreCase) >= 0);
            if (games.Count > 0 && !ours)
            {
                if (!Ask("Terra Nova is already running, started without the co-op build. Close it so Terra Nova Coop can start it again? (save your game first)"))
                { Status("Close the game first.", CRed); return false; }
                foreach (Proc p in games) Kill(p.Id);
                foreach (Proc p in ps.FindAll(q => q.Name == "TNPlus.exe")) Kill(p.Id);
                Thread.Sleep(1500);
            }
        }
        return true;
    }

    static void Kill(int id)
    {
        try { Process p = Process.GetProcessById(id); Log("closing " + p.ProcessName + " " + id); p.Kill(); p.WaitForExit(3000); } catch { }
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
        if (env != null) foreach (KeyValuePair<string, string> kv in env) psi.EnvironmentVariables[kv.Key] = kv.Value ?? "";
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
            p.OutputDataReceived += (s, e) => { if (e.Data != null) Line(tag, e.Data); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null && e.Data.Trim() != "") Log(tag + "! " + e.Data); };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
        }
        lock (mine) mine.Add(p);
        return p;
    }

    // Uplink's coop lines (coop_net.gd; on the host they come through the bridge, which started Uplink): the session line
    static readonly Regex COOP = new Regex(@"coop: \[[0-9:]+\] (.*)$");
    static readonly Regex PING = new Regex(@"ping (\d+) ms");

    static void Line(string tag, string l)
    {
        if (l.StartsWith("x ") || l.Trim() == "" || l.StartsWith("Godot Engine") || l.StartsWith("Vulkan")) return;
        Log(tag + ": " + l);
        Match m = COOP.Match(l);
        string t = m.Success ? m.Groups[1].Value : l;
        Match pm = PING.Match(t);
        if (pm.Success) sessionPing = pm.Groups[1].Value + " ms";
        if (t.Contains("OFFLINE"))
            Session("Steam not available: " + t.Substring(t.IndexOf("OFFLINE") + 7).Trim(), CRed);
        else if (t.Contains("ANOTHER COOP VERSION") || t.Contains("ANOTHER VERSION") || t.Contains("another coop version"))
            Session("Different versions: both of you click HOST / JOIN again (it updates).", CRed);
        else if (t.Contains("GUEST CONNECTED") || t.Contains("CONNECTED TO HOST"))
        {
            string rest = t.Substring(t.IndexOf("CONNECTED") + 9).Replace("TO HOST", "").Trim();
            int cut = rest.IndexOf("  ");
            sessionName = cut > 0 ? rest.Substring(0, cut) : rest;
            Session((t.Contains("GUEST") ? "Connected: " : "Connected to ") + sessionName, CGreen);
        }
        else if (t.StartsWith("status:") && sessionName != "")
            Session("Connected: " + sessionName, CGreen);
        else if (t.Contains("GUEST JOINING"))
            Session("Your friend is joining...", CAmber);
        else if (t.Contains("CONNECTABLE"))
            Session("Lobby open: invite your friend from the list in Uplink (top right).", CAmber);
        else if (t.Contains("the host left"))
            Session("The host left.", CAmber);
        else if (t.Contains("waiting for an invite") || t.Contains("waiting for a game"))
            Session("Waiting: click JOIN next to your friend in Uplink.", CAmber);
        else if (t.StartsWith("invited "))
            Session("Invite sent to " + t.Substring(8) + ".", CAmber);
        else if (t.StartsWith("guest: entity"))
            Session("Your friend is in the mission" + (sessionName != "" ? " (" + sessionName + ")" : "") + ".", CGreen);
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
        Session("No session.", CDim);
    }

    // ------------------------------------------------------------------ bug report: one zip on the desktop
    static void Report()
    {
        string zip = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            "TerraNovaCoop_report_" + DateTime.Now.ToString("yyyy-MM-dd_HH-mm") + ".zip");
        try
        {
            using (ZipArchive a = ZipFile.Open(zip, ZipArchiveMode.Create))
            {
                StringBuilder info = new StringBuilder();
                string g = Game();
                info.AppendLine(TITLE + " " + VERSION + ", " + Environment.OSVersion + (Environment.Is64BitOperatingSystem ? ", 64-bit" : ""));
                info.AppendLine("game: " + g + (g != null && IsEnglish(g) ? " (English)" : " (not English)"));
                info.AppendLine("uplink " + Cfg("uplink_sha") + ", tnplus " + Cfg("tnplus_sha"));
                info.AppendLine("options: mode " + Cfg("mode") + ", window " + Cfg("window") + ", mouse " + Cfg("mouse") +
                                ", invert " + Cfg("invert_y") + ", gamepad " + Cfg("gamepad"));
                info.AppendLine("session: " + (sessionLabel != null ? sessionLabel.Text : "-"));
                foreach (Proc p in Procs()) info.AppendLine("running: " + p.Name + " " + p.Id);
                using (StreamWriter w = new StreamWriter(a.CreateEntry("info.txt").Open())) w.Write(info.ToString());
                Add(a, LogPath, "launcher.log");
                Add(a, Path.Combine(TnpDir, "TNPlus.ini"), "TNPlus.ini");
                Newest(a, Path.Combine(UplinkDir, "live", "logs"), "coop_host_*.log", 3, "bridge/");
                Newest(a, Path.Combine(GodotData, "coop_logs"), "*.log", 4, "uplink_coop/");
                Newest(a, Path.Combine(GodotData, "logs"), "*.log", 2, "uplink_godot/");
            }
            Status("Report saved on your desktop: send it on Discord with a few words on what happened.", CGreen);
            if (form != null) Process.Start("explorer.exe", "/select,\"" + zip + "\"");
            else Console.WriteLine(zip);
        }
        catch (Exception e) { Status("Report failed: " + e.Message, CRed); }
    }

    static void Add(ZipArchive a, string file, string name)
    {
        try
        {   // the logs are still open in the programs writing them: read them shared
            using (FileStream f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (Stream o = a.CreateEntry(name).Open()) f.CopyTo(o);
        }
        catch { }
    }

    static void Newest(ZipArchive a, string dir, string pattern, int n, string into)
    {
        if (!Directory.Exists(dir)) return;
        List<FileInfo> fs = new List<FileInfo>(new DirectoryInfo(dir).GetFiles(pattern));
        fs.Sort((x, y) => y.LastWriteTime.CompareTo(x.LastWriteTime));
        for (int i = 0; i < Math.Min(n, fs.Count); i++) Add(a, fs[i].FullName, into + fs[i].Name);
    }

    // ------------------------------------------------------------------ TN+ Coop settings: HD 848x480 (the live mode's)
    static void WriteTnpIni(string game)
    {
        string ini = Path.Combine(TnpDir, "TNPlus.ini");
        // HD 848x480 stays (the bridge reads the cockpit from it); the rest at its lightest: Uplink draws the world,
        // the game's own picture is only there to keep it running (minimized)
        Dictionary<string, string> want = new Dictionary<string, string> {
            { "display", "HD" }, { "widescreen", "2" }, { "update_check", "0" }, { "game_dir", game },
            { "terrain_detail", "GAME" }, { "object_distance", "GAME" }, { "view_distance", "NORMAL" },
            { "small_views", "0" }, { "edge_objects", "0" }, { "field_of_view", "GAME" } };
        List<string> lines = File.Exists(ini) ? new List<string>(File.ReadAllLines(ini)) : new List<string> { "; Terra Nova Plus settings (written by Terra Nova Coop)" };
        foreach (KeyValuePair<string, string> kv in want)
        {
            int at = lines.FindIndex(l => Regex.IsMatch(l, "^\\s*" + kv.Key + "\\s*="));
            string line = kv.Key + " = " + kv.Value;
            if (at >= 0) lines[at] = line; else lines.Add(line);
        }
        File.WriteAllLines(ini, lines);
    }

    // ------------------------------------------------------------------ install, update, repair
    static void Install(bool host)
    {
        Dictionary<string, string> heads = Heads();
        string up = Get(heads, UPLINK_REPO);
        if (!File.Exists(Path.Combine(UplinkDir, "project.godot")) || (up != null && up != Cfg("uplink_sha")))
        {
            Status("Downloading Uplink (coop)...", CAmber);
            Repo(UPLINK_REPO, UplinkDir);
            if (up != null) Set("uplink_sha", up);
            SaveCfg();
            SelfUpdate();
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
                if (tp != null) Set("tnplus_sha", tp);
                SaveCfg();
            }
            if (!File.Exists(PythonExe) || !File.Exists(Path.Combine(Comp, "python", "Lib", "site-packages", "psutil", "__init__.py")))
            {
                Status("Downloading Python for the bridge (about 30 MB, once)...", CAmber);
                InstallPython();
            }
        }
        if (host) PythonPaths();               // installs made before 0.5 lacked the live folder
        Ui(RefreshUi);
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
            else verLabel.Text = "Update available: installed when you click HOST or JOIN (both PCs need the same).";
            verLabel.ForeColor = up != null && up != Cfg("uplink_sha") && Cfg("uplink_sha") != "" ? CAmber : CDim;
        });
    }

    // a newer launcher in Uplink's files (launcher\TerraNovaCoop.cs, its VERSION): built next to this one, swapped in
    // by a small batch file once this one has closed, then started again
    static void SelfUpdate()
    {
        string src = Path.Combine(UplinkDir, "launcher", "TerraNovaCoop.cs");
        if (!File.Exists(src) || form == null) return;
        Match m = Regex.Match(File.ReadAllText(src), "const string VERSION = \"([0-9.]+)\"");
        Version now, theirs;
        if (!m.Success || !Version.TryParse(VERSION, out now) || !Version.TryParse(m.Groups[1].Value, out theirs) || theirs <= now) return;
        Status("Building the new launcher " + theirs + "...", CAmber);
        string dir = Path.GetDirectoryName(src), outExe = Path.Combine(Root, "Terra Nova Coop.new.exe");
        Process p = Run(Csc(), "/nologo /optimize /target:winexe /win32manifest:app.manifest /win32icon:icon.ico /r:System.Windows.Forms.dll " +
            "/r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Management.dll " +
            "/out:\"" + outExe + "\" TerraNovaCoop.cs", dir, null, true);
        p.WaitForExit();
        if (p.ExitCode != 0 || !File.Exists(outExe)) { Log("new launcher didn't build"); return; }
        if (!Ask("A new Terra Nova Coop (" + theirs + ") is ready. Restart now?")) return;
        string me = Application.ExecutablePath, bat = Path.Combine(Root, "update.bat");
        File.WriteAllText(bat, "@echo off\r\nping -n 3 127.0.0.1 >nul\r\nmove /y \"" + outExe + "\" \"" + me + "\" >nul\r\nstart \"\" \"" + me + "\"\r\n");
        Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + bat + "\"") { CreateNoWindow = true, UseShellExecute = false });
        Environment.Exit(0);
    }

    static void Repair()
    {
        if (busy) return;
        if (!Ask("Download and install everything again? (your settings are kept)")) return;
        Background(delegate {
            StopAll();
            stopping = false;
            foreach (string d in new[] { "uplink", "godot", "python", "tnplus_src", "tmp" })
                try { if (Directory.Exists(Path.Combine(Comp, d))) Directory.Delete(Path.Combine(Comp, d), true); } catch (Exception e) { Log(e.Message); }
            try { File.Delete(TnpExe); } catch { }
            Set("uplink_sha", ""); Set("tnplus_sha", ""); SaveCfg();
            Install(true);
            Status("Repaired: everything is installed again.", CGreen);
        });
    }

    static void Uninstall()
    {
        if (busy) return;
        if (!Ask("Remove everything Terra Nova Coop installed in this folder (about 250 MB)? Your game is not touched.")) return;
        StopAll();
        try { Directory.Delete(Comp, true); } catch (Exception e) { Log(e.Message); }
        try { File.Delete(Ini); } catch { }
        MessageBox.Show(form, "Done. You can now delete Terra Nova Coop.exe.", TITLE);
        Environment.Exit(0);
    }

    static string Csc()
    {
        string c = Path.Combine(Environment.GetEnvironmentVariable("WINDIR"), @"Microsoft.NET\Framework64\v4.0.30319\csc.exe");
        return File.Exists(c) ? c : Path.Combine(Environment.GetEnvironmentVariable("WINDIR"), @"Microsoft.NET\Framework\v4.0.30319\csc.exe");
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
        string cmd = File.ReadAllText(Path.Combine(src, "src", "build.bat"));
        Match m = Regex.Match(cmd, "(?m)^\"%CSC%\"([^\\r\\n]+)");   // build.bat's compiler line, without its pause
        if (!m.Success) throw new Exception("TN+ build.bat not understood");
        Process p = Run(Csc(), m.Groups[1].Value.Trim(), Path.Combine(src, "src"), null, true);
        p.WaitForExit();
        string built = Path.Combine(src, "src", "TNPlus.exe");
        if (p.ExitCode != 0 || !File.Exists(built)) throw new Exception("TN+ Coop didn't build (see the log)");
        Directory.CreateDirectory(TnpDir);
        File.Copy(built, TnpExe, true);       // TNPlus.ini and its coop copy of the game's exe stay in tnplus\
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
        PythonPaths();
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

    // the embedded Python only searches what its ._pth file lists (not even the script's folder): site-packages for
    // numpy / psutil, and Uplink's live folder for the bridge's own modules (tnre, coop_guest...)
    static void PythonPaths()
    {
        string dir = Path.Combine(Comp, "python");
        if (!Directory.Exists(dir)) return;
        foreach (string pth in Directory.GetFiles(dir, "python*._pth"))
        {
            string t = File.ReadAllText(pth).Replace("#import site", "import site");
            foreach (string need in new[] { @"Lib\site-packages", @"..\uplink\live" })
                if (!Regex.IsMatch(t, "(?m)^" + Regex.Escape(need) + @"\s*$")) t = t.TrimEnd() + "\r\n" + need + "\r\n";
            File.WriteAllText(pth, t);
        }
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

    // Looking Glass "LG Res File v2": header (0x7C: directory offset), data blocks (4-aligned), directory at the end:
    // u16 count, u32 first data offset, then per resource u16 id, u32 size | flags << 24, u32 packed size | type << 24.
    // Packed (flags 1) and compound (flags 2) blocks are kept as they are; only whole blocks are replaced.
    class Res
    {
        byte[] head;
        List<int> ids = new List<int>();
        Dictionary<int, uint[]> ab = new Dictionary<int, uint[]>();
        Dictionary<int, byte[]> data = new Dictionary<int, byte[]>();

        public static Res Load(string path)
        {
            byte[] d = File.ReadAllBytes(path);
            if (Encoding.ASCII.GetString(d, 0, 14) != "LG Res File v2") throw new Exception("not an LG Res file");
            Res r = new Res();
            int diro = BitConverter.ToInt32(d, 0x7C);
            int n = BitConverter.ToUInt16(d, diro), off = BitConverter.ToInt32(d, diro + 2), p = diro + 6;
            r.head = new byte[off];
            Array.Copy(d, r.head, off);
            for (int i = 0; i < n; i++, p += 10)
            {
                int id = BitConverter.ToUInt16(d, p);
                uint a = BitConverter.ToUInt32(d, p + 2), b = BitConverter.ToUInt32(d, p + 6);
                int len = (int)(((a >> 24) & 1) != 0 ? b & 0xFFFFFF : a & 0xFFFFFF);
                byte[] blk = new byte[len];
                Array.Copy(d, off, blk, 0, len);
                off += (len + 3) & ~3;
                r.ids.Add(id);
                r.ab[id] = new uint[] { a, b };
                r.data[id] = blk;
            }
            return r;
        }

        public byte[] Data(int id) { return data[id]; }

        public void Set(int id, byte[] d)
        {   // a plain block (not packed, not compound)
            uint[] x = ab[id];
            ab[id] = new uint[] { (uint)d.Length | (x[0] & 0xFE000000), (uint)d.Length | (x[1] & 0xFF000000) };
            data[id] = d;
        }

        public void Save(string path)
        {
            using (MemoryStream m = new MemoryStream())
            {
                m.Write(head, 0, head.Length);
                foreach (int id in ids)
                {
                    m.Write(data[id], 0, data[id].Length);
                    while (m.Length % 4 != 0) m.WriteByte(0);
                }
                int diro = (int)m.Length;
                m.Write(BitConverter.GetBytes((ushort)ids.Count), 0, 2);
                m.Write(BitConverter.GetBytes(head.Length), 0, 4);
                foreach (int id in ids)
                {
                    m.Write(BitConverter.GetBytes((ushort)id), 0, 2);
                    m.Write(BitConverter.GetBytes(ab[id][0]), 0, 4);
                    m.Write(BitConverter.GetBytes(ab[id][1]), 0, 4);
                }
                byte[] o = m.ToArray();
                Array.Copy(BitConverter.GetBytes(diro), 0, o, 0x7C, 4);
                File.WriteAllBytes(path, o);
            }
        }

        public static List<byte[]> Frames(byte[] d)
        {
            List<byte[]> l = new List<byte[]>();
            int n = d.Length >= 2 ? BitConverter.ToUInt16(d, 0) : 0;
            for (int k = 0; k < n; k++)
            {
                int a = BitConverter.ToInt32(d, 2 + 4 * k), b = BitConverter.ToInt32(d, 6 + 4 * k);
                byte[] f = new byte[b - a];
                Array.Copy(d, a, f, 0, b - a);
                l.Add(f);
            }
            return l;
        }
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
