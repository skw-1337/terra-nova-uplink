// Terra Nova Uplink: one window for everything Uplink does. It installs what each mode needs in its own folder
// (Uplink, Godot, Terra Nova Plus and its co-op build, an embedded Python for the live mode's bridge), keeps them up
// to date (itself included: a newer launcher in Uplink's files is built and swapped in) and starts everything in order:
//   PLAY: the game through TN+ (no menu, HD 848x480, windowed behind Uplink), then the bridge, which opens Uplink live.
//   HOST A GAME: the same with the TN+ co-op build and Uplink's Steam lobby (the host plays, a friend joins).
//   JOIN A FRIEND: Uplink's guest window, where the friends hosting a game show up with a JOIN button.
//   MAP VIEWER: Uplink's map viewer, every map of the game.
// Since 2.0 it replaces Terra Nova Coop too (launcher\TerraNovaCoop.cs is a copy of this file, so that Coop launchers
// update themselves into this one). Built with the C# compiler that comes with Windows (.NET Framework 4.5+): build.bat.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
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

static class Uplink
{
    const string TITLE = "Terra Nova Uplink";
    const string VERSION = "2.5";
    const string UPLINK_REPO = "skw-1337/terra-nova-uplink", TNPLUS_REPO = "skw-1337/terra-nova-plus";
    // the branches checked by each repo's .github/workflows/stable.yml (main once its checks have passed, never a broken
    // push): Uplink's, TN+'s (PLAY) and TN+'s co-op build (HOST)
    const string UPLINK_BRANCH = "stable", TNPLUS_BRANCH = "stable", TNPLUS_COOP_BRANCH = "coop-stable";
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
    static readonly string[] CROSSHAIRS = { "", "dot", "none" };          // the look mode's: the game's, a dot, nothing
    // campaign order (mission 1..37) -> MISSn.RES (as Uplink's tn_data.gd)
    static readonly int[] CAMPAIGN = { 37, 38, 1, 2, 3, 4, 5, 6, 7, 8, 9, 32, 33, 10, 11, 12, 13, 34, 29, 15, 17, 16, 36,
        14, 20, 39, 21, 35, 22, 23, 19, 24, 27, 25, 26, 30, 31 };
    const string PLAY_SAVE = "UPLINK Mission ", COOP_SAVE = "COOP Mission ";
    static readonly string[] OUR_SAVES = { PLAY_SAVE, COOP_SAVE, "LAB Mission " };   // ours: never taken as the player's

    // Terra Nova's cockpit: dark green-black, teal panels, amber, green lights, the outfitting screen's orange
    static readonly Color CBack = Color.FromArgb(8, 17, 16), CPanel = Color.FromArgb(13, 26, 24), CLine = Color.FromArgb(29, 53, 49);
    static readonly Color CButton = Color.FromArgb(17, 34, 31), CButtonLine = Color.FromArgb(42, 74, 68), CTeal = Color.FromArgb(47, 106, 94);
    static readonly Color CText = Color.FromArgb(214, 226, 220), CDim = Color.FromArgb(122, 150, 142), CAmber = Color.FromArgb(240, 178, 48);
    static readonly Color CGreen = Color.FromArgb(56, 214, 92), CRed = Color.FromArgb(236, 72, 60), COrange = Color.FromArgb(214, 122, 28);
    static readonly Color CBlue = Color.FromArgb(32, 65, 143), CLedOff = Color.FromArgb(40, 64, 58);

    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out WRect r);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetKeyNameText(int lParam, StringBuilder name, int size);
    [StructLayout(LayoutKind.Sequential)] struct WRect { public int Left, Top, Right, Bottom; }

    static string Root, Comp, Ini, LogPath;
    static Dictionary<string, string> cfg = new Dictionary<string, string>();
    static Form form;
    static Font FHead, FBody, FSmall, FIcon;
    static Label statusLabel, verLabel, sessionLabel, sensLabel;
    static Led sessionLed;
    static Led[] leds;
    static Label[] ledText;
    static Tile playBtn, hostBtn, joinBtn, mapBtn, stopBtn, gameBtn, toolsBtn, reportBtn, logBtn, oldKeyBtn, sharpKeyBtn;
    static RadioButton modeCoop, modeVs;
    static ComboBox gameBox, sizeBox, missionBox, crossBox, runBox;
    static TrackBar sensBar;
    static CheckBox invertBox, padBox;
    static ProgressBar bar;
    static TextBox logBox;
    static Panel sessionRow, lower;
    static int sessionTop;
    static volatile bool busy, stopping, coopRun;
    static readonly List<Process> mine = new List<Process>();
    static string sessionName = "", sessionPing = "";

    enum Mode { Play, Host, Join, Maps }

    [STAThread]
    static void Main()
    {
        Root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        Comp = Path.Combine(Root, "components");
        Ini = Path.Combine(Root, "TerraNovaUplink.ini");
        Directory.CreateDirectory(Path.Combine(Comp, "logs"));
        LogPath = Path.Combine(Comp, "logs", "launcher.log");
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;   // TLS 1.2 (GitHub, python.org, PyPI)
        Migrate();
        LoadCfg();
        string[] args = Environment.GetCommandLineArgs();
        if (args.Length > 2 && args[1] == "--install")    // checks: install / update only, no window (exit code 0 = ok)
        {
            Mode m = args[2] == "host" ? Mode.Host : args[2] == "join" ? Mode.Join : args[2] == "maps" ? Mode.Maps : Mode.Play;
            try { Install(m); Console.WriteLine("installed"); Environment.Exit(0); }
            catch (Exception e) { Log(e.ToString()); Environment.Exit(1); }
        }
        if (args.Length > 1 && args[1] == "--report") { Report(); Environment.Exit(0); }   // the report, without the window
        if (args.Length > 3 && (args[1] == "--labsave" || args[1] == "--makesave"))   // checks: the save of mission N in a TNOVA copy
        { Set("game_dir", args[3]); Console.WriteLine(MakeSave(args[3], int.Parse(args[2]) - 1, args[1] == "--makesave" ? COOP_SAVE : PLAY_SAVE) ?? "failed"); Environment.Exit(0); }
        if (args.Length > 1 && args[1] == "--closegame")   // checks: close the game this launcher started (exit 0 = one was)
        { Environment.Exit(CloseOurGame() ? 0 : 2); }
        if (args.Length > 1 && args[1] == "--binds")       // checks: TN+'s second binds, as Uplink is told them
        { Console.WriteLine(Binds()); Environment.Exit(0); }
        if (args.Length > 1 && args[1] == "--games")       // checks: every Terra Nova found
        { foreach (string d in Installs()) Console.WriteLine(Edition(d) + (IsEnglish(d) ? " EN  " : "     ") + d); Environment.Exit(0); }
        if (args.Length > 3 && args[1] == "--roundtrip")   // checks: an LG Res file read and written back
        { Res.Load(args[2]).Save(args[3]); Environment.Exit(0); }
        try { File.Delete(Path.Combine(Root, "update.bat")); } catch { }
        Application.EnableVisualStyles();
        Build();
        form.Shown += delegate { RefreshUi(); new Thread(CheckUpdates) { IsBackground = true }.Start(); };
        form.FormClosing += delegate { SaveOptions(); stopping = true; };
        Application.Run(form);
    }

    // A Terra Nova Coop folder that updated itself into this launcher: its settings and its TN+ (the co-op build)
    // are taken over (TerraNovaCoop.ini, components\tnplus -> tnplus_coop)
    static void Migrate()
    {
        try
        {
            string coopIni = Path.Combine(Root, "TerraNovaCoop.ini");
            if (File.Exists(Ini) || !File.Exists(coopIni)) return;
            string t = File.ReadAllText(coopIni);
            t = Regex.Replace(t, "(?m)^\\s*tnplus_sha\\s*=", "tnplus_coop_sha =");
            t = Regex.Replace(t, "(?m)^\\s*mission\\s*=", "start_at =");
            File.WriteAllText(Ini, t.Replace("; Terra Nova Coop", "; Terra Nova Uplink (taken over from Terra Nova Coop)"));
            if (Directory.Exists(Path.Combine(Comp, "tnplus")) && !Directory.Exists(Path.Combine(Comp, "tnplus_coop")))
                Directory.Move(Path.Combine(Comp, "tnplus"), Path.Combine(Comp, "tnplus_coop"));
            if (Directory.Exists(Path.Combine(Comp, "tnplus_src")) && !Directory.Exists(Path.Combine(Comp, "tnplus_coop_src")))
                Directory.Move(Path.Combine(Comp, "tnplus_src"), Path.Combine(Comp, "tnplus_coop_src"));
        }
        catch (Exception e) { Log("taking over Terra Nova Coop's settings: " + e.Message); }
    }

    // ------------------------------------------------------------------ window
    static void Build()
    {
        FHead = Pick(new[] { "Bahnschrift SemiBold", "Bahnschrift", "Segoe UI Semibold" }, 13f, FontStyle.Regular);
        FBody = new Font("Segoe UI", 9.5f);
        FSmall = new Font("Segoe UI", 8.5f);
        FIcon = Pick(new[] { "Segoe Fluent Icons", "Segoe MDL2 Assets" }, 16f, FontStyle.Regular);

        form = new Form();
        form.Text = TITLE + " " + VERSION;
        form.FormBorderStyle = FormBorderStyle.FixedSingle;
        form.MaximizeBox = false;
        form.StartPosition = FormStartPosition.CenterScreen;
        form.BackColor = CBack;
        form.ForeColor = CText;
        form.Font = FBody;
        try { form.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        int W = 652, X = 20, y = 16;

        // title: TERRA NOVA · UPLINK, an amber line under it
        Label t1 = new Label { Text = "TERRA NOVA", Font = Pick(new[] { "Bahnschrift SemiBold", "Bahnschrift", "Segoe UI Semibold" }, 22f, FontStyle.Regular),
            ForeColor = CAmber, AutoSize = true, Location = new Point(X - 2, y) };
        form.Controls.Add(t1);
        Label t2 = new Label { Text = "·  UPLINK", Font = t1.Font, ForeColor = CText, AutoSize = true, Location = new Point(t1.Right + 4, y) };
        form.Controls.Add(t2);
        form.Controls.Add(new Panel { BackColor = CAmber, Location = new Point(X, y + 44), Size = new Size(130, 2) });
        toolsBtn = new Tile("Tools", "\uE90F", CButton, CButtonLine, CText) { Location = new Point(X + W - 96, y + 6), Size = new Size(96, 32), Small = true };
        toolsBtn.Click += delegate { ToolsMenu().Show(toolsBtn, new Point(0, toolsBtn.Height)); };
        form.Controls.Add(toolsBtn);
        y += 60;

        // the game: every Terra Nova found on the PC (GOG, Steam, other drives, the ones added with Browse), one picked
        Box gp = new Box { Location = new Point(X, y), Size = new Size(W, 40) };
        form.Controls.Add(gp);
        gameBox = Combo(new Point(10, 8), W - 116);
        gameBox.DrawMode = DrawMode.OwnerDrawFixed;
        gameBox.ItemHeight = 18;
        gameBox.MaxDropDownItems = 12;
        gameBox.DrawItem += DrawGame;
        gameBox.DropDown += delegate { FillGames(); };          // looked for again each time it opens
        gameBox.SelectionChangeCommitted += delegate { PickInstall(); };
        gp.Controls.Add(gameBox);
        gameBtn = new Tile("Browse", null, CButton, CButtonLine, CText) { Location = new Point(W - 94, 5), Size = new Size(86, 30), Small = true };
        gameBtn.Click += delegate { PickGame(); };
        gp.Controls.Add(gameBtn);
        FillGames();
        y += 52;

        // the four actions: PLAY | HOST A GAME, JOIN A FRIEND (+ co-op options) | MAP VIEWER
        int third = (W - 20) / 4;
        playBtn = new Tile("PLAY", "\uE768", COrange, Color.FromArgb(236, 146, 44), Color.FromArgb(30, 14, 0)) { Location = new Point(X, y), Size = new Size(third, 104) };
        playBtn.Click += delegate { Start(Mode.Play); };
        form.Controls.Add(playBtn);
        Box cp = new Box { Location = new Point(X + third + 10, y), Size = new Size(2 * third, 104) };
        form.Controls.Add(cp);
        int half = (2 * third - 24) / 2;
        hostBtn = new Tile("HOST A GAME", "\uE716", CButton, CTeal, CText) { Location = new Point(8, 8), Size = new Size(half, 62), IconColor = Color.FromArgb(93, 202, 165) };
        hostBtn.Click += delegate { Start(Mode.Host); };
        cp.Controls.Add(hostBtn);
        joinBtn = new Tile("JOIN A FRIEND", "\uE8FA", CButton, CTeal, CText) { Location = new Point(16 + half, 8), Size = new Size(half, 62), IconColor = Color.FromArgb(93, 202, 165) };
        joinBtn.Click += delegate { Start(Mode.Join); };
        cp.Controls.Add(joinBtn);
        modeCoop = new Dot { Text = "Squad", AutoSize = true, Location = new Point(40, 78), ForeColor = CDim, BackColor = CPanel };
        modeVs = new Dot { Text = "1v1", AutoSize = true, Location = new Point(118, 78), ForeColor = CDim, BackColor = CPanel };
        padBox = new Tick { Text = "Gamepad (guest)", AutoSize = true, Location = new Point(180, 78), ForeColor = CDim, BackColor = CPanel };
        cp.Controls.Add(modeCoop); cp.Controls.Add(modeVs); cp.Controls.Add(padBox);
        mapBtn = new Tile("MAP VIEWER", "\uE707", CBlue, Color.FromArgb(47, 92, 196), Color.FromArgb(230, 238, 252)) { Location = new Point(X + 3 * third + 20, y), Size = new Size(W - 3 * third - 20, 104) };
        mapBtn.Click += delegate { Start(Mode.Maps); };
        form.Controls.Add(mapBtn);
        y += 116;

        // settings shared by every mode
        Box op = new Box { Location = new Point(X, y), Size = new Size(W, 184) };
        form.Controls.Add(op);
        op.Controls.Add(Caption("START AT", 12, 15));
        missionBox = Combo(new Point(96, 10), W - 210);
        missionBox.MaxDropDownItems = 20;
        op.Controls.Add(missionBox);
        FillMissions();
        Tile savesBtn = new Tile("Saves", null, CButton, CButtonLine, CText) { Location = new Point(W - 104, 8), Size = new Size(94, 28), Small = true };
        savesBtn.Click += delegate { Saves(); };
        op.Controls.Add(savesBtn);
        op.Controls.Add(Caption("WINDOW", 12, 49));
        sizeBox = Combo(new Point(96, 44), W - 106);
        sizeBox.Items.AddRange(new object[] { "1280 x 720", "1696 x 960", "1920 x 1080", "Fullscreen" });
        op.Controls.Add(sizeBox);
        op.Controls.Add(Caption("MOUSE", 12, 84));
        sensBar = new TrackBar { Minimum = 2, Maximum = 30, TickStyle = TickStyle.None, Location = new Point(90, 78), Size = new Size(W - 442, 30),
            BackColor = CPanel, AutoSize = false };
        sensBar.ValueChanged += delegate { sensLabel.Text = "x " + (sensBar.Value / 10.0).ToString("0.0", CultureInfo.InvariantCulture); };
        op.Controls.Add(sensBar);
        sensLabel = new Label { ForeColor = CText, BackColor = CPanel, AutoSize = true, Location = new Point(W - 346, 84) };
        op.Controls.Add(sensLabel);
        invertBox = new Tick { Text = "Invert", AutoSize = true, Location = new Point(W - 298, 82), ForeColor = CDim, BackColor = CPanel };
        op.Controls.Add(invertBox);
        op.Controls.Add(Caption("CROSSHAIR", W - 222, 84));      // (the look mode's: the game's own, a dot, or none)
        crossBox = Combo(new Point(W - 140, 79), 130);
        crossBox.Items.AddRange(new object[] { "The game's", "A dot", "None" });
        op.Controls.Add(crossBox);
        // the keys: Uplink's own two (the old school look and its pixel size: click, press the key), then the game's
        op.Controls.Add(Caption("KEYS", 12, 118));
        oldKeyBtn = new Tile("", null, CButton, CButtonLine, CText) { Location = new Point(96, 111), Size = new Size(214, 28), Small = true };
        oldKeyBtn.Click += delegate { AskKey(false); };
        op.Controls.Add(oldKeyBtn);
        sharpKeyBtn = new Tile("", null, CButton, CButtonLine, CText) { Location = new Point(318, 111), Size = new Size(214, 28), Small = true };
        sharpKeyBtn.Click += delegate { AskKey(true); };
        op.Controls.Add(sharpKeyBtn);
        Tile keysBtn = new Tile("Game keys", null, CButton, CButtonLine, CText) { Location = new Point(W - 104, 111), Size = new Size(94, 28), Small = true };
        keysBtn.Click += delegate { GameKeys(); };
        op.Controls.Add(keysBtn);
        // Shift with a move key: the game's Bound (a leap every four strides, its only fast pace), or a run without the
        // leap at the same pace (Uplink's bridge: TN_RUN)
        op.Controls.Add(Caption("SHIFT", 12, 152));
        runBox = Combo(new Point(96, 147), W - 106);
        runBox.Items.AddRange(new object[] { "Bound: the game's own, a leap every four strides", "Run: no leap, about the same pace" });
        op.Controls.Add(runBox);
        KeyLabels();
        LoadOptions();
        y += 196;

        // what is installed: green lights
        string[] names = { "Uplink", "Godot " + GODOT_VER, "Terra Nova Plus", "TN+ co-op build", "Python", "Steam (co-op only)" };
        leds = new Led[names.Length]; ledText = new Label[names.Length];
        for (int i = 0; i < names.Length; i++)
        {
            int cx = X + 2 + (i % 3) * (W / 3), cy = y + (i / 3) * 22;
            leds[i] = new Led { Location = new Point(cx, cy + 5), Size = new Size(9, 9) };
            ledText[i] = new Label { AutoSize = true, Location = new Point(cx + 14, cy), ForeColor = CDim, Font = FSmall, Tag = names[i], Text = names[i] };
            form.Controls.Add(leds[i]); form.Controls.Add(ledText[i]);
        }
        y += 50;

        // the session (co-op): what Uplink says (lobby open, friend connected, ping...), shown while one runs
        sessionRow = new Box { Location = new Point(X, y), Size = new Size(W, 34), Visible = false };
        form.Controls.Add(sessionRow);
        sessionLed = new Led { Location = new Point(12, 12), Size = new Size(10, 10), On = CDim };
        sessionRow.Controls.Add(sessionLed);
        sessionLabel = new Label { Location = new Point(30, 8), Size = new Size(W - 40, 20), ForeColor = CText, BackColor = CPanel, Text = "No session." };
        sessionRow.Controls.Add(sessionLabel);
        sessionTop = y;

        // below it (moved down while the session row shows): the status, the footer, the log
        lower = new Panel { Location = new Point(0, y), Size = new Size(W + 2 * X, 106), BackColor = CBack };
        form.Controls.Add(lower);
        statusLabel = new Label { Location = new Point(X, 0), Size = new Size(W, 40), ForeColor = CAmber, Font = new Font("Segoe UI Semibold", 10f) };
        lower.Controls.Add(statusLabel);
        bar = new ProgressBar { Location = new Point(X, 42), Size = new Size(W, 4), Style = ProgressBarStyle.Continuous, Visible = false };
        lower.Controls.Add(bar);
        // footer: update state, Discord | Log, Report a bug, Stop
        lower.Controls.Add(new Panel { BackColor = CLine, Location = new Point(X, 52), Size = new Size(W, 1) });
        verLabel = new Label { AutoSize = true, Location = new Point(X, 68), ForeColor = CDim, Font = FSmall };
        lower.Controls.Add(verLabel);
        LinkLabel dc = new LinkLabel { Text = "Discord", AutoSize = true, Location = new Point(X + 250, 68), Font = FSmall,
            LinkColor = CAmber, ActiveLinkColor = Color.White, VisitedLinkColor = CAmber };
        dc.LinkClicked += delegate { try { Process.Start(DISCORD); } catch { } };
        lower.Controls.Add(dc);
        logBtn = new Tile("Log", null, CButton, CButtonLine, CText) { Location = new Point(X + W - 308, 62), Size = new Size(70, 30), Small = true };
        logBtn.Click += delegate { logBox.Visible = !logBox.Visible; Fit(); if (logBox.Visible) { logBox.SelectionStart = logBox.TextLength; logBox.ScrollToCaret(); } };
        lower.Controls.Add(logBtn);
        reportBtn = new Tile("Report a bug", null, CButton, CButtonLine, CText) { Location = new Point(X + W - 230, 62), Size = new Size(124, 30), Small = true };
        reportBtn.Click += delegate { Report(); };
        lower.Controls.Add(reportBtn);
        stopBtn = new Tile("Stop", null, CButton, CButtonLine, CText) { Location = new Point(X + W - 96, 62), Size = new Size(96, 30), Small = true };
        stopBtn.Click += delegate { new Thread(StopAll) { IsBackground = true }.Start(); };
        lower.Controls.Add(stopBtn);
        logBox = new TextBox { Location = new Point(X, 106), Size = new Size(W, 140), Multiline = true, ReadOnly = true, Visible = false,
            ScrollBars = ScrollBars.Vertical, BackColor = CPanel, ForeColor = CDim, BorderStyle = BorderStyle.None, Font = new Font("Consolas", 8.5f) };
        lower.Controls.Add(logBox);
        Fit();
    }

    static void Fit()
    {
        lower.Top = sessionTop + (sessionRow.Visible ? 42 : 0);
        lower.Height = 106 + (logBox.Visible ? 152 : 0);
        form.ClientSize = new Size(lower.Width, lower.Bottom);
    }

    static Font Pick(string[] families, float size, FontStyle style)
    {
        foreach (string f in families)
            using (Font t = new Font(f, size, style))
                if (t.Name == f) return new Font(f, size, style);
        return null;
    }

    static Label Caption(string text, int x, int y)
    {
        return new Label { Text = text, AutoSize = true, Location = new Point(x, y), ForeColor = CDim, BackColor = CPanel, Font = FSmall };
    }

    static ComboBox Combo(Point at, int w)
    {
        return new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Location = at, Size = new Size(w, 24),
            BackColor = CButton, ForeColor = CText, FlatStyle = FlatStyle.Flat };
    }

    // a panel with rounded corners and a thin border
    class Box : Panel
    {
        public Box() { BackColor = CPanel; DoubleBuffered = true; ResizeRedraw = true; }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(Parent != null ? Parent.BackColor : CBack);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath p = Round(new Rectangle(0, 0, Width - 1, Height - 1), 10))
            using (Brush b = new SolidBrush(CPanel))
            using (Pen l = new Pen(CLine))
            { e.Graphics.FillPath(b, p); e.Graphics.DrawPath(l, p); }
        }
    }

    // a flat rounded button: an icon (Segoe's icon font) above its label, or the label alone (Small)
    class Tile : Control
    {
        public string Icon; public Color Fill, Line, Ink; public Color? IconColor; public bool Small; bool over;
        public Tile(string text, string icon, Color fill, Color line, Color ink)
        {
            Text = text; Icon = icon; Fill = fill; Line = line; Ink = ink; Cursor = Cursors.Hand;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }
        protected override void OnMouseEnter(EventArgs e) { over = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { over = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(Parent != null ? Parent.BackColor : CBack);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            Color f = !Enabled ? Mix(Fill, CBack, 0.5f) : over ? ControlPaint.Light(Fill, 0.18f) : Fill;
            using (GraphicsPath p = Round(new Rectangle(0, 0, Width - 1, Height - 1), Small ? 8 : 10))
            using (Brush b = new SolidBrush(f))
            using (Pen l = new Pen(over && Enabled ? ControlPaint.Light(Line, 0.4f) : Line, Small ? 1f : 1.5f))
            { g.FillPath(b, p); g.DrawPath(l, p); }
            Color ink = Enabled ? Ink : Mix(Ink, CBack, 0.5f);
            Font tf = Small ? FBody : FHead;
            Size ts = TextRenderer.MeasureText(Text, tf);
            if (Icon == null || FIcon == null || Small)
            {
                TextRenderer.DrawText(g, Text, tf, ClientRectangle, ink, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                return;
            }
            Size isz = TextRenderer.MeasureText(Icon, FIcon);
            int top = (Height - isz.Height - ts.Height + 2) / 2;
            TextRenderer.DrawText(g, Icon, FIcon, new Rectangle(0, top, Width, isz.Height), IconColor.HasValue && Enabled ? IconColor.Value : ink,
                TextFormatFlags.HorizontalCenter);
            TextRenderer.DrawText(g, Text, tf, new Rectangle(0, top + isz.Height - 2, Width, ts.Height), ink, TextFormatFlags.HorizontalCenter);
        }
    }

    // a check box and a radio button in the cockpit's colours (amber when on)
    class Tick : CheckBox { protected override void OnPaint(PaintEventArgs e) { PaintTick(this, e.Graphics, Checked, false); } }
    class Dot : RadioButton { protected override void OnPaint(PaintEventArgs e) { PaintTick(this, e.Graphics, Checked, true); } }

    static void PaintTick(Control c, Graphics g, bool on, bool round)
    {
        g.Clear(c.BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(1, (c.Height - 14) / 2, 13, 13);
        using (Brush b = new SolidBrush(on ? CAmber : CButton))
        using (Pen l = new Pen(on ? CAmber : CButtonLine))
        using (GraphicsPath p = Round(r, 3))
        {
            if (round) { g.FillEllipse(b, r); g.DrawEllipse(l, r); }
            else { g.FillPath(b, p); g.DrawPath(l, p); }
        }
        if (on && round) using (Brush d = new SolidBrush(CBack)) g.FillEllipse(d, r.X + 4, r.Y + 4, 5, 5);
        if (on && !round) using (Pen d = new Pen(CBack, 2f)) g.DrawLines(d, new[] { new Point(r.X + 3, r.Y + 7), new Point(r.X + 5, r.Y + 10), new Point(r.X + 10, r.Y + 3) });
        TextRenderer.DrawText(g, c.Text, c.Font, new Rectangle(19, 0, c.Width - 19, c.Height), on ? CText : CDim,
            TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
    }

    // a status light
    class Led : Control
    {
        public Color On = CLedOff;
        public Led() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Parent != null ? Parent.BackColor : CBack);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (Brush b = new SolidBrush(On)) e.Graphics.FillEllipse(b, 0, 0, Width - 1, Height - 1);
        }
    }

    static GraphicsPath Round(Rectangle r, int rad)
    {
        GraphicsPath p = new GraphicsPath();
        int d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    static Color Mix(Color a, Color b, float k)
    {
        return Color.FromArgb((int)(a.R + (b.R - a.R) * k), (int)(a.G + (b.G - a.G) * k), (int)(a.B + (b.B - a.B) * k));
    }

    static ContextMenuStrip ToolsMenu()
    {
        ContextMenuStrip m = new ContextMenuStrip();
        m.Items.Add("Open the folder", null, delegate { Process.Start("explorer.exe", "\"" + Root + "\""); });
        m.Items.Add("Check for updates now", null, delegate {
            Background(delegate { Install(Mode.Play); Status("Up to date.", CGreen); CheckUpdates(); }); });
        m.Items.Add("Import keys from my Terra Nova Plus...", null, delegate { ImportKeys(); });
        m.Items.Add("Repair (download everything again)", null, delegate { Repair(); });
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add("Uninstall...", null, delegate { Uninstall(); });
        return m;
    }

    static void Ui(Action a)
    {
        if (form == null || form.IsDisposed) return;
        try { if (form.InvokeRequired) form.BeginInvoke(a); else a(); } catch { }
    }

    static void Status(string s, Color c) { Ui(delegate { statusLabel.Text = s; statusLabel.ForeColor = c; }); Log("== " + s); }
    static void Progress(int pct) { Ui(delegate { bar.Value = Math.Max(0, Math.Min(100, pct)); bar.Visible = pct > 0; }); }

    // the session line (co-op only): it takes the status line's place while a session runs
    static void Session(string s, Color c)
    {
        Ui(delegate {
            sessionLabel.Text = s + (sessionPing != "" && c == CGreen ? "   ·   " + sessionPing : "");
            sessionLed.On = c; sessionLed.Invalidate();
            bool on = s != "No session.";
            if (sessionRow.Visible != on) { sessionRow.Visible = on; Fit(); }
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
        bool[] have = { File.Exists(Path.Combine(UplinkDir, "project.godot")), File.Exists(GodotExe), File.Exists(TnpExe), File.Exists(TnpCoopExe),
                        File.Exists(PythonExe), Process.GetProcessesByName("steam").Length > 0 };
        for (int i = 0; i < leds.Length; i++)
        {
            leds[i].On = have[i] ? CGreen : CLedOff; leds[i].Invalidate();
            ledText[i].ForeColor = have[i] ? Color.FromArgb(159, 182, 175) : CDim;
            ledText[i].Text = (string)ledText[i].Tag + (i == 0 && have[0] && Cfg("uplink_sha").Length >= 7 ? " " + Cfg("uplink_sha").Substring(0, 7) : "");
        }
        playBtn.Enabled = hostBtn.Enabled = joinBtn.Enabled = mapBtn.Enabled = gameBtn.Enabled = toolsBtn.Enabled = gameBox.Enabled = !busy;
        if (statusLabel.Text == "")
        {
            statusLabel.Text = "Ready.";
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
        StringBuilder sb = new StringBuilder("; Terra Nova Uplink\r\n");
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
        crossBox.SelectedIndex = Math.Max(0, Array.IndexOf(CROSSHAIRS, Cfg("crosshair")));
        runBox.SelectedIndex = Cfg("shift_run") == "1" ? 1 : 0;
        padBox.Checked = Cfg("gamepad") != "0";
        int mi;
        string start = Cfg("start_at") != "" ? Cfg("start_at") : Cfg("lab_mission");   // (1.x: the lab's selector)
        missionBox.SelectedIndex = int.TryParse(start, out mi) && mi >= 0 && mi < missionBox.Items.Count ? mi : 0;
    }

    static void SaveOptions()
    {
        if (sizeBox == null) return;
        Set("mode", modeVs.Checked ? "versus" : "coop");
        Set("window", SIZES[Math.Max(0, sizeBox.SelectedIndex)]);
        Set("mouse", (sensBar.Value / 10.0).ToString("0.0", CultureInfo.InvariantCulture));
        Set("invert_y", invertBox.Checked ? "1" : "0");
        Set("crosshair", CROSSHAIRS[Math.Max(0, crossBox.SelectedIndex)]);
        Set("shift_run", runBox.SelectedIndex == 1 ? "1" : "0");
        Set("gamepad", padBox.Checked ? "1" : "0");
        Set("start_at", Math.Max(0, missionBox.SelectedIndex).ToString());
        SaveCfg();
    }

    static string UplinkDir { get { return Path.Combine(Comp, "uplink"); } }
    static string GodotExe { get { return Path.Combine(Comp, "godot", "Godot_v" + GODOT_VER + "-stable_win64.exe"); } }
    static string TnpDir { get { return Path.Combine(Comp, "tnplus"); } }                // TN+ (main): PLAY
    static string TnpExe { get { return Path.Combine(TnpDir, "TNPlus.exe"); } }
    static string TnpCoopDir { get { return Path.Combine(Comp, "tnplus_coop"); } }       // TN+ co-op build: HOST
    static string TnpCoopExe { get { return Path.Combine(TnpCoopDir, "TNPlus.exe"); } }
    static string PythonExe { get { return Path.Combine(Comp, "python", "python.exe"); } }
    static string GodotData { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Godot", "app_userdata", "Terra Nova Uplink"); } }

    // ------------------------------------------------------------------ the game folder (GOG, Steam, or picked)
    static bool IsGame(string d) { return !string.IsNullOrEmpty(d) && File.Exists(Path.Combine(d, "TNOVA", "DATA", "RESMISS.RES")); }
    static bool IsSteam(string d) { return d.IndexOf("steamapps", StringComparison.OrdinalIgnoreCase) >= 0; }

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
        List<string> l = Installs();
        if (l.Count == 0) return null;
        Set("game_dir", l[0]); SaveCfg();
        return l[0];
    }

    static string Edition(string d)
    {
        if (IsSteam(d)) return "STEAM";
        try { if (Directory.GetFiles(d, "goggame-*.info").Length > 0 || d.IndexOf("GOG", StringComparison.OrdinalIgnoreCase) >= 0) return "GOG"; }
        catch { }
        return "GAME";
    }

    // every Terra Nova on the PC: those of the candidates that hold the game, each once
    static List<string> Installs()
    {
        List<string> l = new List<string>();
        foreach (string c in Candidates())
            try
            {
                string d = Path.GetFullPath(c.Trim().Trim('"'));
                if (d.Length > 3) d = d.TrimEnd('\\');
                if (IsGame(d) && !l.Exists(x => string.Equals(x, d, StringComparison.OrdinalIgnoreCase))) l.Add(d);
            }
            catch { }
        return l;
    }

    // where a Terra Nova can be: GOG's and Steam's own records, Windows' list of installed programs (any edition), the
    // usual game folders of every drive, and the folders added with Browse
    static IEnumerable<string> Candidates()
    {
        List<string> l = new List<string>();
        foreach (string k in new[] { @"SOFTWARE\WOW6432Node\GOG.com\Games", @"SOFTWARE\GOG.com\Games" })
            try
            {
                using (RegistryKey r = Registry.LocalMachine.OpenSubKey(k))
                    if (r != null)
                        foreach (string id in r.GetSubKeyNames())
                            using (RegistryKey gk = r.OpenSubKey(id))
                            {
                                string name = (gk.GetValue("gameName") ?? gk.GetValue("GAMENAME") ?? "") as string ?? "";
                                if ((id == GOG_ID || name.IndexOf("Terra Nova", StringComparison.OrdinalIgnoreCase) >= 0) && gk.GetValue("path") != null)
                                    l.Add((string)gk.GetValue("path"));
                            }
            }
            catch { }
        foreach (RegistryKey hive in new[] { Registry.LocalMachine, Registry.CurrentUser })
            foreach (string k in new[] { @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" })
                try
                {
                    using (RegistryKey r = hive.OpenSubKey(k))
                        if (r != null)
                            foreach (string id in r.GetSubKeyNames())
                                using (RegistryKey u = r.OpenSubKey(id))
                                {
                                    string name = u == null ? null : u.GetValue("DisplayName") as string, at = u == null ? null : u.GetValue("InstallLocation") as string;
                                    if (name != null && at != null && name.IndexOf("Terra Nova", StringComparison.OrdinalIgnoreCase) >= 0) l.Add(at);
                                }
                }
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
        foreach (DriveInfo dr in DriveInfo.GetDrives())
            try
            {
                if (dr.DriveType != DriveType.Fixed || !dr.IsReady) continue;
                l.Add(dr.RootDirectory.FullName);                          // a plain DOS install (X:\TNOVA)
                foreach (string sub in new[] { "", "GOG Games", "Games", @"Program Files (x86)\GOG Galaxy\Games", @"Program Files\GOG Galaxy\Games",
                                               @"SteamLibrary\steamapps\common", @"Steam\steamapps\common", @"Program Files (x86)\Steam\steamapps\common",
                                               "Program Files (x86)", "Program Files" })
                {
                    string at = Path.Combine(dr.RootDirectory.FullName, sub);
                    if (Directory.Exists(at)) l.AddRange(Directory.GetDirectories(at, "*Terra*Nova*"));
                }
            }
            catch { }
        foreach (string d in Cfg("game_dirs").Split('|'))
            if (d.Trim() != "") l.Add(d);
        return l;
    }

    static void FillGames()
    {
        List<string> l = Installs();
        string g = Game();
        if (g != null && !l.Exists(x => string.Equals(x, g, StringComparison.OrdinalIgnoreCase))) l.Insert(0, g);
        gameBox.Items.Clear();
        foreach (string d in l) gameBox.Items.Add(d);
        if (l.Count == 0) gameBox.Items.Add("");
        int at = l.FindIndex(x => string.Equals(x, g, StringComparison.OrdinalIgnoreCase));
        gameBox.SelectedIndex = Math.Max(0, at);
    }

    static void PickInstall()
    {
        string d = gameBox.SelectedItem as string;
        if (string.IsNullOrEmpty(d) || string.Equals(d, Cfg("game_dir"), StringComparison.OrdinalIgnoreCase)) return;
        Set("game_dir", d); SaveCfg(); FillMissions(); RefreshUi();
        Log("game: " + d);
    }

    // an install: GOG / STEAM on green, then its folder
    static void DrawGame(object s, DrawItemEventArgs e)
    {
        ComboBox c = (ComboBox)s;
        bool edit = (e.State & DrawItemState.ComboBoxEdit) != 0, sel = (e.State & DrawItemState.Selected) != 0 && !edit;
        using (Brush b = new SolidBrush(sel ? CTeal : CButton)) e.Graphics.FillRectangle(b, e.Bounds);
        if (e.Index < 0) return;
        string d = (string)c.Items[e.Index];
        Rectangle tag = new Rectangle(e.Bounds.X + 3, e.Bounds.Y + 2, 58, e.Bounds.Height - 4);
        using (Brush b = new SolidBrush(d == "" ? Color.FromArgb(70, 24, 20) : Color.FromArgb(18, 58, 34))) e.Graphics.FillRectangle(b, tag);
        TextRenderer.DrawText(e.Graphics, d == "" ? "NONE" : Edition(d), FSmall, tag, d == "" ? CRed : CGreen,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        TextRenderer.DrawText(e.Graphics, d == "" ? "No Terra Nova found: Browse, then pick the folder that contains TNOVA" : d, c.Font,
            new Rectangle(tag.Right + 8, e.Bounds.Y, e.Bounds.Right - tag.Right - (edit ? 28 : 10), e.Bounds.Height), d == "" ? CDim : CText,
            TextFormatFlags.VerticalCenter | TextFormatFlags.PathEllipsis | TextFormatFlags.NoPrefix);
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
            if (!Installs().Exists(x => string.Equals(x, p, StringComparison.OrdinalIgnoreCase)))
                Set("game_dirs", (Cfg("game_dirs") + "|" + p).Trim('|'));          // kept in the list
            Set("game_dir", p); SaveCfg(); FillGames(); FillMissions(); RefreshUi();
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

    // ------------------------------------------------------------------ play / host / join / map viewer
    static void Start(Mode m)
    {
        if (busy) return;
        SaveOptions();
        if (Game() == null) { PickGame(); if (Game() == null) return; }
        if (m == Mode.Host && !IsEnglish(Game()))
        {   // the co-op code only knows the English exe: another install of the PC that has it
            string en = Installs().Find(IsEnglish);
            if (en == null)
            {
                MessageBox.Show(form, "Hosting needs the English version of the game (Steam's, or GOG's in English), and none was found. Add one with Browse.", TITLE);
                return;
            }
            Set("game_dir", en); SaveCfg(); FillGames(); FillMissions(); RefreshUi();
            Log("hosting: the English game, " + en);
        }
        sessionName = sessionPing = "";
        coopRun = m == Mode.Host || m == Mode.Join;
        Background(delegate {
            if (m == Mode.Play || m == Mode.Host) Live(m == Mode.Host);
            else if (m == Mode.Join) Join();
            else Maps();
        });
    }

    // PLAY and HOST A GAME: the game through TN+ (its co-op build to host), then the bridge, which opens Uplink live
    static void Live(bool host)
    {
        Status("Getting things ready...", CAmber);
        Install(host ? Mode.Host : Mode.Play);
        bool running;
        if (!Preflight(host, out running) || (host && !SteamUp())) return;
        string dir = host ? TnpCoopDir : TnpDir, exe = host ? TnpCoopExe : TnpExe;
        wholeMenus = !running || (ownGame && WholeMenusIni(dir));   // (see Env)
        string load = null;
        int pick;
        if (int.TryParse(Cfg("start_at"), out pick) && pick > 0)
        {
            load = MakeSave(Game(), pick - 1, host ? COOP_SAVE : PLAY_SAVE);
            if (load == null) return;
        }
        Process tnp = null;
        if (!running)
        {
            WriteTnpIni(dir, Game());
            if (host) SyncKeys();
            Status("Starting the game (Terra Nova Plus" + (host ? ", co-op build" : "") + ")...", CAmber);
            if (host) Session("Starting the game...", CAmber);
            // the game windowed, Uplink's size (the editions start DOSBox fullscreen, and a fullscreen DOSBox comes back
            // over Uplink at each video mode change): on the menus the bridge reads the game's screen from this window
            string conf = Path.Combine(dir, host ? "coop_host.conf" : "uplink_live.conf");
            File.WriteAllLines(conf, new[] { "# Terra Nova Uplink: the game in a window behind Uplink's (Uplink draws it)",
                "[sdl]", "fullscreen = false", "windowresolution = " + (Cfg("window") == "native" || Cfg("window") == "" ? "1696x960" : Cfg("window")) });
            tnp = Run(exe, "--launch --conf \"" + conf + "\"", dir, null, false);
        }
        else Log("the game is already running: Uplink attaches to it (it needs TN+ Display HD 848x480)");
        // the bridge needs the game's code loaded: tried every few seconds until it stays up
        Status("Waiting for the game to load...", CAmber);
        Process bridge = null;
        DateTime t0 = DateTime.Now;
        while (!stopping)
        {
            if ((tnp == null || tnp.HasExited) && Process.GetProcessesByName("dosbox-staging").Length == 0)
            { Status("The game was closed.", CText); Session("No session.", CDim); return; }
            if ((DateTime.Now - t0).TotalMinutes > 5)
            { Status("The game didn't load in 5 minutes: see the log (Log).", CRed); return; }
            Thread.Sleep(3000);
            bridge = Bridge(host, dir);
            DateTime b0 = DateTime.Now;
            while (!bridge.HasExited && (DateTime.Now - b0).TotalSeconds < 12) Thread.Sleep(250);
            if (!bridge.HasExited) break;
            Log("bridge not ready yet (" + bridge.ExitCode + "), trying again");
        }
        if (stopping || bridge == null) return;
        if (host)
            Status(load != null ? "Uplink is open. In the game: Load Game, then \"" + load + "\". Invite your friend from Uplink's list (top right)." :
                "Uplink is open: invite your friend from its list (top right), go to Mission Outfitting, wait for READY.", CGreen);
        else
            Status(load != null ? "Uplink is open. In the game: Load Game, then \"" + load + "\"." :
                "Uplink is open: click in its window to take the mouse, " + ScanName(FreelookScan()) + " for the game's cursor, " + KeyName(OldKey()) +
                " for the old school look" + (SharpKey() != "" ? " (" + KeyName(SharpKey()) + ": finer pixels)." : "."), CGreen);
        int n = 0;
        while (!stopping && !bridge.HasExited)
        {
            Thread.Sleep(500);
            if (tnp != null && ++n % 4 == 0) KeepGameBehind();
        }
        if (!stopping)
        {
            Status(tnp != null && CloseOurGame() ? "Uplink was closed: the game too." :
                Process.GetProcessesByName("dosbox-staging").Length == 0 ? "The game was closed." :
                "Uplink was closed. Click " + (host ? "HOST A GAME" : "PLAY") + " to open it again.", CText);
            Session("No session.", CDim);
        }
    }

    // the game's window tucked right behind Uplink's: out of sight, but not minimized (on the menus the bridge
    // photographs it, PrintWindow, which a minimized window can't give). Left alone while it is in front (the player
    // brought it up); put back behind when it comes up by itself
    static WRect lastUp;

    static void KeepGameBehind()
    {
        IntPtr up = IntPtr.Zero;
        foreach (Process g in Process.GetProcesses())
            try { if (g.ProcessName.StartsWith("Godot") && g.MainWindowHandle != IntPtr.Zero && Ours(g, UplinkDir)) { up = g.MainWindowHandle; break; } } catch { }
        if (up == IntPtr.Zero) return;
        WRect ur;
        if (!GetWindowRect(up, out ur)) return;
        bool still = ur.Left == lastUp.Left && ur.Top == lastUp.Top;   // not while Uplink is being dragged
        lastUp = ur;
        foreach (Process d in Process.GetProcessesByName("dosbox-staging"))
            try
            {
                d.Refresh();
                IntPtr h = d.MainWindowHandle;
                if (h == IntPtr.Zero || GetForegroundWindow() == h || !(Ours(d, TnpDir) || Ours(d, TnpCoopDir))) continue;
                WRect r;
                GetWindowRect(h, out r);
                bool iconic = IsIconic(h);
                if (iconic) ShowWindow(h, 4);                      // restored without taking the focus
                if (iconic || (still && (r.Left != ur.Left || r.Top != ur.Top)))
                {   // under Uplink's window, at its place: moved only once Uplink has stopped moving
                    SetWindowPos(h, up, ur.Left, ur.Top, 0, 0, 0x0001 | 0x0010);
                    Log("game window behind Uplink");
                }
            }
            catch { }
    }

    // only what this launcher started: its DOSBox (our conf, in tnplus\ or tnplus_coop\) and its Uplink (in uplink\).
    // Another DOSBox game or another Uplink open on the PC is left where it is. Looked up once per process
    static Dictionary<string, bool> ours = new Dictionary<string, bool>();

    static bool Ours(Process p, string dir)
    {
        bool b;
        string key = p.Id + "|" + dir;
        if (ours.TryGetValue(key, out b)) return b;
        try
        {
            using (ManagementObjectSearcher s = new ManagementObjectSearcher("SELECT CommandLine FROM Win32_Process WHERE ProcessId = " + p.Id))
                foreach (ManagementObject o in s.Get())
                    b = ((string)o["CommandLine"] ?? "").IndexOf(dir + "\\", StringComparison.OrdinalIgnoreCase) >= 0;
        }
        catch { return false; }
        return ours[key] = b;
    }

    static Process Bridge(bool host, string dir)
    {
        Dictionary<string, string> env = Env();
        env["PYTHONIOENCODING"] = "utf-8";
        env["PYTHONUNBUFFERED"] = "1";
        // the game this launcher started: with another DOSBox open too, the bridge would not know which one to read
        Proc game = Procs().Find(p => p.Name == "dosbox-staging.exe" && p.Cmd.IndexOf(dir + "\\", StringComparison.OrdinalIgnoreCase) >= 0);
        if (game != null) env["TNRE_PID"] = game.Id.ToString();
        return Run(PythonExe, "-u \"" + Path.Combine(UplinkDir, "live", "live_bridge.py") + "\" --launch --hud --play" +
            (host ? " --guest-remote" : "") + " --fov 91.5 --res " + Cfg("window") + (host && Cfg("mode") == "versus" ? " --versus" : ""),
            UplinkDir, env, true);
    }

    static void Join()
    {
        Status("Getting things ready...", CAmber);
        Install(Mode.Join);
        bool running;
        if (!Preflight(false, out running) || !SteamUp()) return;
        Status("Opening Uplink...", CAmber);
        Session("Opening Uplink...", CAmber);
        string size = Cfg("window");
        string win = size == "native" ? "" : "--resolution " + size + " ";
        Dictionary<string, string> env = Env();
        List<string> km = new List<string>();                  // his keys (Game keys): Uplink turns them before sending
        foreach (KeyValuePair<int, int> kv in KeyMap()) km.Add(kv.Key.ToString("X2") + ":" + kv.Value.ToString("X2"));
        env["TN_KEYS"] = string.Join(",", km.ToArray());
        Process g = Run(GodotExe, "--path \"" + UplinkDir + "\" " + win + "-- --live --coop-guest --live-port 47831 --play --play-port 47834" +
            (size == "native" ? " --native" : ""), UplinkDir, env, true);
        Status("Uplink is open: click JOIN next to your friend (he must have clicked HOST A GAME).", CGreen);
        while (!stopping && !g.HasExited) Thread.Sleep(500);
        if (!stopping) { Status("Uplink was closed.", CText); Session("No session.", CDim); }
    }

    static void Maps()
    {
        Status("Getting things ready...", CAmber);
        Install(Mode.Maps);
        Status("Opening the map viewer...", CAmber);
        string size = Cfg("window");
        string win = size == "native" ? "" : "--resolution " + size + " ";
        Process g = Run(GodotExe, "--path \"" + UplinkDir + "\" " + win + (size == "native" ? "-- --native" : ""), UplinkDir, Env(), true);
        Status("Map viewer open: right mouse button to look, WASD to move, Tab for the mission list.", CGreen);
        while (!stopping && !g.HasExited) Thread.Sleep(500);
        if (!stopping) Status("Uplink was closed.", CText);
    }

    // The game's menus come whole in its picture when this launcher started the game (wide_menus = 1 in its TNPlus.ini,
    // also for a game it started earlier and finds still running): Uplink then keeps their 4:3 itself. A game the
    // player started himself keeps his TN+'s own way (1.2.5 narrows the menus in the picture by default): Uplink shows
    // that picture over its whole window, as it always did.
    static bool wholeMenus = false, ownGame = false;

    static bool WholeMenusIni(string dir)
    {
        try
        {
            string ini = Path.Combine(dir, "TNPlus.ini");
            if (!File.Exists(ini)) return false;
            foreach (string l in File.ReadAllLines(ini))
                if (Regex.IsMatch(l, @"^\s*wide_menus\s*=\s*1\s*$")) return true;
        }
        catch (Exception) { }
        return false;
    }

    static Dictionary<string, string> Env()
    {
        Dictionary<string, string> env = new Dictionary<string, string>();
        env["TN_MENUS43"] = wholeMenus ? "1" : "0";
        env["GODOT"] = GodotExe;
        env["TN_GAME_DIR"] = Game();
        env["TN_MOUSE_SENS"] = Cfg("mouse");
        env["TN_INVERT_Y"] = Cfg("invert_y");
        env["TN_KEY_FREELOOK"] = FreelookScan().ToString("X2");
        env["TN_KEY_OLDSCHOOL"] = OldKey();
        env["TN_KEY_SHARP"] = SharpKey();
        env["TN_BINDS"] = Binds();
        env["TN_CROSSHAIR"] = Cfg("crosshair");
        env["TN_RUN"] = Cfg("shift_run") == "1" ? "1" : "0";
        env["TN_NO_PAD"] = Cfg("gamepad") == "0" ? "1" : "0";
        return env;
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

    // running: the game is already open (started by the player with TN+): PLAY attaches to it. HOST needs the game
    // started by its co-op build: another one is closed first (asked)
    static bool Preflight(bool host, out bool running)
    {
        List<Proc> ps = Procs();
        running = false;
        // an Uplink or bridge already open (another launch, a .bat): same ports, the new one would not get its packets
        List<Proc> old = ps.FindAll(p => (p.Name.StartsWith("Godot") && p.Cmd.Contains("--live")) ||
                                         (p.Name == "python.exe" && p.Cmd.Contains("live_bridge.py")));
        if (old.Count > 0)
        {
            if (!Ask("Uplink's live mode is already open (" + old.Count + " program(s)). Close it and start again?"))
            { Status("Close the other Uplink first.", CRed); return false; }
            foreach (Proc p in old) Kill(p.Id);
            Thread.Sleep(1000);
        }
        List<Proc> games = ps.FindAll(p => p.Name == "dosbox-staging.exe");
        ownGame = games.Exists(p => p.Cmd.IndexOf(TnpDir + "\\", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                    p.Cmd.IndexOf(TnpCoopDir + "\\", StringComparison.OrdinalIgnoreCase) >= 0);
        if (host)
        {   // a game started without the co-op build has no co-op code: it must be started again from here
            bool ok = games.Exists(p => p.Cmd.IndexOf(TnpCoopDir + "\\", StringComparison.OrdinalIgnoreCase) >= 0);
            if (games.Count > 0 && !ok)
            {
                if (!Ask("Terra Nova is already running, started without the co-op build. Close it so it can start again for the co-op? (save your game first)"))
                { Status("Close the game first.", CRed); return false; }
                foreach (Proc p in games) Kill(p.Id);
                foreach (Proc p in ps.FindAll(q => q.Name == "TNPlus.exe")) Kill(p.Id);
                Thread.Sleep(1500);
            }
            else running = ok;
        }
        else running = games.Count > 0;
        return true;
    }

    // Uplink closed: the game this launcher started goes with it (its DOSBox, started by our TN+ with our conf, then
    // TN+ itself, which ends with it). A game the player started himself is left alone.
    static bool CloseOurGame()
    {
        bool any = false;
        foreach (Proc p in Procs())
            if (p.Name == "dosbox-staging.exe" && (p.Cmd.IndexOf(TnpDir + "\\", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                                   p.Cmd.IndexOf(TnpCoopDir + "\\", StringComparison.OrdinalIgnoreCase) >= 0))
            {
                any = true;
                try
                {
                    Process d = Process.GetProcessById(p.Id);
                    Log("closing the game (DOSBox " + p.Id + ")");
                    d.CloseMainWindow();
                    if (!d.WaitForExit(3000)) d.Kill();
                }
                catch { }
            }
        Thread.Sleep(500);
        foreach (Proc p in Procs())
            if (p.Name == "TNPlus.exe" && (p.Cmd.IndexOf(TnpDir + "\\", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                           p.Cmd.IndexOf(TnpCoopDir + "\\", StringComparison.OrdinalIgnoreCase) >= 0)) Kill(p.Id);
        return any;
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
        if (!coopRun) return;                                              // PLAY, MAP VIEWER: no session to show
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

    // ------------------------------------------------------------------ start at a mission
    // A campaign mission is picked by a save: the most advanced one of the game (its squad, pilots and equipment) is
    // copied into a free slot as "UPLINK Mission NN" (PLAY) or "COOP Mission NN" (HOST), its header (resource 1776,
    // read by the game into 0x359708 = the mission's MISSn.RES and 0x35D0EC = the campaign position + 3) set on the
    // picked mission. The player loads it.
    static void FillMissions()
    {
        int keep = missionBox.SelectedIndex;
        missionBox.Items.Clear();
        missionBox.Items.Add("From the game's menus");
        string g = Game();
        string[] names = g != null ? MissionNames(g) : null;
        for (int i = 0; i < CAMPAIGN.Length; i++)
        {
            int n = CAMPAIGN[i];
            string nm = names != null && n - 1 < names.Length && names[n - 1].Trim() != "" ? names[n - 1].Trim() : "MISS" + n;
            missionBox.Items.Add((i + 1).ToString("00") + "   " + nm);
        }
        if (keep >= 0 && keep < missionBox.Items.Count) missionBox.SelectedIndex = keep;
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

    static string MakeSave(string game, int index, string prefix)
    {
        string dir = Path.Combine(game, "TNOVA");
        Res best = null;
        int bestPos = -1, ourSlot = -1, free = -1;
        for (int slot = 1; slot <= 9; slot++)
        {
            string f = Path.Combine(dir, "SAVE" + slot.ToString("00") + ".RES");
            if (!File.Exists(f)) { if (free < 0) free = slot; continue; }
            try
            {
                Res r = Res.Load(f);
                string name = Encoding.ASCII.GetString(r.Data(1775)).TrimEnd('\0');
                if (name.StartsWith(prefix) || (prefix == PLAY_SAVE && name.StartsWith("LAB Mission ")))   // (1.x: the lab's)
                { if (ourSlot < 0) ourSlot = slot; continue; }
                if (Array.Exists(OUR_SAVES, s => name.StartsWith(s))) continue;
                byte[] h = r.Data(1776);
                int pos = BitConverter.ToInt32(h, 8);
                if (BitConverter.ToInt32(h, 0) == 0x06EF0018 && pos > bestPos) { bestPos = pos; best = r; }
            }
            catch (Exception e) { Log("SAVE" + slot.ToString("00") + ": " + e.Message); }
        }
        if (best == null)
        {
            Status("To start at a mission, the game needs at least one save of yours (play the first mission and save).", CRed);
            return null;
        }
        int target = ourSlot > 0 ? ourSlot : free;          // our own slot again, else a free one: never a save of yours
        if (target < 0)
        {
            Status("The 9 save slots are all used: free one with Saves (or start from the game's menus).", CRed);
            return null;
        }
        string label = prefix + (index + 1).ToString("00");
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

    // The game's 9 save slots: one can be deleted to free it (the file goes to components\save backups, not lost)
    static void Saves()
    {
        string g = Game();
        if (g == null) { PickGame(); g = Game(); if (g == null) return; }
        string dir = Path.Combine(g, "TNOVA");
        Form d = new Form { Text = "Saves", ClientSize = new Size(460, 300), FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false, MinimizeBox = false, StartPosition = FormStartPosition.CenterParent, BackColor = CBack, ForeColor = CText,
            Font = form.Font, ShowInTaskbar = false };
        ListBox list = new ListBox { Location = new Point(12, 12), Size = new Size(436, 220), BackColor = CPanel, ForeColor = CText,
            BorderStyle = BorderStyle.None, Font = new Font("Consolas", 10f) };
        d.Controls.Add(list);
        Action fill = delegate {
            list.Items.Clear();
            for (int slot = 1; slot <= 9; slot++)
            {
                string f = Path.Combine(dir, "SAVE" + slot.ToString("00") + ".RES");
                string what = "(empty)";
                if (File.Exists(f))
                    try
                    {
                        Res r = Res.Load(f);
                        what = Encoding.ASCII.GetString(r.Data(1775)).TrimEnd('\0');
                        byte[] h = r.Data(1776);
                        if (BitConverter.ToInt32(h, 0) == 0x06EF0018 && !Array.Exists(OUR_SAVES, s => what.StartsWith(s)))
                            what += "  (mission " + (BitConverter.ToInt32(h, 8) - 2).ToString("00") + ")";
                    }
                    catch { what = "(unreadable)"; }
                list.Items.Add(slot + "  " + what);
            }
        };
        fill();
        Tile del = new Tile("Delete", null, Color.FromArgb(110, 34, 30), Color.FromArgb(150, 54, 46), CText) { Location = new Point(12, 250), Size = new Size(120, 34), Small = true };
        del.Click += delegate {
            int slot = list.SelectedIndex + 1;
            string f = Path.Combine(dir, "SAVE" + slot.ToString("00") + ".RES");
            if (slot < 1 || !File.Exists(f)) return;
            if (MessageBox.Show(d, "Delete save " + list.SelectedItem + "?\nA copy is kept in components\\save backups.", "Saves",
                MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            try
            {
                string bk = Path.Combine(Comp, "save backups");
                Directory.CreateDirectory(bk);
                string to = Path.Combine(bk, "SAVE" + slot.ToString("00") + " " + DateTime.Now.ToString("yyyy-MM-dd HH-mm-ss") + ".RES");
                File.Move(f, to);
                Log("save " + slot + " deleted (copy: " + to + ")");
                Status("Save " + slot + " deleted: the slot is free.", CGreen);
            }
            catch (Exception e) { Log("save " + slot + ": " + e.Message); MessageBox.Show(d, e.Message, "Saves"); }
            fill();
        };
        d.Controls.Add(del);
        Tile close = new Tile("Close", null, CButton, CButtonLine, CText) { Location = new Point(328, 250), Size = new Size(120, 34), Small = true };
        close.Click += delegate { d.Close(); };
        d.Controls.Add(close);
        d.ShowDialog(form);
        d.Dispose();
    }

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
            "TerraNovaUplink_report_" + DateTime.Now.ToString("yyyy-MM-dd_HH-mm") + ".zip");
        try
        {
            using (ZipArchive a = ZipFile.Open(zip, ZipArchiveMode.Create))
            {
                StringBuilder info = new StringBuilder();
                string g = Game();
                info.AppendLine(TITLE + " " + VERSION + ", " + Environment.OSVersion + (Environment.Is64BitOperatingSystem ? ", 64-bit" : ""));
                info.AppendLine("game: " + g + (g != null && IsEnglish(g) ? " (English)" : " (not English)"));
                info.AppendLine("uplink " + Cfg("uplink_sha") + ", tnplus " + Cfg("tnplus_sha") + ", tnplus coop " + Cfg("tnplus_coop_sha"));
                info.AppendLine("options: mode " + Cfg("mode") + ", window " + Cfg("window") + ", mouse " + Cfg("mouse") +
                                ", invert " + Cfg("invert_y") + ", gamepad " + Cfg("gamepad") + ", start at " + Cfg("start_at"));
                info.AppendLine("session: " + (sessionLabel != null ? sessionLabel.Text : "-"));
                foreach (Proc p in Procs()) info.AppendLine("running: " + p.Name + " " + p.Id);
                using (StreamWriter w = new StreamWriter(a.CreateEntry("info.txt").Open())) w.Write(info.ToString());
                Add(a, LogPath, "launcher.log");
                Add(a, Path.Combine(TnpDir, "TNPlus.ini"), "TNPlus.ini");
                Add(a, Path.Combine(TnpCoopDir, "TNPlus.ini"), "TNPlus_coop.ini");
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

    // ------------------------------------------------------------------ TN+ settings: HD 848x480 (the live mode's)
    static void WriteTnpIni(string dir, string game)
    {
        Directory.CreateDirectory(dir);
        string ini = Path.Combine(dir, "TNPlus.ini"), other = Path.Combine(dir == TnpDir ? TnpCoopDir : TnpDir, "TNPlus.ini");
        if (!File.Exists(ini) && File.Exists(other)) CopyKeys(other, ini);    // a first TN+ of the two: the keys of the other
        // HD 848x480 (the bridge reads the cockpit from it). Terrain detail: TN+'s SHARPER, not the game's: the game
        // moves the player on the ground it draws, and with its own detail that ground is not kept up to date while he
        // looks up (jets into a slope pushed him down and back; SHARPER alone fixes it, tested 21/10/2026). Objects: TN+'s
        // MAX (the game locks only what it draws: at its own distance far targets could not be locked; the far suits it
        // then draws enlarged are left out by the bridge, Uplink walks them at their own size). Menus: TN+ 1.2.5 narrows
        // the 640 x 480 screens in the game's picture to keep their proportions in true 16:9 (columns of pixels dropped);
        // Uplink shows that picture itself and keeps their proportions on its own, from the whole picture: wide_menus = 1
        Dictionary<string, string> want = new Dictionary<string, string> {
            { "display", "HD" }, { "widescreen", "2" }, { "update_check", "0" }, { "game_dir", game },
            { "terrain_detail", "SHARPER" }, { "object_distance", "MAX" }, { "view_distance", "NORMAL" },
            { "small_views", "0" }, { "edge_objects", "0" }, { "field_of_view", "GAME" }, { "wide_menus", "1" } };
        List<string> lines = File.Exists(ini) ? new List<string>(File.ReadAllLines(ini)) : new List<string> { "; Terra Nova Plus settings (written by Terra Nova Uplink)" };
        foreach (KeyValuePair<string, string> kv in want)
        {
            int at = lines.FindIndex(l => Regex.IsMatch(l, "^\\s*" + kv.Key + "\\s*="));
            string line = kv.Key + " = " + kv.Value;
            if (at >= 0) lines[at] = line; else lines.Add(line);
        }
        File.WriteAllLines(ini, lines);
    }

    // ------------------------------------------------------------------ the game's keys (TN+'s KEYBOARD page)
    // TN+ changes the keys in the game itself (TNPlus.ini next to its exe: key_game_<id> = [SHIFT+|CTRL+|ALT+]scancode).
    // "Game keys" opens that page of our TN+ (tnplus\, the one PLAY uses); the co-op build gets the same keys (SyncKeys),
    // and a guest's keys are turned by Uplink from them (KeyMap). "Import" copies the keys of a TN+ already set up
    static void GameKeys()
    {
        if (busy) return;
        Background(delegate {
            if (!File.Exists(TnpExe))
            {
                Status("Downloading and building Terra Nova Plus (for its key settings)...", CAmber);
                BuildTnp(false);
                string tp = Get(Heads(), Head(TNPLUS_REPO, TNPLUS_BRANCH));
                if (tp != null) Set("tnplus_sha", tp);
                SaveCfg();
            }
            if (Game() != null) WriteTnpIni(TnpDir, Game());
            Status("Set your keys in the window that opened, then click DONE.", CAmber);
            Process p = Run(TnpExe, "--keys", TnpDir, null, false);
            p.WaitForExit();
            SyncKeys();
            Status("Keys saved: " + KeysSummary(), CGreen);
        });
    }

    static readonly string[] KEY_LINES = { "key_", "keys_", "mouse_", "invert_y" };

    static void ImportKeys()
    {
        using (OpenFileDialog d = new OpenFileDialog())
        {
            d.Title = "Pick the TNPlus.ini of your Terra Nova Plus (next to its TNPlus.exe)";
            d.Filter = "TNPlus.ini|TNPlus.ini|ini files|*.ini";
            if (d.ShowDialog(form) != DialogResult.OK) return;
            int n = CopyKeys(d.FileName, Path.Combine(TnpDir, "TNPlus.ini"));
            SyncKeys();
            Status(n + " key and mouse settings imported: " + KeysSummary(), CGreen);
        }
    }

    // the key lines of one TNPlus.ini into another (its other settings kept)
    static int CopyKeys(string from, string to)
    {
        if (!File.Exists(from)) return 0;
        List<string> mine = File.Exists(to) ? new List<string>(File.ReadAllLines(to)) : new List<string>();
        mine.RemoveAll(l => Array.Exists(KEY_LINES, k => l.TrimStart().StartsWith(k)));
        int n = 0;
        foreach (string l in File.ReadAllLines(from))
            if (Array.Exists(KEY_LINES, k => l.TrimStart().StartsWith(k))) { mine.Add(l); n++; }
        Directory.CreateDirectory(Path.GetDirectoryName(to));
        File.WriteAllLines(to, mine);
        return n;
    }

    static void SyncKeys()
    {
        string solo = Path.Combine(TnpDir, "TNPlus.ini");
        if (File.Exists(solo) && Directory.Exists(TnpCoopDir)) CopyKeys(solo, Path.Combine(TnpCoopDir, "TNPlus.ini"));
    }

    // TN+'s commands that have a key of their own by default (id, scancode): the guest's keys are turned by Uplink
    static readonly string[] DEFAULT_KEYS = {
        "fwd:11", "back:2D", "turnl:1E", "turnr:20", "stop:1F", "sidel:2C", "sider:2E", "jump:39", "crouch:29", "bound:2A",
        "lookup:13", "lookdn:2F", "lookl:10", "lookr:12", "centre:21", "v360:30", "full:22", "ir:17", "zoomin:0D",
        "zoomout:0C", "mfd:0F", "w1:02", "w2:03", "w3:04", "w4:05", "asf:06", "tnext:14", "tprev:15",
        "sq1:3B", "sq2:3C", "sq3:3D", "sqall:3E", "drop:1C", "recentre:31", "maphud:32", "mapout:33", "mapin:34",
        "squadinfo:43", "sensor:44", "wrange:57", "minfo:58" };

    // TN+'s other commands (TNPlusKeys.cs), which come with a modifier or have no key to turn for a guest: with
    // DEFAULT_KEYS, every command a second bind can press
    static readonly string[] CHORD_KEYS = {
        "o_attack:ALT+1E", "o_cover:ALT+2E", "o_caution:ALT+20", "o_form:ALT+21", "o_hold:ALT+23", "o_follow:ALT+32",
        "o_nav:ALT+31", "o_pickup:ALT+19", "o_retreat:ALT+13", "o_status:ALT+1F", "o_target:ALT+14",
        "d_up:CTRL+C9", "d_down:CTRL+D1", "d_recall:CTRL+C7", "pause:19", "objectives:42", "help:35", "exit:ALT+2D" };

    // TN+'s second binds (its KEYBOARD page: the middle and side buttons, the wheel, PgUp / PgDn, Home / End, Ins /
    // Del can press a command's key as well: mouse_<command> = MID, M4, M5, WHEELUP, WHEELDOWN, PGUP...). TN+ only
    // acts on them when the game's own window is in front: behind Uplink's they did nothing (ticket #7). Uplink does
    // it instead, told here which input presses which key (TN_BINDS: NAME:[SHIFT+|CTRL+|ALT+]scancode, the command's
    // key being the player's own, or NAME:FREELOOK for the look / cursor swap).
    static string Binds()
    {
        string ini = KeysIni();
        if (!File.Exists(ini)) return "";
        Dictionary<string, string> chord = new Dictionary<string, string>();
        foreach (string dk in DEFAULT_KEYS) chord[dk.Split(':')[0]] = dk.Split(':')[1];
        foreach (string dk in CHORD_KEYS) chord[dk.Split(':')[0]] = dk.Split(':')[1];
        List<string[]> mouse = new List<string[]>();
        foreach (string l in File.ReadAllLines(ini))
        {
            Match k = Regex.Match(l, @"^\s*key_game_(\w+)\s*=\s*((?:(?:SHIFT|CTRL|ALT)\+)?[0-9A-Fa-f]{1,2})\s*$", RegexOptions.IgnoreCase);
            if (k.Success && chord.ContainsKey(k.Groups[1].Value)) chord[k.Groups[1].Value] = k.Groups[2].Value.ToUpperInvariant();
            Match m = Regex.Match(l, @"^\s*mouse_(\w+)\s*=\s*(\w+)\s*$");
            if (m.Success) mouse.Add(new[] { m.Groups[1].Value, m.Groups[2].Value.ToUpperInvariant() });
        }
        List<string> b = new List<string>();
        foreach (string[] m in mouse)
        {
            string c;
            if (m[0] == "freelook") b.Add(m[1] + ":FREELOOK");
            else if (chord.TryGetValue(m[0], out c))
            {
                int plus = c.LastIndexOf('+');                    // (TN+ writes the grey block's keys 0x80 + code: E0xx here)
                int sc = Convert.ToInt32(c.Substring(plus + 1), 16);
                b.Add(m[1] + ":" + c.Substring(0, plus + 1) + (sc >= 0x80 ? "E0" + (sc & 0x7F).ToString("X2") : sc.ToString("X2")));
            }
        }
        return string.Join(",", b.ToArray());
    }

    static string KeysIni()
    {
        string solo = Path.Combine(TnpDir, "TNPlus.ini"), coop = Path.Combine(TnpCoopDir, "TNPlus.ini");
        return File.Exists(solo) ? solo : coop;
    }

    static Dictionary<int, int> KeyMap()
    {
        Dictionary<int, int> m = new Dictionary<int, int>();
        string ini = KeysIni();
        if (!File.Exists(ini)) return m;
        Dictionary<string, int> def = new Dictionary<string, int>();
        foreach (string dk in DEFAULT_KEYS) def[dk.Split(':')[0]] = Convert.ToInt32(dk.Split(':')[1], 16);
        Dictionary<int, int> moved = new Dictionary<int, int>();          // new key -> the command's default key
        foreach (string l in File.ReadAllLines(ini))
        {
            Match mm = Regex.Match(l, @"^\s*key_game_(\w+)\s*=\s*([0-9A-Fa-f]{1,2})\s*$");   // plain keys only (no modifier)
            int d;
            if (mm.Success && def.TryGetValue(mm.Groups[1].Value, out d)) moved[Convert.ToInt32(mm.Groups[2].Value, 16)] = d;
        }
        foreach (KeyValuePair<int, int> kv in moved) m[kv.Key] = kv.Value;
        foreach (int d in moved.Values) if (!moved.ContainsKey(d) && d != 0x2A) m[d] = 0;   // the old key of a moved command: nothing
                                                                              // (Shift, the bound's: still Shift, as in TN+)
        return m;
    }

    // TN+'s freelook key (key_freelook, a PC scancode; Y unless changed): in Uplink it gives the game's cursor and takes
    // the mouse back. Uplink is told which (TN_KEY_FREELOOK); the status line names it as this keyboard prints it
    static int FreelookScan()
    {
        string ini = KeysIni();
        if (File.Exists(ini))
            foreach (string l in File.ReadAllLines(ini))
            {
                Match m = Regex.Match(l, @"^\s*key_freelook\s*=\s*([0-9A-Fa-f]{1,2})\s*$");
                if (m.Success) return Convert.ToInt32(m.Groups[1].Value, 16);
            }
        return 0x15;
    }

    static string ScanName(int scan)
    {
        bool grey = (scan & 0xFF00) == 0xE000;                // (E0xx: the arrows, Insert, Home... and the pad's Enter and /)
        uint vk = grey ? 0 : MapVirtualKey((uint)scan, 1);
        if (vk >= 0x70 && vk <= 0x87) return "F" + (vk - 0x6F);
        if (vk >= 0x30 && vk <= 0x5A) return ((char)vk).ToString();
        StringBuilder sb = new StringBuilder(32);
        return GetKeyNameText(((scan & 0xFF) << 16) | (grey ? 1 << 24 : 0), sb, 32) > 0 ? sb.ToString().ToUpperInvariant() : "key 0x" + scan.ToString("X2");
    }

    // ------------------------------------------------------------------ Uplink's own keys
    // The old school look on / off (F12) and its pixel size (Shift+F12) are keys of Uplink's window, not of the game:
    // TN+'s KEYBOARD page does not have them. A small keyboard has no F12: each can be put on another key, alone or
    // with Shift, Ctrl or Alt (TerraNovaUplink.ini: key_oldschool, key_sharp = [SHIFT+][CTRL+][ALT+]scancode, as TN+
    // writes its keys; E0xx: a key of the grey block). Uplink is told when it starts (TN_KEY_OLDSCHOOL, TN_KEY_SHARP).
    static bool KeyOk(string k) { return Regex.IsMatch(k ?? "", @"^((SHIFT|CTRL|ALT)\+)*[0-9A-F]{1,4}$"); }

    static string OldKey() { string k = Cfg("key_oldschool").ToUpperInvariant(); return KeyOk(k) ? k : "58"; }

    static string SharpKey()
    {
        string k = Cfg("key_sharp").ToUpperInvariant();
        if (KeyOk(k)) return k;
        string o = OldKey();
        return o.Contains("SHIFT+") ? "" : "SHIFT+" + o;      // not set: Shift with the look's key (as Uplink does by itself)
    }

    // "SHIFT+58" -> "Shift+F12", the key named as this keyboard prints it
    static string KeyName(string spec)
    {
        if (spec == "") return "no key";
        string[] p = spec.Split('+');
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < p.Length - 1; i++) sb.Append(p[i].Substring(0, 1) + p[i].Substring(1).ToLowerInvariant() + "+");
        return sb + ScanName(Convert.ToInt32(p[p.Length - 1], 16));
    }

    static void KeyLabels()
    {
        oldKeyBtn.Text = "Old school look: " + KeyName(OldKey());
        sharpKeyBtn.Text = "Its pixel size: " + KeyName(SharpKey());
        oldKeyBtn.Invalidate(); sharpKeyBtn.Invalidate();
    }

    // the keys Uplink's window knows (viewer.gd, SCANCODES), less the modifiers and the three the question keeps
    static bool KeyKnown(int scan)
    {
        if ((scan & 0xFF00) == 0xE000)
            return Array.IndexOf(new[] { 0x1C, 0x35, 0x47, 0x48, 0x49, 0x4B, 0x4D, 0x4F, 0x50, 0x51, 0x52 }, scan & 0xFF) >= 0;
        return scan >= 0x02 && scan <= 0x58 && Array.IndexOf(new[] { 0x0E, 0x1D, 0x2A, 0x36, 0x38, 0x54, 0x55 }, scan) < 0;
    }

    // the game's command on that key, if any (the player's keys, else the game's own): Uplink would keep the key
    static string GameUses(int scan)
    {
        Dictionary<string, int> keys = new Dictionary<string, int>();
        foreach (string dk in DEFAULT_KEYS) keys[dk.Split(':')[0]] = Convert.ToInt32(dk.Split(':')[1], 16);
        string ini = KeysIni();
        if (File.Exists(ini))
            foreach (string l in File.ReadAllLines(ini))
            {
                Match m = Regex.Match(l, @"^\s*key_game_(\w+)\s*=\s*(\S+)\s*$");
                if (!m.Success || !keys.ContainsKey(m.Groups[1].Value)) continue;
                Match plain = Regex.Match(m.Groups[2].Value, "^[0-9A-Fa-f]{1,2}$");
                keys[m.Groups[1].Value] = plain.Success ? Convert.ToInt32(plain.Value, 16) : -1;    // (with a modifier: not this key alone)
            }
        foreach (KeyValuePair<string, int> kv in keys) if (kv.Value == scan) return kv.Key;
        // TN+'s second binds on keys (mouse_<command> = PGUP...): Uplink presses the command's key for them
        Dictionary<string, int> grey = new Dictionary<string, int> {
            { "PGUP", 0xE049 }, { "PGDN", 0xE051 }, { "HOME", 0xE047 }, { "END", 0xE04F }, { "INS", 0xE052 }, { "DEL", 0xE053 } };
        if (File.Exists(ini))
            foreach (string l in File.ReadAllLines(ini))
            {
                Match m = Regex.Match(l, @"^\s*mouse_(\w+)\s*=\s*(\w+)\s*$");
                int sc;
                if (m.Success && grey.TryGetValue(m.Groups[2].Value.ToUpperInvariant(), out sc) && sc == scan)
                    return m.Groups[1].Value + "'s second bind";
            }
        return null;
    }

    static void AskKey(bool sharp)
    {
        string what = sharp ? "the old school look's pixel size" : "the old school look, on / off";
        using (KeyAsk d = new KeyAsk(what, KeyName(sharp ? SharpKey() : OldKey())))
        {
            if (d.ShowDialog(form) != DialogResult.OK) return;
            string spec = d.Spec;
            string explicitSharp = KeyOk(Cfg("key_sharp").ToUpperInvariant()) ? Cfg("key_sharp").ToUpperInvariant() : "";
            if (spec != "" && spec == (sharp ? OldKey() : explicitSharp))
            { Status(KeyName(spec) + " is already the key of " + (sharp ? "the old school look" : "its pixel size") + ".", CAmber); return; }
            if (spec == FreelookScan().ToString("X2") || spec == "45")
            { Status(KeyName(spec) + " already swaps the look and the game's cursor.", CAmber); return; }
            Set(sharp ? "key_sharp" : "key_oldschool", spec);
            SaveCfg();
            KeyLabels();
            string game = spec != "" && spec.IndexOf('+') < 0 ? GameUses(Convert.ToInt32(spec, 16)) : null;
            Status("Old school look: " + KeyName(OldKey()) + ", its pixel size: " + KeyName(SharpKey()) + " (from the next time Uplink starts)." +
                (game != null ? " " + KeyName(spec) + " is one of the game's keys too (" + game + "): the game will not get it any more." : ""), game != null ? CAmber : CGreen);
        }
    }

    // "Press a key": the next key pressed, with the Shift, Ctrl or Alt held (Esc: nothing changed, Del: as it came)
    class KeyAsk : Form
    {
        public string Spec;
        Label note;
        public KeyAsk(string what, string now)
        {
            Text = "Uplink's keys"; ClientSize = new Size(420, 150); FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false; StartPosition = FormStartPosition.CenterParent; BackColor = CBack; ForeColor = CText;
            Font = form.Font; ShowInTaskbar = false; KeyPreview = true;
            Controls.Add(new Label { Text = "Press the key for " + what + ".", Location = new Point(16, 18), Size = new Size(388, 22),
                Font = new Font("Segoe UI Semibold", 10.5f), ForeColor = CAmber });
            Controls.Add(new Label { Text = "Now: " + now + ".  Alone, or with Shift, Ctrl or Alt held.", Location = new Point(16, 48), Size = new Size(388, 20) });
            Controls.Add(new Label { Text = "Esc: change nothing.    Del: the key it came with.", Location = new Point(16, 72), Size = new Size(388, 20), ForeColor = CDim });
            note = new Label { Location = new Point(16, 108), Size = new Size(388, 20), ForeColor = CRed };
            Controls.Add(note);
        }
        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (msg.Msg != 0x100 && msg.Msg != 0x104) return base.ProcessCmdKey(ref msg, keyData);      // WM_KEYDOWN, WM_SYSKEYDOWN
            Keys k = keyData & Keys.KeyCode;
            if (k == Keys.ShiftKey || k == Keys.ControlKey || k == Keys.Menu || k == Keys.LWin || k == Keys.RWin) return true;
            if (keyData == Keys.Escape) { DialogResult = DialogResult.Cancel; return true; }
            if (keyData == Keys.Delete || keyData == Keys.Back) { Spec = ""; DialogResult = DialogResult.OK; return true; }
            long lp = msg.LParam.ToInt64();
            int scan = (int)((lp >> 16) & 0xFF) | (((lp >> 24) & 1) != 0 ? 0xE000 : 0);
            if (!KeyKnown(scan)) { note.Text = "Uplink can't use that key: another one."; return true; }
            Spec = ((keyData & Keys.Shift) != 0 ? "SHIFT+" : "") + ((keyData & Keys.Control) != 0 ? "CTRL+" : "") +
                ((keyData & Keys.Alt) != 0 ? "ALT+" : "") + scan.ToString("X2");
            DialogResult = DialogResult.OK;
            return true;
        }
    }

    static string KeysSummary()
    {
        string ini = KeysIni();
        int n = File.Exists(ini) ? new List<string>(File.ReadAllLines(ini)).FindAll(l => l.TrimStart().StartsWith("key_game_")).Count : 0;
        return n == 0 ? "the game's own keys." : "your keys (" + n + " changed).";
    }

    // ------------------------------------------------------------------ install, update, repair
    // PLAY: Uplink, Godot, TN+, Python. HOST: the same with TN+'s co-op build. JOIN and MAP VIEWER: Uplink and Godot
    static void Install(Mode mode)
    {
        Dictionary<string, string> heads = Heads();
        string up = Get(heads, Head(UPLINK_REPO, UPLINK_BRANCH));
        if (!File.Exists(Path.Combine(UplinkDir, "project.godot")) || (up != null && up != Cfg("uplink_sha")))
        {
            Status("Downloading Uplink...", CAmber);
            Repo(UPLINK_REPO, UPLINK_BRANCH, UplinkDir);
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
        if (mode == Mode.Play || mode == Mode.Host)
        {
            bool coop = mode == Mode.Host;
            string tp = Get(heads, Head(TNPLUS_REPO, coop ? TNPLUS_COOP_BRANCH : TNPLUS_BRANCH)), key = coop ? "tnplus_coop_sha" : "tnplus_sha";
            if (!File.Exists(coop ? TnpCoopExe : TnpExe) || (tp != null && tp != Cfg(key)))
            {
                Status("Downloading and building Terra Nova Plus" + (coop ? " (co-op build)" : "") + "...", CAmber);
                BuildTnp(coop);
                if (tp != null) Set(key, tp);
                SaveCfg();
            }
            if (!File.Exists(PythonExe) || !File.Exists(Path.Combine(Comp, "python", "Lib", "site-packages", "psutil", "__init__.py")))
            {
                Status("Downloading Python for the live mode (about 30 MB, once)...", CAmber);
                InstallPython();
            }
            PythonPaths();
        }
        Ui(RefreshUi);
        Progress(0);
    }

    static string Head(string repo, string branch) { return repo + "@" + branch; }

    static Dictionary<string, string> Heads()
    {   // the last commits of Uplink (stable), TN+ (stable) and its co-op build (coop-stable): both co-op PCs must run the same
        Dictionary<string, string> d = new Dictionary<string, string>();
        foreach (string[] rb in new[] { new[] { UPLINK_REPO, UPLINK_BRANCH }, new[] { TNPLUS_REPO, TNPLUS_BRANCH }, new[] { TNPLUS_REPO, TNPLUS_COOP_BRANCH } })
            try
            {
                string j = Text("https://api.github.com/repos/" + rb[0] + "/commits/" + rb[1]);
                Match m = Regex.Match(j, "\"sha\"\\s*:\\s*\"([0-9a-f]{40})\"");
                if (m.Success) d[Head(rb[0], rb[1])] = m.Groups[1].Value;
            }
            catch (Exception e) { Log("GitHub not reachable (" + e.Message + "): keeping the installed files"); break; }
        return d;
    }

    static string Get(Dictionary<string, string> d, string k) { string v; return d.TryGetValue(k, out v) ? v : null; }

    static void CheckUpdates()
    {
        Dictionary<string, string> h = Heads();
        string up = Get(h, Head(UPLINK_REPO, UPLINK_BRANCH));
        Ui(delegate {
            if (up == null) { verLabel.Text = "●  Couldn't check for updates (offline?)"; verLabel.ForeColor = CDim; }
            else if (Cfg("uplink_sha") == "") { verLabel.Text = "●  Uplink " + up.Substring(0, 7) + " will be installed"; verLabel.ForeColor = CAmber; }
            else if (up == Cfg("uplink_sha")) { verLabel.Text = "●  Up to date"; verLabel.ForeColor = CGreen; }
            else { verLabel.Text = "●  Update available: installed when you start"; verLabel.ForeColor = CAmber; }
        });
    }

    // a newer launcher in Uplink's files (launcher\TerraNovaUplink.cs, its VERSION): built next to this one, swapped in
    // by a small batch file once this one has closed, then started again
    static void SelfUpdate()
    {
        string src = Path.Combine(UplinkDir, "launcher", "TerraNovaUplink.cs");
        if (!File.Exists(src) || form == null) return;
        Match m = Regex.Match(File.ReadAllText(src), "const string VERSION = \"([0-9.]+)\"");
        Version now, theirs;
        if (!m.Success || !Version.TryParse(VERSION, out now) || !Version.TryParse(m.Groups[1].Value, out theirs) || theirs <= now) return;
        Status("Building the new launcher " + theirs + "...", CAmber);
        string dir = Path.GetDirectoryName(src), outExe = Path.Combine(Root, "Terra Nova Uplink.new.exe");
        Process p = Run(Csc(), "/nologo /optimize /target:winexe /win32manifest:app.manifest /win32icon:icon.ico /r:System.Windows.Forms.dll " +
            "/r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Management.dll " +
            "/out:\"" + outExe + "\" TerraNovaUplink.cs", dir, null, true);
        p.WaitForExit();
        if (p.ExitCode != 0 || !File.Exists(outExe)) { Log("new launcher didn't build"); return; }
        if (!Ask("A new Terra Nova Uplink launcher (" + theirs + ") is ready. Restart now?")) return;
        string me = Application.ExecutablePath, bat = Path.Combine(Root, "update.bat");
        File.WriteAllText(bat, "@echo off\r\nping -n 3 127.0.0.1 >nul\r\nmove /y \"" + outExe + "\" \"" + me + "\" >nul\r\nstart \"\" \"" + me + "\"\r\n");
        Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + bat + "\"") { CreateNoWindow = true, UseShellExecute = false });
        Environment.Exit(0);
    }

    static void Repair()
    {
        if (busy) return;
        if (!Ask("Download and install everything again? (your settings and keys are kept)")) return;
        Background(delegate {
            StopAll();
            stopping = false;
            foreach (string d in new[] { "uplink", "godot", "python", "tnplus_src", "tnplus_coop_src", "tmp" })
                try { if (Directory.Exists(Path.Combine(Comp, d))) Directory.Delete(Path.Combine(Comp, d), true); } catch (Exception e) { Log(e.Message); }
            try { File.Delete(TnpExe); } catch { }
            try { File.Delete(TnpCoopExe); } catch { }
            Set("uplink_sha", ""); Set("tnplus_sha", ""); Set("tnplus_coop_sha", ""); SaveCfg();
            Install(Mode.Play);
            Status("Repaired: everything is installed again.", CGreen);
        });
    }

    static void Uninstall()
    {
        if (busy) return;
        if (!Ask("Remove everything Terra Nova Uplink installed in this folder (about 300 MB)? Your game is not touched.")) return;
        StopAll();
        try { Directory.Delete(Comp, true); } catch (Exception e) { Log(e.Message); }
        try { File.Delete(Ini); } catch { }
        MessageBox.Show(form, "Done. You can now delete " + Path.GetFileName(Application.ExecutablePath) + ".", TITLE);
        Environment.Exit(0);
    }

    static string Csc()
    {
        string c = Path.Combine(Environment.GetEnvironmentVariable("WINDIR"), @"Microsoft.NET\Framework64\v4.0.30319\csc.exe");
        return File.Exists(c) ? c : Path.Combine(Environment.GetEnvironmentVariable("WINDIR"), @"Microsoft.NET\Framework\v4.0.30319\csc.exe");
    }

    static void Repo(string repo, string branch, string dest)
    {
        string z = Download("https://github.com/" + repo + "/archive/refs/heads/" + branch + ".zip", "repo.zip");
        string tmp = Path.Combine(Comp, "tmp");
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        Unzip(z, tmp);
        File.Delete(z);
        string top = Directory.GetDirectories(tmp)[0];
        if (Directory.Exists(dest)) Directory.Delete(dest, true);
        Directory.Move(top, dest);
        Directory.Delete(tmp, true);
    }

    // TN+ from its sources (main for PLAY, coop for HOST), built with build.bat's compiler line
    static void BuildTnp(bool coop)
    {
        string src = Path.Combine(Comp, coop ? "tnplus_coop_src" : "tnplus_src");
        Repo(TNPLUS_REPO, coop ? TNPLUS_COOP_BRANCH : TNPLUS_BRANCH, src);
        string cmd = File.ReadAllText(Path.Combine(src, "src", "build.bat"));
        Match m = Regex.Match(cmd, "(?m)^\"%CSC%\"([^\\r\\n]+)");   // build.bat's compiler line, without its pause
        if (!m.Success) throw new Exception("TN+ build.bat not understood");
        Process p = Run(Csc(), m.Groups[1].Value.Trim(), Path.Combine(src, "src"), null, true);
        p.WaitForExit();
        string built = Path.Combine(src, "src", "TNPlus.exe");
        if (p.ExitCode != 0 || !File.Exists(built)) throw new Exception("Terra Nova Plus didn't build (see the log)");
        string dir = coop ? TnpCoopDir : TnpDir;
        Directory.CreateDirectory(dir);
        File.Copy(built, Path.Combine(dir, "TNPlus.exe"), true);       // its TNPlus.ini stays next to it
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
    // numpy / psutil, and Uplink's live folder for the bridge's own modules (tnre...)
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
