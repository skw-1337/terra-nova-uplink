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

static partial class Uplink
{
    const string TITLE = "Terra Nova Uplink";
    const string VERSION = "2.7.1";
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
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string ids);
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
    static Label statusLabel, verLabel, sessionLabel, sensLabel, newsLink;
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
        if (Environment.GetCommandLineArgs().Length > 1 && Environment.GetCommandLineArgs()[1] == "--selftest")
        { Console.WriteLine(TITLE + " " + VERSION); return; }   // (a launcher just built by an update: it starts, says its version)
        Root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        Comp = Path.Combine(Root, "components");
        Ini = Path.Combine(Root, "TerraNovaUplink.ini");
        Directory.CreateDirectory(Path.Combine(Comp, "logs"));
        LogPath = Path.Combine(Comp, "logs", "launcher.log");
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;   // TLS 1.2 (GitHub, python.org, PyPI)
        Migrate();
        LoadCfg();
        UpdStartup();                                          // (release channels: the launcher this one replaced; --rollback)
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
    static Panel[] pages;
    static Tile[] navs;
    static Tile helpBtn;
    static Tick fpsBox, oldBox, runTick, introBox;
    static Label fpsKeyLabel, shotKeyLabel;
    static ComboBox capBox;
    static readonly string[] PAGES = { "Play", "Co-op", "Maps", "In game", "Settings" };
    static readonly string[] PAGE_ICONS = { "", "", "", "", "" };
    const int SB = 150, PW = 520, PH = 300;        // the side bar's width, a page's inner width and height

    static void ShowPage(int k)
    {
        for (int i = 0; i < pages.Length; i++)
        {
            pages[i].Visible = i == k;
            navs[i].Fill = navs[i].Line = i == k ? Color.FromArgb(18, 51, 43) : CPanel;
            navs[i].Ink = i == k ? Color.FromArgb(93, 202, 165) : CDim;
            navs[i].Invalidate();
        }
        Set("page", k.ToString());
    }

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
        int W = PW, X = 20;

        // the side bar: the title, then one entry per page
        side = new Panel { Location = new Point(0, 0), Size = new Size(SB, PH + 106), BackColor = CPanel };
        form.Controls.Add(side);
        UpdBadgeAt(side, 18, 360);                           // the beta's badge (RELEASE CHANNELS)
        side.Controls.Add(new Label { Text = "TERRA NOVA", Font = Pick(new[] { "Bahnschrift SemiBold", "Bahnschrift", "Segoe UI Semibold" }, 14f, FontStyle.Regular),
            ForeColor = CAmber, BackColor = CPanel, AutoSize = true, Location = new Point(12, 14) });
        side.Controls.Add(new Label { Text = "Uplink " + VERSION, Font = FSmall, ForeColor = CDim, BackColor = CPanel, AutoSize = true, Location = new Point(14, 40) });
        side.Controls.Add(new Panel { BackColor = CAmber, Location = new Point(14, 62), Size = new Size(60, 2) });
        pages = new Panel[PAGES.Length]; navs = new Tile[PAGES.Length];
        for (int i = 0; i < PAGES.Length; i++)
        {
            int k = i;
            navs[i] = new Tile(PAGES[i], PAGE_ICONS[i], CPanel, CPanel, CDim) { Location = new Point(8, 80 + i * 38), Size = new Size(SB - 16, 32), Small = true };
            navs[i].Click += delegate { ShowPage(k); };
            side.Controls.Add(navs[i]);
            pages[i] = new Panel { Location = new Point(SB, 0), Size = new Size(W + 2 * X, PH), BackColor = CBack, Visible = false };
            form.Controls.Add(pages[i]);
        }

        // ---- Play: the game (every Terra Nova found on the PC, one picked), the one big button, where to start
        Panel pg = pages[0];
        Box gp = new Box { Location = new Point(X, 16), Size = new Size(W, 40) };
        pg.Controls.Add(gp);
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
        playBtn = new Tile("PLAY", "", COrange, Color.FromArgb(236, 146, 44), Color.FromArgb(30, 14, 0)) { Location = new Point(X, 68), Size = new Size(W, 92) };
        playBtn.Click += delegate { Start(Mode.Play); };
        pg.Controls.Add(playBtn);
        Box sp = new Box { Location = new Point(X, 172), Size = new Size(W, 44) };
        pg.Controls.Add(sp);
        sp.Controls.Add(Caption("START AT", 12, 15));
        missionBox = Combo(new Point(96, 10), W - 210);
        missionBox.MaxDropDownItems = 20;
        sp.Controls.Add(missionBox);
        FillMissions();
        Tile savesBtn = new Tile("Saves", null, CButton, CButtonLine, CText) { Location = new Point(W - 104, 8), Size = new Size(94, 28), Small = true };
        savesBtn.Click += delegate { Saves(); };
        sp.Controls.Add(savesBtn);

        // ---- Co-op: host or join, the mode, the guest's gamepad; the session's line while one runs
        pg = pages[1];
        Box cp = new Box { Location = new Point(X, 16), Size = new Size(W, 118) };
        pg.Controls.Add(cp);
        int half = (W - 24) / 2;
        hostBtn = new Tile("HOST A GAME", "", CButton, CTeal, CText) { Location = new Point(8, 8), Size = new Size(half, 72), IconColor = Color.FromArgb(93, 202, 165) };
        hostBtn.Click += delegate { Start(Mode.Host); };
        cp.Controls.Add(hostBtn);
        joinBtn = new Tile("JOIN A FRIEND", "", CButton, CTeal, CText) { Location = new Point(16 + half, 8), Size = new Size(half, 72), IconColor = Color.FromArgb(93, 202, 165) };
        joinBtn.Click += delegate { Start(Mode.Join); };
        cp.Controls.Add(joinBtn);
        modeCoop = new Dot { Text = "Squad", AutoSize = true, Location = new Point(14, 90), ForeColor = CDim, BackColor = CPanel };
        modeVs = new Dot { Text = "1v1", AutoSize = true, Location = new Point(92, 90), ForeColor = CDim, BackColor = CPanel };
        padBox = new Tick { Text = "Gamepad (guest)", AutoSize = true, Location = new Point(160, 90), ForeColor = CDim, BackColor = CPanel };
        cp.Controls.Add(modeCoop); cp.Controls.Add(modeVs); cp.Controls.Add(padBox);
        sessionRow = new Box { Location = new Point(X, 146), Size = new Size(W, 34), Visible = false };
        pg.Controls.Add(sessionRow);
        sessionLed = new Led { Location = new Point(12, 12), Size = new Size(10, 10), On = CDim };
        sessionRow.Controls.Add(sessionLed);
        sessionLabel = new Label { Location = new Point(30, 8), Size = new Size(W - 40, 20), ForeColor = CText, BackColor = CPanel, Text = "No session." };
        sessionRow.Controls.Add(sessionLabel);

        // ---- Maps
        pg = pages[2];
        mapBtn = new Tile("MAP VIEWER", "", CBlue, Color.FromArgb(47, 92, 196), Color.FromArgb(230, 238, 252)) { Location = new Point(X, 16), Size = new Size(W, 92) };
        mapBtn.Click += delegate { Start(Mode.Maps); };
        pg.Controls.Add(mapBtn);
        pg.Controls.Add(new Label { Text = "Every map of the game in 3D, without starting the game.", AutoSize = true, Location = new Point(X + 2, 118), ForeColor = CDim, Font = FSmall });

        // ---- In game: what shows and how it plays in a mission, one switch a line
        pg = pages[3];
        Box ig = new Box { Location = new Point(X, 16), Size = new Size(W, 254) };
        pg.Controls.Add(ig);
        int ry = 10, RH = 34;
        fpsBox = new Tick { Text = "Frame counter (top right)", AutoSize = true, Location = new Point(12, ry + 4), ForeColor = CText, BackColor = CPanel };
        ig.Controls.Add(fpsBox);
        fpsKeyLabel = new Label { AutoSize = true, Location = new Point(258, ry + 6), ForeColor = CDim, BackColor = CPanel, Font = FSmall };
        ig.Controls.Add(fpsKeyLabel); ry += RH;
        ig.Controls.Add(Caption("FRAME LIMIT", 12, ry + 6));
        capBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDown, Location = new Point(120, ry + 1), Size = new Size(130, 24), BackColor = CButton, ForeColor = CText, FlatStyle = FlatStyle.Flat };
        capBox.Items.AddRange(new object[] { "Unlimited", "60", "120", "144", "240" });
        ig.Controls.Add(capBox);
        ig.Controls.Add(new Label { Text = "pictures a second (or type your own)", AutoSize = true, Location = new Point(258, ry + 6), ForeColor = CDim, BackColor = CPanel, Font = FSmall });
        ry += RH;
        ig.Controls.Add(Caption("CROSSHAIR", 12, ry + 6));       // (the look mode's: the game's own, a dot, or none)
        crossBox = Combo(new Point(120, ry + 1), 130);
        crossBox.Items.AddRange(new object[] { "The game's", "A dot", "None" });
        ig.Controls.Add(crossBox); ry += RH;
        oldBox = new Tick { Text = "Old school look at start", AutoSize = true, Location = new Point(12, ry + 4), ForeColor = CText, BackColor = CPanel };
        ig.Controls.Add(oldBox);
        shotKeyLabel = new Label { AutoSize = true, Location = new Point(258, ry + 6), ForeColor = CDim, BackColor = CPanel, Font = FSmall };
        ig.Controls.Add(shotKeyLabel); ry += RH;
        // Uplink's own two keys (the old school look and its pixel size: click, press the key)
        ig.Controls.Add(Caption("ITS KEYS", 30, ry + 6));          // (the old school look's, right under its switch)
        oldKeyBtn = new Tile("", null, CButton, CButtonLine, CText) { Location = new Point(120, ry), Size = new Size(190, 28), Small = true };
        oldKeyBtn.Click += delegate { AskKey(false); };
        ig.Controls.Add(oldKeyBtn);
        sharpKeyBtn = new Tile("", null, CButton, CButtonLine, CText) { Location = new Point(318, ry), Size = new Size(190, 28), Small = true };
        sharpKeyBtn.Click += delegate { AskKey(true); };
        ig.Controls.Add(sharpKeyBtn); ry += RH;
        // Shift with a move key: the game's Bound (a leap every four strides, its only fast pace), or a run without the
        // leap at the same pace (Uplink's bridge: TN_RUN)
        runTick = new Tick { Text = "Run instead of Bound (Shift + move, no leap)", AutoSize = true, Location = new Point(12, ry + 4), ForeColor = CText, BackColor = CPanel };
        ig.Controls.Add(runTick); ry += RH;
        invertBox = new Tick { Text = "Invert mouse (up / down)", AutoSize = true, Location = new Point(12, ry + 4), ForeColor = CText, BackColor = CPanel };
        ig.Controls.Add(invertBox);
        // the Looking Glass logo and the opening film skipped at the game's start (the bridge presses Esc on them, once each)
        introBox = new Tick { Text = "Skip the intro videos", AutoSize = true, Location = new Point(270, ry + 4), ForeColor = CText, BackColor = CPanel };
        ig.Controls.Add(introBox);
        runBox = new ComboBox();                                 // (kept for the code that reads it: the switch drives it)
        runBox.Items.AddRange(new object[] { "Bound", "Run" });
        runTick.CheckedChanged += delegate { runBox.SelectedIndex = runTick.Checked ? 1 : 0; };

        // ---- Settings: the window, the mouse, the game's keys, the tools; what is installed
        pg = pages[4];
        Box st = new Box { Location = new Point(X, 16), Size = new Size(W, 116) };
        pg.Controls.Add(st);
        st.Controls.Add(Caption("WINDOW", 12, 15));
        sizeBox = Combo(new Point(96, 10), W - 106);
        sizeBox.Items.AddRange(new object[] { "1280 x 720", "1696 x 960", "1920 x 1080", "Fullscreen" });
        st.Controls.Add(sizeBox);
        st.Controls.Add(Caption("MOUSE", 12, 50));
        sensBar = new TrackBar { Minimum = 2, Maximum = 30, TickStyle = TickStyle.None, Location = new Point(90, 44), Size = new Size(W - 170, 30),
            BackColor = CPanel, AutoSize = false };
        sensBar.ValueChanged += delegate { sensLabel.Text = "x " + (sensBar.Value / 10.0).ToString("0.0", CultureInfo.InvariantCulture); };
        st.Controls.Add(sensBar);
        sensLabel = new Label { ForeColor = CText, BackColor = CPanel, AutoSize = true, Location = new Point(W - 70, 50) };
        st.Controls.Add(sensLabel);
        Tile keysBtn = new Tile("Game keys", null, CButton, CButtonLine, CText) { Location = new Point(96, 78), Size = new Size(120, 28), Small = true };
        keysBtn.Click += delegate { GameKeys(); };
        st.Controls.Add(keysBtn);
        toolsBtn = new Tile("Tools", "", CButton, CButtonLine, CText) { Location = new Point(224, 78), Size = new Size(110, 28), Small = true };
        toolsBtn.Click += delegate { ToolsMenu().Show(toolsBtn, new Point(0, toolsBtn.Height)); };
        st.Controls.Add(toolsBtn);
        UpdSettingsRow(st, 350, 83);                         // Beta updates (RELEASE CHANNELS)
        KeyLabels();
        LoadOptions();
        // what is installed: green lights
        string[] names = { "Uplink", "Godot " + GODOT_VER, "Terra Nova Plus", "TN+ co-op build", "Python", "Steam (co-op only)" };
        leds = new Led[names.Length]; ledText = new Label[names.Length];
        for (int i = 0; i < names.Length; i++)
        {
            int cx = X + 2 + (i % 3) * (W / 3), cy = 148 + (i / 3) * 22;
            leds[i] = new Led { Location = new Point(cx, cy + 5), Size = new Size(9, 9) };
            ledText[i] = new Label { AutoSize = true, Location = new Point(cx + 14, cy), ForeColor = CDim, Font = FSmall, Tag = names[i], Text = names[i] };
            pg.Controls.Add(leds[i]); pg.Controls.Add(ledText[i]);
        }

        // under the pages, always there: the status, the footer (update state | Help, Stop), the log
        lower = new Panel { Location = new Point(SB, PH), Size = new Size(W + 2 * X, 106), BackColor = CBack };
        form.Controls.Add(lower);
        statusLabel = new Label { Location = new Point(X, 0), Size = new Size(W, 40), ForeColor = CAmber, Font = new Font("Segoe UI Semibold", 10f) };
        lower.Controls.Add(statusLabel);
        bar = new ProgressBar { Location = new Point(X, 42), Size = new Size(W, 4), Style = ProgressBarStyle.Continuous, Visible = false };
        lower.Controls.Add(bar);
        lower.Controls.Add(new Panel { BackColor = CLine, Location = new Point(X, 52), Size = new Size(W, 1) });
        verLabel = new Label { AutoSize = true, Location = new Point(X, 68), ForeColor = CDim, Font = FSmall };
        lower.Controls.Add(verLabel);
        // What's new, right beside the update state (in the Help menu only, nobody saw it)
        newsLink = new Label { Text = "What's new", AutoSize = true, Location = new Point(X + 14, 68), ForeColor = CAmber,
            Font = new Font(FSmall, FontStyle.Underline), Cursor = Cursors.Hand };
        newsLink.Click += delegate { WhatsNew(); };
        lower.Controls.Add(newsLink);
        verLabel.SizeChanged += delegate { newsLink.Left = verLabel.Right + 14; };
        helpBtn = new Tile("Help", "", CButton, CButtonLine, CText) { Location = new Point(X + W - 196, 62), Size = new Size(92, 30), Small = true };
        helpBtn.Click += delegate { HelpMenu().Show(helpBtn, new Point(0, -helpBtn.Height * 4 - 8)); };
        lower.Controls.Add(helpBtn);
        logBtn = new Tile("Log", null, CButton, CButtonLine, CText);      // (not shown: in Help)
        reportBtn = new Tile("Report a bug", null, CButton, CButtonLine, CText);
        stopBtn = new Tile("Stop", null, CButton, CButtonLine, CText) { Location = new Point(X + W - 96, 62), Size = new Size(96, 30), Small = true };
        stopBtn.Click += delegate { new Thread(StopAll) { IsBackground = true }.Start(); };
        lower.Controls.Add(stopBtn);
        logBox = new TextBox { Location = new Point(X, 106), Size = new Size(W, 140), Multiline = true, ReadOnly = true, Visible = false,
            ScrollBars = ScrollBars.Vertical, BackColor = CPanel, ForeColor = CDim, BorderStyle = BorderStyle.None, Font = new Font("Consolas", 8.5f) };
        lower.Controls.Add(logBox);
        int pg0;
        ShowPage(int.TryParse(Cfg("page"), out pg0) && pg0 >= 0 && pg0 < PAGES.Length ? pg0 : 0);
        Fit();
        // a new Uplink since the last look at What's new: said once, on the status line
        if (Cfg("uplink_sha") != "" && Cfg("news_seen") != Cfg("uplink_sha") && File.Exists(NewsFile))
        {
            statusLabel.Text = "Updated: see What's new, below."; statusLabel.ForeColor = CGreen;
        }
    }

    static Panel side;
    static string NewsFile { get { return Path.Combine(UplinkDir, "WHATSNEW.txt"); } }

    static void ToggleLog()
    {
        logBox.Visible = !logBox.Visible; Fit();
        if (logBox.Visible) { logBox.SelectionStart = logBox.TextLength; logBox.ScrollToCaret(); }
    }

    static ContextMenuStrip HelpMenu()
    {
        ContextMenuStrip m = new ContextMenuStrip();
        m.Items.Add("What's new", null, delegate { WhatsNew(); });
        m.Items.Add(logBox.Visible ? "Hide the log" : "Show the log", null, delegate { ToggleLog(); });
        m.Items.Add("Report a bug (makes a zip with the logs)", null, delegate { Report(); });
        m.Items.Add("Discord", null, delegate { try { Process.Start(DISCORD); } catch { } });
        return m;
    }

    // what changed, version by version (WHATSNEW.txt of the installed Uplink: a version number alone on its line, then
    // its "- " lines, continued on lines that start with spaces): can be read again at any time
    static void WhatsNew()
    {
        string text = "";
        try { if (File.Exists(NewsFile)) text = File.ReadAllText(NewsFile).Replace("\r\n", "\n"); } catch { }
        Form f = new Form { Text = "What's new", StartPosition = FormStartPosition.CenterParent, ClientSize = new Size(600, 470), BackColor = CBack,
            FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, ShowInTaskbar = false };
        try { f.Icon = form.Icon; } catch { }
        Font head = Pick(new[] { "Bahnschrift SemiBold", "Bahnschrift", "Segoe UI Semibold" }, 18f, FontStyle.Regular);
        f.Controls.Add(new Label { Text = "WHAT'S NEW", Font = head, ForeColor = CAmber, AutoSize = true, Location = new Point(22, 16) });
        f.Controls.Add(new Panel { BackColor = CAmber, Location = new Point(24, 54), Size = new Size(90, 2) });
        Box box = new Box { Location = new Point(20, 70), Size = new Size(560, 334) };
        f.Controls.Add(box);
        RichTextBox rt = new RichTextBox { ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = CPanel, ForeColor = CText, DetectUrls = false,
            Location = new Point(16, 12), Size = new Size(536, 310), ScrollBars = RichTextBoxScrollBars.Vertical, TabStop = false, Cursor = Cursors.Default };
        box.Controls.Add(rt);
        try { SetWindowTheme(rt.Handle, "DarkMode_Explorer", null); } catch { }   // (its scrollbar: dark, not Windows' white one)
        Font fVer = Pick(new[] { "Bahnschrift SemiBold", "Bahnschrift", "Segoe UI Semibold" }, 13f, FontStyle.Regular), fItem = new Font("Segoe UI", 10f);
        List<string> items = new List<string>();
        Action flush = delegate {
            foreach (string it in items)
            {
                rt.SelectionFont = fItem; rt.SelectionColor = CText; rt.SelectionIndent = 8; rt.SelectionHangingIndent = 16;
                rt.AppendText("\u2022  " + it + "\n");
            }
            items.Clear();
        };
        bool any = false;
        foreach (string raw in text.Split('\n'))
        {
            string l = raw.TrimEnd();
            if (l.StartsWith("- ")) items.Add(l.Substring(2).Trim());
            else if (l.StartsWith(" ") && items.Count > 0) items[items.Count - 1] += " " + l.Trim();
            else if (Regex.IsMatch(l, "^[0-9]+([.][0-9]+)+$"))
            {
                flush();
                rt.SelectionIndent = 0; rt.SelectionHangingIndent = 0;
                if (any) { rt.SelectionFont = new Font("Segoe UI", 5f); rt.AppendText("\n"); }
                rt.SelectionFont = fVer; rt.SelectionColor = CAmber; rt.AppendText("Version " + l + "\n");
                any = true;
            }
        }
        flush();
        if (!any) { rt.SelectionFont = fItem; rt.SelectionColor = CDim; rt.AppendText("Nothing to show yet: start once so that Uplink is downloaded."); }
        rt.SelectionStart = 0; rt.SelectionLength = 0;
        Tile ok = new Tile("Close", null, CButton, CButtonLine, CText) { Location = new Point(600 - 20 - 110, 420), Size = new Size(110, 32), Small = true };
        ok.Click += delegate { f.Close(); };
        f.Controls.Add(ok);
        f.Shown += delegate { rt.SelectionStart = 0; rt.ScrollToCaret(); ok.Focus(); };
        Set("news_seen", Cfg("uplink_sha")); SaveCfg();
        f.ShowDialog(form);
    }

    static void Fit()
    {
        lower.Height = 106 + (logBox.Visible ? 152 : 0);
        form.ClientSize = new Size(SB + lower.Width, PH + lower.Height);
        side.Height = form.ClientSize.Height;
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
        m.Items.Add("Check for updates now", null, delegate { UpdCheckNow(); });
        m.Items.Add("Import keys from my Terra Nova Plus...", null, delegate { ImportKeys(); });
        m.Items.Add("Repair (download everything again)", null, delegate { Repair(); });
        UpdToolsItems(m);
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
        sizeBox.SelectedIndex = s >= 0 ? s : 3;                  // (nothing chosen yet, a new installation: Fullscreen)
        double sens;
        sensBar.Value = double.TryParse(Cfg("mouse"), NumberStyles.Float, CultureInfo.InvariantCulture, out sens) ?
            Math.Max(2, Math.Min(30, (int)Math.Round(sens * 10))) : 10;
        sensLabel.Text = "x " + (sensBar.Value / 10.0).ToString("0.0", CultureInfo.InvariantCulture);
        invertBox.Checked = Cfg("invert_y") == "1";
        crossBox.SelectedIndex = Math.Max(0, Array.IndexOf(CROSSHAIRS, Cfg("crosshair")));
        runBox.SelectedIndex = Cfg("shift_run") == "1" ? 1 : 0;
        runTick.Checked = runBox.SelectedIndex == 1;
        fpsBox.Checked = Cfg("fps_counter") == "1";              // (off unless asked for: ticket #13)
        introBox.Checked = Cfg("skip_intro") == "1";
        oldBox.Checked = Cfg("old_school") != "0";
        int cap;
        capBox.Text = int.TryParse(Cfg("fps_cap"), out cap) && cap > 0 ? cap.ToString() : "Unlimited";
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
        Set("fps_counter", fpsBox.Checked ? "1" : "0");
        Set("skip_intro", introBox.Checked ? "1" : "0");
        Set("old_school", oldBox.Checked ? "1" : "0");
        int cap;
        Set("fps_cap", int.TryParse(capBox.Text.Trim(), out cap) && cap > 0 ? Math.Max(20, Math.Min(1000, cap)).ToString() : "0");
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
                // (drawn by software: with Direct3D or OpenGL NVIDIA's overlay hooked this hidden window, and its notification
                // came out in the picture Uplink copies, pixelated. The output is named too: TN+'s own conf says opengl when
                // its scaling is "sharp", and the texture renderer is then ignored)
                "[sdl]", "fullscreen = false", "output = texturenb", "texture_renderer = software", "windowresolution = " + (Cfg("window") == "native" || Cfg("window") == "" ? "1696x960" : Cfg("window")) });
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
            Status(tnp != null && CloseOurGame() ? "Closed." :
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
        env["TN_KEY_SHOT"] = ShotKey();
        env["TN_KEY_FPS"] = FpsKey();
        env["TN_SKIP_INTRO"] = Cfg("skip_intro") == "1" ? "1" : "0";
        env["TN_BINDS"] = Binds();
        env["TN_CROSSHAIR"] = Cfg("crosshair");
        env["TN_RUN"] = Cfg("shift_run") == "1" ? "1" : "0";
        env["TN_FPS"] = Cfg("fps_counter") == "1" ? "1" : "0";
        env["TN_FPS_CAP"] = Cfg("fps_cap") == "" ? "0" : Cfg("fps_cap");
        env["TN_OLDSCHOOL"] = Cfg("old_school") == "0" ? "0" : "1";
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
            Session(UpdCoopText(t), CRed);
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

    // Two more keys of Uplink's window: a screenshot (Ctrl with the look's key) and the frame counter on / off
    // (Ctrl+Shift with it); none when the look's own key already has a modifier (key_shot, key_fps in the ini: another)
    static string ShotKey()
    {
        string k = Cfg("key_shot").ToUpperInvariant();
        if (KeyOk(k)) return k;
        return OldKey().Contains("+") ? "" : "CTRL+" + OldKey();
    }

    static string FpsKey()
    {
        string k = Cfg("key_fps").ToUpperInvariant();
        if (KeyOk(k)) return k;
        return OldKey().Contains("+") ? "" : "CTRL+SHIFT+" + OldKey();
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
        oldKeyBtn.Text = "On / off in game: " + KeyName(OldKey());
        sharpKeyBtn.Text = "Bigger / finer pixels: " + KeyName(SharpKey());
        oldKeyBtn.Invalidate(); sharpKeyBtn.Invalidate();
        fpsKeyLabel.Text = FpsKey() != "" ? "in game: " + KeyName(FpsKey()) : "";
        shotKeyLabel.Text = ShotKey() != "" ? "Screenshot: " + KeyName(ShotKey()) + "  (saved in Pictures)" : "";
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
        int upd = UpdInstall(mode);                        // release.json (RELEASE CHANNELS, at the end): 1 = Uplink, TN+, the launcher done there
        Dictionary<string, string> heads = upd == 0 ? Heads() : new Dictionary<string, string>();
        string up = Get(heads, Head(UPLINK_REPO, UPLINK_BRANCH));
        if (upd == 0 && (!File.Exists(Path.Combine(UplinkDir, "project.godot")) || (up != null && up != Cfg("uplink_sha"))))
        {
            Status("Downloading Uplink...", CAmber);
            Repo(UPLINK_REPO, UPLINK_BRANCH, UplinkDir);
            if (up != null) Set("uplink_sha", up);
            SaveCfg();
        }
        if (upd == 0) SelfUpdate();
        if (!File.Exists(GodotExe))
        {
            Status("Downloading Godot " + GODOT_VER + " (about 90 MB, once)...", CAmber);
            string z = Download(GODOT_URL, "godot.zip");
            UpdVerifyDep("godot", z);
            Unzip(z, Path.GetDirectoryName(GodotExe));
            File.Delete(z);
        }
        if (mode == Mode.Play || mode == Mode.Host)
        {
            bool coop = mode == Mode.Host;
            string tp = Get(heads, Head(TNPLUS_REPO, coop ? TNPLUS_COOP_BRANCH : TNPLUS_BRANCH)), key = coop ? "tnplus_coop_sha" : "tnplus_sha";
            if (upd == 0 && (!File.Exists(coop ? TnpCoopExe : TnpExe) || (tp != null && tp != Cfg(key))))
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
        if (NoUpdate) return d;
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
        if (UpdCheck()) return;                            // (release.json: RELEASE CHANNELS)
        Dictionary<string, string> h = Heads();
        string up = Get(h, Head(UPLINK_REPO, UPLINK_BRANCH));
        Ui(delegate {
            if (up == null) { verLabel.Text = "●  Couldn't check for updates (offline?)"; verLabel.ForeColor = CDim; }
            else if (Cfg("uplink_sha") == "") { verLabel.Text = "●  Uplink " + up.Substring(0, 7) + " will be installed"; verLabel.ForeColor = CAmber; }
            else if (up == Cfg("uplink_sha")) { verLabel.Text = "●  Up to date"; verLabel.ForeColor = CGreen; }
            else { verLabel.Text = "●  Update available at the next start"; verLabel.ForeColor = CAmber; }
        });
    }

    // a newer launcher in Uplink's files (launcher\TerraNovaUplink.cs, its VERSION): built next to this one, swapped in
    // by a small batch file once this one has closed, then started again. Looked at on every install pass (a player who
    // said no is asked again the next time the launcher is opened), once per run
    static bool selfAsked;
    static void SelfUpdate()
    {
        string src = Path.Combine(UplinkDir, "launcher", "TerraNovaUplink.cs");
        if (selfAsked || !File.Exists(src) || form == null || NoUpdate) return;
        Match m = Regex.Match(File.ReadAllText(src), "const string VERSION = \"([0-9.]+)\"");
        Version now, theirs;
        if (!m.Success || !Version.TryParse(VERSION, out now) || !Version.TryParse(m.Groups[1].Value, out theirs) || theirs <= now) return;
        selfAsked = true;
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
        UpdVerifyDep("python", z);
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
            UpdVerifyDep(w[0], wf);
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
            return c.DownloadString(Net(url));
        }
    }

    static string Download(string url, string name)
    {
        string dest = Path.Combine(Comp, name);
        Log("download " + url);
        HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(Net(url));
        rq.UserAgent = TITLE + "/" + VERSION;
        rq.Timeout = 30000; rq.ReadWriteTimeout = 60000;
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

// ====================================================================================================================
// RELEASE CHANNELS (since 2.7.1). This region is the same text in every launcher from 2.7.1 on; only the "host glue"
// region after it differs (where the window puts the switch, the badge, the label). The manifest and how to publish:
// docs/release-manifest.md.
//  - release.json (branch "release" of this repo) names, for each channel (stable, beta), the version, the exact
//    commits of Uplink and of Terra Nova Plus (solo and co-op builds) with the SHA-256 of their files, the launcher's
//    version and the oldest launcher that may install it, the changelog, the beta's invitation.
//  - Beta updates (Settings > Updates, off unless switched on): the newer of beta and stable; no beta: stable.
//  - Everything is downloaded into components\updates and checked against those hashes, and only then swapped in;
//    what it replaced is kept in components\previous (Tools > Roll back), the settings of each version in
//    components\settings. Nothing is replaced while anything runs from components\, nothing at all with
//    no_update.txt beside the exe, and two launchers never update the same folder at once (components\updates\
//    update.lock).
//  - Offline, GitHub down or rate-limited, a bad download, a failed build: the installed version stays and plays.
//  - Checks only: TN_UPLINK_TEST_SERVER=http://127.0.0.1:PORT sends every GitHub request to a local fake GitHub
//    (tools/release/fake_github.py); any other value, or one that is not a loopback address, is ignored.
// ====================================================================================================================
static partial class Uplink
{
    const string REL_URL = "https://raw.githubusercontent.com/" + UPLINK_REPO + "/release/release.json";
    const string REL_HOSTS = "https://codeload.github.com/skw-1337/ https://github.com/skw-1337/ https://raw.githubusercontent.com/skw-1337/";
    static readonly Color UOrange = Color.FromArgb(232, 134, 42), UInk = Color.FromArgb(21, 20, 15), UEdge = Color.FromArgb(42, 74, 68);
    static string UpdDir { get { return Path.Combine(Comp, "updates"); } }
    static string PrevDir { get { return Path.Combine(Comp, "previous"); } }
    static string SetDir { get { return Path.Combine(Comp, "settings"); } }
    static Dictionary<string, object> rel;                    // this pass's release.json (null: not read)
    static int relCode;                                       // 0: read, 404: not published yet, -1: not reachable / not valid
    static string relError = "";
    static RelChan relStable, relBeta, relTarget;
    static volatile bool updAuto;                             // the player has just asked for it: no question
    static bool updNoticed;

    // ---- versions: 2.7.1, 2.8.0-beta.1 (semver: a pre-release comes before its release, beta.2 after beta.1)
    class SemVer : IComparable<SemVer>
    {
        public int Major, Minor, Patch;
        public string[] Pre;
        public static SemVer Parse(string v)
        {
            if (v == null) return null;
            Match m = Regex.Match(v.Trim(), @"^v?(\d{1,6})\.(\d{1,6})(?:\.(\d{1,6}))?(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$");
            if (!m.Success) return null;
            return new SemVer { Major = int.Parse(m.Groups[1].Value), Minor = int.Parse(m.Groups[2].Value),
                Patch = m.Groups[3].Success ? int.Parse(m.Groups[3].Value) : 0, Pre = m.Groups[4].Success ? m.Groups[4].Value.Split('.') : new string[0] };
        }
        public bool IsPre { get { return Pre.Length > 0; } }
        public string Line { get { return Major + "." + Minor; } }                                        // "2.8"
        public string Short { get { return (Patch == 0 ? Line : Line + "." + Patch) + (IsPre ? " " + Pre[0] : ""); } }    // "2.8 beta", "2.7.1"
        public string Full { get { return (Patch == 0 ? Line : Line + "." + Patch) + (IsPre ? " " + string.Join(" ", Pre) : ""); } }   // "2.8 beta 1"
        public int CompareTo(SemVer o)
        {
            int c = Major.CompareTo(o.Major);
            if (c == 0) c = Minor.CompareTo(o.Minor);
            if (c == 0) c = Patch.CompareTo(o.Patch);
            if (c != 0) return Math.Sign(c);
            if (Pre.Length == 0 || o.Pre.Length == 0) return o.Pre.Length.CompareTo(Pre.Length) > 0 ? 1 : o.Pre.Length == Pre.Length ? 0 : -1;
            for (int i = 0; i < Math.Min(Pre.Length, o.Pre.Length); i++)
            {
                long a, b;
                bool na = Regex.IsMatch(Pre[i], "^[0-9]{1,15}$") && long.TryParse(Pre[i], out a), nb = Regex.IsMatch(o.Pre[i], "^[0-9]{1,15}$") && long.TryParse(o.Pre[i], out b);
                if (na && nb) c = long.Parse(Pre[i]).CompareTo(long.Parse(o.Pre[i]));
                else c = na ? -1 : nb ? 1 : string.CompareOrdinal(Pre[i], o.Pre[i]);
                if (c != 0) return Math.Sign(c);
            }
            return Math.Sign(Pre.Length.CompareTo(o.Pre.Length));
        }
    }
    static int VerCmp(string a, string b)
    {
        SemVer x = SemVer.Parse(a), y = SemVer.Parse(b);
        if (x == null || y == null) return x == null ? (y == null ? 0 : -1) : 1;
        return x.CompareTo(y);
    }
    static string VerShort(string v) { SemVer s = SemVer.Parse(v); return s == null ? v : s.Short; }
    static string VerFull(string v) { SemVer s = SemVer.Parse(v); return s == null ? v : s.Full; }
    // the version of Uplink's files here (what the last install from a release said; before any: this launcher's)
    static string Installed { get { string v = Cfg("upd_version"); return SemVer.Parse(v) != null ? v : VERSION; } }

    // ---- a small JSON reader (the launcher is built by Windows' own C# compiler with a fixed list of references, no
    // JSON library): objects -> Dictionary, arrays -> List, strings, numbers (double), true / false, null
    class UJson
    {
        string s; int i;
        public static object Parse(string text)
        {
            UJson j = new UJson { s = text, i = 0 };
            object v = j.Value();
            j.Ws();
            if (j.i != j.s.Length) throw new FormatException("JSON: text after the end, at " + j.i);
            return v;
        }
        void Ws() { while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n' || s[i] == '\uFEFF')) i++; }
        char Peek() { Ws(); if (i >= s.Length) throw new FormatException("JSON: unexpected end"); return s[i]; }
        void Expect(char c) { if (Peek() != c) throw new FormatException("JSON: '" + c + "' expected at " + i); i++; }
        object Value()
        {
            char c = Peek();
            if (c == '{')
            {
                i++;
                Dictionary<string, object> d = new Dictionary<string, object>();
                if (Peek() == '}') { i++; return d; }
                while (true)
                {
                    string k = Str(); Expect(':'); d[k] = Value();
                    if (Peek() == ',') { i++; continue; }
                    Expect('}'); return d;
                }
            }
            if (c == '[')
            {
                i++;
                List<object> l = new List<object>();
                if (Peek() == ']') { i++; return l; }
                while (true)
                {
                    l.Add(Value());
                    if (Peek() == ',') { i++; continue; }
                    Expect(']'); return l;
                }
            }
            if (c == '"') return Str();
            foreach (string w in new[] { "true", "false", "null" })
                if (string.CompareOrdinal(s, i, w, 0, w.Length) == 0) { i += w.Length; return w == "null" ? null : (object)(w == "true"); }
            int st = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            if (st == i) throw new FormatException("JSON: unexpected '" + c + "' at " + i);
            return double.Parse(s.Substring(st, i - st), NumberStyles.Float, CultureInfo.InvariantCulture);
        }
        string Str()
        {
            Expect('"');
            StringBuilder b = new StringBuilder();
            while (true)
            {
                if (i >= s.Length) throw new FormatException("JSON: unfinished string");
                char c = s[i++];
                if (c == '"') return b.ToString();
                if (c != '\\') { b.Append(c); continue; }
                char e = s[i++];
                switch (e)
                {
                    case 'n': b.Append('\n'); break;
                    case 't': b.Append('\t'); break;
                    case 'r': b.Append('\r'); break;
                    case 'b': b.Append('\b'); break;
                    case 'f': b.Append('\f'); break;
                    case 'u': b.Append((char)Convert.ToInt32(s.Substring(i, 4), 16)); i += 4; break;
                    default: b.Append(e); break;
                }
            }
        }
    }
    static object JGet(object o, string k) { Dictionary<string, object> d = o as Dictionary<string, object>; object v; return d != null && d.TryGetValue(k, out v) ? v : null; }
    static string JStr(object o, string k) { return JGet(o, k) as string; }

    // ---- what a channel of release.json says
    class RelPart { public string Ref, Url, Tree, Version; public Dictionary<string, string> Files; }
    class RelChan
    {
        public string Name, Version, Launcher, MinLauncher, Title, Subtitle;
        public SemVer V;
        public RelPart Uplink, Tnp, TnpCoop;
        public List<KeyValuePair<string, List<string>>> Changes = new List<KeyValuePair<string, List<string>>>();
        public List<string[]> Pictures = new List<string[]>();      // url, sha256, caption
    }
    static bool OurUrl(string u)
    {
        if (u == null) return false;
        foreach (string h in REL_HOSTS.Split(' ')) if (u.StartsWith(h, StringComparison.Ordinal)) return true;
        return false;
    }
    static RelPart RelPartOf(object o, string repo)
    {
        if (o == null) return null;
        RelPart p = new RelPart { Ref = JStr(o, "ref"), Tree = JStr(o, "tree_sha256"), Version = JStr(o, "version"), Url = JStr(o, "url") };
        if (p.Ref == null || !Regex.IsMatch(p.Ref, "^[0-9a-f]{40}$") || p.Tree == null || !Regex.IsMatch(p.Tree, "^[0-9a-f]{64}$")) return null;
        if (p.Url == null) p.Url = "https://codeload.github.com/" + repo + "/zip/" + p.Ref;
        if (!OurUrl(p.Url)) return null;                       // (only this project's GitHub, only https)
        Dictionary<string, object> f = JGet(o, "files") as Dictionary<string, object>;
        if (f != null)
        {
            p.Files = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (KeyValuePair<string, object> kv in f) { string h = kv.Value as string; if (h != null && Regex.IsMatch(h, "^[0-9a-f]{64}$")) p.Files[kv.Key] = h; }
        }
        return p;
    }
    static RelChan RelChannel(string name)
    {
        object c = JGet(JGet(rel, "channels"), name);
        if (c == null) return null;
        RelChan r = new RelChan { Name = name, Version = JStr(c, "version"), Launcher = JStr(c, "launcher"), MinLauncher = JStr(c, "min_launcher") };
        r.V = SemVer.Parse(r.Version);
        r.Uplink = RelPartOf(JGet(c, "uplink"), UPLINK_REPO);
        r.Tnp = RelPartOf(JGet(c, "tnplus"), TNPLUS_REPO);
        r.TnpCoop = RelPartOf(JGet(c, "tnplus_coop"), TNPLUS_REPO);
        if (r.V == null || r.Uplink == null || r.Tnp == null || r.TnpCoop == null || SemVer.Parse(r.Launcher) == null || (r.MinLauncher != null && SemVer.Parse(r.MinLauncher) == null))
        { Log("release.json: channel " + name + " left out (incomplete or not valid)"); return null; }
        List<object> cl = JGet(c, "changelog") as List<object>;
        if (cl != null)
            foreach (object sec in cl)
            {
                List<string> items = new List<string>();
                List<object> il = JGet(sec, "items") as List<object>;
                if (il != null) foreach (object it in il) if (it is string) items.Add((string)it);
                if (JStr(sec, "section") != null && items.Count > 0) r.Changes.Add(new KeyValuePair<string, List<string>>(JStr(sec, "section"), items));
            }
        object inv = JGet(c, "invitation");
        r.Title = JStr(inv, "title");
        r.Subtitle = JStr(inv, "subtitle");
        List<object> pics = JGet(inv, "images") as List<object>;
        if (pics != null)
            foreach (object p in pics)
            {
                string u = JStr(p, "url"), h = JStr(p, "sha256");
                if (OurUrl(u) && h != null && Regex.IsMatch(h, "^[0-9a-f]{64}$")) r.Pictures.Add(new[] { u, h, JStr(p, "caption") ?? "" });
            }
        return r;
    }

    // release.json read now (each check, each install pass); then the channel this folder follows
    static bool RelLoad()
    {
        rel = null; relStable = relBeta = relTarget = null;
        if (NoUpdate) { relCode = -1; relError = "updates are off here (no_update.txt)"; return false; }
        try
        {
            byte[] b = UFetch(REL_URL, null, 15000, false, 1 << 20);
            rel = UJson.Parse(Encoding.UTF8.GetString(b)) as Dictionary<string, object>;
            if (rel == null || !(JGet(rel, "schema") is double)) throw new FormatException("not a release manifest");
            relCode = 0;
        }
        catch (UpdNetError e) { relCode = e.Code == 404 ? 404 : -1; relError = e.Message; rel = null; Log("release.json: " + e.Message); return false; }
        catch (Exception e) { relCode = -1; relError = "release.json not valid"; rel = null; Log("release.json: " + e.Message); return false; }
        relStable = RelChannel("stable");
        relBeta = RelChannel("beta");
        bool beta = Cfg("beta_updates") == "1";
        relTarget = relStable;
        if (beta && relBeta != null && (relStable == null || relBeta.V.CompareTo(relStable.V) > 0)) relTarget = relBeta;
        Log("release.json: stable " + (relStable != null ? relStable.Version : "-") + ", beta " + (relBeta != null ? relBeta.Version : "-") +
            ", followed: " + (relTarget != null ? relTarget.Name + " " + relTarget.Version : "none") + ", installed " + Installed);
        return true;
    }

    // what is installed, as a channel (a version rolled back from is not put back by itself: this one is kept)
    static RelChan RelInstalled()
    {
        RelChan r = new RelChan { Name = Cfg("upd_channel"), Version = Installed, Launcher = VERSION };
        r.V = SemVer.Parse(r.Version);
        r.Uplink = new RelPart { Ref = Cfg("uplink_sha") };
        if (Cfg("upd_tnplus_ref") != "") r.Tnp = new RelPart { Ref = Cfg("upd_tnplus_ref"), Tree = Cfg("upd_tnplus_tree"), Url = "https://codeload.github.com/" + TNPLUS_REPO + "/zip/" + Cfg("upd_tnplus_ref") };
        if (Cfg("upd_tnplus_coop_ref") != "") r.TnpCoop = new RelPart { Ref = Cfg("upd_tnplus_coop_ref"), Tree = Cfg("upd_tnplus_coop_tree"), Url = "https://codeload.github.com/" + TNPLUS_REPO + "/zip/" + Cfg("upd_tnplus_coop_ref") };
        return r;
    }

    // ---- the network: every GitHub address through Net (the checks' fake GitHub), timeouts on the tick counter
    static string TestServer
    {
        get
        {
            string t = Environment.GetEnvironmentVariable("TN_UPLINK_TEST_SERVER");
            return t != null && Regex.IsMatch(t, @"^http://(127\.0\.0\.1|localhost):\d{2,5}/?$") ? t.TrimEnd('/') : null;
        }
    }
    static string Net(string url)
    {
        string t = TestServer;
        if (t == null || url == null) return url;
        foreach (string[] p in new[] { new[] { "https://raw.githubusercontent.com/", "/raw/" }, new[] { "https://codeload.github.com/", "/codeload/" },
            new[] { "https://api.github.com/", "/api/" }, new[] { "https://github.com/", "/gh/" }, new[] { "https://www.python.org/", "/py/" },
            new[] { "https://pypi.org/", "/pypi/" }, new[] { "https://files.pythonhosted.org/", "/pyfiles/" } })
            if (url.StartsWith(p[0], StringComparison.Ordinal)) return t + p[1] + url.Substring(p[0].Length);
        return url;
    }
    class UpdNetError : Exception { public int Code; public UpdNetError(string m, int code) : base(m) { Code = code; } }
    class UpdFail : Exception { public string Why; public UpdFail(string why, string m) : base(m) { Why = why; } }
    static bool DiskFull(Exception e) { int h = e.HResult & 0xFFFF; return e is IOException && (h == 0x70 || h == 0x27); }
    static string DiskText() { return "Not enough free disk space to update Uplink (" + Root + "). Nothing was changed: the installed version still plays."; }
    static string ReadOnlyText()
    {
        return "Uplink can't update itself in this folder: it is read-only for you (" + Root + "). Nothing was changed and the installed " +
            "version still plays. To get updates, move the Terra Nova Uplink folder to one of yours (Documents, for example).";
    }

    // one GET: the body, or (to != null) a file, written as .part and renamed once whole. 403 / 429: GitHub's limit
    static byte[] UFetch(string url, string to, int ms, bool progress, long max)
    {
        string u = Net(url);
        Log("get " + u);
        string part = to != null ? to + ".part" : null;
        try
        {
            HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(u);
            rq.UserAgent = TITLE + "/" + VERSION;
            rq.Timeout = ms; rq.ReadWriteTimeout = ms;
            rq.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);
            Stopwatch sw = Stopwatch.StartNew();
            using (HttpWebResponse rs = (HttpWebResponse)rq.GetResponse())
            using (Stream s = rs.GetResponseStream())
            using (Stream f = part != null ? (Stream)File.Create(part) : new MemoryStream())
            {
                long total = rs.ContentLength, got = 0;
                byte[] buf = new byte[1 << 16];
                int n, last = -1;
                while ((n = s.Read(buf, 0, buf.Length)) > 0)
                {
                    if (stopping) throw new UpdNetError("stopped", 0);
                    f.Write(buf, 0, n);
                    got += n;
                    if (got > max) throw new UpdNetError("too big", 0);
                    if (to == null && sw.ElapsedMilliseconds > ms * 2) throw new UpdNetError("no answer (too slow)", 0);
                    if (progress)
                    {
                        int pct = total > 0 ? (int)(got * 100 / total) : (int)(got / 1000000 % 100);
                        if (pct != last) { last = pct; Progress(Math.Max(1, pct)); }
                    }
                }
                if (total > 0 && got != total) throw new UpdNetError("the download was cut (" + got + " of " + total + " bytes)", 0);
                if (to == null) return ((MemoryStream)f).ToArray();
            }
            if (File.Exists(to)) File.Delete(to);
            File.Move(part, to);
            return null;
        }
        catch (WebException e)
        {
            HttpWebResponse r = e.Response as HttpWebResponse;
            int code = r != null ? (int)r.StatusCode : 0;
            throw new UpdNetError(code == 403 || code == 429 ? "GitHub's limit for now (HTTP " + code + ")" : code != 0 ? "HTTP " + code :
                e.Status == WebExceptionStatus.Timeout ? "no answer (timeout)" : e.Message, code);
        }
        catch (IOException e) { if (DiskFull(e)) throw new UpdFail("disk", DiskText()); throw new UpdNetError(e.Message, 0); }
        finally { if (progress) Progress(0); if (part != null) try { if (File.Exists(part)) File.Delete(part); } catch { } }
    }

    // ---- files
    static string Sha256File(string f)
    {
        using (System.Security.Cryptography.SHA256 h = System.Security.Cryptography.SHA256.Create())
        using (FileStream s = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.Read)) return Hex(h.ComputeHash(s));
    }
    static string Hex(byte[] b) { StringBuilder sb = new StringBuilder(b.Length * 2); foreach (byte x in b) sb.Append(x.ToString("x2")); return sb.ToString(); }
    // what Godot and Python make by themselves, and our own list, are not the release's files
    static bool TreeSkip(string r) { return r.StartsWith(".godot/") || r.StartsWith("__pycache__/") || r.Contains("/__pycache__/") || r == ".release-files"; }
    // a folder's files, "relative/path" -> SHA-256, in ordinal order (as release.json's tree_sha256 is made)
    static SortedDictionary<string, string> TreeFiles(string dir)
    {
        SortedDictionary<string, string> d = new SortedDictionary<string, string>(StringComparer.Ordinal);
        string root = Path.GetFullPath(dir).TrimEnd('\\') + "\\";
        foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
        {
            string r = Path.GetFullPath(f).Substring(root.Length).Replace('\\', '/');
            if (!TreeSkip(r)) d[r] = Sha256File(f);
        }
        return d;
    }
    // the tree's SHA-256: of the lines "<sha256 of the file> <path>\n", in that order
    static string TreeDigest(SortedDictionary<string, string> files)
    {
        StringBuilder sb = new StringBuilder();
        foreach (KeyValuePair<string, string> kv in files) sb.Append(kv.Value).Append(' ').Append(kv.Key).Append('\n');
        using (System.Security.Cryptography.SHA256 h = System.Security.Cryptography.SHA256.Create()) return Hex(h.ComputeHash(Encoding.UTF8.GetBytes(sb.ToString())));
    }
    static void UDel(string dir)
    {
        if (!Directory.Exists(dir)) return;
        foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories)) try { File.SetAttributes(f, FileAttributes.Normal); } catch { }
        Directory.Delete(dir, true);
    }
    static void UDelFile(string f) { if (File.Exists(f)) { File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); } }
    static string URead(string f) { try { return File.Exists(f) ? File.ReadAllText(f).Trim() : ""; } catch { return ""; } }
    static Dictionary<string, string> UReadIni(string f)
    {
        if (!File.Exists(f)) return null;
        Dictionary<string, string> d = new Dictionary<string, string>();
        foreach (string l in File.ReadAllLines(f)) { int e = l.IndexOf('='); if (e > 0 && !l.StartsWith(";")) d[l.Substring(0, e).Trim()] = l.Substring(e + 1).Trim(); }
        return d;
    }
    static string USafe(string v) { return Regex.Replace(v ?? "", "[^0-9A-Za-z.+-]", "_"); }
    // a rename recorded, so that a step that fails puts everything back as it was (UUndo)
    static void URen(List<string[]> done, string from, string to)
    {
        if (Directory.Exists(from)) Directory.Move(from, to); else File.Move(from, to);
        done.Add(new[] { from, to });
    }
    static void UUndo(List<string[]> done)
    {
        for (int i = done.Count - 1; i >= 0; i--)
            try { if (Directory.Exists(done[i][1])) Directory.Move(done[i][1], done[i][0]); else File.Move(done[i][1], done[i][0]); }
            catch (Exception e) { Log("undo " + done[i][1] + ": " + e.Message); }
        done.Clear();
    }
    // a program run hidden, its output kept: the exit code (-1: too long, -2: could not be started at all)
    static int UExec(string exe, string args, string dir, int ms, out string output)
    {
        Log("> " + Path.GetFileName(exe) + " " + args);
        StringBuilder sb = new StringBuilder();
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe, args) { WorkingDirectory = dir, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true };
            using (Process p = Process.Start(psi))
            {
                p.OutputDataReceived += (s, e) => { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                p.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                if (!p.WaitForExit(ms)) { try { p.Kill(); } catch { } output = "it took too long"; return -1; }
                p.WaitForExit();
                lock (sb) output = sb.ToString();
                return p.ExitCode;
            }
        }
        catch (Exception e) { output = e.Message; return -2; }
    }
    static string FirstError(string log)
    {
        foreach (string l in (log ?? "").Split('\n')) if (l.Contains("error")) return l.Trim();
        return (log ?? "").Trim().Split('\n')[0].Trim();
    }

    // ---- safety checks before anything is downloaded or replaced
    static FileStream updLock;
    static bool UpdTakeLock(int waitMs)
    {
        Stopwatch sw = Stopwatch.StartNew();
        Directory.CreateDirectory(UpdDir);
        while (true)
        {
            try { updLock = new FileStream(Path.Combine(UpdDir, "update.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); return true; }
            catch (IOException) { if (sw.ElapsedMilliseconds >= waitMs) return false; Thread.Sleep(250); }
        }
    }
    static void UpdReleaseLock() { if (updLock != null) { try { updLock.Dispose(); } catch { } updLock = null; } }
    // a program running from components\ (Uplink's Godot, the bridge's Python, TN+, its DOSBox): its name
    static string UpdInUse()
    {
        int me = Process.GetCurrentProcess().Id;
        string comp = Path.GetFullPath(Comp).TrimEnd('\\') + "\\", upd = Path.GetFullPath(UpdDir) + "\\";
        try
        {
            using (System.Management.ManagementObjectSearcher s = new System.Management.ManagementObjectSearcher("SELECT ProcessId, Name, ExecutablePath, CommandLine FROM Win32_Process"))
                foreach (System.Management.ManagementObject o in s.Get())
                {
                    if (Convert.ToInt32(o["ProcessId"]) == me) continue;
                    string t = (o["ExecutablePath"] as string ?? "") + " " + (o["CommandLine"] as string ?? "");
                    if (t.IndexOf(comp, StringComparison.OrdinalIgnoreCase) >= 0 && t.IndexOf(upd, StringComparison.OrdinalIgnoreCase) < 0) return o["Name"] as string ?? "a program";
                }
        }
        catch (Exception e) { Log("process list: " + e.Message); }
        return null;
    }
    static void UpdCanWrite(long need)
    {
        foreach (string d in new[] { Root, UpdDir })
            try { Directory.CreateDirectory(d); string p = Path.Combine(d, ".write-test"); File.WriteAllText(p, "x"); File.Delete(p); }
            catch (UnauthorizedAccessException) { throw new UpdFail("readonly", ReadOnlyText()); }
            catch (IOException e) { if (DiskFull(e)) throw new UpdFail("disk", DiskText()); throw; }
        try
        {
            DriveInfo di = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(Root)));
            long free = di.AvailableFreeSpace;
            string force = TestServer != null ? Environment.GetEnvironmentVariable("TN_UPLINK_TEST_FREE") : null;   // (checks: a full disk)
            if (force != null) long.TryParse(force, out free);
            if (free < need) throw new UpdFail("disk", DiskText());
        }
        catch (ArgumentException) { }                         // (a network path: not known)
    }
    static void UpdLast(string s) { Set("upd_last", s); SaveCfg(); Log("update: " + s); }
    static void UpdNoticeOnce(string s, Color c) { if (updNoticed) { Log(s); return; } updNoticed = true; Status(s, c); }

    // ---- the install pass's first step (Install). 0: no release.json published yet, nothing installed from one:
    // the branches' heads as 2.7 did. 1: done here (installed, nothing to do, or not possible now: what is installed plays)
    static int UpdInstall(Mode mode)
    {
        if (NoUpdate) return 0;
        bool have = File.Exists(Path.Combine(UplinkDir, "project.godot"));
        bool resume = Cfg("upd_resume") != "";
        if (!RelLoad())
        {
            if (relCode == 404 && Cfg("upd_channel") == "") return 0;
            if (!have) { if (Cfg("upd_channel") == "") return 0; throw new Exception("Uplink isn't installed and the update can't be checked (" + relError + ")"); }
            UpdLast((relCode == 404 ? "norelease " : "offline ") + relError);
            UpdNoticeOnce("Couldn't check for updates (" + relError + "): playing the installed version.", CDim);
            UpdLabel("Couldn't check for updates (" + relError + ")", CDim);
            UpdTnpMissing(mode);
            return 1;
        }
        RelChan t = relTarget;
        if (t == null) { UpdLast("nochannel"); if (!have) throw new Exception("release.json has no channel to install"); return 1; }
        if (have && Cfg("upd_skip") != "" && Cfg("upd_skip") == t.Version && !resume)
        {
            UpdLast("skip " + t.Version);
            UpdNoticeOnce("Uplink " + t.V.Short + " is skipped (you rolled back): Tools > Check for updates installs it.", CDim);
            t = RelInstalled();
        }
        bool locked;
        try { locked = UpdTakeLock(resume ? 20000 : 0); }
        catch (Exception e)
        {                                                     // (components\updates can't even be made: a read-only folder)
            if (!have) throw;
            UpdLast("failed readonly");
            Log("update lock: " + e.Message);
            Status(e is UnauthorizedAccessException ? ReadOnlyText() : "The update couldn't start (" + e.Message + "): the installed version still plays.", CRed);
            UpdLabel("Update not installed: read-only folder", CRed);
            return 1;
        }
        if (!locked)
        {
            UpdLast("locked");
            UpdNoticeOnce("Another Uplink launcher is updating this folder: playing the installed version.", CAmber);
            if (!have) throw new Exception("another Uplink launcher is installing this folder");
            return 1;
        }
        try { UpdApply(t, mode, updAuto || resume || form == null); }
        catch (UpdFail e)
        {
            UpdLast("failed " + e.Why);
            Status(e.Message, CRed);
            UpdLabel("Update not installed: " + (e.Why == "readonly" ? "read-only folder" : e.Why == "disk" ? "disk full" : "see the log"), CRed);
            if (!have) throw new Exception(e.Message);
        }
        catch (UpdNetError e)
        {
            UpdLast("netfail " + e.Message);
            UpdNoticeOnce("Couldn't download the update (" + e.Message + "): playing the installed version. It will be tried again next time.", CAmber);
            if (!have) throw new Exception("the download failed (" + e.Message + ")");
        }
        catch (UnauthorizedAccessException) { UpdLast("failed readonly"); Status(ReadOnlyText(), CRed); if (!have) throw; }
        catch (Exception e)
        {                                                     // (anything else: never in the way of PLAY when something is installed)
            if (!have) throw;
            UpdLast("failed other");
            Log(e.ToString());
            Status("The update couldn't be installed (" + (DiskFull(e) ? "disk full" : e.Message) + "): the installed version still plays.", CRed);
        }
        finally
        {
            if (Cfg("upd_last").StartsWith("failed") || Cfg("upd_last").StartsWith("netfail")) UpdCleanStage();
            UpdReleaseLock();
            if (Cfg("upd_resume") != "") { Set("upd_resume", ""); SaveCfg(); }
            Progress(0);
        }
        return 1;
    }

    // after a failed update: nothing of it left in components\updates (a staged tree is kept only for a launcher restart)
    static void UpdCleanStage()
    {
        if (!Directory.Exists(UpdDir)) return;
        foreach (string d in Directory.GetDirectories(UpdDir))
            if (Path.GetFileName(d).StartsWith("s-") || Path.GetFileName(d) == "launcher")
                try { UDel(d); } catch (Exception e) { Log("clean-up of " + d + ": " + e.Message); }
        foreach (string f in Directory.GetFiles(UpdDir))
            if (f.EndsWith(".exe") || f.EndsWith(".zip") || f.EndsWith(".part"))
                try { UDelFile(f); } catch (Exception e) { Log("clean-up of " + f + ": " + e.Message); }
    }

    // offline: the TN+ this mode needs must at least be there
    static void UpdTnpMissing(Mode mode)
    {
        if (mode == Mode.Play && !File.Exists(TnpExe)) throw new Exception("Terra Nova Plus isn't installed yet and the update can't be checked (" + relError + ")");
        if (mode == Mode.Host && !File.Exists(TnpCoopExe)) throw new Exception("Terra Nova Plus's co-op build isn't installed yet and the update can't be checked (" + relError + ")");
    }

    // ---- bring this folder to channel t. The launcher first when it changes (built from t's sources, tested, swapped
    // in, restarted: the new one does the rest); then Uplink's files and the TN+ builds, all staged and checked
    // before the first one is replaced, undone together if one swap fails. auto: no question (asked for just now)
    static void UpdApply(RelChan t, Mode mode, bool auto)
    {
        SemVer me = SemVer.Parse(VERSION), lv = SemVer.Parse(t.Launcher), minv = SemVer.Parse(t.MinLauncher);
        bool have = File.Exists(Path.Combine(UplinkDir, "project.godot"));
        bool game = !have || Cfg("uplink_sha") != t.Uplink.Ref;
        if (minv != null && me != null && minv.CompareTo(me) > 0 && lv.CompareTo(minv) < 0)
            throw new UpdFail("manifest", "release.json is not consistent (launcher " + t.Launcher + " below its minimum " + t.MinLauncher + "): nothing was changed.");
        // a newer launcher always; an older one only with the files it came with (going back to stable, a roll back)
        bool launcher = me == null || lv.CompareTo(me) > 0 || (lv.CompareTo(me) < 0 && game);
        List<string> kinds = new List<string>();
        foreach (string k in new[] { "tnplus", "tnplus_coop" })
        {
            RelPart p = k == "tnplus" ? t.Tnp : t.TnpCoop;
            string exe = k == "tnplus" ? TnpExe : TnpCoopExe;
            bool need = (k == "tnplus" ? mode == Mode.Play : mode == Mode.Host) || File.Exists(exe);
            if (!need) continue;
            if (p == null || p.Tree == null || p.Tree == "") { if (!File.Exists(exe)) BuildTnp(k == "tnplus_coop"); continue; }   // (no release commit known: as before)
            if (!File.Exists(exe) || Cfg(k + "_sha") != p.Ref) kinds.Add(k);
        }
        if (!game && !launcher && kinds.Count == 0)
        {
            if (Cfg("upd_version") != t.Version && t.Uplink.Tree != null) UpdRecord(t);    // (installed by the branches' heads: the same files)
            UpdLast("uptodate " + t.Version);
            return;
        }
        string by = UpdInUse();
        if (by != null)
        {
            UpdLast("deferred " + t.Version + " " + by);
            UpdNoticeOnce("Uplink " + VerShort(t.Version) + " is ready to install: it will be the next time you press PLAY with nothing running (" + by + " runs now).", CAmber);
            UpdLabel("Uplink " + VerShort(t.Version) + " ready: installed at the next start", CAmber);
            return;
        }
        UpdCanWrite(200L << 20);
        string tree = game || launcher ? StageTree(t.Uplink, "Uplink " + VerShort(t.Version)) : null;
        if (launcher)
        {
            string exe = UpdBuildLauncher(tree, t.Launcher);
            if (!auto && !Ask("Uplink " + VerShort(t.Version) + " comes with a new launcher. Restart now to install it?\n\n(No: you play the installed version this time.)"))
            { UpdLast("put off " + t.Version); return; }
            PrevBegin(t.Version);
            Set("upd_resume", t.Version);
            SaveCfg();
            UpdSwapLauncher(exe);                             // (does not come back)
            return;
        }
        // the TN+ builds, in components\updates: nothing replaced yet
        Dictionary<string, string> built = new Dictionary<string, string>();
        foreach (string k in kinds) built[k] = UpdBuildTnp(k == "tnplus" ? t.Tnp : t.TnpCoop, k);
        string from = Installed;
        bool back = have && VerCmp(t.Version, from) < 0;
        List<string> kept = new List<string>();
        List<string[]> done = new List<string[]>();
        if (game && have) { PrevBegin(t.Version); SettingsSave(from); }
        try
        {
            if (game)
            {
                StringBuilder list = new StringBuilder();
                foreach (KeyValuePair<string, string> kv in TreeFiles(tree)) list.Append(kv.Value).Append(' ').Append(kv.Key).Append('\n');
                if (have) kept = UpdKeepUserFiles(UplinkDir, tree);
                File.WriteAllText(Path.Combine(tree, ".release-files"), list.ToString());
                if (have)
                {
                    string pu = Path.Combine(PrevDir, "uplink");
                    UDel(pu);
                    URen(done, UplinkDir, pu);
                }
                URen(done, tree, UplinkDir);
            }
            foreach (KeyValuePair<string, string> kv in built)
            {
                string dir = kv.Key == "tnplus" ? TnpDir : TnpCoopDir, exe = Path.Combine(dir, "TNPlus.exe");
                Directory.CreateDirectory(dir);
                if (File.Exists(exe))
                {
                    string slot = game && have ? Path.Combine(PrevDir, kv.Key, "TNPlus.exe") : exe + ".old";
                    Directory.CreateDirectory(Path.GetDirectoryName(slot));
                    UDelFile(slot);
                    URen(done, exe, slot);
                }
                URen(done, kv.Value, exe);
            }
        }
        catch (Exception e)
        {
            UUndo(done);
            if (DiskFull(e)) throw new UpdFail("disk", DiskText());
            if (e is UnauthorizedAccessException) throw new UpdFail("readonly", ReadOnlyText());
            throw new UpdFail("swap", "Uplink " + VerShort(t.Version) + " couldn't be put in place (" + e.Message + "): the installed version is unchanged and still plays.");
        }
        // done: what is installed now
        if (game || (Cfg("upd_version") != t.Version && t.Uplink.Tree != null)) UpdRecord(t);
        foreach (string k in built.Keys) { Set(k + "_sha", (k == "tnplus" ? t.Tnp : t.TnpCoop).Ref); UDelFile(Path.Combine(k == "tnplus" ? TnpDir : TnpCoopDir, "TNPlus.exe.old")); }
        SaveCfg();
        UpdLast("ok " + t.Version);
        try { foreach (string d in Directory.GetDirectories(UpdDir, "s-*")) UDel(d); } catch (Exception e) { Log("clean-up: " + e.Message); }
        if (kept.Count > 0)
            Status(kept.Count + " file" + (kept.Count > 1 ? "s" : "") + " you had changed in components\\uplink " + (kept.Count > 1 ? "were" : "was") +
                " kept beside the new one" + (kept.Count > 1 ? "s" : "") + " as .user-modified (" + kept[0] + (kept.Count > 1 ? ", ..." : "") + ").", CAmber);
        else if (game) Status("Uplink " + VerFull(t.Version) + " is installed.", CGreen);
        Ui(RefreshUi);
        if (back)
        {
            bool restored = SettingsRestore(t.Version);
            string say = restored
                ? "Your Uplink " + VerShort(t.Version) + " settings are back as you left them. What you changed in " + VerShort(from) + " is kept in components\\settings."
                : "Uplink " + VerShort(t.Version) + " keeps the settings you had in " + VerShort(from) + ": anything it doesn't know is left as it is.";
            UpdRestartWith(say);
        }
    }

    static void UpdRecord(RelChan t)
    {
        Set("uplink_sha", t.Uplink.Ref);
        Set("upd_version", t.Version);
        Set("upd_channel", t.Name);
        if (t.Tnp != null) { Set("upd_tnplus_ref", t.Tnp.Ref); Set("upd_tnplus_tree", t.Tnp.Tree); }
        if (t.TnpCoop != null) { Set("upd_tnplus_coop_ref", t.TnpCoop.Ref); Set("upd_tnplus_coop_tree", t.TnpCoop.Tree); }
        if (Cfg("upd_skip") != "" && VerCmp(t.Version, Cfg("upd_skip")) > 0) Set("upd_skip", "");
        SaveCfg();
    }

    // Uplink's files the player changed (their SHA-256 is not the installed release's): kept beside the new ones as
    // <name>.user-modified; files of the player's own (not the release's) come along. Gives the changed ones' paths
    static List<string> UpdKeepUserFiles(string live, string staged)
    {
        List<string> kept = new List<string>();
        Dictionary<string, string> was = null;
        string lf = Path.Combine(live, ".release-files");
        if (File.Exists(lf))
        {
            was = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (string l in File.ReadAllLines(lf)) if (l.Length > 66) was[l.Substring(65)] = l.Substring(0, 64);
        }
        else
            foreach (RelChan c in new[] { relStable, relBeta })
                if (c != null && c.Uplink.Ref == Cfg("uplink_sha") && c.Uplink.Files != null) was = c.Uplink.Files;
        if (was == null) { Log("no list of the installed files: files changed by hand can't be told apart (left with the old version)"); return kept; }
        foreach (KeyValuePair<string, string> kv in TreeFiles(live))
        {
            string src = Path.Combine(live, kv.Key.Replace('/', '\\')), dst = Path.Combine(staged, kv.Key.Replace('/', '\\'));
            string h;
            if (was.TryGetValue(kv.Key, out h))
            {
                if (h == kv.Value) continue;
                Directory.CreateDirectory(Path.GetDirectoryName(dst));
                File.Copy(src, dst + ".user-modified", true);
                kept.Add(kv.Key);
                Log("changed by hand, kept as " + kv.Key + ".user-modified");
            }
            else if (!File.Exists(dst)) { Directory.CreateDirectory(Path.GetDirectoryName(dst)); File.Copy(src, dst); }
        }
        return kept;
    }

    // a release's tree (Uplink, TN+'s sources): downloaded, unpacked and checked in components\updates, given back only
    // whole and matching release.json (one checked before a launcher restart is taken again, checked again)
    static string StageTree(RelPart p, string what)
    {
        string dir = Path.Combine(UpdDir, "s-" + p.Ref.Substring(0, 12)), zip = dir + ".zip", tmp = dir + ".x";   // (short: deep paths stay under 260)
        if (Directory.Exists(dir)) { if (TreeOk(dir, p)) return dir; UDel(dir); }
        Status("Downloading " + what + "...", CAmber);
        UFetch(p.Url, zip, 30000, true, 2L << 30);
        UDel(tmp);
        try { UUnzip(zip, tmp); }
        catch (InvalidDataException) { UDel(tmp); throw new UpdFail("damaged", what + ": the download is damaged. Nothing was changed; it will be tried again next time."); }
        catch (PathTooLongException) { UDel(tmp); throw new UpdFail("path", what + " can't be unpacked here: the folder's path is too long (" + Root + "). Move the Terra Nova Uplink folder higher up (C:\\Games, for example). Nothing was changed."); }
        catch (IOException e) { UDel(tmp); if (DiskFull(e)) throw new UpdFail("disk", DiskText()); throw; }
        finally { try { File.Delete(zip); } catch { } }
        Directory.Move(tmp, dir);
        if (!TreeOk(dir, p))
        {
            UDel(dir);
            throw new UpdFail("hash", what + " as downloaded doesn't match the release (SHA-256): nothing was changed. It will be tried again next time.");
        }
        return dir;
    }
    // an archive as GitHub makes it, unpacked without its top folder ("terra-nova-uplink-<commit>/": 58 letters less)
    static void UUnzip(string zip, string dest)
    {
        Directory.CreateDirectory(dest);
        string full = Path.GetFullPath(dest).TrimEnd('\\') + "\\";
        using (ZipArchive a = ZipFile.OpenRead(zip))
        {
            string top = null;
            bool one = true;
            foreach (ZipArchiveEntry e in a.Entries)
            {
                int s = e.FullName.IndexOf('/');
                string t = s > 0 ? e.FullName.Substring(0, s + 1) : null;
                if (t == null || (top != null && t != top)) one = false;
                if (top == null) top = t;
            }
            foreach (ZipArchiveEntry e in a.Entries)
            {
                string n = one && top != null ? e.FullName.Substring(top.Length) : e.FullName;
                if (n == "") continue;
                string to = Path.GetFullPath(Path.Combine(dest, n.Replace('/', '\\')));
                if (!to.StartsWith(full, StringComparison.OrdinalIgnoreCase)) continue;            // (no way out of dest)
                if (n.EndsWith("/")) { Directory.CreateDirectory(to); continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(to));
                e.ExtractToFile(to, true);
            }
        }
    }
    static bool TreeOk(string dir, RelPart p)
    {
        string d = TreeDigest(TreeFiles(dir));
        if (d == p.Tree) return true;
        Log("tree " + Path.GetFileName(dir) + ": SHA-256 " + d + ", release.json " + p.Tree);
        return false;
    }

    // a new program just written: an antivirus that takes it away (or locks it) is told apart from a failed build
    static string AvText(string what)
    {
        return "Windows or an antivirus took " + what + " away just after it was built. Nothing was changed: the installed version still plays. " +
            "If your antivirus quarantined it, restore it or allow the Terra Nova Uplink folder, then Tools > Check for updates.";
    }
    static void UAvCheck(string exe, string what)
    {
        Thread.Sleep(1500);                                   // (the time an antivirus takes to look at a new program)
        try { using (FileStream f = new FileStream(exe, FileMode.Open, FileAccess.Read, FileShare.Read)) if (f.Length < 4096) throw new IOException("empty"); }
        catch (Exception e) { Log(what + ": " + e.Message); throw new UpdFail("antivirus", AvText(what)); }
    }

    // the launcher of t, from t's sources with its build.bat's line, tested (--selftest: it must start and say its version)
    static string UpdBuildLauncher(string tree, string want)
    {
        string dir = Path.Combine(tree, "launcher"), cs = Path.Combine(dir, "TerraNovaUplink.cs");
        Match v = File.Exists(cs) ? Regex.Match(File.ReadAllText(cs), "const string VERSION = \"([^\"]+)\"") : Match.Empty;
        if (!v.Success || v.Groups[1].Value != want) throw new UpdFail("manifest", "Uplink's launcher sources are not version " + want + ": nothing was changed.");
        string outDir = Path.Combine(UpdDir, "launcher");
        UDel(outDir);
        Directory.CreateDirectory(outDir);
        string exe = Path.Combine(outDir, Path.GetFileName(Application.ExecutablePath)), args = null, bat = Path.Combine(dir, "build.bat");
        if (File.Exists(bat))
        {
            Match m = Regex.Match(File.ReadAllText(bat), "(?m)^\"%CSC%\"\\s+(.*?)/out:\"Terra Nova Uplink\\.exe\"\\s+TerraNovaUplink\\.cs\\s*$");
            if (m.Success) args = m.Groups[1].Value + "/out:\"" + exe + "\" TerraNovaUplink.cs";
        }
        if (args == null)
        {
            string res = "";
            foreach (string f in Directory.GetFiles(dir, "bg_*.jpg")) res += "/resource:" + Path.GetFileName(f) + " ";
            args = "/nologo /optimize /target:winexe /platform:anycpu /win32manifest:app.manifest /win32icon:icon.ico /r:System.Windows.Forms.dll /r:System.Drawing.dll " +
                "/r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Management.dll " + res + "/out:\"" + exe + "\" TerraNovaUplink.cs";
        }
        Status("Building the launcher of Uplink " + VerShort(want) + "...", CAmber);
        string log;
        int code = UExec(Csc(), args, dir, 180000, out log);
        if (code != 0 || !File.Exists(exe))
        {
            Log("csc: " + log);
            if (code == 0 && !File.Exists(exe)) throw new UpdFail("antivirus", AvText("the new launcher"));
            throw new UpdFail("build", "The new launcher (" + VerShort(want) + ") didn't build (" + FirstError(log) + "). Nothing was changed: Uplink " +
                VerShort(Installed) + " still plays.");
        }
        UAvCheck(exe, "the new launcher");
        string said;
        int sc = UExec(exe, "--selftest", outDir, 30000, out said);
        if (sc != 0 || !said.Contains(TITLE + " " + want)) { Log("selftest " + sc + ": " + said); throw new UpdFail("antivirus", AvText("the new launcher")); }
        return exe;
    }

    // a running program can be renamed, not deleted: this one becomes <exe>.old (put in components\previous by the new
    // one), the new one takes its name and is started; the checks (no window) are told by exit code 3
    static void UpdSwapLauncher(string exe)
    {
        string me = Application.ExecutablePath, old = me + ".old";
        try
        {
            UDelFile(old);
            File.Move(me, old);
            try { File.Move(exe, me); }
            catch { File.Move(old, me); throw; }
        }
        catch (UnauthorizedAccessException) { throw new UpdFail("readonly", ReadOnlyText()); }
        catch (IOException e) { if (DiskFull(e)) throw new UpdFail("disk", DiskText()); throw new UpdFail("swap", "The new launcher couldn't be put in place (" + e.Message + "): nothing was changed."); }
        Log("launcher " + VERSION + " replaced, starting the new one");
        UpdReleaseLock();
        if (form == null) { Console.WriteLine("launcher updated"); Environment.Exit(3); }
        Process.Start(new ProcessStartInfo(me) { UseShellExecute = false, WorkingDirectory = Root });
        Environment.Exit(0);
    }
    // restarted (the settings put back are what the window must show): what to say, said by the next start
    static void UpdRestartWith(string say)
    {
        Set("upd_say", say);
        SaveCfg();
        Log(say);
        if (form == null) { Console.WriteLine(say); return; }
        UpdReleaseLock();
        Process.Start(new ProcessStartInfo(Application.ExecutablePath) { UseShellExecute = false, WorkingDirectory = Root });
        Environment.Exit(0);
    }

    // a TN+ build of release part p, in components\updates (TN+'s build.bat's compiler line, as BuildTnp)
    static string UpdBuildTnp(RelPart p, string kind)
    {
        string what = kind == "tnplus" ? "Terra Nova Plus" : "Terra Nova Plus (co-op build)";
        string src = StageTree(p, what), bat = Path.Combine(src, "src", "build.bat");
        Match m = File.Exists(bat) ? Regex.Match(File.ReadAllText(bat), "(?m)^\"%CSC%\"([^\\r\\n]+)") : Match.Empty;
        if (!m.Success) throw new UpdFail("build", what + ": its build.bat is not understood. Nothing was changed.");
        Status("Building " + what + "...", CAmber);
        string log;
        int code = UExec(Csc(), m.Groups[1].Value.Trim(), Path.Combine(src, "src"), 180000, out log);
        string built = Path.Combine(src, "src", "TNPlus.exe"), outExe = Path.Combine(UpdDir, kind + "-" + p.Ref.Substring(0, 12) + ".exe");
        if (code != 0 || !File.Exists(built))
        {
            Log("csc: " + log);
            throw new UpdFail("build", what + " didn't build (" + FirstError(log) + "). Nothing was changed: the installed version still plays.");
        }
        UDelFile(outExe);
        File.Copy(built, outExe);
        UDel(src);
        UAvCheck(outExe, what);
        return outExe;
    }

    // ---- components\previous: what the last change of version replaced (Tools > Roll back). for.txt: the version it
    // was begun for (a launcher restart in between keeps it); state.ini: the version keys before
    static readonly string[] STATE_KEYS = { "upd_version", "upd_channel", "uplink_sha", "tnplus_sha", "tnplus_coop_sha", "upd_tnplus_ref", "upd_tnplus_tree",
        "upd_tnplus_coop_ref", "upd_tnplus_coop_tree" };
    static void PrevBegin(string forVersion)
    {
        if (URead(Path.Combine(PrevDir, "for.txt")) == forVersion && File.Exists(Path.Combine(PrevDir, "state.ini"))) return;
        UDel(PrevDir);
        Directory.CreateDirectory(PrevDir);
        StringBuilder sb = new StringBuilder();
        foreach (string k in STATE_KEYS) sb.Append(k + " = " + (k == "upd_version" ? Installed : Cfg(k)) + "\r\n");
        sb.Append("launcher = " + VERSION + "\r\n");
        File.WriteAllText(Path.Combine(PrevDir, "state.ini"), sb.ToString());
        File.WriteAllText(Path.Combine(PrevDir, "for.txt"), forVersion);
    }
    // at each start: the launcher this one replaced goes to components\previous; what the last one had to say is said
    static void UpdStartup()
    {
        string[] args = Environment.GetCommandLineArgs();
        if (args.Length > 1 && args[1] == "--rollback")      // checks: Tools > Roll back, without the window
        {
            try { UpdRollbackCore(); Console.WriteLine("rolled back"); Environment.Exit(0); }
            catch (Exception e) { Log(e.Message); Console.WriteLine(e.Message); Environment.Exit(1); }
        }
        // a 2.7 launcher in a folder whose path has accents builds this one as "Terra Nova Uplink.new.exe" but its
        // update.bat can't move it (cmd reads the path in another code page): opened by hand, it takes its place
        string self = Application.ExecutablePath;
        if (args.Length == 1 && self.EndsWith(".new.exe", StringComparison.OrdinalIgnoreCase))
            try
            {
                string target = self.Substring(0, self.Length - 8) + ".exe";
                if (File.Exists(target)) { UDelFile(target + ".old"); File.Move(target, target + ".old"); }
                File.Move(self, target);
                try { File.Delete(Path.Combine(Root, "update.bat")); } catch { }
                Process.Start(new ProcessStartInfo(target) { UseShellExecute = false, WorkingDirectory = Root });
                Environment.Exit(0);
            }
            catch (Exception e) { Log("taking the place of the launcher before: " + e.Message); }
        string old = Application.ExecutablePath + ".old";
        if (File.Exists(old))
            for (int i = 0; i < 20; i++)
                try
                {
                    string slot = Path.Combine(PrevDir, "launcher", Path.GetFileName(Application.ExecutablePath));
                    Directory.CreateDirectory(Path.GetDirectoryName(slot));
                    UDelFile(slot);
                    File.Move(old, slot);
                    break;
                }
                catch (Exception e) { if (i == 19) Log("the launcher before: " + e.Message); else Thread.Sleep(250); }
    }
    static string PrevVersion() { Dictionary<string, string> st = UReadIni(Path.Combine(PrevDir, "state.ini")); string v; return st != null && st.TryGetValue("upd_version", out v) && v != "" ? v : null; }

    // Tools > Roll back to previous version: what components\previous holds and what is installed swap places (so that
    // a second roll back goes forward again); the older version's settings come back; the version left is not put back
    // by itself (upd_skip) until a newer one comes, or Tools > Check for updates
    static void UpdRollback()
    {
        string back = PrevVersion();
        if (back == null || !Directory.Exists(Path.Combine(PrevDir, "uplink"))) { Status("No previous version is kept in this folder.", CText); return; }
        if (busy) return;
        if (!Ask("Go back to Uplink " + VerFull(back) + "? (installed now: " + VerFull(Installed) + ")\n\nThe launcher restarts.")) return;
        Background(UpdRollbackCore);
    }
    static void UpdRollbackCore()
    {
        string back = PrevVersion(), now = Installed;
        if (back == null || !Directory.Exists(Path.Combine(PrevDir, "uplink"))) throw new Exception("no previous version is kept in this folder");
        if (!UpdTakeLock(3000)) throw new Exception("another Uplink launcher is updating this folder");
        List<string[]> done = new List<string[]>();
        try
        {
            string by = UpdInUse();
            if (by != null) throw new Exception("close Uplink and the game first (" + by + " is running)");
            UpdCanWrite(0);
            Dictionary<string, string> st = UReadIni(Path.Combine(PrevDir, "state.ini"));
            SettingsSave(now);
            StringBuilder sb = new StringBuilder();          // components\previous will hold what is installed now
            foreach (string k in STATE_KEYS) sb.Append(k + " = " + (k == "upd_version" ? now : Cfg(k)) + "\r\n");
            string me = Application.ExecutablePath, pl = Path.Combine(PrevDir, "launcher", Path.GetFileName(me)), tmp = Path.Combine(Comp, "swap.tmp");
            bool swapLauncher = File.Exists(pl);
            sb.Append("launcher = " + VERSION + "\r\n");
            UDel(tmp); UDelFile(tmp);
            URen(done, UplinkDir, tmp);
            URen(done, Path.Combine(PrevDir, "uplink"), UplinkDir);
            URen(done, tmp, Path.Combine(PrevDir, "uplink"));
            foreach (string k in new[] { "tnplus", "tnplus_coop" })
            {
                string cur = Path.Combine(k == "tnplus" ? TnpDir : TnpCoopDir, "TNPlus.exe"), prev = Path.Combine(PrevDir, k, "TNPlus.exe");
                string want; st.TryGetValue(k + "_sha", out want);
                if (File.Exists(prev))
                {
                    if (File.Exists(cur)) { URen(done, cur, tmp); URen(done, prev, cur); URen(done, tmp, prev); }
                    else { Directory.CreateDirectory(Path.GetDirectoryName(cur)); URen(done, prev, cur); }
                }
                else if (File.Exists(cur) && Cfg(k + "_sha") != (want ?? ""))
                {                                         // (built after the change: built again, at its own commit, when needed)
                    Directory.CreateDirectory(Path.Combine(PrevDir, k));
                    URen(done, cur, prev);
                }
            }
            if (swapLauncher) { URen(done, me, tmp); URen(done, pl, me); URen(done, tmp, pl); }
            foreach (KeyValuePair<string, string> kv in st) if (Array.IndexOf(STATE_KEYS, kv.Key) >= 0) Set(kv.Key, kv.Value);
            Set("upd_skip", now);
            SaveCfg();
            File.WriteAllText(Path.Combine(PrevDir, "state.ini"), sb.ToString());
            File.WriteAllText(Path.Combine(PrevDir, "for.txt"), now);
            done.Clear();
            UpdLast("rolledback " + back);
            bool restored = VerCmp(back, now) < 0 && SettingsRestore(back);
            UpdReleaseLock();
            UpdRestartWith("Back to Uplink " + VerFull(back) + "." + (restored ? " Your settings of that version are back." : "") +
                " Tools > Check for updates installs " + VerShort(now) + " again.");
        }
        catch (Exception e)
        {
            UUndo(done);
            UpdReleaseLock();
            throw new Exception("roll back not done, nothing was changed: " + e.Message);
        }
    }

    // ---- the settings of each version: kept when the version changes (components\settings\<version>), put back when
    // an older version comes back. Not the update's own keys (upd_*, beta_updates, the commits): those are of the folder
    static readonly string[] UPD_KEYS = { "uplink_sha", "tnplus_sha", "tnplus_coop_sha", "beta_updates" };
    static bool UpdKey(string k) { return k.StartsWith("upd_") || Array.IndexOf(UPD_KEYS, k) >= 0; }
    static string GodotUser()
    {
        string a = Environment.GetEnvironmentVariable("APPDATA");
        if (string.IsNullOrEmpty(a)) a = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(a, "Godot", "app_userdata", "Terra Nova Uplink");
    }
    static string[][] SettingsFiles()
    {
        return new[] { new[] { "TerraNovaUplink.ini", Ini }, new[] { "tnplus.TNPlus.ini", Path.Combine(TnpDir, "TNPlus.ini") },
            new[] { "tnplus_coop.TNPlus.ini", Path.Combine(TnpCoopDir, "TNPlus.ini") }, new[] { "viewer.cfg", Path.Combine(GodotUser(), "viewer.cfg") } };
    }
    static void SettingsSave(string ver)
    {
        string d = Path.Combine(SetDir, USafe(ver));
        UDel(d);
        Directory.CreateDirectory(d);
        SaveCfg();
        foreach (string[] f in SettingsFiles()) if (File.Exists(f[1])) File.Copy(f[1], Path.Combine(d, f[0]), true);
        Log("settings of " + ver + " kept in " + d);
    }
    static bool SettingsRestore(string ver)
    {
        string d = Path.Combine(SetDir, USafe(ver));
        Dictionary<string, string> old = UReadIni(Path.Combine(d, "TerraNovaUplink.ini"));
        if (old == null) { Log("no settings kept for " + ver); return false; }
        foreach (string[] f in SettingsFiles())
        {
            string c = Path.Combine(d, f[0]);
            if (f[0] == "TerraNovaUplink.ini" || !File.Exists(c)) continue;
            try { Directory.CreateDirectory(Path.GetDirectoryName(f[1])); File.Copy(c, f[1], true); } catch (Exception e) { Log("settings " + f[0] + ": " + e.Message); }
        }
        lock (cfg)
        {
            Dictionary<string, string> keep = new Dictionary<string, string>();
            foreach (KeyValuePair<string, string> kv in cfg) if (UpdKey(kv.Key)) keep[kv.Key] = kv.Value;
            cfg.Clear();
            foreach (KeyValuePair<string, string> kv in old) if (!UpdKey(kv.Key)) cfg[kv.Key] = kv.Value;
            foreach (KeyValuePair<string, string> kv in keep) cfg[kv.Key] = kv.Value;
        }
        SaveCfg();
        Log("settings of " + ver + " put back");
        return true;
    }

    // a dependency downloaded by Install (Godot, Python, its wheels): checked against release.json when it gives a hash
    static void UpdVerifyDep(string name, string file)
    {
        string want = JStr(JGet(JGet(rel, "deps"), name), "sha256");
        if (want == null) return;
        if (Sha256File(file) == want) return;
        try { File.Delete(file); } catch { }
        throw new Exception(name + " as downloaded doesn't match its SHA-256 in release.json: nothing was installed. Try again later.");
    }

    // ---- at each start (CheckUpdates, in the background): the label, a finished restart's word, the invitation, the
    // question to a beta tester whose beta became final. false: no release.json yet (the host says as before)
    static bool UpdCheck()
    {
        if (NoUpdate) return false;
        string say = Cfg("upd_say");
        if (say != "") { Set("upd_say", ""); SaveCfg(); Status(say, CGreen); }
        if (!RelLoad())
        {
            if (relCode == 404 && Cfg("upd_channel") == "") return false;
            UpdLabel("Couldn't check for updates (offline?)", CDim);
            return true;
        }
        if (Cfg("upd_resume") != "")
        {
            Ui(delegate {
                Background(delegate {
                    Status("Finishing the update to Uplink " + VerShort(Cfg("upd_resume")) + "...", CAmber);
                    updAuto = true;
                    try { Install(Mode.Play); } finally { updAuto = false; }
                    UpdCheck();
                });
            });
            return true;
        }
        RelChan t = relTarget;
        string inst = Installed, chan = Cfg("upd_channel") == "beta" || (SemVer.Parse(inst) != null && SemVer.Parse(inst).IsPre) ? " (beta)" : "";
        if (t == null) UpdLabel("Uplink " + VerFull(inst) + chan, CDim);
        else if (Cfg("uplink_sha") == t.Uplink.Ref && (Cfg("upd_version") == t.Version || Cfg("upd_version") == "")) UpdLabel("Uplink " + VerFull(inst) + chan + ", up to date", CGreen);
        else if (Cfg("upd_skip") == t.Version) UpdLabel("Uplink " + VerFull(inst) + chan + " (" + t.V.Short + " skipped)", CDim);
        else UpdLabel("Uplink " + t.V.Full + " ready: installed when you press PLAY", CAmber);
        UpdInviteCheck(true);
        UpdFinalCheck();
        return true;
    }

    // ---- the beta: invited when it is newer than stable and than what is installed, and betas are not taken yet.
    // Shown by itself once per line (2.8, 2.9...: upd_invite), then a badge at the foot of the side bar opens it again
    static bool InviteDue()
    {
        return relBeta != null && Cfg("beta_updates") != "1" && (relStable == null || relBeta.V.CompareTo(relStable.V) > 0) && VerCmp(relBeta.Version, Installed) > 0;
    }
    static List<Image> invitePics;
    static List<string> inviteCaps;
    static void UpdInviteCheck(bool auto)
    {
        bool due = InviteDue();
        RelChan b = relBeta;
        Ui(delegate { UpdBadge(due ? b.V.Line + " beta" : null); });
        if (!due || !auto || Cfg("upd_invite") == b.V.Line) return;
        Set("upd_invite", b.V.Line);
        SaveCfg();
        UpdPictures(b);
        Ui(delegate { UpdInviteShow(); });
    }
    static void UpdPictures(RelChan b)
    {
        List<Image> l = new List<Image>();
        List<string> caps = new List<string>();
        foreach (string[] im in b.Pictures)
        {
            if (l.Count == 2) break;
            try
            {
                string f = Path.Combine(UpdDir, "cache", im[1] + ".img");
                if (!File.Exists(f) || Sha256File(f) != im[1])
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(f));
                    UFetch(im[0], f, 15000, false, 8 << 20);
                    if (Sha256File(f) != im[1]) { UDelFile(f); Log("picture " + im[0] + ": its SHA-256 isn't release.json's, left out"); continue; }
                }
                using (MemoryStream ms = new MemoryStream(File.ReadAllBytes(f)))
                using (Image raw = Image.FromStream(ms)) l.Add(new Bitmap(raw));
                caps.Add(im[2]);
            }
            catch (Exception e) { Log("picture left out: " + e.Message); }
        }
        invitePics = l; inviteCaps = caps;
    }
    static void UpdInviteShow()
    {
        RelChan b = relBeta;
        if (b == null || form == null) return;
        if (invitePics == null) { invitePics = new List<Image>(); inviteCaps = new List<string>(); }
        bool yes;
        using (BetaInvite d = new BetaInvite(b, invitePics, inviteCaps)) yes = d.ShowDialog(form) == DialogResult.OK;
        if (yes) UpdTryBeta();
    }
    static void UpdTryBeta()
    {
        Set("beta_updates", "1");
        SaveCfg();
        UpdToggle(true);
        UpdBadge(null);
        UpdSwitchNow("Switching to Uplink " + (relBeta != null ? relBeta.V.Full : "beta") + "...");
    }
    static void UpdSwitchNow(string what)
    {
        if (busy) { Status("Close the game first: the switch is made the next time you press PLAY.", CAmber); return; }
        Background(delegate {
            Status(what, CAmber);
            updAuto = true;
            try { Install(Mode.Play); } finally { updAuto = false; }
            UpdCheck();
        });
    }
    // Settings > Updates > Beta updates
    static void UpdBetaSwitched(bool on)
    {
        Set("beta_updates", on ? "1" : "0");
        SaveCfg();
        if (NoUpdate) { Status("Updates are off in this folder (no_update.txt).", CText); return; }
        if (on)
        {
            UpdBadge(null);
            if (relBeta != null && (relStable == null || relBeta.V.CompareTo(relStable.V) > 0) && VerCmp(relBeta.Version, Installed) > 0)
            {
                if (Ask("Install Uplink " + relBeta.V.Full + " now?\n\n(No: it is installed the next time you press PLAY.)")) UpdSwitchNow("Switching to Uplink " + relBeta.V.Full + "...");
                else Status("Beta updates on: Uplink " + relBeta.V.Short + " is installed the next time you press PLAY.", CGreen);
            }
            else Status("Beta updates on: you get the next beta as soon as there is one.", CGreen);
            return;
        }
        if (SemVer.Parse(Installed) != null && SemVer.Parse(Installed).IsPre && relStable != null)
        {
            if (Ask("Go back to Uplink " + relStable.V.Full + " (stable) now?\n\nYour " + relStable.V.Short + " settings come back as you left them.\n(No: at the next PLAY.)"))
                UpdSwitchNow("Going back to Uplink " + relStable.V.Full + "...");
            else Status("Beta updates off: back to Uplink " + relStable.V.Short + " the next time you press PLAY.", CGreen);
        }
        else Status("Beta updates off.", CGreen);
        UpdInviteCheck(false);
    }
    // a beta tester whose beta became the stable version: once, keep getting betas or not
    static void UpdFinalCheck()
    {
        SemVer inst = SemVer.Parse(Installed);
        if (Cfg("beta_updates") != "1" || relStable == null || relTarget != relStable || inst == null || !inst.IsPre) return;
        if (relStable.V.CompareTo(inst) <= 0 || Cfg("upd_final_asked") == relStable.V.Line) return;
        Set("upd_final_asked", relStable.V.Line);
        SaveCfg();
        RelChan s = relStable;
        Ui(delegate {
            bool keep;
            using (FinalAsk d = new FinalAsk(s)) keep = d.ShowDialog(form) != DialogResult.No;
            Set("beta_updates", keep ? "1" : "0");
            SaveCfg();
            UpdToggle(keep);
            Status(keep ? "You keep getting betas. Uplink " + s.V.Short + " is installed the next time you press PLAY."
                : "Stable only from now on. Uplink " + s.V.Short + " is installed the next time you press PLAY.", CGreen);
        });
    }
    // Tools: Check for updates now (a version rolled back from comes back), Roll back to previous version
    static void UpdCheckNow()
    {
        if (NoUpdate) { Status("Updates are off in this folder (no_update.txt): nothing was checked.", CText); return; }
        Set("upd_skip", "");
        SaveCfg();
        Background(delegate {
            updAuto = true;
            try { Install(Mode.Play); } finally { updAuto = false; }
            string l = Cfg("upd_last");
            if (l.StartsWith("ok ") || l.StartsWith("uptodate ") || l == "") Status("Up to date: Uplink " + VerFull(Installed) + ".", CGreen);
            CheckUpdates();
        });
    }
    static void UpdToolsItems(ContextMenuStrip m)
    {
        string back = PrevVersion();
        ToolStripItem it = m.Items.Add(back != null ? "Roll back to previous version (" + VerFull(back) + ")" : "Roll back to previous version", null, delegate { UpdRollback(); });
        it.Enabled = back != null && !NoUpdate;
    }

    // ---- co-op: two different versions. Uplink 2.8 and later say the friend's version ("friend is on Uplink 2.8
    // beta"); 2.7 only its co-op protocol ("host 4, you 3", "HELLO4"): told by this table
    static readonly string[][] COOP_PROTOCOLS = { new[] { "3", "2.7" }, new[] { "4", "2.8" } };
    static string coopTheirs, coopOurs;
    static string UpdCoopText(string t)
    {
        Match f = Regex.Match(t, @"friend is on (Uplink [^:;,()]+)");
        if (f.Success) return "Your friend is on " + f.Groups[1].Value.Trim() + ": both need the same version (Settings > Updates).";
        string theirs = coopTheirs, ours = coopOurs;          // (one line may say the friend's, another ours)
        Match h = Regex.Match(t, @"host (\S+), you (\d+)");
        if (h.Success) { theirs = h.Groups[1].Value; ours = h.Groups[2].Value; }
        Match g = Regex.Match(t, @"HELLO(\d+)");
        if (g.Success) theirs = g.Groups[1].Value;
        Match y = Regex.Match(t, @"yours: (\d+)");
        if (y.Success) ours = y.Groups[1].Value;
        coopTheirs = theirs; coopOurs = ours;
        string name = null;
        foreach (string[] p in COOP_PROTOCOLS) if (p[0] == theirs) name = p[1];
        int a, b;
        if (theirs != null && ours != null && int.TryParse(theirs, out a) && int.TryParse(ours, out b) && a != b)
        {
            if (a > b) return "Your friend is on a newer Uplink (" + (name ?? "protocol " + theirs) + "): both need the same version. Switch on Beta updates " +
                "(Settings > Updates) if it is a beta, or your friend goes back to stable.";
            return "Your friend is on an older Uplink (" + (name ?? "protocol " + theirs) + "): both need the same version. Your friend updates (PLAY " +
                "updates it), or you go back to stable (Settings > Updates).";
        }
        if (theirs == "older") return "Your friend is on an older Uplink: both need the same version (your friend updates with PLAY).";
        return "Different versions: both of you need the same Uplink (Settings > Updates).";
    }

    // ---- the invitation and the final question: dark, orange, Bahnschrift, drawn at the window's scale
    [DllImport("user32.dll", EntryPoint = "GetDC")] static extern IntPtr UGetDC(IntPtr h);
    [DllImport("user32.dll", EntryPoint = "ReleaseDC")] static extern int UReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll", EntryPoint = "GetDeviceCaps")] static extern int UGetDeviceCaps(IntPtr dc, int what);
    static int udpi;
    static int UDpi()
    {
        if (udpi != 0) return udpi;
        udpi = 96;
        try { IntPtr dc = UGetDC(IntPtr.Zero); if (dc != IntPtr.Zero) { int d = UGetDeviceCaps(dc, 88); UReleaseDC(IntPtr.Zero, dc); if (d >= 48 && d <= 960) udpi = d; } } catch { }
        return udpi;
    }
    static Font UFont(float px, bool bold)
    {
        float size = (float)Math.Round(px * UpdScale()) * 72f / UDpi();
        foreach (string n in bold ? new[] { "Bahnschrift SemiBold", "Segoe UI Semibold" } : new[] { "Bahnschrift", "Segoe UI" })
        {
            Font f = new Font(n, size, FontStyle.Regular, GraphicsUnit.Point);
            if (f.Name == n) return f;
            f.Dispose();
        }
        return new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Point);
    }
    static GraphicsPath URound(RectangleF r, float rad)
    {
        GraphicsPath p = new GraphicsPath();
        float d = Math.Min(rad * 2, Math.Min(r.Width, r.Height));
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    static Color UMix(Color a, Color b, float t) { return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t)); }

    class UButton : Control
    {
        public bool Primary;
        bool over;
        public UButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            Cursor = Cursors.Hand; TabStop = true;
        }
        protected override void OnMouseEnter(EventArgs e) { over = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { over = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnMouseDown(MouseEventArgs e) { Focus(); base.OnMouseDown(e); }
        protected override bool IsInputKey(Keys k) { return k == Keys.Enter || k == Keys.Space || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e) { base.OnKeyDown(e); if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space) OnClick(EventArgs.Empty); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(Parent != null ? Parent.BackColor : CBack);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float z = UpdScale();
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            Color fill = Primary ? (over ? UMix(UOrange, Color.White, 0.18f) : UOrange) : (over ? UMix(CPanel, CText, 0.10f) : CPanel);
            using (GraphicsPath p = URound(r, 6 * z))
            {
                using (Brush b = new SolidBrush(fill)) g.FillPath(b, p);
                if (!Primary) using (Pen l = new Pen(UEdge)) g.DrawPath(l, p);
            }
            if (Focused && ShowFocusCues)
                using (GraphicsPath p = URound(RectangleF.Inflate(r, -3 * z, -3 * z), 4 * z))
                using (Pen l = new Pen(Primary ? UInk : CText)) { l.DashStyle = DashStyle.Dot; g.DrawPath(l, p); }
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, Primary ? UInk : CText, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }

    class BetaInvite : Form
    {
        RelChan b;
        float z;
        Font fTag, fTitle, fSub, fHead, fItem, fNote, fCap;
        List<Image> pics; List<string> caps;
        Rectangle notes;
        int scroll, contentH;
        int Z(float v) { return (int)Math.Round(v * z); }
        public BetaInvite(RelChan beta, List<Image> pictures, List<string> captions)
        {
            b = beta; pics = pictures; caps = captions; z = UpdScale();
            Text = "Uplink " + b.V.Line + " beta";
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent; BackColor = CBack; ForeColor = CText; KeyPreview = true; DoubleBuffered = true;
            fTag = UFont(10, true); fTitle = UFont(25, true); fSub = UFont(14, false); fHead = UFont(11, true); fItem = UFont(13, false);
            fNote = UFont(12, false); fCap = UFont(11, false);
            Font = UFont(14, true);
            int W = 600, H = pics.Count > 0 ? 600 : 480;
            ClientSize = new Size(Z(W), Z(H));
            int pich = pics.Count > 0 ? 150 + 26 : 0;
            notes = new Rectangle(Z(28), Z(132), Z(W - 56), Z(H - 76 - 16 - 132 - pich));
            UButton yes = new UButton { Primary = true, Text = "Try the beta", Name = "try_beta", Font = Font, Bounds = new Rectangle(Z(W - 28 - 160), Z(H - 58), Z(160), Z(40)) };
            UButton no = new UButton { Text = "Not now", Name = "not_now", Font = Font, Bounds = new Rectangle(Z(W - 28 - 160 - 12 - 116), Z(H - 58), Z(116), Z(40)) };
            yes.Click += delegate { DialogResult = DialogResult.OK; };
            no.Click += delegate { DialogResult = DialogResult.Cancel; };
            Controls.Add(no); Controls.Add(yes);
            Shown += delegate { yes.Focus(); };
            MouseWheel += delegate(object s, MouseEventArgs e) { ScrollBy(-e.Delta / 120 * Z(36)); };
            using (Graphics g = CreateGraphics()) contentH = DrawNotes(g, false);
        }
        void ScrollBy(int dy) { int max = Math.Max(0, contentH - notes.Height); int s = Math.Max(0, Math.Min(max, scroll + dy)); if (s != scroll) { scroll = s; Invalidate(notes); } }
        protected override bool ProcessCmdKey(ref Message msg, Keys k)
        {
            if (k == Keys.Escape) { DialogResult = DialogResult.Cancel; return true; }
            if (k == Keys.Down || k == Keys.PageDown) { ScrollBy(k == Keys.Down ? Z(36) : notes.Height - Z(20)); return true; }
            if (k == Keys.Up || k == Keys.PageUp) { ScrollBy(k == Keys.Up ? -Z(36) : -(notes.Height - Z(20))); return true; }
            return base.ProcessCmdKey(ref msg, k);
        }
        // the changelog by sections; its height (drawn only when draw)
        int DrawNotes(Graphics g, bool draw)
        {
            int y = 0, w = notes.Width - Z(14);
            TextFormatFlags wrap = TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.TextBoxControl | TextFormatFlags.PreserveGraphicsClipping;
            List<KeyValuePair<string, List<string>>> secs = b.Changes.Count > 0 ? b.Changes :
                new List<KeyValuePair<string, List<string>>> { new KeyValuePair<string, List<string>>("What's new", new List<string> { "See What's new once it is installed." }) };
            foreach (KeyValuePair<string, List<string>> s in secs)
            {
                if (draw) TextRenderer.DrawText(g, s.Key.ToUpperInvariant(), fHead, new Point(notes.X, notes.Y + y - scroll), UOrange, TextFormatFlags.NoPadding | TextFormatFlags.PreserveGraphicsClipping);
                y += Z(22);
                foreach (string it in s.Value)
                {
                    Size sz = TextRenderer.MeasureText(g, it, fItem, new Size(w - Z(18), 10000), wrap);
                    if (draw)
                    {
                        using (Brush br = new SolidBrush(UOrange)) g.FillRectangle(br, notes.X + Z(2), notes.Y + y - scroll + Z(7), Z(5), Z(5));
                        TextRenderer.DrawText(g, it, fItem, new Rectangle(notes.X + Z(18), notes.Y + y - scroll, w - Z(18), sz.Height), CText, wrap);
                    }
                    y += sz.Height + Z(6);
                }
                y += Z(12);
            }
            return y;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int W = ClientSize.Width, H = ClientSize.Height;
            using (Brush top = new SolidBrush(UOrange)) g.FillRectangle(top, 0, 0, W, Z(3));
            // BETA tag, the title, the subtitle
            string tag = b.V.Full.ToUpperInvariant();       // "2.8 BETA 1"
            Size ts = TextRenderer.MeasureText(g, tag, fTag, new Size(1000, 100), TextFormatFlags.NoPadding);
            RectangleF tr = new RectangleF(Z(28), Z(24), ts.Width + Z(18), Z(20));
            using (GraphicsPath p = URound(tr, Z(10))) using (Pen l = new Pen(UOrange, Math.Max(1f, z))) g.DrawPath(l, p);
            TextRenderer.DrawText(g, tag, fTag, Rectangle.Round(tr), UOrange, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            TextRenderer.DrawText(g, b.Title ?? "Uplink " + b.V.Line + " is in beta", fTitle, new Point(Z(26), Z(52)), CText, TextFormatFlags.NoPadding);
            TextRenderer.DrawText(g, b.Subtitle ?? "Try the next version before everyone else. You can go back to stable at any time.", fSub,
                new Rectangle(Z(28), Z(90), W - Z(56), Z(36)), CDim, TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
            using (Pen l = new Pen(CLine)) g.DrawLine(l, Z(28), Z(122), W - Z(28), Z(122));
            // the changelog (scrolls with the wheel and the arrows when it is longer than its place)
            GraphicsState st = g.Save();
            g.SetClip(notes);
            DrawNotes(g, true);
            g.Restore(st);
            if (contentH > notes.Height)
            {
                float th = Math.Max(Z(24), notes.Height * (float)notes.Height / contentH), ty = notes.Y + (notes.Height - th) * scroll / (contentH - notes.Height);
                using (Brush sb = new SolidBrush(CLine)) g.FillRectangle(sb, notes.Right - Z(4), notes.Y, Z(3), notes.Height);
                using (Brush sb = new SolidBrush(CDim)) g.FillRectangle(sb, notes.Right - Z(4), ty, Z(3), th);
            }
            // the pictures (at most two, each with its caption)
            if (pics.Count > 0)
            {
                int pw = (W - Z(56) - Z(16)) / 2, ph = Z(150), py = H - Z(76) - Z(16) - ph - Z(26);
                for (int i = 0; i < pics.Count; i++)
                {
                    Rectangle box = new Rectangle(Z(28) + i * (pw + Z(16)), py, pw, ph);
                    Image im = pics[i];
                    float k = Math.Max((float)box.Width / im.Width, (float)box.Height / im.Height);
                    RectangleF src = new RectangleF((im.Width - box.Width / k) / 2, (im.Height - box.Height / k) / 2, box.Width / k, box.Height / k);
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    using (GraphicsPath p = URound(box, Z(6)))
                    {
                        GraphicsState s2 = g.Save();
                        g.SetClip(p);
                        g.DrawImage(im, box, src, GraphicsUnit.Pixel);
                        g.Restore(s2);
                        using (Pen l = new Pen(UEdge)) g.DrawPath(l, p);
                    }
                    if (i < caps.Count && caps[i] != "")
                        TextRenderer.DrawText(g, caps[i], fCap, new Rectangle(box.X, box.Bottom + Z(6), box.Width, Z(18)), CDim, TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
                }
            }
            // the foot: how to go back, the two buttons (controls)
            using (Pen l = new Pen(CLine)) g.DrawLine(l, 0, H - Z(76), W, H - Z(76));
            TextRenderer.DrawText(g, "Back to stable at any time:\nBeta updates, in Settings.", fNote, new Rectangle(Z(28), H - Z(58), Z(250), Z(40)), CDim,
                TextFormatFlags.NoPadding | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak);
        }
    }

    class FinalAsk : Form
    {
        float z;
        int Z(float v) { return (int)Math.Round(v * z); }
        RelChan s;
        Font fTitle, fBody;
        public FinalAsk(RelChan stable)
        {
            s = stable; z = UpdScale();
            Text = "Uplink " + s.V.Short;
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent; BackColor = CBack; ForeColor = CText; KeyPreview = true; DoubleBuffered = true;
            fTitle = UFont(23, true); fBody = UFont(14, false); Font = UFont(14, true);
            ClientSize = new Size(Z(540), Z(272));
            UButton keep = new UButton { Primary = true, Text = "Keep getting betas", Name = "keep_betas", Font = Font, Bounds = new Rectangle(Z(540 - 28 - 190), Z(272 - 58), Z(190), Z(40)) };
            UButton stab = new UButton { Text = "Stable only", Name = "stable_only", Font = Font, Bounds = new Rectangle(Z(540 - 28 - 190 - 12 - 140), Z(272 - 58), Z(140), Z(40)) };
            keep.Click += delegate { DialogResult = DialogResult.Yes; };
            stab.Click += delegate { DialogResult = DialogResult.No; };
            Controls.Add(stab); Controls.Add(keep);
            Shown += delegate { keep.Focus(); };
        }
        protected override bool ProcessCmdKey(ref Message msg, Keys k)
        {
            if (k == Keys.Escape) { DialogResult = DialogResult.Cancel; return true; }
            return base.ProcessCmdKey(ref msg, k);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            int W = ClientSize.Width, H = ClientSize.Height;
            using (Brush top = new SolidBrush(UOrange)) g.FillRectangle(top, 0, 0, W, Z(3));
            TextRenderer.DrawText(g, "Uplink " + s.V.Short + " is now final", fTitle, new Point(Z(26), Z(28)), CText, TextFormatFlags.NoPadding);
            TextRenderer.DrawText(g, "Thanks for trying the beta. " + s.V.Short + " is the stable version now: it is installed the next time you press PLAY.\n\n" +
                "Keep getting beta versions when there are new ones?", fBody, new Rectangle(Z(28), Z(74), W - Z(56), Z(110)), CDim, TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
            using (Pen l = new Pen(CLine)) g.DrawLine(l, 0, H - Z(76), W, H - Z(76));
        }
    }

    // the badge at the foot of the side bar ("2.8 beta"): opens the invitation again
    class UBadge : Control
    {
        bool over;
        public UBadge()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            Cursor = Cursors.Hand; TabStop = true; Visible = false; Name = "beta_badge";
            Click += delegate { UpdInviteShow(); };
        }
        protected override void OnMouseEnter(EventArgs e) { over = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { over = false; Invalidate(); base.OnMouseLeave(e); }
        protected override bool IsInputKey(Keys k) { return k == Keys.Enter || k == Keys.Space || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e) { base.OnKeyDown(e); if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space) OnClick(EventArgs.Empty); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(Parent != null ? Parent.BackColor : CPanel);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float z = UpdScale();
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (GraphicsPath p = URound(r, Height / 2f))
            {
                using (Brush b = new SolidBrush(over ? UMix(CPanel, UOrange, 0.22f) : UMix(CPanel, UOrange, 0.10f))) g.FillPath(b, p);
                using (Pen l = new Pen(UOrange, Math.Max(1f, z))) g.DrawPath(l, p);
            }
            float d = 6 * z;
            using (Brush b = new SolidBrush(UOrange)) g.FillEllipse(b, 10 * z, (Height - d) / 2f, d, d);
            using (Font f = UFont(12, true))
                TextRenderer.DrawText(g, Text, f, new Rectangle((int)(22 * z), 0, Width - (int)(26 * z), Height), UOrange, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            if (Focused && ShowFocusCues) using (Pen l = new Pen(CText)) { l.DashStyle = DashStyle.Dot; g.DrawRectangle(l, 2, 2, Width - 5, Height - 5); }
        }
    }
    static UBadge badge;
    static void UpdBadge(string text)
    {
        if (badge == null) return;
        badge.Text = text ?? "";
        badge.Visible = text != null;
        badge.Invalidate();
    }
}

// ====================================================================================================================
// RELEASE CHANNELS, host glue: where this launcher's window shows them (Settings, the side bar's foot, the label)
// ====================================================================================================================
static partial class Uplink
{
    // A test folder: with a file no_update.txt beside the exe, nothing is looked for on GitHub and nothing is
    // downloaded, built or replaced
    static bool NoUpdate { get { return File.Exists(Path.Combine(Root, "no_update.txt")); } }
    static Tick betaTick;
    static bool betaLoading;
    // this window is drawn at 100 % (Windows scales it); checks can ask for the dialogs at another scale
    static float UpdScale()
    {
        float f;
        return float.TryParse(Environment.GetEnvironmentVariable("TN_LAUNCHER_SCALE"), NumberStyles.Float, CultureInfo.InvariantCulture, out f) && f >= 1f && f <= 3f ? f : 1f;
    }
    static void UpdLabel(string s, Color c) { Ui(delegate { if (verLabel == null) return; verLabel.Text = "●  " + s; verLabel.ForeColor = c; }); }
    static void UpdToggle(bool on) { Ui(delegate { if (betaTick == null) return; betaLoading = true; betaTick.Checked = on; betaLoading = false; }); }
    static void UpdSettingsRow(Control box, int x, int y)
    {
        betaTick = new Tick { Text = "Beta updates", AutoSize = true, Location = new Point(x, y), ForeColor = CText, BackColor = CPanel, Name = "beta_updates" };
        betaTick.Checked = Cfg("beta_updates") == "1";
        betaTick.CheckedChanged += delegate { if (!betaLoading) UpdBetaSwitched(betaTick.Checked); };
        box.Controls.Add(betaTick);
    }
    static void UpdBadgeAt(Control bar, int x, int y)
    {
        badge = new UBadge { Location = new Point(x, y), Size = new Size(114, 26) };
        bar.Controls.Add(badge);
    }
}
