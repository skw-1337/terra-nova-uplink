// Terra Nova Uplink: one window for everything Uplink does. It installs what each mode needs in its own folder
// (Uplink, Godot, Terra Nova Plus and its co-op build, an embedded Python for the live mode's bridge), keeps them up
// to date (itself included: a newer launcher in Uplink's files is built and swapped in) and starts everything in order:
//   PLAY: the game through TN+ (no menu, HD 848x480, windowed behind Uplink), then the bridge, which opens Uplink live.
//   HOST A GAME: the same with the TN+ co-op build and Uplink's Steam lobby (the host plays, a friend joins).
//   JOIN A FRIEND: Uplink's guest window, where the friends hosting a game show up with a JOIN button.
//   MAP VIEWER: Uplink's map viewer, every map of the game.
// The pages' pictures (bg_play.jpg, bg_coop.jpg, bg_maps.jpg, next to this file) are built into the exe by build.bat;
// a launcher built without them (a 2.7 launcher updating itself) reads them from Uplink's files: see LoadHeroes.
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
    const string VERSION = "2.7";
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
    // (orange and blue: the two players' colours on the co-op HUD)
    static readonly Color CGreen = Color.FromArgb(56, 214, 92), CRed = Color.FromArgb(236, 72, 60), COrange = Color.FromArgb(232, 134, 42);
    static readonly Color CBlue = Color.FromArgb(61, 139, 240), CLedOff = Color.FromArgb(40, 64, 58);

    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool IsProcessDPIAware();
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern int GetDeviceCaps(IntPtr dc, int what);
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
    static volatile bool busy, stopping, coopRun;
    static readonly List<Process> mine = new List<Process>();
    static string sessionName = "", sessionPing = "";

    enum Mode { Play, Host, Join, Maps }
    static Mode? running;                                     // what PLAY, HOST, JOIN or MAP VIEWER started, while it runs

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
        bool had = File.Exists(Ini);
        LoadCfg();
        AdoptGameSettings();                                   // (what Uplink's own menu changed since: its viewer.cfg)
        // The keys a new installation comes with (2: freelook on F), as against one that was already there (1: on
        // Y): said once, when the settings do not say yet, so that nobody's key changes with an update
        if (Cfg("keys_gen") != "1" && Cfg("keys_gen") != "2") Set("keys_gen", had && cfg.Count > 0 ? "1" : "2");
        string[] args = Environment.GetCommandLineArgs();
        if (args.Length > 2 && args[1] == "--install")    // checks: install / update only, no window (exit code 0 = ok)
        {
            Mode m = args[2] == "host" ? Mode.Host : args[2] == "join" ? Mode.Join : args[2] == "maps" ? Mode.Maps : Mode.Play;
            try { Install(m); Console.WriteLine("installed"); Environment.Exit(0); }
            catch (Exception e) { Log(e.ToString()); Environment.Exit(1); }
        }
        if (args.Length > 1 && args[1] == "--report")           // the report, without the window (checks: into that folder)
        { if (args.Length > 2) Report(args[2]); else Report(); Environment.Exit(0); }
        if (args.Length > 3 && (args[1] == "--labsave" || args[1] == "--makesave"))   // checks: the save of mission N in a TNOVA copy
        { Set("game_dir", args[3]); Console.WriteLine(MakeSave(args[3], int.Parse(args[2]) - 1, args[1] == "--makesave" ? COOP_SAVE : PLAY_SAVE) ?? "failed"); Environment.Exit(0); }
        if (args.Length > 1 && args[1] == "--closegame")   // checks: close the game this launcher started (exit 0 = one was)
        { Environment.Exit(CloseOurGame() ? 0 : 2); }
        if (args.Length > 1 && args[1] == "--steam-ready") // checks: Steam running and logged in (exit 0 = yes)
        { Environment.Exit(SteamReady() ? 0 : 2); }
        if (args.Length > 1 && args[1] == "--binds")       // checks: TN+'s second binds, as Uplink is told them
        { Console.WriteLine(Binds()); Environment.Exit(0); }
        if (args.Length > 1 && args[1] == "--env")         // checks: what Uplink is told when it starts (the options)
        { foreach (KeyValuePair<string, string> kv in Env()) Console.WriteLine(kv.Key + "=" + kv.Value); Environment.Exit(0); }
        if (args.Length > 1 && args[1] == "--games")       // checks: every Terra Nova found
        { foreach (string d in Installs()) Console.WriteLine(Edition(d) + (IsEnglish(d) ? " EN  " : "     ") + d); Environment.Exit(0); }
        if (args.Length > 3 && args[1] == "--roundtrip")   // checks: an LG Res file read and written back
        { Res.Load(args[2]).Save(args[3]); Environment.Exit(0); }
        try { File.Delete(Path.Combine(Root, "update.bat")); } catch { }
        // The window is drawn at the screen's own scale (100, 125, 150 %...): every size below is for 100 % and
        // multiplied by K, the text set on whole pixels at that scale. The process says it handles the scale in its
        // manifest (dpiAware: in force before any code, GDI+ included, which keeps the scale it first saw; called here
        // too for a launcher built without it). The scale is read from GDI, which draws the text, and the fonts are
        // made from that same DPI (ScaleFonts): a 13-pixel line is 13 x K pixels whatever GDI+ believes.
        try { SetProcessDPIAware(); } catch { }
        Application.EnableVisualStyles();
        ReadScale();
        if (args.Length > 1 && args[1] == "--dpi")             // checks: what this PC's scale gives
        {
            using (Graphics g0 = Graphics.FromHwnd(IntPtr.Zero))
            using (Font f13 = Px(13f, 400))
                Console.WriteLine("aware " + IsProcessDPIAware() + ", GDI dpi " + DpiGdi + ", GDI+ dpi " + g0.DpiX + ", K " + K.ToString(CultureInfo.InvariantCulture) +
                    ", a 13 px line: " + TextRenderer.MeasureText("Hg", f13, new Size(500, 100), TextFormatFlags.NoPadding).Height + " px high (expected about " +
                    Math.Round(13 * K * 1.2) + "), font " + f13.Name + " " + f13.SizeInPoints.ToString("0.##", CultureInfo.InvariantCulture) + " pt");
            Environment.Exit(0);
        }
        Build();
        form.Shown += delegate { RefreshUi(); new Thread(CheckUpdates) { IsBackground = true }.Start(); };
        form.FormClosing += delegate { AdoptNow(); loading = false; SaveOptions(); stopping = true; };
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
    // A side bar (the five pages, What's new and Help at its foot) and one page at a time, 610 x 500. Play, Co-op and
    // Maps lie on a picture of Uplink's own (bg_play.jpg, bg_coop.jpg, bg_maps.jpg: see LoadHero); In game and
    // Settings are cards. Everything is drawn here (switches, lists, sliders, key buttons): no Windows control shows.
    static Surface[] pages;
    static Surface side;
    static Nav[] navs;
    static Switch fpsBox, oldBox, runTick, introBox, wheelTick, subsTick, invertBox, padBox, hudTick, editTick;
    static Btn wheelKeyBtn, photoKeyBtn, shotKeyBtn, oldKeyBtn, sharpKeyBtn, gameBtn, gameBtn2, toolsBtn, keysBtn, checkBtn;
    static Big playBtn, mapBtn;
    static CoopTile hostBtn, joinBtn;
    static GameLine gameLine, gameLine2;
    static Drop sizeBox, missionBox, crossBox, capBox, tapGround, tapEnemy;
    static Seg sharpSeg;
    static Slide sensBar, tapBar, deadBar;
    static Txt sensLabel, tapLabel, sessionLabel;
    static LedLine[] leds;
    static LedLine verLabel;
    static Led sessionLed;
    static Surface sessionRow;
    static Panel bar, barFill;
    static TextBox logBox;
    static WheelPad wheel;
    static Radio[] wheelPicks;
    static Toast toast;
    static bool loading;                                      // the options are being put on the pages: nothing is saved
    static int capValue;                                      // the frame limit (0: none)
    // Uplink's extras on top of the game's look, each on unless switched off (fx_<name> in the ini, TN_FX_<NAME> for Uplink)
    static readonly string[] FX = { "marks", "lights", "cloud_shadows", "look_down", "cliffs", "stars", "tracks" };
    static readonly string[] FX_NAMES = { "Impact marks", "Light from shots", "Cloud shadows", "Look further down", "Unstretched cliffs", "Sharp stars", "Footprints, tracks" };
    static Switch[] fxTicks = new Switch[7];
    static readonly string[] PAGES = { "Play", "Co-op", "Maps", "In game", "Controls", "Settings" };
    const int SB = 150, MW = 610, MH = 500;                   // the side bar's width, a page's size
    const int P_WHEEL = 6;                                    // the order wheel's page (opened from In game)
    const int P_CONTROLS = 4, P_SETTINGS = 5;
    // the squad's orders, by their number (as Uplink and its bridge count them: scripts\order_wheel.gd, live\orders.py)
    static readonly string[] ORDERS = { "Attack target", "Move there", "Take cover", "Retreat", "Follow me", "Hold position", "Assume formation" };
    static readonly Color CSoft = Color.FromArgb(157, 176, 169), CTape = Color.FromArgb(242, 194, 26), CTapeInk = Color.FromArgb(21, 20, 15);
    static readonly Color COff = Color.FromArgb(34, 51, 47), CKnob = Color.FromArgb(108, 133, 125);
    static Font F10, F9, F95b, F10b, F105b, F11, F115, F12, F12s, F125, F13, F14s, F16b, F19b, F22b;
    static StringFormat SF;
    static readonly Graphics GM = Graphics.FromImage(new Bitmap(1, 1));
    static float K = 1f;                                      // the screen's scale: 1 at 100 %, 1.25, 1.5...
    static int DpiGdi = 96;                                   // the screen's DPI as GDI gives it (what draws the text)

    static void ReadScale()
    {
        try
        {
            IntPtr dc = GetDC(IntPtr.Zero);
            if (dc != IntPtr.Zero) { int d = GetDeviceCaps(dc, 88); ReleaseDC(IntPtr.Zero, dc); if (d >= 48 && d <= 960) DpiGdi = d; }   // LOGPIXELSX
        }
        catch { }
        K = DpiGdi / 96f;
        float forced;
        if (float.TryParse(Environment.GetEnvironmentVariable("TN_LAUNCHER_SCALE"), NumberStyles.Float, CultureInfo.InvariantCulture, out forced) && forced >= 1f && forced <= 3f)
            K = forced;                                           // (checks: the window as on a screen at that scale)
    }

    // A font of so many pixels at this scale, in points from GDI's own DPI: drawn by GDI (TextRenderer: the size in
    // points times the DC's DPI) it is exactly that many pixels; a font in pixels went through GDI+'s idea of the
    // DPI on its way, and came out too big where the two differ.
    static Font Sized(string name, float px, FontStyle style) { return new Font(name, px * 72f / DpiGdi, style, GraphicsUnit.Point); }
    static int S(float v) { return (int)Math.Round(v * K); }

    static int pageNow;

    static void ShowPage(int k)
    {
        pageNow = k;
        for (int i = 0; i < pages.Length; i++) pages[i].Visible = i == k;
        int nav = k == P_WHEEL ? 3 : k;
        for (int i = 0; i < navs.Length; i++) { navs[i].On = i == nav; navs[i].Invalidate(); }
        Set("page", nav.ToString());
        if (k == 3) ReadSharp();
        if (k == P_WHEEL) WheelUi();
        if (k == P_CONTROLS) { ControlsLoad(); keyList.Top0 = 0; keyList.Invalidate(); }
        if (toast != null) toast.Place();
    }

    // One family for the whole window, in three weights. Bahnschrift (Windows 10 and 11's own DIN): the face Uplink
    // writes its HUD lines and its order wheel in, close to the game's cockpit letters. "font = segoe" in the ini:
    // Segoe UI. A PC without the family (before Windows 10 1709): Segoe UI. Sizes are whole pixels at the screen's
    // scale, drawn by GDI (the hinting Windows' own text has).
    static readonly string[][] FAMILIES = {
        new[] { "Bahnschrift", "Bahnschrift SemiBold", "Bahnschrift SemiBold" },
        new[] { "Segoe UI", "Segoe UI Semibold", "Segoe UI Semibold" } };

    static Font Px(float px, int weight)
    {
        float size = (float)Math.Max(7, Math.Round(px * K));
        foreach (string[] fam in new[] { FAMILIES[Cfg("font").ToLowerInvariant() == "segoe" ? 1 : 0], FAMILIES[1] })
        {
            string name = fam[weight >= 700 ? 2 : weight >= 600 ? 1 : 0];
            Font f = Sized(name, size, FontStyle.Regular);
            if (f.Name == name) return f;
            f.Dispose();
        }
        return Sized("Segoe UI", size, weight >= 600 ? FontStyle.Bold : FontStyle.Regular);
    }

    // a dialog's font: a size in points as at 100 %, set in pixels at the screen's scale
    static Font Pt(string[] families, float pt, FontStyle style)
    {
        float size = (float)Math.Round(pt * 96f / 72f * K);
        foreach (string f in families)
            using (Font t = Sized(f, size, style))
                if (t.Name == f) return Sized(f, size, style);
        return Sized("Segoe UI", size, style);
    }

    // a dialog built for 100 %: its sizes at the screen's scale
    static void Dpi(Form f) { if (K != 1f) f.Scale(new SizeF(K, K)); }

    // the pages, built for 100 %: every control's place and size at the screen's scale
    static void ScaleTree(Control c)
    {
        foreach (Control k in c.Controls)
        {
            int x0 = S(k.Left), y0 = S(k.Top), x1 = S(k.Right), y1 = S(k.Bottom);
            ScaleTree(k);
            k.Bounds = new Rectangle(x0, y0, x1 - x0, y1 - y0);
        }
    }

    static RectangleF Logical(Control c) { return new RectangleF(c.Left / K, c.Top / K, c.Width / K, c.Height / K); }

    static void Build()
    {
        FHead = Px(17f, 600);
        FBody = Px(13f, 400);
        FSmall = Px(11f, 400);
        FIcon = Pt(new[] { "Segoe Fluent Icons", "Segoe MDL2 Assets" }, 16f, FontStyle.Regular);
        F10 = Px(10f, 400); F9 = Px(9f, 400); F95b = Px(10f, 700); F10b = Px(10f, 700); F105b = Px(11f, 700); F11 = Px(11f, 400); F115 = Px(12f, 400);
        F12 = Px(12f, 400); F12s = Px(12f, 600); F125 = Px(13f, 400); F13 = Px(13f, 400); F14s = Px(15f, 600); F16b = Px(17f, 700);
        F19b = Px(20f, 700); F22b = Px(23f, 700);
        SF = new StringFormat(StringFormat.GenericTypographic);
        SF.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap;

        form = new Form();
        form.Text = TITLE + " " + VERSION;
        form.FormBorderStyle = FormBorderStyle.FixedSingle;
        form.MaximizeBox = false;
        form.StartPosition = FormStartPosition.CenterScreen;
        form.BackColor = CBack;
        form.ForeColor = CText;
        form.Font = FBody;
        try { form.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        loading = true;

        // the side bar: the title, one entry per page, What's new and Help at its foot
        side = new Surface { Location = new Point(0, 0), Size = new Size(SB, MH) };
        side.Look = delegate(Graphics g) {
            g.Clear(CPanel);
            using (Brush p = new SolidBrush(CLine)) g.FillRectangle(p, SB - 1, 0, 1, side.Height / K + 1);
            Spaced(g, "TERRA NOVA", F16b, COrange, 18, 16, 0.8f);
            Str(g, "Uplink " + VERSION, F11, CDim, 18, 42);
            using (Brush b = new SolidBrush(CBlue)) g.FillRectangle(b, 18, 64, 66, 2);
        };
        form.Controls.Add(side);
        pages = new Surface[PAGES.Length + 1]; navs = new Nav[PAGES.Length];
        for (int i = 0; i < pages.Length; i++)
        {
            pages[i] = new Surface { Location = new Point(SB, 0), Size = new Size(MW, MH), Visible = false };
            form.Controls.Add(pages[i]);
        }
        for (int i = 0; i < PAGES.Length; i++)
        {
            int k = i;
            navs[i] = new Nav { Text = PAGES[i], Location = new Point(10, 86 + i * 39), Size = new Size(SB - 20, 35) };
            navs[i].Click += delegate { ShowPage(k); };
            side.Controls.Add(navs[i]);
        }
        Link news = new Link { Text = "What's new", Ink = CBlue, Location = new Point(20, 442), Size = new Size(90, 18) };
        news.Click += delegate { WhatsNew(); };
        side.Controls.Add(news);
        Link help = new Link { Text = "Help", Ink = CDim, Location = new Point(20, 461), Size = new Size(60, 18) };
        help.Click += delegate { HelpMenu().Show(help, new Point(0, 0), ToolStripDropDownDirection.AboveRight); };
        side.Controls.Add(help);

        BuildPlay(pages[0]);
        BuildCoop(pages[1]);
        BuildMaps(pages[2]);
        BuildInGame(pages[3]);
        BuildControls(pages[P_CONTROLS]);
        BuildSettings(pages[P_SETTINGS]);
        BuildWheel(pages[P_WHEEL]);
        LoadHeroes();

        // over the pages: the progress of a download, a thin line at the foot; under them, the log when it is asked for
        bar = new Panel { Location = new Point(SB, MH - 3), Size = new Size(MW, 3), BackColor = CLine, Visible = false };      // (its fill: see Progress)
        barFill = new Panel { Location = new Point(0, 0), Size = new Size(0, 3), BackColor = COrange };
        bar.Controls.Add(barFill);
        form.Controls.Add(bar);
        bar.BringToFront();
        logBox = new TextBox { Location = new Point(SB + 18, MH + 6), Size = new Size(MW - 36, 140), Multiline = true, ReadOnly = true, Visible = false,
            ScrollBars = ScrollBars.Vertical, BackColor = CPanel, ForeColor = CDim, BorderStyle = BorderStyle.None, Font = Pt(new[] { "Consolas" }, 8.5f, FontStyle.Regular) };
        form.Controls.Add(logBox);
        try { SetWindowTheme(logBox.Handle, "DarkMode_Explorer", null); } catch { }
        toast = new Toast();
        form.Move += delegate { toast.Place(); };
        form.Activated += delegate {                          // (the pixel size, options or keys may have been changed in the game meanwhile)
            ReadSharp();
            AdoptNow();
        };

        KeyLabels();
        LoadOptions();
        ShowGame();
        if (K != 1f) { ScaleTree(form); foreach (Surface s in pages) s.Dirty(); side.Dirty(); }
        loading = false;
        int pg0;
        ShowPage(int.TryParse(Cfg("page"), out pg0) && pg0 >= 0 && pg0 < PAGES.Length ? pg0 : 0);
        Fit();
        // a new Uplink since the last look at What's new: said once
        if (Cfg("uplink_sha") != "" && Cfg("news_seen") != Cfg("uplink_sha") && File.Exists(NewsFile))
            form.Shown += delegate { toast.Say("Updated: see What's new, bottom left.", CGreen); };
    }

    // ---- Play: the game (every Terra Nova found on the PC, one picked), the one big button, where to start
    static void BuildPlay(Surface pg)
    {
        gameLine = new GameLine { Location = new Point(18, 14), Size = new Size(MW - 36 - 78, 30) };
        gameLine.Click += delegate { GamesMenu(gameLine); };
        pg.Controls.Add(gameLine);
        gameBtn = Ghost("Change", MW - 18 - 68, 14, 68);
        gameBtn.Click += delegate { GamesMenu(gameLine); };
        pg.Controls.Add(gameBtn);
        playBtn = new Big { Text = "PLAY", Fill = COrange, Ink = Color.FromArgb(30, 14, 0), Arrow = true, F = F22b, Location = new Point(18, MH - 16 - 62), Size = new Size(187, 62) };
        playBtn.Click += delegate { if (busy) StopNow(); else Start(Mode.Play); };
        pg.Controls.Add(playBtn);
        missionBox = new Drop { Caption = "START AT", Location = new Point(18 + 187 + 14, MH - 16 - 51), Size = new Size(230, 51), Rows = 14 };
        missionBox.Changed += delegate { SaveOptions(); };
        pg.Controls.Add(missionBox);
        FillMissions();
        Btn saves = Ghost("Saves", MW - 18 - 60, MH - 16 - 30, 60);
        saves.Click += delegate { Saves(); };
        pg.Controls.Add(saves);
        pg.Look = delegate(Graphics g) { Hero(g, heroes[0]); if (!playBtn.Stop) Glow(g, Rectangle.Round(Logical(playBtn)), COrange); };
    }

    // ---- Co-op: host or join, the guest's gamepad; the session's line while one runs. (The 1v1 mode of Terra Nova
    // Coop is being redone: its place is kept, taped off, and nothing here starts it.)
    static void BuildCoop(Surface pg)
    {
        pg.Controls.Add(new Txt { Text = "Two players, one squad. Steam friends only.", Location = new Point(18, 14), Size = new Size(MW - 36, 20) });
        sessionRow = GhostBox(18, 44, MW - 36, 30, Color.FromArgb(48, 255, 255, 255), null);
        sessionRow.Visible = false;
        pg.Controls.Add(sessionRow);
        sessionLed = new Led { Location = new Point(12, 10), Size = new Size(10, 10), On = CDim };
        sessionRow.Controls.Add(sessionLed);
        sessionLabel = new Txt { Text = "No session.", Location = new Point(30, 0), Size = new Size(MW - 36 - 40, 30) };
        sessionRow.Controls.Add(sessionLabel);
        int ty = MH - 16 - 77, ry = ty - 12 - 30, tw = (MW - 36 - 12) / 2;
        Surface mode = GhostBox(18, ry, 122, 30, Color.FromArgb(48, 255, 255, 255), delegate(Graphics g) {
            Str(g, "Mode", F12, CSoft, 14, 7); Str(g, "Campaign", F12s, Color.White, 14 + StrW(g, "Mode", F12) + 8, 7); });
        pg.Controls.Add(mode);
        Rectangle slot = new Rectangle(18 + 122 + 12, ry, 128, 30);
        Surface pad = GhostBox(slot.Right + 12, ry, 188, 30, Color.FromArgb(48, 255, 255, 255), null);
        pg.Controls.Add(pad);
        // the gamepad (TN_NO_PAD: Uplink reads none; solo, host and guest; also on the Controls page): off unless asked
        // for, a trigger that does not come back to zero keeps firing
        padBox = new Switch { Text = "Gamepad", F = F12, Location = new Point(14, 1), Size = new Size(188 - 26, 28) };
        padBox.CheckedChanged += delegate { SaveOptions(); };
        pad.Controls.Add(padBox);
        hostBtn = new CoopTile { Text = "HOST A GAME", Desc = "Your campaign, your saves. Invite a friend.", Accent = COrange, Location = new Point(18, ty), Size = new Size(tw, 77) };
        hostBtn.Click += delegate { if (busy) StopNow(); else Start(Mode.Host); };
        pg.Controls.Add(hostBtn);
        joinBtn = new CoopTile { Text = "JOIN A FRIEND", Desc = "Take a seat in their squad.", Accent = CBlue, Location = new Point(18 + tw + 12, ty), Size = new Size(tw, 77) };
        joinBtn.Click += delegate { if (busy) StopNow(); else Start(Mode.Join); };
        pg.Controls.Add(joinBtn);
        pg.Look = delegate(Graphics g) { Hero(g, heroes[1]); Tape(g, slot); };
    }

    // ---- Maps: the map viewer; its mission editor, a prototype (TN_EDITOR), off unless asked for
    static void BuildMaps(Surface pg)
    {
        pg.Controls.Add(new Txt { Text = "Every map of the game in 3D, without starting the game.", F = F12, Location = new Point(18, 14), Size = new Size(MW - 36, 20) });
        mapBtn = new Big { Text = "MAP VIEWER", Fill = CBlue, Ink = Color.FromArgb(2, 20, 46), F = F19b, Location = new Point(18, MH - 16 - 58), Size = new Size(239, 58) };
        mapBtn.Click += delegate { if (busy) StopNow(); else Start(Mode.Maps); };
        pg.Controls.Add(mapBtn);
        Surface ed = GhostBox(18 + 239 + 14, MH - 16 - 52, 304, 52, Color.FromArgb(144, CTape), delegate(Graphics g) {
            using (Brush y = new SolidBrush(CTape)) g.FillPolygon(y, new[] { new PointF(22, 17), new PointF(31, 34), new PointF(13, 34) });
            using (Brush d = new SolidBrush(CTapeInk)) { g.FillRectangle(d, 21, 23, 2, 5.5f); g.FillRectangle(d, 21, 30, 2, 2); }
            Str(g, "Mission editor", F125, CText, 44, 9);
            float x = 44 + StrW(g, "Mission editor", F125) + 8, w = Spaced(g, "EXPERIMENTAL", F95b, Color.Empty, 0, 0, 1.2f);
            using (GraphicsPath p = Round(new RectangleF(x, 10, w + 10, 14), 2))
            using (Brush y = new SolidBrush(CTape)) g.FillPath(y, p);
            Spaced(g, "EXPERIMENTAL", F95b, CTapeInk, x + 5, 11, 1.2f);
            Str(g, "F6 in the map viewer. Can break a mission.", F11, CSoft, 44, 28);
        });
        pg.Controls.Add(ed);
        editTick = new Switch { Text = "Mission editor", PillOnly = true, Location = new Point(304 - 12 - 34, 16), Size = new Size(34, 20) };
        editTick.CheckedChanged += delegate { SaveOptions(); };
        ed.Controls.Add(editTick);
        pg.Look = delegate(Graphics g) { Hero(g, heroes[2]); if (!mapBtn.Stop) Glow(g, Rectangle.Round(Logical(mapBtn)), CBlue); };
    }

    // ---- In game: what shows and how it plays in a mission, in four cards
    static void BuildInGame(Surface pg)
    {
        const int CW = 281, RH = 29, X = 13, IW = CW - 26;
        EventHandler save = delegate { SaveOptions(); };
        Surface c = Card(pg, "DISPLAY", COrange, null, 18, 16, CW, 220);
        int y = 32;
        // the old school look (TN_OLDSCHOOL) and its key; its pixel size, kept by Uplink itself (see ReadSharp)
        oldBox = Row(c, "Old school look", X, y, IW, COrange, save);
        oldKeyBtn = Key(c, X + IW - 38 - 62, y, 62); oldKeyBtn.Click += delegate { AskKey(false); };
        y += RH;
        c.Controls.Add(new Txt { Text = "Pixels", Ink = Color.FromArgb(185, 199, 193), Location = new Point(X + 8, y), Size = new Size(46, RH) });
        sharpSeg = new Seg { Items = new[] { "1×", "2×", "3×", "Max" }, Text = "Pixels", Location = new Point(X + IW - 137, y + 3), Size = new Size(137, 23) };
        sharpSeg.Changed += delegate { WriteSharp(); };
        c.Controls.Add(sharpSeg);
        sharpKeyBtn = Key(c, X + IW - 137 - 8 - 62, y, 62); sharpKeyBtn.Click += delegate { AskKey(true); };
        y += RH;
        // Uplink's own colours on the cockpit: orange energy bar, light blue armour indicator (off: the game's; TN_HUD_COLOURS)
        hudTick = Row(c, "Uplink HUD colours", X, y, IW, COrange, save); y += RH;
        c.Controls.Add(new Txt { Text = "Crosshair", Location = new Point(X, y), Size = new Size(120, RH) });      // (the look mode's)
        crossBox = new Drop { Text = "Crosshair", Items = new List<string> { "The game's", "A dot", "None" }, Location = new Point(X + IW - 104, y + 3), Size = new Size(104, 23) };
        crossBox.Changed += save;
        c.Controls.Add(crossBox); y += RH;
        c.Controls.Add(new Txt { Text = "Frame limit", Location = new Point(X, y), Size = new Size(120, RH) });
        capBox = new Drop { Text = "Frame limit", Location = new Point(X + IW - 104, y + 3), Size = new Size(104, 23) };
        capBox.Changed += delegate { PickCap(); };
        c.Controls.Add(capBox); y += RH;
        fpsBox = Row(c, "Frame counter", X, y, IW, COrange, save);

        c = Card(pg, "CONTROLS", COrange, null, 18 + CW + 12, 16, CW, 220);
        y = 32;
        // Shift with a move key: the game's Bound (a leap every four strides, its only fast pace), or a run without the
        // leap at the same pace (Uplink's bridge: TN_RUN)
        runTick = Row(c, "Run instead of Bound", X, y, IW, COrange, save); y += RH;
        invertBox = Row(c, "Invert mouse", X, y, IW, COrange, save); y += RH;
        // the Looking Glass logo and the opening film skipped at the game's start (the bridge presses Esc on them, once each)
        introBox = Row(c, "Skip the intro videos", X, y, IW, COrange, save); y += RH;
        // the photo mode's key (TN_KEY_PHOTO): the game paused, a free camera, pictures
        c.Controls.Add(new Txt { Text = "Photo mode", Location = new Point(X, y), Size = new Size(120, RH) });
        photoKeyBtn = Key(c, X + IW - 104, y, 104); photoKeyBtn.Click += delegate { AskPhotoKey(); };
        y += RH;
        c.Controls.Add(new Txt { Text = "Screenshot", Em = "to Pictures", Location = new Point(X, y), Size = new Size(140, RH) });
        shotKeyBtn = Key(c, X + IW - 104, y, 104); shotKeyBtn.Click += delegate { AskShotKey(); };

        // squad orders on one button, held: Uplink's order wheel (off unless asked; TN_ORDER_WHEEL, TN_ORDER_KEY); what
        // a squadmate says, written under the crosshair while he speaks (off unless asked; TN_SUBTITLES)
        c = Card(pg, "SQUAD", CBlue, null, 18, 268, MW - 36, 74);
        wheelTick = Row(c, "Order wheel", X, 32, 296, CBlue, save);
        wheelKeyBtn = Key(c, X + 296 - 38 - 92, 32, 92); wheelKeyBtn.Click += delegate { AskOrderKey(); };
        Btn custom = Key(c, X + 296 - 38 - 92 - 8 - 74, 32, 74);
        custom.Text = "Customise"; custom.Line = CBlue; custom.Ink = Color.FromArgb(156, 196, 255);
        custom.Click += delegate { ShowPage(P_WHEEL); };
        subsTick = Row(c, "Squadmates' subtitles", X + 296 + 16, 32, MW - 36 - 26 - 296 - 16, CBlue, save);

        c = Card(pg, "EXTRAS", COrange, "Uplink's own, not in the game", 18, 376, MW - 36, 104);
        for (int i = 0; i < FX.Length; i++)
            fxTicks[i] = Row(c, FX_NAMES[i], X + 142 * (i % 4), 32 + RH * (i / 4), 134, COrange, save);
    }

    // ---- Settings: the window, the mouse, the game's keys, the tools; what is installed; the folder; updates; links
    static void BuildSettings(Surface pg)
    {
        const int CW = 281, RH = 29, X = 13, IW = CW - 26;
        Surface c = Card(pg, "WINDOW", COrange, null, 18, 16, CW, 108);
        c.Controls.Add(new Txt { Text = "Mode", Location = new Point(X, 32), Size = new Size(100, RH) });
        sizeBox = new Drop { Text = "Mode", Items = new List<string> { "1280 x 720", "1696 x 960", "1920 x 1080", "Fullscreen" }, Location = new Point(X + IW - 130, 35), Size = new Size(130, 23) };
        sizeBox.Changed += delegate { SaveOptions(); };
        c.Controls.Add(sizeBox);
        sensLabel = new Txt { Text = "Mouse speed", Location = new Point(X, 61), Size = new Size(118, RH) };
        c.Controls.Add(sensLabel);
        sensBar = new Slide { Text = "Mouse speed", Minimum = 2, Maximum = 30, Value = 10, Location = new Point(X + IW - 130 - 6, 61 + 4), Size = new Size(142, 21) };
        sensBar.Changed += delegate { SensLabel(); SaveOptions(); };
        c.Controls.Add(sensBar);

        c = Card(pg, "KEYS AND TOOLS", COrange, null, 18 + CW + 12, 16, CW, 108);
        c.Controls.Add(new Txt { Text = "Every key, saves folder, repair.", F = F115, Ink = CDim, Location = new Point(X, 32), Size = new Size(IW, RH) });
        keysBtn = Key(c, X, 64, 123, 28, "Controls");
        keysBtn.Click += delegate { ShowPage(P_CONTROLS); };
        toolsBtn = Key(c, X + 123 + 9, 64, 123, 28, "Tools");
        toolsBtn.Click += delegate { ToolsMenu().Show(toolsBtn, new Point(0, toolsBtn.Height + 2)); };

        // what is installed: green lights
        c = Card(pg, "INSTALLED", CBlue, null, 18, 136, MW - 36, 98);
        string[] names = { "Uplink", "Godot " + GODOT_VER, "Terra Nova Plus", "TN+ co-op build", "Python", "Steam (co-op only)" };
        int[] cell = { 0, 1, 2, 4, 3, 5 };
        leds = new LedLine[names.Length];
        for (int i = 0; i < names.Length; i++)
        {
            leds[i] = new LedLine { Text = names[i], Tag = names[i], Location = new Point(X + 190 * (cell[i] % 3), 32 + 27 * (cell[i] / 3)), Size = new Size(176, 27) };
            c.Controls.Add(leds[i]);
        }

        c = Card(pg, "GAME FOLDER", COrange, null, 18, 246, MW - 36, 73);
        gameLine2 = new GameLine { Location = new Point(X, 32), Size = new Size(MW - 36 - 26 - 78, RH) };
        gameLine2.Click += delegate { GamesMenu(gameLine2); };
        c.Controls.Add(gameLine2);
        gameBtn2 = Key(c, MW - 36 - 13 - 70, 32, 70, 23, "Change");
        gameBtn2.Click += delegate { GamesMenu(gameLine2); };

        c = Card(pg, "UPDATES", COrange, null, 18, 331, CW, 153);
        verLabel = new LedLine { Text = "Uplink " + VERSION, Location = new Point(X, 32), Size = new Size(IW, 27) };
        c.Controls.Add(verLabel);
        c.Controls.Add(new Txt { Text = "Looked for at each start and each game.", F = F115, Ink = CDim, Location = new Point(X, 61), Size = new Size(IW, RH) });
        checkBtn = Key(c, X, 112, 123, 28, "Check now");
        checkBtn.Click += delegate { Background(delegate { Install(Mode.Play); Status("Up to date.", CGreen); CheckUpdates(); }); };
        Key(c, X + 123 + 9, 112, 123, 28, "What's new").Click += delegate { WhatsNew(); };

        c = Card(pg, "COMMUNITY", CBlue, null, 18 + CW + 12, 331, CW, 153);
        c.Controls.Add(new Txt { Text = "Questions, co-op partners, bug reports.", F = F115, Ink = CDim, Location = new Point(X, 32), Size = new Size(IW, RH) });
        Key(c, X, 112, 79, 28, "Discord").Click += delegate { Open(DISCORD); };
        Key(c, X + 88, 112, 79, 28, "GitHub").Click += delegate { Open("https://github.com/" + UPLINK_REPO); };
        Key(c, X + 176, 112, 79, 28, "Report a bug").Click += delegate { Report(); };
    }

    static void Open(string url) { try { Process.Start(url); } catch { } }

    static void SensLabel()
    {
        sensLabel.Em = "× " + (sensBar.Value / 10.0).ToString("0.0", CultureInfo.InvariantCulture);
        sensLabel.Invalidate();
    }

    // ---- the order wheel's page (In game, Customise): which order on which pane, the short press, its time, the
    // middle where nothing is picked. Kept in the ini (wheel_panes, tap_ground, tap_enemy, tap_ms, wheel_dead) and
    // given to Uplink when it starts (TN_ORDER_PANES, TN_ORDER_TAP_GROUND, TN_ORDER_TAP_ENEMY, TN_ORDER_TAP_MS,
    // TN_ORDER_DEAD); as the wheel comes: the six orders around, attack on an enemy, move on the ground, 0.20 s, 48
    static readonly int[] PANES0 = { 0, 1, 2, 3, 4, 5 };
    const int TAP_MS0 = 200, DEAD0 = 48;

    static int[] Panes()
    {
        string[] p = Cfg("wheel_panes").Split(',');
        int[] o = new int[6];
        if (p.Length != 6) return (int[])PANES0.Clone();
        for (int i = 0; i < 6; i++)
            if (!int.TryParse(p[i].Trim(), out o[i]) || o[i] < -1 || o[i] >= ORDERS.Length) return (int[])PANES0.Clone();
        return o;
    }

    static int Num(string key, int def, int lo, int hi)
    {
        int v;
        return int.TryParse(Cfg(key).Trim(), out v) ? Math.Max(lo, Math.Min(hi, v)) : def;
    }

    static void BuildWheel(Surface pg)
    {
        Link back = new Link { Text = "‹ In game", Ink = CDim, F = F12, Location = new Point(18, 16), Size = new Size(64, 20) };
        back.Click += delegate { ShowPage(3); };
        pg.Controls.Add(back);
        pg.Controls.Add(new Txt { Text = "Order wheel", F = F14s, Location = new Point(86, 15), Size = new Size(140, 22) });
        wheel = new WheelPad { Text = "Order wheel", Location = new Point(26, 44), Size = new Size(300, 300), Panes = Panes() };
        wheel.Picked += delegate { WheelUi(); };
        wheel.Changed += delegate { SaveWheel(); };
        pg.Controls.Add(wheel);
        pg.Controls.Add(new Txt { Text = "Click a pane, then choose its order.", F = F11, Ink = CDim, Mid = true, Location = new Point(18, 350), Size = new Size(316, 16) });
        pg.Controls.Add(new Txt { Text = "Drag one pane onto another to swap them.", F = F11, Ink = CDim, Mid = true, Location = new Point(18, 366), Size = new Size(316, 16) });
        Btn reset = new Btn { Text = "Back to the default wheel", F = F115, Fill = Color.Transparent, Line = CButtonLine, Ink = CDim, Radius = 5, Location = new Point(18 + 79, 394), Size = new Size(158, 28) };
        reset.Click += delegate {
            wheel.Panes = (int[])PANES0.Clone();
            Set("tap_ground", "1"); Set("tap_enemy", "0"); Set("tap_ms", TAP_MS0.ToString()); Set("wheel_dead", DEAD0.ToString());
            SaveWheel(); wheel.Invalidate();
        };
        pg.Controls.Add(reset);
        const int X = 13, CX = 348, CW = MW - 18 - 348, IW = CW - 26;
        Surface c = Card(pg, "THIS PANE", CBlue, null, CX, 16, CW, 252);
        wheelPicks = new Radio[ORDERS.Length + 1];
        for (int i = 0; i < wheelPicks.Length; i++)
        {
            int k = i < ORDERS.Length ? i : -1;
            wheelPicks[i] = new Radio { Text = k < 0 ? "Nothing" : ORDERS[i], Location = new Point(X, 32 + 26 * i), Size = new Size(IW, 26) };
            wheelPicks[i].Click += delegate { SetPane(k); };
            c.Controls.Add(wheelPicks[i]);
        }
        c = Card(pg, "QUICK TAP", CBlue, null, CX, 280, CW, 204);
        List<string> orders = new List<string>(ORDERS);
        orders.Add("Nothing");
        c.Controls.Add(new Txt { Text = "On the ground", Location = new Point(X, 32), Size = new Size(100, 29) });
        tapGround = new Drop { Text = "On the ground", Items = orders, Location = new Point(X + IW - 118, 35), Size = new Size(118, 23) };
        tapGround.Changed += delegate { if (loading) return; Set("tap_ground", (tapGround.Selected < ORDERS.Length ? tapGround.Selected : -1).ToString()); SaveWheel(); };
        c.Controls.Add(tapGround);
        c.Controls.Add(new Txt { Text = "On an enemy", Location = new Point(X, 61), Size = new Size(100, 29) });
        tapEnemy = new Drop { Text = "On an enemy", Items = orders, Location = new Point(X + IW - 118, 64), Size = new Size(118, 23) };
        tapEnemy.Changed += delegate { if (loading) return; Set("tap_enemy", (tapEnemy.Selected < ORDERS.Length ? tapEnemy.Selected : -1).ToString()); SaveWheel(); };
        c.Controls.Add(tapEnemy);
        tapLabel = new Txt { Text = "Tap time", Location = new Point(X, 90), Size = new Size(110, 29) };
        c.Controls.Add(tapLabel);
        tapBar = new Slide { Text = "Tap time", Minimum = 10, Maximum = 35, Value = 20, Accent = CBlue, Location = new Point(X + IW - 104 - 6, 94), Size = new Size(116, 21) };
        tapBar.Changed += delegate { if (loading) return; Set("tap_ms", (tapBar.Value * 10).ToString()); SaveWheel(); };
        c.Controls.Add(tapBar);
        c.Controls.Add(new Txt { Text = "Dead zone", Location = new Point(X, 119), Size = new Size(110, 29) });
        deadBar = new Slide { Text = "Dead zone", Minimum = 6, Maximum = 26, Value = 12, Accent = CBlue, Location = new Point(X + IW - 104 - 6, 123), Size = new Size(116, 21) };
        deadBar.Changed += delegate { if (loading) return; Set("wheel_dead", (deadBar.Value * 4).ToString()); SaveWheel(); };
        c.Controls.Add(deadBar);
        c.Controls.Add(new Txt { Text = "A short press: that order at once.", F = F11, Ink = CDim, Location = new Point(X, 152), Size = new Size(IW, 18) });
        c.Controls.Add(new Txt { Text = "Held longer: the wheel opens.", F = F11, Ink = CDim, Location = new Point(X, 168), Size = new Size(IW, 18) });
    }

    // an order for the pane picked; the pane that had it takes this one's (an order is on one pane at most)
    static void SetPane(int order)
    {
        int[] p = wheel.Panes;
        int was = p[wheel.Sel], other = order >= 0 ? Array.IndexOf(p, order) : -1;
        if (was == order) return;
        if (other >= 0) p[other] = was;
        p[wheel.Sel] = order;
        SaveWheel();
        wheel.Invalidate();
    }

    static void SaveWheel()
    {
        if (loading) return;
        string[] s = new string[6];
        for (int i = 0; i < 6; i++) s[i] = wheel.Panes[i].ToString();
        Set("wheel_panes", string.Join(",", s));
        SaveCfg();
        WheelUi();
    }

    static void WheelUi()
    {
        bool was = loading;
        loading = true;
        int[] p = wheel.Panes;
        for (int i = 0; i < wheelPicks.Length; i++)
        {
            int k = i < ORDERS.Length ? i : -1;
            wheelPicks[i].On = p[wheel.Sel] == k;
            wheelPicks[i].Em = wheelPicks[i].On ? "here" : k >= 0 && Array.IndexOf(p, k) < 0 ? "unused" : null;
            wheelPicks[i].Invalidate();
        }
        int tg = Num("tap_ground", 1, -1, ORDERS.Length - 1), te = Num("tap_enemy", 0, -1, ORDERS.Length - 1);
        tapGround.Selected = tg < 0 ? ORDERS.Length : tg;
        tapEnemy.Selected = te < 0 ? ORDERS.Length : te;
        tapBar.Value = Num("tap_ms", TAP_MS0, 100, 350) / 10;
        deadBar.Value = Num("wheel_dead", DEAD0, 24, 104) / 4;
        tapLabel.Em = (tapBar.Value / 100.0).ToString("0.00", CultureInfo.InvariantCulture) + " s";
        tapLabel.Invalidate();
        loading = was;
    }

    // ---- the old school look's pixel size. Uplink keeps it itself (viewer.cfg in its own folder: [look] old_sharp =
    // 1, 2, 3 times the game's pixels, 0 the window's own) and changes it in game with its key (Shift+F12). That file
    // is the one place it is written: the launcher shows what it holds (read again each time the window comes to
    // the front) and writes the choice made here straight into it; Uplink reads it when it starts.
    static readonly int[] SHARP = { 1, 2, 3, 0 };
    static string ViewerCfg { get { return Path.Combine(GodotData, "viewer.cfg"); } }

    static void ReadSharp()
    {
        int k = 1;
        try
        {
            bool look = false;
            if (File.Exists(ViewerCfg))
                foreach (string raw in File.ReadAllLines(ViewerCfg))
                {
                    string l = raw.Trim();
                    Match m = Regex.Match(l, @"^old_sharp\s*=\s*(-?\d+)\s*$");
                    if (l.StartsWith("[")) look = l == "[look]";
                    else if (look && m.Success) k = int.Parse(m.Groups[1].Value);
                }
        }
        catch { }
        bool was = loading;
        loading = true;
        sharpSeg.Selected = Math.Max(0, Array.IndexOf(SHARP, k));
        loading = was;
    }

    static void WriteSharp()
    {
        if (loading) return;
        try
        {
            string line = "old_sharp=" + SHARP[sharpSeg.Selected];
            List<string> ls = File.Exists(ViewerCfg) ? new List<string>(File.ReadAllLines(ViewerCfg)) : new List<string>();
            int head = ls.FindIndex(l => l.Trim() == "[look]"), at = -1;
            for (int i = head + 1; head >= 0 && i < ls.Count && !ls[i].TrimStart().StartsWith("["); i++)
                if (Regex.IsMatch(ls[i], @"^\s*old_sharp\s*=")) at = i;
            if (at >= 0) ls[at] = line;
            else if (head >= 0) ls.Insert(head + 1, line);
            else { if (ls.Count > 0 && ls[ls.Count - 1].Trim() != "") ls.Add(""); ls.Add("[look]"); ls.Add(""); ls.Add(line); }
            Directory.CreateDirectory(GodotData);
            File.WriteAllLines(ViewerCfg, ls);
            Status("Old school pixels: " + sharpSeg.Items[sharpSeg.Selected] + " (from the next time Uplink starts).", CGreen);
        }
        catch (Exception e) { Status("The pixel size could not be saved: " + e.Message, CRed); }
    }

    // ---- the frame limit: none, a usual one, or one's own number
    static void FillCap()
    {
        List<string> l = new List<string> { "Unlimited", "60", "120", "144", "240" };
        if (capValue > 0 && !l.Contains(capValue.ToString())) l.Add(capValue.ToString());
        l.Add("Other...");
        bool was = loading;
        loading = true;
        capBox.Items = l;
        capBox.Selected = capValue > 0 ? l.IndexOf(capValue.ToString()) : 0;
        loading = was;
    }

    static void PickCap()
    {
        if (loading) return;
        string s = capBox.Items[capBox.Selected];
        int v = 0;
        if (s == "Other...")
        {
            using (NumAsk d = new NumAsk("Frame limit", "Pictures a second, 20 to 1000:", capValue > 0 ? capValue.ToString() : "90"))
                v = d.ShowDialog(form) == DialogResult.OK && int.TryParse(d.Value.Trim(), out v) && v > 0 ? Math.Max(20, Math.Min(1000, v)) : capValue;
        }
        else int.TryParse(s, out v);
        capValue = v;
        FillCap();
        SaveOptions();
    }

    // a number asked for, in the launcher's colours
    class NumAsk : Form
    {
        TextBox box;
        public string Value { get { return box.Text; } }
        public NumAsk(string title, string what, string now)
        {
            Text = title; ClientSize = new Size(320, 124); FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent; BackColor = CBack; ForeColor = CText; Font = form.Font; ShowInTaskbar = false;
            Controls.Add(new Label { Text = what, Location = new Point(16, 16), Size = new Size(288, 20) });
            box = new TextBox { Text = now, Location = new Point(16, 42), Size = new Size(120, 24), BackColor = CButton, ForeColor = CText, BorderStyle = BorderStyle.FixedSingle, MaxLength = 4 };
            Controls.Add(box);
            Tile ok = new Tile("OK", null, CButton, CButtonLine, CText) { Location = new Point(96, 80), Size = new Size(100, 30), Small = true };
            ok.Click += delegate { DialogResult = DialogResult.OK; };
            Controls.Add(ok);
            Tile no = new Tile("Cancel", null, CButton, CButtonLine, CText) { Location = new Point(204, 80), Size = new Size(100, 30), Small = true };
            no.Click += delegate { DialogResult = DialogResult.Cancel; };
            Controls.Add(no);
            Shown += delegate { box.SelectAll(); box.Focus(); };
        }
        protected override void OnLoad(EventArgs e) { Dpi(this); base.OnLoad(e); }
        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Enter) { DialogResult = DialogResult.OK; return true; }
            if (keyData == Keys.Escape) { DialogResult = DialogResult.Cancel; return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }
    }

    // ---- the pictures behind Play, Co-op and Maps: one JPEG each, screenshots of Uplink itself. Taken from Uplink's
    // own files when they are there (components\uplink\launcher\bg_*.jpg: a new picture comes with an Uplink update,
    // no new launcher needed), else from the copy built into this exe (build.bat), else none: the page stays dark.
    static readonly string[] HEROES = { "bg_play.jpg", "bg_coop.jpg", "bg_maps.jpg" };
    static Image[] heroes = new Image[3];

    static void LoadHeroes()
    {
        for (int i = 0; i < HEROES.Length; i++)
        {
            if (heroes[i] != null) continue;
            try
            {
                string f = Path.Combine(UplinkDir, "launcher", HEROES[i]);
                if (File.Exists(f)) heroes[i] = Image.FromStream(new MemoryStream(File.ReadAllBytes(f)));
            }
            catch { }
            try
            {
                Stream s = heroes[i] == null ? typeof(Uplink).Assembly.GetManifestResourceStream(HEROES[i]) : null;
                if (s != null) heroes[i] = Image.FromStream(s);
            }
            catch { }
            if (heroes[i] != null) pages[i].Dirty();
        }
    }

    // the picture over the whole page (cut, not squeezed), under the dark veil that lets the page's lines be read
    static void Hero(Graphics g, Image img)
    {
        g.Clear(CBack);
        if (img != null)
        {
            float k = Math.Max(MW / (float)img.Width, MH / (float)img.Height), w = img.Width * k, h = img.Height * k;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            using (System.Drawing.Imaging.ImageAttributes ia = new System.Drawing.Imaging.ImageAttributes())
            {
                ia.SetWrapMode(WrapMode.TileFlipXY);          // (no pale line where the picture ends)
                g.DrawImage(img, Rectangle.Round(new RectangleF((MW - w) / 2, 0, w, h)), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, ia);
            }
        }
        using (LinearGradientBrush b = new LinearGradientBrush(new Rectangle(0, -1, MW, MH + 2), Color.Black, Color.Black, 90f))
        {
            b.InterpolationColors = new ColorBlend { Positions = new[] { 0f, 0.24f, 0.55f, 0.92f, 1f }, Colors = new[] {
                Color.FromArgb(224, 8, 17, 15), Color.FromArgb(32, 8, 17, 15), Color.FromArgb(48, 8, 17, 15), Color.FromArgb(245, 8, 17, 15), Color.FromArgb(245, 8, 17, 15) } };
            g.FillRectangle(b, 0, 0, MW, MH);
        }
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
    }

    // the light a big button throws under itself
    static void Glow(Graphics g, Rectangle r, Color c)
    {
        r.Offset(0, 6);
        for (int i = 11; i >= 1; i--)
        {
            Rectangle q = r;
            q.Inflate(i * 2, i * 2);
            using (GraphicsPath p = Round(q, 6 + i * 2))
            using (Brush b = new SolidBrush(Color.FromArgb(7, c))) g.FillPath(b, p);
        }
    }

    // the 1v1 mode's place on the Co-op page: a dashed slot, a construction tape across it
    static void Tape(Graphics g, Rectangle slot)
    {
        using (GraphicsPath p = Round(slot, 5))
        using (Brush b = new SolidBrush(Color.FromArgb(176, 8, 17, 15)))
        using (Pen l = new Pen(Color.FromArgb(48, 255, 255, 255)) { DashStyle = DashStyle.Dash })
        { g.FillPath(b, p); g.DrawPath(l, p); }
        GraphicsState st = g.Save();
        g.TranslateTransform(slot.X + slot.Width / 2f, slot.Y + slot.Height / 2f);
        g.RotateTransform(-7f);
        RectangleF t = new RectangleF(-slot.Width / 2f - 7, -7.5f, slot.Width + 14, 15);
        for (int i = 3; i >= 1; i--)
            using (Brush sh = new SolidBrush(Color.FromArgb(40, 0, 0, 0))) g.FillRectangle(sh, t.X - i, t.Y + 2 - i, t.Width + 2 * i, t.Height + 2 * i);
        g.SetClip(t);
        using (Brush y = new SolidBrush(CTape)) g.FillRectangle(y, t);
        using (Brush d = new SolidBrush(CTapeInk))
            for (float x = t.Left - 30; x < t.Right + 30; x += 25.46f)
                g.FillPolygon(d, new[] { new PointF(x, t.Top), new PointF(x + 12.73f, t.Top), new PointF(x + 12.73f + 15, t.Bottom), new PointF(x + 15, t.Bottom) });
        using (Brush y = new SolidBrush(CTape)) g.FillRectangle(y, -46, t.Top + 1, 92, t.Height - 2);
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
        using (Font tf = new Font(F95b.FontFamily, 10f, FontStyle.Bold, GraphicsUnit.Pixel))   // (GDI+ under the scale: pixels as at 100 %)
        {
            float w = SpacedPlus(g, "VERSUS · WIP", tf, Color.Empty, 0, 0, 1.0f);
            SpacedPlus(g, "VERSUS · WIP", tf, CTapeInk, -w / 2, -6f, 1.0f);
        }
        g.Restore(st);
    }

    // ---- small builders
    static Surface Card(Control on, string title, Color accent, string hint, int x, int y, int w, int h)
    {
        Surface c = new Surface { Location = new Point(x, y), Size = new Size(w, h) };
        c.Look = delegate(Graphics g) {
            using (GraphicsPath p = Round(new Rectangle(0, 0, w - 1, h - 1), 7))
            using (Brush b = new SolidBrush(CPanel))
            using (Pen l = new Pen(CLine))
            { g.FillPath(b, p); g.DrawPath(l, p); }
            float tw = Spaced(g, title, F10b, accent, 13, 11, 1.2f);
            if (hint != null) Str(g, hint, F11, CDim, 13 + tw + 10, 10);
        };
        on.Controls.Add(c);
        return c;
    }

    static Surface GhostBox(int x, int y, int w, int h, Color line, Action<Graphics> more)
    {
        Surface c = new Surface { Location = new Point(x, y), Size = new Size(w, h) };
        c.Look = delegate(Graphics g) {
            using (GraphicsPath p = Round(new Rectangle(0, 0, w - 1, h - 1), 5))
            using (Brush b = new SolidBrush(Color.FromArgb(144, 8, 17, 15)))
            using (Pen l = new Pen(line))
            { g.FillPath(b, p); g.DrawPath(l, p); }
            if (more != null) more(g);
        };
        return c;
    }

    static Switch Row(Control on, string text, int x, int y, int w, Color accent, EventHandler changed)
    {
        Switch s = new Switch { Text = text, Accent = accent, Location = new Point(x, y), Size = new Size(w, 29) };
        s.CheckedChanged += changed;
        on.Controls.Add(s);
        return s;
    }

    static Btn Key(Control on, int x, int y, int w) { return Key(on, x, y + 3, w, 23, ""); }

    static Btn Key(Control on, int x, int y, int w, int h, string text)
    {
        Btn b = new Btn { Text = text, F = h > 24 ? F12 : F11, Fill = CButton, Line = CButtonLine, Ink = CText, Radius = 4, Location = new Point(x, y), Size = new Size(w, h) };
        on.Controls.Add(b);
        b.BringToFront();                                     // (over the switch whose line it sits on)
        return b;
    }

    static Btn Ghost(string text, int x, int y, int w)
    {
        return new Btn { Text = text, F = F12, Fill = Color.FromArgb(144, 8, 17, 15), Line = Color.FromArgb(48, 255, 255, 255), Ink = CText, Radius = 5,
            Location = new Point(x, y), Size = new Size(w, 30) };
    }

    // ---- drawing: text, sizes in pixels, as Windows draws it (GDI; the surfaces have no alpha, so it can lie on a picture)
    const TextFormatFlags TF = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine;
    const TextFormatFlags TFLeft = TF | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis, TFMid = TFLeft | TextFormatFlags.HorizontalCenter,
        TFRight = TFLeft | TextFormatFlags.Right, TFPath = TF | TextFormatFlags.VerticalCenter | TextFormatFlags.PathEllipsis,
        TFWrap = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak;

    // (places and sizes are given as at 100 %; the fonts are already at the screen's scale)
    static void Str(Graphics g, string s, Font f, Color c, float x, float y) { TextRenderer.DrawText(g, s, f, new Point(S(x), S(y)), c, TF); }
    static float StrW(Graphics g, string s, Font f) { return TextRenderer.MeasureText(g, s, f, new Size(8000, 200), TF).Width / K; }
    static void StrIn(Graphics g, string s, Font f, Color c, RectangleF r, TextFormatFlags tf)
    {
        TextRenderer.DrawText(g, s, f, Rectangle.FromLTRB(S(r.Left), S(r.Top), S(r.Right), S(r.Bottom)), c, tf);
    }

    // letters set apart (the titles), each on a whole pixel, the same gap between all; its width, and nothing drawn
    // when the colour is Color.Empty
    static float Spaced(Graphics g, string s, Font f, Color c, float x, float y, float gap)
    {
        int px = S(x), x0 = px, py = S(y), gi = Math.Max(1, S(gap));
        foreach (char ch in s)
        {
            string t = ch.ToString();
            if (c != Color.Empty && ch != ' ') TextRenderer.DrawText(g, t, f, new Point(px, py), c, TF);
            px += TextRenderer.MeasureText(g, t, f, new Size(800, 200), TF).Width + gi;
        }
        return (px - x0 - gi) / K;
    }

    // the same through GDI+, for text that is turned (the tape)
    static float SpacedPlus(Graphics g, string s, Font f, Color c, float x, float y, float gap)
    {
        float x0 = x;
        using (Brush b = new SolidBrush(c))
            foreach (char ch in s)
            {
                string t = ch.ToString();
                if (c != Color.Empty) g.DrawString(t, f, b, x, y, SF);
                x += g.MeasureString(t, f, 4000, SF).Width + gap;
            }
        return x - x0 - gap;
    }

    static GraphicsPath Round(RectangleF r, float rad)
    {
        GraphicsPath p = new GraphicsPath();
        float d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    static GraphicsPath Round(Rectangle r, int rad) { return Round(new RectangleF(r.X, r.Y, r.Width, r.Height), rad); }

    static Color Mix(Color a, Color b, float k)
    {
        return Color.FromArgb((int)(a.A + (b.A - a.A) * k), (int)(a.R + (b.R - a.R) * k), (int)(a.G + (b.G - a.G) * k), (int)(a.B + (b.B - a.B) * k));
    }

    // what lies under a control: the nearest surface above it (a page's picture, a card), at the control's place
    static void PaintBack(Control c, Graphics g)
    {
        int x = c.Left, y = c.Top;
        for (Control p = c.Parent; p != null; x += p.Left, y += p.Top, p = p.Parent)
        {
            Surface s = p as Surface;
            if (s == null) continue;
            g.DrawImageUnscaled(s.Bmp, -x, -y);
            return;
        }
        g.Clear(CBack);
    }

    // a panel drawn once into a picture of its own (Look), which the controls on it take as their background
    class Surface : Panel
    {
        public Action<Graphics> Look;
        Bitmap bmp;
        public Surface() { BackColor = CBack; DoubleBuffered = true; ResizeRedraw = true; }
        public Bitmap Bmp
        {
            get
            {
                if (bmp != null && bmp.Size == ClientSize) return bmp;
                if (bmp != null) bmp.Dispose();
                bmp = new Bitmap(Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height), System.Drawing.Imaging.PixelFormat.Format32bppRgb);
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    PaintBack(this, g);
                    g.ScaleTransform(K, K);
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
                    if (Look != null) Look(g);
                }
                return bmp;
            }
        }
        public void Dirty()
        {
            if (bmp != null) bmp.Dispose();
            bmp = null;
            foreach (Control c in Controls) { Surface s = c as Surface; if (s != null) s.Dirty(); }
            Invalidate(true);
        }
        protected override void OnPaintBackground(PaintEventArgs e) { e.Graphics.DrawImageUnscaled(Bmp, 0, 0); }
    }

    // a control drawn here. One that acts takes the keyboard too: Tab reaches it, Space or Enter is its click
    class Drawn : Control
    {
        protected bool over;
        protected bool acts;
        public Font F = F125;
        public Drawn(bool acts)
        {
            this.acts = acts;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            SetStyle(ControlStyles.Selectable, acts);
            TabStop = acts;
            if (acts) Cursor = Cursors.Hand;
        }
        protected bool Cue { get { return Focused && ShowFocusCues; } }
        protected float W { get { return Width / K; } }        // (its size as at 100 %: what its drawing counts in)
        protected float H { get { return Height / K; } }
        protected Graphics Begin(PaintEventArgs e)
        {
            PaintBack(this, e.Graphics);
            e.Graphics.ScaleTransform(K, K);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            return e.Graphics;
        }
        protected override void OnMouseEnter(EventArgs e) { over = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { over = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (acts && CanFocus) Focus(); base.OnMouseDown(e); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (acts && !e.Handled && (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) && e.Modifiers == Keys.None) { e.Handled = true; OnClick(EventArgs.Empty); }
        }
        protected void Ring(Graphics g, RectangleF r, float rad)
        {
            if (!Cue) return;
            using (GraphicsPath p = Round(r, rad))
            using (Pen l = new Pen(Color.FromArgb(200, 255, 255, 255))) g.DrawPath(l, p);
        }
    }

    // a line of text (and a dimmer word after it)
    class Txt : Drawn
    {
        public Color Ink = CText;
        public string Em;
        public bool Mid;
        public Txt() : base(false) { }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            StrIn(g, Text, F, Ink, new RectangleF(0, 0, W, H), Mid ? TFMid : TFLeft);
            if (Em != null) StrIn(g, Em, F11, CDim, new RectangleF(StrW(g, Text, F) + 8, 1, W, H), TFLeft);
        }
    }

    // a word that is clicked
    class Link : Drawn
    {
        public Color Ink = CDim;
        public Link() : base(true) { F = F11; }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            Color c = over ? Mix(Ink, Color.White, 0.45f) : Ink;
            StrIn(g, Text, F, c, new RectangleF(2, 0, W, H), TFLeft);
            if (Cue) using (Pen p = new Pen(c)) g.DrawLine(p, 2, H - 2, 2 + StrW(g, Text, F), H - 2);
        }
    }

    // a page's entry in the side bar: an orange bar and a lit line for the one shown
    class Nav : Drawn
    {
        public bool On;
        public Nav() : base(true) { F = F13; }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            if (On || over || Cue)
                using (GraphicsPath p = Round(new RectangleF(0, 0, W - 1, H - 1), 5))
                using (Brush b = new SolidBrush(On ? Color.FromArgb(19, 38, 31) : Color.FromArgb(16, 31, 27))) g.FillPath(b, p);
            if (On)
                using (GraphicsPath p = Round(new RectangleF(12, (H - 14) / 2f, 4, 14), 2))
                using (Brush b = new SolidBrush(COrange)) g.FillPath(b, p);
            StrIn(g, Text, F, On ? Color.White : over || Cue ? CText : CDim, new RectangleF(25, 0, W - 25, H - 1), TFLeft);
        }
    }

    // a flat button: a key's name, a tool, a link on a picture
    class Btn : Drawn
    {
        public Color Fill, Line, Ink;
        public int Radius = 4;
        public Btn() : base(true) { F = F11; }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            RectangleF r = new RectangleF(0.5f, 0.5f, W - 1, H - 1);
            using (GraphicsPath p = Round(r, Radius))
            {
                using (Brush b = new SolidBrush(Fill)) g.FillPath(b, p);
                if (over && Enabled) using (Brush b = new SolidBrush(Color.FromArgb(22, 255, 255, 255))) g.FillPath(b, p);
                using (Pen l = new Pen(Cue ? Color.FromArgb(200, 255, 255, 255) : over && Enabled ? Mix(Line, Color.White, 0.3f) : Line)) g.DrawPath(l, p);
            }
            StrIn(g, Text, F, Enabled ? Ink : Mix(Ink, CBack, 0.55f), new RectangleF(3, 0, W - 6, H - 1), TFMid);
        }
    }

    // PLAY, MAP VIEWER; STOP while something of theirs runs
    class Big : Drawn
    {
        public Color Fill, Ink;
        public bool Arrow, Stop;
        public Big() : base(true) { }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            Color f = Stop ? Color.FromArgb(236, 14, 26, 24) : Fill, ink = Stop ? Color.White : Ink;
            if (over) f = Mix(f, Color.White, Stop ? 0.06f : 0.12f);
            using (GraphicsPath p = Round(new RectangleF(0.5f, 0.5f, W - 1, H - 1), 6))
            {
                using (Brush b = new SolidBrush(f)) g.FillPath(b, p);
                if (Stop) using (Pen l = new Pen(Fill, 1.5f)) g.DrawPath(l, p);
                else if (Cue) using (Pen l = new Pen(Color.White, 1.5f)) g.DrawPath(l, p);
            }
            string t = Stop ? "STOP" : Text;
            float tw = Spaced(g, t, F, Color.Empty, 0, 0, 1.6f), icon = Stop || Arrow ? 34 : 0, x = (W - tw - icon) / 2f - (Arrow && !Stop ? 4 : 0), cy = H / 2f;
            using (Brush b = new SolidBrush(Stop ? Fill : ink))
                if (Stop) g.FillRectangle(b, x + 2, cy - 7, 14, 14);
                else if (Arrow) g.FillPolygon(b, new[] { new PointF(x + 4, cy - 8), new PointF(x + 17, cy), new PointF(x + 4, cy + 8) });
            Spaced(g, t, F, ink, x + icon, cy - F.Height / K / 2f, 1.6f);
        }
    }

    // HOST A GAME, JOIN A FRIEND: a name, a line under it, the edge in the player's colour
    class CoopTile : Drawn
    {
        public Color Accent;
        public string Desc;
        public bool Stop;
        public CoopTile() : base(true) { }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            Color a = Enabled ? Accent : Mix(Accent, CBack, 0.6f);
            using (GraphicsPath p = Round(new RectangleF(0.5f, 0.5f, W - 1, H - 1), 7))
            {
                using (Brush b = new SolidBrush(over && Enabled ? Color.FromArgb(232, 18, 34, 31) : Color.FromArgb(216, 8, 17, 15))) g.FillPath(b, p);
                GraphicsState st = g.Save();
                g.SetClip(p);
                using (Brush b = new SolidBrush(a)) g.FillRectangle(b, 0, 0, 4, H);
                g.Restore(st);
                using (Pen l = new Pen(Cue ? Color.White : a)) g.DrawPath(l, p);
            }
            Spaced(g, Stop ? "STOP" : Text, F16b, Enabled ? Color.White : CDim, 19, 17, 1.2f);
            Str(g, Stop ? "Close this session." : Desc, F115, Enabled ? CSoft : Mix(CSoft, CBack, 0.5f), 19, 44);
        }
    }

    // a switch: its name on the left, the pill on the right (PillOnly: the pill alone)
    class Switch : Drawn
    {
        bool on;
        public Color Accent = COrange;
        public string Em;
        public bool PillOnly;
        public event EventHandler CheckedChanged;
        public Switch() : base(true) { }
        public bool Checked
        {
            get { return on; }
            set { if (on == value) return; on = value; Invalidate(); if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty); }
        }
        protected override void OnClick(EventArgs e) { Checked = !Checked; base.OnClick(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            if (!PillOnly)
            {
                StrIn(g, Text, F, CText, new RectangleF(0, 0, W - 36, H), TFLeft);
                if (Em != null) StrIn(g, Em, F11, CDim, new RectangleF(StrW(g, Text, F) + 8, 1, W, H), TFLeft);
            }
            RectangleF r = new RectangleF(W - 32, (H - 16) / 2f, 30, 16);
            using (GraphicsPath p = Round(r, 8))
            using (Brush b = new SolidBrush(on ? Accent : over ? Mix(COff, CKnob, 0.25f) : COff)) g.FillPath(b, p);
            using (Brush b = new SolidBrush(on ? Color.White : CKnob)) g.FillEllipse(b, r.X + (on ? 16 : 2), r.Y + 2, 12, 12);
            Ring(g, RectangleF.Inflate(r, 1.5f, 1.5f), 9.5f);
        }
    }

    // one of a few, side by side (the pixel size)
    class Seg : Drawn
    {
        public string[] Items = new string[0];
        int sel;
        public event EventHandler Changed;
        public Seg() : base(true) { F = F11; }
        public int Selected
        {
            get { return sel; }
            set { value = Math.Max(0, Math.Min(Items.Length - 1, value)); if (sel == value) return; sel = value; Invalidate(); if (Changed != null) Changed(this, EventArgs.Empty); }
        }
        protected override bool IsInputKey(Keys k) { return k == Keys.Left || k == Keys.Right || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Left) Selected = sel - 1;
            else if (e.KeyCode == Keys.Right) Selected = sel + 1;
        }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left) Selected = e.X * Items.Length / Math.Max(1, Width);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            RectangleF r = new RectangleF(0.5f, 0.5f, W - 1, H - 1);
            float w = r.Width / Items.Length;
            using (GraphicsPath p = Round(r, 4))
            {
                GraphicsState st = g.Save();
                g.SetClip(p);
                using (Brush b = new SolidBrush(CButton)) g.FillRectangle(b, r);
                using (Brush b = new SolidBrush(COrange)) g.FillRectangle(b, r.X + w * sel, r.Y, w, r.Height);
                using (Pen l = new Pen(CButtonLine))
                    for (int i = 1; i < Items.Length; i++) g.DrawLine(l, r.X + w * i, r.Y, r.X + w * i, r.Bottom);
                g.Restore(st);
                using (Pen l = new Pen(Cue ? Color.FromArgb(200, 255, 255, 255) : CButtonLine)) g.DrawPath(l, p);
            }
            for (int i = 0; i < Items.Length; i++)
                StrIn(g, Items[i], i == sel ? F10b : F, i == sel ? Color.FromArgb(30, 14, 0) : CDim, new RectangleF(r.X + w * i, 0, w, H - 1), TFMid);
        }
    }

    // a slider: a thin line, a round handle (the mouse, or the arrow keys)
    class Slide : Drawn
    {
        public int Minimum, Maximum = 10;
        public Color Accent = CBlue;
        int val;
        public event EventHandler Changed;
        public Slide() : base(true) { }
        public int Value
        {
            get { return val; }
            set { value = Math.Max(Minimum, Math.Min(Maximum, value)); if (val == value) return; val = value; Invalidate(); if (Changed != null) Changed(this, EventArgs.Empty); }
        }
        void At(int x) { Value = Minimum + (int)Math.Round((x / K - 6) * (Maximum - Minimum) / (double)Math.Max(1, W - 12)); }
        protected override bool IsInputKey(Keys k) { return k == Keys.Left || k == Keys.Right || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Left) Value = val - 1;
            else if (e.KeyCode == Keys.Right) Value = val + 1;
            else if (e.KeyCode == Keys.Home) Value = Minimum;
            else if (e.KeyCode == Keys.End) Value = Maximum;
        }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) At(e.X); }
        protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); if (e.Button == MouseButtons.Left) At(e.X); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            float cy = H / 2f, x = 6 + (W - 12) * (val - Minimum) / (float)Math.Max(1, Maximum - Minimum);
            using (GraphicsPath p = Round(new RectangleF(6, cy - 2, W - 12, 4), 2))
            using (Brush b = new SolidBrush(COff)) g.FillPath(b, p);
            if (x > 8)
                using (GraphicsPath p = Round(new RectangleF(6, cy - 2, x - 6, 4), 2))
                using (Brush b = new SolidBrush(Accent)) g.FillPath(b, p);
            using (Brush b = new SolidBrush(Color.White)) g.FillEllipse(b, x - 6, cy - 6, 12, 12);
            if (Cue) using (Pen l = new Pen(Accent, 1.5f)) g.DrawEllipse(l, x - 8, cy - 8, 16, 16);
        }
    }

    // a list that drops down (Caption: the big one of the Play page, its name over its value)
    class Drop : Drawn
    {
        public List<string> Items = new List<string>();
        public string Caption;
        public int Rows = 12;
        int sel;
        public event EventHandler Changed;
        public Drop() : base(true) { F = F115; }
        public int Selected
        {
            get { return sel; }
            set { value = Math.Max(0, Math.Min(Items.Count - 1, value)); if (sel == value) { Invalidate(); return; } sel = value; Invalidate(); if (Changed != null) Changed(this, EventArgs.Empty); }
        }
        protected override bool IsInputKey(Keys k) { return k == Keys.Up || k == Keys.Down || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Up && !e.Alt) Selected = sel - 1;
            else if (e.KeyCode == Keys.Down && !e.Alt) Selected = sel + 1;
            else if (e.KeyCode == Keys.F4 || e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter || e.KeyCode == Keys.Down) OnClick(EventArgs.Empty);
        }
        protected override void OnClick(EventArgs e)
        {
            base.OnClick(e);
            Popup(this, Math.Max(Width, 60), Items, sel, Caption != null ? 24 : 22, Rows, null, delegate(int i) { Selected = i; });
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            RectangleF r = new RectangleF(0.5f, 0.5f, W - 1, H - 1);
            string t = sel < Items.Count ? Items[sel] : "";
            using (GraphicsPath p = Round(r, Caption != null ? 6 : 4))
            {
                using (Brush b = new SolidBrush(Caption != null ? Color.FromArgb(200, 8, 17, 15) : CButton)) g.FillPath(b, p);
                if (over && Enabled) using (Brush b = new SolidBrush(Color.FromArgb(16, 255, 255, 255))) g.FillPath(b, p);
                using (Pen l = new Pen(Cue ? Color.FromArgb(200, 255, 255, 255) : Caption != null ? Color.FromArgb(40, 255, 255, 255) : CButtonLine)) g.DrawPath(l, p);
            }
            if (Caption != null)
            {
                Spaced(g, Caption, Px10, CDim, 12, 8, 1f);
                StrIn(g, t, F13, CText, new RectangleF(12, 22, W - 40, 22), TFLeft);
                Arrow(g, W - 19, 33);
            }
            else
            {
                StrIn(g, t, F, CText, new RectangleF(9, 0, W - 26, H - 1), TFLeft);
                Arrow(g, W - 14, H / 2f);
            }
        }
        static Font Px10 { get { return F10; } }
        static void Arrow(Graphics g, float x, float y)
        {
            using (Brush b = new SolidBrush(CDim)) g.FillPolygon(b, new[] { new PointF(x - 3.5f, y - 2), new PointF(x + 3.5f, y - 2), new PointF(x, y + 2.5f) });
        }
    }

    // the list of a Drop (and of Change, the game's folder): a dark box under its control; the mouse, or the arrows
    // and Enter; Esc or a click elsewhere closes it
    static void Popup(Control anchor, int width, IList<string> items, int selected, int rowH, int rows, DrawItemEventHandler paint, Action<int> picked)
    {
        rowH = S(rowH);
        if (paint == null)                                    // (as wide as its longest line)
            foreach (string s in items) width = Math.Max(width, TextRenderer.MeasureText(s, FBody).Width + S(16 + (items.Count > rows ? 18 : 0)));
        ListBox lb = new ListBox { DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = rowH, BorderStyle = BorderStyle.None, BackColor = CButton, ForeColor = CText,
            IntegralHeight = false, Font = FBody, Size = new Size(width - 2, Math.Min(items.Count, rows) * rowH), Cursor = Cursors.Hand };
        foreach (string s in items) lb.Items.Add(s);
        if (selected >= 0 && selected < items.Count) lb.SelectedIndex = selected;
        lb.DrawItem += paint ?? DrawRow;
        ToolStripControlHost host = new ToolStripControlHost(lb) { Margin = Padding.Empty, Padding = Padding.Empty, AutoSize = false, Size = lb.Size };
        ToolStripDropDown dd = new ToolStripDropDown { Padding = new Padding(1), Margin = Padding.Empty, BackColor = CButtonLine, DropShadowEnabled = false };
        dd.Renderer = new ToolStripProfessionalRenderer(new DarkColors());
        dd.Items.Add(host);
        bool done = false;
        Action<int> pick = delegate(int i) { if (done || i < 0) return; done = true; dd.Close(); picked(i); };
        lb.MouseMove += delegate(object s, MouseEventArgs e) { int i = lb.IndexFromPoint(e.Location); if (i >= 0 && i != lb.SelectedIndex) lb.SelectedIndex = i; };
        lb.MouseUp += delegate(object s, MouseEventArgs e) { if (e.Button == MouseButtons.Left) pick(lb.IndexFromPoint(e.Location)); };
        lb.PreviewKeyDown += delegate(object s, PreviewKeyDownEventArgs e) { if (e.KeyCode == Keys.Enter) e.IsInputKey = true; };
        lb.KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space) { e.Handled = e.SuppressKeyPress = true; pick(lb.SelectedIndex); } };
        dd.Opened += delegate { try { SetWindowTheme(lb.Handle, "DarkMode_Explorer", null); } catch { } lb.Focus(); };
        dd.Closed += delegate { if (anchor.CanFocus) anchor.Focus(); };
        dd.Show(anchor, new Point(0, anchor.Height + S(2)));
    }

    static void DrawRow(object s, DrawItemEventArgs e)
    {
        bool sel = (e.State & DrawItemState.Selected) != 0;
        using (Brush b = new SolidBrush(sel ? Color.FromArgb(30, 62, 56) : CButton)) e.Graphics.FillRectangle(b, e.Bounds);
        if (e.Index < 0) return;
        TextRenderer.DrawText(e.Graphics, (string)((ListBox)s).Items[e.Index], FBody, new Rectangle(e.Bounds.X + S(7), e.Bounds.Y, e.Bounds.Width - S(9), e.Bounds.Height),
            sel ? Color.White : CText, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }

    // the menus (Help, Tools) and the lists, dark
    class DarkColors : ProfessionalColorTable
    {
        public override Color MenuItemSelected { get { return Color.FromArgb(30, 62, 56); } }
        public override Color MenuItemBorder { get { return Color.FromArgb(30, 62, 56); } }
        public override Color MenuBorder { get { return CButtonLine; } }
        public override Color ToolStripDropDownBackground { get { return CButton; } }
        public override Color ImageMarginGradientBegin { get { return CButton; } }
        public override Color ImageMarginGradientMiddle { get { return CButton; } }
        public override Color ImageMarginGradientEnd { get { return CButton; } }
        public override Color SeparatorDark { get { return CButtonLine; } }
        public override Color SeparatorLight { get { return CButton; } }
    }

    static ContextMenuStrip Menu()
    {
        return new ContextMenuStrip { Renderer = new ToolStripProfessionalRenderer(new DarkColors()), BackColor = CButton, ForeColor = CText, ShowImageMargin = false, Font = FBody };
    }

    // one of several (the order of a pane): a round mark, a word on the right (here / unused)
    class Radio : Drawn
    {
        public bool On;
        public string Em;
        public Radio() : base(true) { }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            if (On || over || Cue)
                using (GraphicsPath p = Round(new RectangleF(0.5f, 0.5f, W - 1, H - 1), 4))
                using (Brush b = new SolidBrush(On ? Color.FromArgb(16, 42, 74) : Color.FromArgb(17, 34, 40))) g.FillPath(b, p);
            RectangleF c = new RectangleF(8, (H - 10) / 2f, 10, 10);
            if (On) using (Brush b = new SolidBrush(CBlue)) { g.FillEllipse(b, c); using (Pen r = new Pen(Color.FromArgb(16, 42, 74), 1.6f)) g.DrawEllipse(r, RectangleF.Inflate(c, -2.2f, -2.2f)); }
            else using (Pen l = new Pen(Color.FromArgb(74, 106, 98), 1.5f)) g.DrawEllipse(l, c);
            StrIn(g, Text, F, On ? Color.White : Color.FromArgb(185, 199, 193), new RectangleF(27, 0, W - 27, H - 1), TFLeft);
            if (Em != null) StrIn(g, Em, Px105, CDim, new RectangleF(0, 0, W - 8, H - 1), TFRight);
        }
        static Font Px105 { get { return F11; } }
    }

    // a status light, alone or with its line
    class Led : Drawn
    {
        public Color On = CLedOff;
        public Led() : base(false) { }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            using (Brush b = new SolidBrush(On)) g.FillEllipse(b, 0, 0, W - 1, H - 1);
        }
    }

    class LedLine : Drawn
    {
        public Color On = CLedOff;
        public LedLine() : base(false) { }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            float cy = H / 2f;
            bool lit = On != CLedOff;
            if (lit) using (Brush h = new SolidBrush(Color.FromArgb(46, On))) g.FillEllipse(h, -2, cy - 7, 14, 14);
            using (Brush b = new SolidBrush(On)) g.FillEllipse(b, 1, cy - 4, 8, 8);
            StrIn(g, Text, F, lit ? CText : CDim, new RectangleF(17, 0, W - 17, H - 1), TFLeft);
        }
    }

    // the game's folder: GOG / STEAM on green, then where it is
    class GameLine : Drawn
    {
        public string Dir;
        public GameLine() : base(true) { F = F12; }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            float x = Badge(g, Dir, 0, H / 2f);
            StrIn(g, Dir ?? "No Terra Nova found: Change, then pick the folder that contains TNOVA", F, Dir == null ? CSoft : over || Cue ? Color.White : CText,
                new RectangleF(x + 10, 0, W - x - 10, H - 1), TFPath);
        }
        public static float Badge(Graphics g, string dir, float x, float cy)
        {
            string t = dir == null ? "NONE" : Edition(dir);
            float w = Spaced(g, t, F10b, Color.Empty, 0, 0, 0.6f) + 16;
            using (GraphicsPath p = Round(new RectangleF(x, cy - 9, w, 18), 3))
            using (Brush b = new SolidBrush(dir == null ? Color.FromArgb(70, 24, 20) : Color.FromArgb(18, 58, 34))) g.FillPath(b, p);
            Spaced(g, t, F10b, dir == null ? CRed : Color.FromArgb(95, 220, 134), x + 8, cy - 7, 0.6f);
            return x + w;
        }
    }

    // the order wheel as the game shows it: a flat-top hexagon of six panes. A click picks a pane (the arrow keys:
    // the next one), a pane dragged onto another swaps their orders
    class WheelPad : Drawn
    {
        public int[] Panes = (int[])PANES0.Clone();
        public int Sel;
        public event EventHandler Picked, Changed;
        int drag = -1, hot = -1;
        bool moved;
        Point from, at;
        public WheelPad() : base(true) { Cursor = Cursors.Default; }
        static PointF V(float r, int i) { double a = (-120 + 60 * i) * Math.PI / 180; return new PointF(150 + r * (float)Math.Cos(a), 150 + r * (float)Math.Sin(a)); }
        static PointF[] Pane(int i)
        {
            PointF a = V(134, i), b = V(134, i + 1), c = V(48, i + 1), d = V(48, i);
            float ux = (b.X - a.X) / 134 * 4.3f, uy = (b.Y - a.Y) / 134 * 4.3f;
            return new[] { new PointF(a.X + ux, a.Y + uy), new PointF(b.X - ux, b.Y - uy), new PointF(c.X - ux, c.Y - uy), new PointF(d.X + ux, d.Y + uy) };
        }
        int PaneAt(Point p)
        {
            for (int i = 0; i < 6; i++)
                using (GraphicsPath gp = new GraphicsPath()) { gp.AddPolygon(Pane(i)); if (gp.IsVisible(p)) return i; }
            return -1;
        }
        protected override bool IsInputKey(Keys k) { return k == Keys.Left || k == Keys.Right || k == Keys.Up || k == Keys.Down || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            int step = e.KeyCode == Keys.Right || e.KeyCode == Keys.Down ? 1 : e.KeyCode == Keys.Left || e.KeyCode == Keys.Up ? 5 : 0;
            if (step == 0) return;
            Sel = (Sel + step) % 6; Invalidate();
            if (Picked != null) Picked(this, EventArgs.Empty);
        }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            Point here = new Point((int)(e.X / K), (int)(e.Y / K));
            int p = PaneAt(here);
            if (e.Button != MouseButtons.Left || p < 0) return;
            Sel = drag = p; hot = -1; moved = false; from = at = here; Invalidate();
            if (Picked != null) Picked(this, EventArgs.Empty);
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            Point here = new Point((int)(e.X / K), (int)(e.Y / K));
            int p = PaneAt(here);
            Cursor = p >= 0 || drag >= 0 ? Cursors.Hand : Cursors.Default;
            if (drag < 0) return;
            at = here;
            if (Math.Abs(at.X - from.X) + Math.Abs(at.Y - from.Y) > 6) moved = true;
            hot = moved && p != drag ? p : -1;
            Invalidate();
        }
        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (drag >= 0 && moved && hot >= 0)
            {
                int t = Panes[drag]; Panes[drag] = Panes[hot]; Panes[hot] = t;
                Sel = hot;
                if (Changed != null) Changed(this, EventArgs.Empty);
            }
            drag = hot = -1; moved = false; Invalidate();
        }
        static void Words(Graphics g, string name, float cx, float cy, Color c)
        {
            string[] w = name.ToUpperInvariant().Split(' ');
            for (int j = 0; j < w.Length; j++)
            {
                float tw = Spaced(g, w[j], F105b, Color.Empty, 0, 0, 0.6f);
                Spaced(g, w[j], F105b, c, cx - tw / 2, cy - 6.5f * w.Length + 13 * j, 0.6f);
            }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            for (int i = 0; i < 6; i++)
            {
                bool sel = i == Sel, empty = Panes[i] < 0, target = i == hot;
                PointF[] p = Pane(i);
                using (Brush b = new SolidBrush(sel ? Color.FromArgb(18, 58, 102) : empty ? Color.FromArgb(9, 20, 26) : Color.FromArgb(11, 29, 44))) g.FillPolygon(b, p);
                using (Pen l = new Pen(target ? COrange : sel ? CBlue : Color.FromArgb(39, 66, 92), target || sel ? 2f : 1f))
                {
                    if (empty && !sel && !target) l.DashStyle = DashStyle.Dash;
                    g.DrawPolygon(l, p);
                }
                if (empty || (i == drag && moved)) continue;
                double a = (-90 + 60 * i) * Math.PI / 180;
                Words(g, ORDERS[Panes[i]], 150 + 80.5f * (float)Math.Cos(a), 150 + 80.5f * (float)Math.Sin(a), sel ? Color.White : Color.FromArgb(185, 201, 216));
            }
            float w1 = Spaced(g, "ENTIRE", F9, Color.Empty, 0, 0, 1f), w2 = Spaced(g, "SQUAD", F9, Color.Empty, 0, 0, 1f);
            Spaced(g, "ENTIRE", F9, CDim, 150 - w1 / 2, 138, 1f);
            Spaced(g, "SQUAD", F9, CDim, 150 - w2 / 2, 151, 1f);
            if (Cue) using (Pen l = new Pen(Color.FromArgb(90, 255, 255, 255)) { DashStyle = DashStyle.Dot }) g.DrawPolygon(l, new[] { V(140, 0), V(140, 1), V(140, 2), V(140, 3), V(140, 4), V(140, 5) });
            if (drag >= 0 && moved && Panes[drag] >= 0) Words(g, ORDERS[Panes[drag]], at.X, at.Y - 14, COrange);
        }
    }

    // what the launcher has to say: a small box at the top right of the page, gone by itself after a few seconds.
    // What went wrong (red) or is still going on (amber) stays until the next one, or a click on it.
    class Toast : Form
    {
        string msg = "";
        Color edge = CBlue;
        bool stays;
        DateTime until;
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 40 };
        public Toast()
        {
            FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; StartPosition = FormStartPosition.Manual; BackColor = CPanel;
            DoubleBuffered = true; Cursor = Cursors.Hand; Text = "";
            timer.Tick += delegate {
                double left = (until - DateTime.Now).TotalSeconds;
                if (stays || !Visible) return;
                if (left <= 0) { timer.Stop(); Hide(); }
                else if (left < 0.6) Opacity = 0.96 * left / 0.6;
            };
            Click += delegate { timer.Stop(); Hide(); };
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get { CreateParams p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; }      // never the active window, no button of its own
        }
        public string Now { get { return Visible ? msg : ""; } }
        public void Say(string s, Color c)
        {
            if (form == null || form.IsDisposed || !form.Visible) return;
            msg = s; Text = s;
            edge = c == CRed ? CRed : c == CAmber ? CAmber : CBlue;
            stays = c == CRed || c == CAmber;
            Size sz = TextRenderer.MeasureText(GM, s, F12, new Size(S(330), 2000), TFWrap);
            ClientSize = new Size(sz.Width + S(28), sz.Height + S(17));
            using (GraphicsPath p = Round(new Rectangle(0, 0, Width, Height), 5)) Region = new Region(p);
            Place();
            Opacity = 0.96;
            until = DateTime.Now.AddSeconds(Math.Min(12, 4 + s.Length * 0.05));
            if (!Visible && form.WindowState != FormWindowState.Minimized) Show(form);
            Invalidate();
            timer.Start();
        }
        public void Place()
        {
            if (form == null || !form.Visible || form.WindowState == FormWindowState.Minimized) return;
            // (under the top line of a page with a picture; over the cards' titles on the others: no switch is covered)
            Location = form.PointToScreen(new Point(S(SB + MW - 18) - Width, S(pageNow <= 2 ? 56 : pageNow == P_CONTROLS ? 418 : 7)));
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(CPanel);
            using (Pen l = new Pen(CLine)) g.DrawRectangle(l, 0, 0, Width - 1, Height - 1);
            using (Brush b = new SolidBrush(edge)) g.FillRectangle(b, 0, 0, S(3), Height);
            RectangleF r = new RectangleF(15, 8, Width / K - 26, Height / K - 8);
            StrIn(g, msg, F12, CText, r, TFWrap);
            int cut = msg.IndexOf(": ");                      // "Photo mode: O ..." : its first words in the edge's colour
            if (cut > 0 && cut < 28) StrIn(g, msg.Substring(0, cut), F12, edge == CBlue ? Color.FromArgb(120, 176, 250) : edge, r, TFWrap);
        }
    }

    static string NewsFile { get { return Path.Combine(UplinkDir, "WHATSNEW.txt"); } }

    static void ToggleLog()
    {
        logBox.Visible = !logBox.Visible; Fit();
        if (logBox.Visible) { logBox.SelectionStart = logBox.TextLength; logBox.ScrollToCaret(); }
    }

    static ContextMenuStrip HelpMenu()
    {
        ContextMenuStrip m = Menu();
        m.Items.Add("What's new", null, delegate { WhatsNew(); });
        m.Items.Add(logBox.Visible ? "Hide the log" : "Show the log", null, delegate { ToggleLog(); });
        m.Items.Add("Report a bug (a zip of the logs, without your name or folders)", null, delegate { Report(); });
        m.Items.Add("Discord", null, delegate { Open(DISCORD); });
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
        Font head = Px(24f, 600);
        f.Controls.Add(new Label { Text = "WHAT'S NEW", Font = head, ForeColor = CAmber, AutoSize = true, Location = new Point(22, 16) });
        f.Controls.Add(new Panel { BackColor = CAmber, Location = new Point(24, 54), Size = new Size(90, 2) });
        Box box = new Box { Location = new Point(20, 70), Size = new Size(560, 334) };
        f.Controls.Add(box);
        RichTextBox rt = new RichTextBox { ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = CPanel, ForeColor = CText, DetectUrls = false,
            Location = new Point(16, 12), Size = new Size(536, 310), ScrollBars = RichTextBoxScrollBars.Vertical, TabStop = false, Cursor = Cursors.Default };
        box.Controls.Add(rt);
        try { SetWindowTheme(rt.Handle, "DarkMode_Explorer", null); } catch { }   // (its scrollbar: dark, not Windows' white one)
        Font fVer = Px(17f, 600), fItem = Px(13f, 400);
        List<string> items = new List<string>();
        Action flush = delegate {
            foreach (string it in items)
            {
                rt.SelectionFont = fItem; rt.SelectionColor = CText; rt.SelectionIndent = S(8); rt.SelectionHangingIndent = S(16);
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
                if (any) { rt.SelectionFont = Px(7f, 400); rt.AppendText("\n"); }
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
        Dpi(f);
        f.ShowDialog(form);
    }

    static void Fit()
    {
        form.ClientSize = new Size(S(SB + MW), S(MH + (logBox.Visible ? 152 : 0)));
        side.Height = form.ClientSize.Height;
        toast.Place();
    }

    static Font Pick(string[] families, float size, FontStyle style)
    {
        foreach (string f in families)
            using (Font t = Sized(f, size * DpiGdi / 72f, style))
                if (t.Name == f) return Sized(f, size * DpiGdi / 72f, style);
        return null;
    }

    // a panel with rounded corners and a thin border (the dialogs')
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

    // a flat rounded button of the dialogs: an icon (Segoe's icon font) above its label, or the label alone (Small)
    class Tile : Control
    {
        public string Icon; public Color Fill, Line, Ink; public bool Small; bool over;
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
            TextRenderer.DrawText(g, Icon, FIcon, new Rectangle(0, top, Width, isz.Height), ink, TextFormatFlags.HorizontalCenter);
            TextRenderer.DrawText(g, Text, tf, new Rectangle(0, top + isz.Height - 2, Width, ts.Height), ink, TextFormatFlags.HorizontalCenter);
        }
    }

    static ContextMenuStrip ToolsMenu()
    {
        ContextMenuStrip m = Menu();
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

    // what is going on: said in the toast (top right of the page), and kept in the log
    static void Status(string s, Color c) { Ui(delegate { if (toast != null) toast.Say(s, c); }); Log("== " + s); }
    static void Progress(int pct) { Ui(delegate { barFill.Size = new Size(bar.Width * Math.Max(0, Math.Min(100, pct)) / 100, bar.Height); bar.Visible = pct > 0; }); }

    // the session line (co-op only), at the top of the Co-op page while a session runs
    static void Session(string s, Color c)
    {
        Ui(delegate {
            sessionLabel.Text = s + (sessionPing != "" && c == CGreen ? "   ·   " + sessionPing : "");
            sessionLed.On = c; sessionLed.Invalidate();
            sessionRow.Visible = s != "No session.";
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
            leds[i].On = have[i] ? CGreen : CLedOff;
            leds[i].Text = (string)leds[i].Tag + (i == 0 && have[0] && Cfg("uplink_sha").Length >= 7 ? " " + Cfg("uplink_sha").Substring(0, 7) : "");
            leds[i].Invalidate();
        }
        // while something runs, the button that started it stops it (PLAY and MAP VIEWER: whatever runs)
        bool b = busy, glow = playBtn.Stop != b;
        playBtn.Stop = mapBtn.Stop = b;
        hostBtn.Stop = b && running == Mode.Host;
        joinBtn.Stop = b && running == Mode.Join;
        hostBtn.Enabled = !b || hostBtn.Stop;
        joinBtn.Enabled = !b || joinBtn.Stop;
        gameBtn.Enabled = gameBtn2.Enabled = gameLine.Enabled = gameLine2.Enabled = toolsBtn.Enabled = keysBtn.Enabled = checkBtn.Enabled = !b;
        if (glow) { pages[0].Dirty(); pages[2].Dirty(); }
        foreach (Control c in new Control[] { playBtn, mapBtn, hostBtn, joinBtn }) c.Invalidate();
        LoadHeroes();                                         // (a first installation: the pictures have just come)
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
        int s = Array.IndexOf(SIZES, Cfg("window"));
        sizeBox.Selected = s >= 0 ? s : 3;                       // (nothing chosen yet, a new installation: Fullscreen)
        double sens;
        sensBar.Value = double.TryParse(Cfg("mouse"), NumberStyles.Float, CultureInfo.InvariantCulture, out sens) ?
            Math.Max(2, Math.Min(30, (int)Math.Round(sens * 10))) : 10;
        SensLabel();
        invertBox.Checked = Cfg("invert_y") == "1";
        crossBox.Selected = Math.Max(0, Array.IndexOf(CROSSHAIRS, Cfg("crosshair")));
        runTick.Checked = Cfg("shift_run") == "1";
        fpsBox.Checked = Cfg("fps_counter") == "1";              // (off unless asked for: ticket #13)
        hudTick.Checked = Cfg("hud_colours") != "0";             // (on unless turned off)
        editTick.Checked = Cfg("mission_editor") == "1";         // (off unless asked for)
        introBox.Checked = Cfg("skip_intro") == "1";
        oldBox.Checked = Cfg("old_school") != "0";
        wheelTick.Checked = Cfg("order_wheel") == "1";           // (off unless asked for)
        subsTick.Checked = Cfg("subtitles") == "1";              // (off unless asked for)
        for (int i = 0; i < FX.Length; i++) fxTicks[i].Checked = Cfg("fx_" + FX[i]) != "0";   // (the extras: on unless turned off)
        int cap;
        capValue = int.TryParse(Cfg("fps_cap"), out cap) && cap > 0 ? cap : 0;
        FillCap();
        padBox.Checked = Cfg("gamepad") == "1";
        if (padBox2 != null) padBox2.Checked = padBox.Checked;                  // (off unless asked for; up to 2.7 it was on unless turned off)
        int mi;
        string start = Cfg("start_at") != "" ? Cfg("start_at") : Cfg("lab_mission");   // (1.x: the lab's selector)
        missionBox.Selected = int.TryParse(start, out mi) && mi >= 0 && mi < missionBox.Items.Count ? mi : 0;
        ReadSharp();
    }

    // every option of the pages into the ini (at each change, before each start, when the window closes)
    static void SaveOptions()
    {
        if (sizeBox == null || loading) return;
        Set("mode", "coop");                                     // (the 1v1 mode is being redone: nothing here asks for it)
        Set("window", SIZES[sizeBox.Selected]);
        Set("mouse", (sensBar.Value / 10.0).ToString("0.0", CultureInfo.InvariantCulture));
        Set("invert_y", invertBox.Checked ? "1" : "0");
        Set("crosshair", CROSSHAIRS[crossBox.Selected]);
        Set("shift_run", runTick.Checked ? "1" : "0");
        Set("fps_counter", fpsBox.Checked ? "1" : "0");
        Set("hud_colours", hudTick.Checked ? "1" : "0");
        Set("mission_editor", editTick.Checked ? "1" : "0");
        Set("skip_intro", introBox.Checked ? "1" : "0");
        Set("old_school", oldBox.Checked ? "1" : "0");
        Set("order_wheel", wheelTick.Checked ? "1" : "0");
        Set("subtitles", subsTick.Checked ? "1" : "0");
        for (int i = 0; i < FX.Length; i++) Set("fx_" + FX[i], fxTicks[i].Checked ? "1" : "0");
        Set("fps_cap", capValue > 0 ? Math.Max(20, Math.Min(1000, capValue)).ToString() : "0");
        Set("gamepad", padBox.Checked ? "1" : "0");
        if (padBox2 != null && padBox2.Checked != padBox.Checked) padBox2.Checked = padBox.Checked;
        Set("start_at", missionBox.Selected.ToString());
        SaveCfg();
    }

    static string UplinkDir { get { return Path.Combine(Comp, "uplink"); } }
    static string GodotExe { get { return Path.Combine(Comp, "godot", "Godot_v" + GODOT_VER + "-stable_win64.exe"); } }
    static string TnpDir { get { return Path.Combine(Comp, "tnplus"); } }                // TN+ (main): PLAY
    static string TnpExe { get { return Path.Combine(TnpDir, "TNPlus.exe"); } }
    static string TnpCoopDir { get { return Path.Combine(Comp, "tnplus_coop"); } }       // TN+ co-op build: HOST
    static string TnpCoopExe { get { return Path.Combine(TnpCoopDir, "TNPlus.exe"); } }
    static string PythonExe { get { return Path.Combine(Comp, "python", "python.exe"); } }
    // Uplink's own folder (Godot's user://: under %APPDATA%, which Godot reads from the environment). An Uplink that
    // comes with an override.cfg naming a folder of its own (a test copy) keeps its files there, as Godot does.
    static string GodotData
    {
        get
        {
            string a = Environment.GetEnvironmentVariable("APPDATA");
            if (string.IsNullOrEmpty(a)) a = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            try
            {
                string o = Path.Combine(UplinkDir, "override.cfg"), t = File.Exists(o) ? File.ReadAllText(o) : "";
                Match m = Regex.Match(t, "(?m)^\\s*config/custom_user_dir_name\\s*=\\s*\"([^\"]+)\"");
                if (m.Success && Regex.IsMatch(t, "(?m)^\\s*config/use_custom_user_dir\\s*=\\s*true")) return Path.Combine(a, m.Groups[1].Value);
            }
            catch { }
            return Path.Combine(a, "Godot", "app_userdata", "Terra Nova Uplink");
        }
    }

    // A test folder: with a file no_update.txt beside the exe, nothing is looked for on GitHub and nothing is
    // downloaded, built or replaced (Uplink, Terra Nova Plus, Godot, Python, the launcher itself): what is in
    // components\ is used as it is, and what is missing is said. Not for a normal installation.
    static bool NoUpdate { get { return File.Exists(Path.Combine(Root, "no_update.txt")); } }

    static void Missing(string what)
    {
        if (NoUpdate) throw new Exception(what + " is not in this folder, and updates are off here (no_update.txt).");
    }

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

    static void ShowGame()
    {
        gameLine.Dir = gameLine2.Dir = Game();
        gameLine.Invalidate(); gameLine2.Invalidate();
    }

    // Change (and a click on the folder's line): every Terra Nova found on the PC, looked for again each time, the
    // one in use picked; the last line takes any other folder
    static void GamesMenu(Control line)
    {
        if (busy) return;
        List<string> l = Installs();
        string g = Game();
        if (g != null && !l.Exists(x => string.Equals(x, g, StringComparison.OrdinalIgnoreCase))) l.Insert(0, g);
        l.Add("");
        Popup(line, S(MW - 36), l, l.FindIndex(x => string.Equals(x, g, StringComparison.OrdinalIgnoreCase)), 26, 12, DrawGame, delegate(int i) {
            if (l[i] == "") { PickGame(); return; }
            if (string.Equals(l[i], Cfg("game_dir"), StringComparison.OrdinalIgnoreCase)) return;
            Set("game_dir", l[i]); SaveCfg(); FillMissions(); ShowGame(); RefreshUi();
            Log("game: " + l[i]);
        });
    }

    // an install: GOG / STEAM on green, then its folder
    static void DrawGame(object s, DrawItemEventArgs e)
    {
        bool sel = (e.State & DrawItemState.Selected) != 0;
        using (Brush b = new SolidBrush(sel ? Color.FromArgb(30, 62, 56) : CButton)) e.Graphics.FillRectangle(b, e.Bounds);
        if (e.Index < 0) return;
        string d = (string)((ListBox)s).Items[e.Index];
        int x = e.Bounds.X + S(7);
        if (d != "")
        {
            GraphicsState st = e.Graphics.Save();             // (the badge is drawn as on the pages: sizes as at 100 %)
            e.Graphics.ScaleTransform(K, K);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            x = S(GameLine.Badge(e.Graphics, d, x / K, (e.Bounds.Y + e.Bounds.Height / 2f) / K) + 8);
            e.Graphics.Restore(st);
        }
        TextRenderer.DrawText(e.Graphics, d == "" ? "Another folder... (the one that contains TNOVA)" : d, FBody,
            new Rectangle(x, e.Bounds.Y, e.Bounds.Right - x - 4, e.Bounds.Height), d == "" ? CSoft : sel ? Color.White : CText,
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
            Set("game_dir", p); SaveCfg(); ShowGame(); FillMissions(); RefreshUi();
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
            running = null;
            Progress(0);
            Ui(RefreshUi);
        }) { IsBackground = true }.Start();
    }

    // ------------------------------------------------------------------ play / host / join / map viewer
    static void Start(Mode m)
    {
        if (busy) return;
        AdoptNow();                                          // (what Uplink's menu changed: before the options are given)
        SaveOptions();
        if (Game() == null) { PickGame(); if (Game() == null) return; }
        if (m == Mode.Host && !IsEnglish(Game()))
        {   // the co-op code only knows the English exe: another install of the PC that has it
            string en = Installs().Find(IsEnglish);
            if (en == null)
            {
                MessageBox.Show(form, "Hosting needs the English version of the game (Steam's, or GOG's in English), and none was found. Add one with Change.", TITLE);
                return;
            }
            Set("game_dir", en); SaveCfg(); ShowGame(); FillMissions(); RefreshUi();
            Log("hosting: the English game, " + en);
        }
        sessionName = sessionPing = "";
        coopRun = m == Mode.Host || m == Mode.Join;
        running = m;
        Background(delegate {
            if (m == Mode.Play || m == Mode.Host) Live(m == Mode.Host, 0);
            else if (m == Mode.Join) Join();
            else Maps();
        });
    }

    // PLAY and HOST A GAME: the game through TN+ (its co-op build to host), then the bridge, which opens Uplink live
    // playMission > 0 (the mission editor's "Play this mission", see Maps): the game is then taken into that mission
    static void Live(bool host, int playMission)
    {
        Status("Getting things ready...", CAmber);
        Install(host ? Mode.Host : Mode.Play);
        bool running;
        if (!Preflight(host, out running) || (host && !SteamUp())) return;
        string dir = host ? TnpCoopDir : TnpDir, exe = host ? TnpCoopExe : TnpExe;
        wholeMenus = !running || (ownGame && WholeMenusIni(dir));   // (see Env)
        string load = null;
        int pick;
        if (playMission <= 0 && int.TryParse(Cfg("start_at"), out pick) && pick > 0)
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
            PruneMstat(Game(), host);
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
            { Status("The game didn't load in 5 minutes: see the log (Help, Show the log).", CRed); return; }
            Thread.Sleep(3000);
            bridge = Bridge(host, dir);
            DateTime b0 = DateTime.Now;
            while (!bridge.HasExited && (DateTime.Now - b0).TotalSeconds < 12) Thread.Sleep(250);
            if (!bridge.HasExited) break;
            Log("bridge not ready yet (" + bridge.ExitCode + "), trying again");
        }
        if (stopping || bridge == null) return;
        Process starter = null;
        if (playMission > 0)
        {   // a save of ours set on the mission, then the game's menus driven into it (live\mission_play.py)
            Status("Starting mission " + playMission + " in the game...", CAmber);
            Dictionary<string, string> penv = new Dictionary<string, string>();
            penv["PYTHONIOENCODING"] = "utf-8";
            Proc game = Procs().Find(p => p.Name == "dosbox-staging.exe" && p.Cmd.IndexOf(dir + "\\", StringComparison.OrdinalIgnoreCase) >= 0);
            playError = "";
            starter = Run(PythonExe, "-u \"" + Path.Combine(UplinkDir, "live", "mission_play.py") + "\" --game \"" + Game() +
                "\" --mission " + playMission + " --start" + (game != null ? " --pid " + game.Id : ""), UplinkDir, penv, true);
        }
        else if (host)
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
            if (starter != null && starter.HasExited)
            {
                if (starter.ExitCode == 0)
                    Status("Mission " + playMission + " started." + (playMission == 18 || playMission == 28 ?
                        " (In a mission of your own the game drops the player alone, in a standard suit.)" : ""), CGreen);
                else Status(playError != "" ? playError : "The mission could not be started: see the log (Help, Show the log).", CRed);
                starter = null;
            }
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
            (host ? " --guest-remote" : "") + " --res " + Cfg("window") + (host && Cfg("mode") == "versus" ? " --versus" : ""),
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
        bool editor = Cfg("mission_editor") == "1";
        Status("Opening the map viewer...", CAmber);
        string size = Cfg("window");
        string win = size == "native" ? "" : "--resolution " + size + " ";
        // the mission editor's "Play this mission": the map viewer writes the mission's number in this file; the game
        // is then started from here as PLAY does and taken into that mission
        Dictionary<string, string> env = Env();
        string req = Path.Combine(Comp, "play_request.txt");
        try { File.Delete(req); } catch { }
        env["TN_PLAY_REQUEST"] = req;
        env["TN_OLDSCHOOL"] = "0";                             // ("Old school look" is the live game's: here F12 turns it on)
        Process g = Run(GodotExe, "--path \"" + UplinkDir + "\" " + win + (size == "native" ? "-- --native" : ""), UplinkDir, env, true);
        string open = "Map viewer open: right mouse button to look, WASD to move, Tab for the mission list." + (editor ? " F6: the mission editor." : "");
        Status(open, CGreen);
        while (!stopping && !g.HasExited)
        {
            Thread.Sleep(500);
            int play = PlayRequest(req);
            if (play <= 0) continue;
            Live(false, play);
            if (!stopping && !g.HasExited) Status(open, CGreen);
        }
        if (!stopping) Status("Uplink was closed.", CText);
    }

    // the mission the map viewer asked to play (first line of the request file, which is taken away), else 0
    static string playError = "";

    static int PlayRequest(string req)
    {
        try
        {
            if (!File.Exists(req)) return 0;
            string[] l = File.ReadAllLines(req);
            File.Delete(req);
            int n;
            return l.Length > 0 && int.TryParse(l[0].Trim(), out n) && n > 0 && n < 128 ? n : 0;
        }
        catch { return 0; }
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
        env["TN_KEY_PHOTO"] = PhotoKey();
        env["TN_KEY_MENU"] = MenuKey();
        env["TN_HUD_COLOURS"] = Cfg("hud_colours") == "0" ? "0" : "1";
        env["TN_EDITOR"] = Cfg("mission_editor") == "1" ? "1" : "0";
        env["TN_SKIP_INTRO"] = Cfg("skip_intro") == "1" ? "1" : "0";
        env["TN_BINDS"] = Binds();
        env["TN_CROSSHAIR"] = Cfg("crosshair");
        env["TN_RUN"] = Cfg("shift_run") == "1" ? "1" : "0";
        env["TN_FPS"] = Cfg("fps_counter") == "1" ? "1" : "0";
        env["TN_FPS_CAP"] = Cfg("fps_cap") == "" ? "0" : Cfg("fps_cap");
        env["TN_OLDSCHOOL"] = Cfg("old_school") == "0" ? "0" : "1";
        env["TN_NO_PAD"] = Cfg("gamepad") == "1" ? "0" : "1";
        env["TN_ORDER_WHEEL"] = Cfg("order_wheel") == "1" ? "1" : "0";
        env["TN_SUBTITLES"] = Cfg("subtitles") == "1" ? "1" : "0";
        env["TN_ORDER_KEY"] = OrderKey();
        env["TN_ORDER_PANES"] = string.Join(",", Array.ConvertAll(Panes(), x => x.ToString()));
        env["TN_ORDER_TAP_GROUND"] = Num("tap_ground", 1, -1, ORDERS.Length - 1).ToString();
        env["TN_ORDER_TAP_ENEMY"] = Num("tap_enemy", 0, -1, ORDERS.Length - 1).ToString();
        env["TN_ORDER_TAP_MS"] = Num("tap_ms", TAP_MS0, 100, 350).ToString();
        env["TN_ORDER_DEAD"] = Num("wheel_dead", DEAD0, 24, 104).ToString();
        foreach (string fx in FX) env["TN_FX_" + fx.ToUpperInvariant()] = Cfg("fx_" + fx) == "0" ? "0" : "1";
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
                    if (!d.WaitForExit(3000)) { d.Kill(); d.WaitForExit(3000); }
                }
                catch { }
            }
        Thread.Sleep(500);
        if (any) PruneMstat(Game(), true);
        foreach (Proc p in Procs())
            if (p.Name == "TNPlus.exe" && (p.Cmd.IndexOf(TnpDir + "\\", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                           p.Cmd.IndexOf(TnpCoopDir + "\\", StringComparison.OrdinalIgnoreCase) >= 0)) Kill(p.Id);
        return any;
    }

    // The game makes a scratch file TNOVA\MSTATnnn.RES at each start (the first free name, octal 000 to 777) and only
    // removes it when it is left by its own menu: closed with its window, as from here, the file stays, and with all
    // 512 names taken the game stays on a black screen. No save needs them. Only with no game running (a running game
    // needs its own), and without insisting where Windows refuses (Program Files)
    static void PruneMstat(string game, bool coop)
    {
        if (string.IsNullOrEmpty(game) || Process.GetProcessesByName("dosbox-staging").Length > 0) return;
        int n = 0;
        foreach (string dir in new[] { Path.Combine(game, "TNOVA"), coop ? Path.Combine(TnpCoopDir, "coop_overlay", "TNOVA") : null })
            try
            {
                if (dir == null || !Directory.Exists(dir)) continue;
                foreach (string f in Directory.GetFiles(dir, "MSTAT???.RES"))
                    if (Regex.IsMatch(Path.GetFileName(f), @"^MSTAT[0-7]{3}\.RES$", RegexOptions.IgnoreCase))
                        try { File.Delete(f); n++; } catch { }
            }
            catch { }
        if (n > 0) Log("removed " + n + " leftover MSTAT file(s) of the game");
    }

    static void Kill(int id)
    {
        try { Process p = Process.GetProcessById(id); Log("closing " + p.ProcessName + " " + id); p.Kill(); p.WaitForExit(3000); } catch { }
    }

    // HOST / JOIN: Steam running AND logged in before Uplink starts its Steam (started too early, while Steam was still
    // starting, it stayed OFFLINE). Test switch TN_TEST_STEAM_WAIT=N: Steam "ready" after N s, never started for real
    static bool SteamUp()
    {
        int test = -1;
        int.TryParse(Environment.GetEnvironmentVariable("TN_TEST_STEAM_WAIT") ?? "", out test);
        bool testing = Environment.GetEnvironmentVariable("TN_TEST_STEAM_WAIT") != null;
        DateTime t0 = DateTime.Now;
        Func<bool> ready = () => testing ? (DateTime.Now - t0).TotalSeconds >= test : SteamReady();
        if (ready()) return true;
        if (!testing && Process.GetProcessesByName("steam").Length == 0)
        {
            Log("Steam isn't running: starting it");
            try { Process.Start("steam://open/main"); } catch { }
        }
        const int wait = 180;                              // (an update of Steam, then the login)
        for (int i = 0; i < wait && !stopping; i++)
        {
            if (i % 5 == 0) Status("Waiting for Steam... start it and log in (" + (wait - i) + " s left).", CAmber);
            Thread.Sleep(1000);
            if (ready()) { Log("Steam ready after " + (i + 1) + " s"); Thread.Sleep(3000); return true; }
        }
        if (!stopping) Status("Steam isn't ready: start it, log in, then click again.", CRed);
        return false;
    }

    // Steam's own: HKCU\Software\Valve\Steam\ActiveProcess, pid (running) and ActiveUser (not 0 once logged in). The
    // values are only compared, never logged or shown
    static bool SteamReady()
    {
        try
        {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam\ActiveProcess"))
            {
                if (k == null) return false;
                object pid = k.GetValue("pid"), user = k.GetValue("ActiveUser");
                if (!(pid is int) || !(user is int) || (int)pid == 0 || (int)user == 0) return false;
                using (Process p = Process.GetProcessById((int)pid)) return !p.HasExited;
            }
        }
        catch { return false; }
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
        if (l.StartsWith("ERROR: ")) playError = l.Substring(7);          // (live\mission_play.py: why the mission did not start)
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
        int keep = missionBox.Selected;
        List<string> l = new List<string> { "From the game's menus" };
        string g = Game();
        string[] names = g != null ? MissionNames(g) : null;
        for (int i = 0; i < CAMPAIGN.Length; i++)
        {
            int n = CAMPAIGN[i];
            string nm = names != null && n - 1 < names.Length && names[n - 1].Trim() != "" ? names[n - 1].Trim() : "MISS" + n;
            l.Add((i + 1).ToString("00") + "   " + nm);
        }
        bool was = loading;
        loading = true;
        missionBox.Items = l;
        missionBox.Selected = keep < l.Count ? keep : 0;
        loading = was;
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
            BorderStyle = BorderStyle.None, Font = Pt(new[] { "Consolas" }, 10f, FontStyle.Regular) };
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
        Dpi(d);
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

    static void StopNow() { new Thread(StopAll) { IsBackground = true }.Start(); }

    static void StopAll()
    {
        stopping = true;
        lock (mine)
        {
            foreach (Process p in mine)
                try { if (!p.HasExited) { p.CloseMainWindow(); if (!p.WaitForExit(1500)) p.Kill(); } } catch { }
            mine.Clear();
        }
        // and what those had started in turn: this launcher's Uplink (opened by the bridge) and its game (opened by
        // Terra Nova Plus). Without them STOP left both open, with nothing driving them any more
        foreach (Proc p in Procs())
            if (p.Name.StartsWith("Godot") && p.Cmd.IndexOf(UplinkDir, StringComparison.OrdinalIgnoreCase) >= 0) Kill(p.Id);
        CloseOurGame();
        Status("Stopped.", CText);
        Session("No session.", CDim);
    }

    // ------------------------------------------------------------------ bug report: one zip on the desktop
    // Nothing personal goes into it. Every file is text, and each is cleaned as the zip is made (so lines written
    // long ago are covered too): the folders of this PC (the user's own become %USERPROFILE%, %APPDATA%...; the
    // game's becomes its edition; any other absolute path keeps its last name only), the Windows user name, the PC's
    // name, Steam names (the player's: "me"; the others': "friend1", "friend2"..., found on the lines of the co-op log
    // that name them), long numbers (Steam and lobby ids), e-mail addresses. What stays: the logs, the settings of
    // Uplink and Terra Nova Plus, the versions, Windows' version and, in Godot's log, the graphics card's name.
    const string REPORT_NOTE =
        "WHAT IS IN THIS REPORT\r\n\r\n" +
        "- the launcher's log, Uplink's own logs (co-op, Godot) and the bridge's\r\n" +
        "- the settings of Uplink and of Terra Nova Plus (options, keys)\r\n" +
        "- the versions installed, Windows' version, and in Godot's log the name of the graphics card\r\n\r\n" +
        "Taken out before the zip was made: the Windows user name and the folders of the PC (written as\r\n" +
        "%USERPROFILE%, <game STEAM>, <folder>...), the PC's name, Steam names (written as me, friend1...),\r\n" +
        "Steam and lobby numbers, e-mail addresses. No save and no file of the game is in it.\r\n";

    static void Report() { Report(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory)); }

    static void Report(string folder)
    {
        string zip = Path.Combine(folder, "TerraNovaUplink_report_" + DateTime.Now.ToString("yyyy-MM-dd_HH-mm") + ".zip");
        try
        {
            List<string[]> files = new List<string[]>();              // [its name in the zip, its text]
            StringBuilder info = new StringBuilder();
            string g = Game();
            Version v = Environment.OSVersion.Version;
            info.AppendLine(TITLE + " " + VERSION + ", Windows " + (v.Major == 10 ? (v.Build >= 22000 ? "11" : "10") : v.Major + "." + v.Minor) +
                " (build " + v.Build + ")" + (Environment.Is64BitOperatingSystem ? ", 64-bit" : ""));
            info.AppendLine("game: " + (g == null ? "none" : Edition(g) + (IsEnglish(g) ? " (English)" : " (not English)")));
            info.AppendLine("uplink " + Cfg("uplink_sha") + ", tnplus " + Cfg("tnplus_sha") + ", tnplus coop " + Cfg("tnplus_coop_sha"));
            info.AppendLine("options: mode " + Cfg("mode") + ", window " + Cfg("window") + ", mouse " + Cfg("mouse") +
                            ", invert " + Cfg("invert_y") + ", gamepad " + Cfg("gamepad") + ", start at " + Cfg("start_at"));
            string session = sessionLabel != null ? sessionLabel.Text : "-";
            info.AppendLine("session: " + (sessionName != "" ? session.Replace(sessionName, "friend") : session));
            foreach (Proc p in Procs()) info.AppendLine("running: " + p.Name + " " + p.Id);
            files.Add(new[] { "info.txt", info.ToString() });
            files.Add(new[] { "WHAT IS IN THIS REPORT.txt", REPORT_NOTE });
            Add(files, LogPath, "launcher.log");
            Add(files, Path.Combine(TnpDir, "TNPlus.ini"), "TNPlus.ini");
            Add(files, Path.Combine(TnpCoopDir, "TNPlus.ini"), "TNPlus_coop.ini");
            Newest(files, Path.Combine(UplinkDir, "live", "logs"), "coop_host_*.log", 3, "bridge/");
            Newest(files, Path.Combine(GodotData, "coop_logs"), "*.log", 4, "uplink_coop/");
            Newest(files, Path.Combine(GodotData, "logs"), "*.log", 2, "uplink_godot/");
            List<string[]> names = SteamNames(files);
            using (ZipArchive a = ZipFile.Open(zip, ZipArchiveMode.Create))
                foreach (string[] f in files)
                    using (StreamWriter w = new StreamWriter(a.CreateEntry(f[0]).Open(), new UTF8Encoding(false))) w.Write(Scrub(f[1], names));
            Status("Report saved on your desktop (logs and settings, no name, no folder of yours): send it on Discord with a few words on what happened.", CGreen);
            if (form != null) Process.Start("explorer.exe", "/select,\"" + zip + "\"");
            else Console.WriteLine(zip);
        }
        catch (Exception e) { Status("Report failed: " + e.Message, CRed); }
    }

    static void Add(List<string[]> files, string file, string name)
    {
        try
        {   // the logs are still open in the programs writing them: read them shared
            using (FileStream f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader r = new StreamReader(f, Encoding.UTF8)) files.Add(new[] { name, r.ReadToEnd() });
        }
        catch { }
    }

    static void Newest(List<string[]> files, string dir, string pattern, int n, string into)
    {
        if (!Directory.Exists(dir)) return;
        List<FileInfo> fs = new List<FileInfo>(new DirectoryInfo(dir).GetFiles(pattern));
        fs.Sort((x, y) => y.LastWriteTime.CompareTo(x.LastWriteTime));
        for (int i = 0; i < Math.Min(n, fs.Count); i++) Add(files, fs[i].FullName, into + fs[i].Name);
    }

    // The Steam names the logs hold, each with what is written in its place. Uplink's co-op lines name the player
    // himself ("ONLINE  <name> - waiting...") and his friends ("CONNECTED TO HOST  <name>", "invited <name>"...)
    static readonly Regex NAME_ME = new Regex(@"ONLINE  (.+?) - (?:opening a friends-only lobby|waiting for an invite)");
    static readonly Regex[] NAME_FRIEND = {
        new Regex(@"ONLINE  joining (.+?)\.\.\.\s*$"), new Regex(@"GUEST CONNECTED  (.+?)   "), new Regex(@"CONNECTED TO HOST  (.+?)   "),
        new Regex(@"GUEST HAS ANOTHER VERSION  (.+?): both need"), new Regex(@"GUEST JOINING  (.+?)\s*$"), new Regex(@"\] status: (.+?), "),
        new Regex(@"\] guest (.+?) said HELLO"), new Regex(@"\] invited (.+?)\s*$") };

    static List<string[]> SteamNames(List<string[]> files)
    {
        List<string[]> names = new List<string[]>();
        Action<string, bool> add = delegate(string n, bool me) {
            n = n.Trim();
            if (n.Length == 0 || names.Exists(x => x[0] == n)) return;
            names.Add(new[] { n, me ? "me" : "friend" + (names.FindAll(x => x[1] != "me").Count + 1) });
        };
        foreach (string[] f in files)
            foreach (string l in f[1].Split('\n'))
            {
                Match m = NAME_ME.Match(l);
                if (m.Success) add(m.Groups[1].Value, true);
            }
        foreach (string[] f in files)
            foreach (string raw in f[1].Split('\n'))
            {
                string l = raw.TrimEnd('\r');
                foreach (Regex r in NAME_FRIEND) { Match m = r.Match(l); if (m.Success) add(m.Groups[1].Value, false); }
            }
        names.Sort((x, y) => y[0].Length.CompareTo(x[0].Length));    // (the longest first: one name may hold another)
        return names;
    }

    // a folder of this PC, written with \ or / (or \\, as in a quoted string), whatever the case
    static string Unfold(string t, string folder, string with)
    {
        if (string.IsNullOrEmpty(folder) || folder.TrimEnd('\\').Length < 4) return t;
        return Regex.Replace(t, Regex.Escape(folder.TrimEnd('\\')).Replace(@"\\", @"[\\/]+"), with.Replace("$", "$$"), RegexOptions.IgnoreCase);
    }

    static string Scrub(string t, List<string[]> names)
    {
        List<string[]> known = new List<string[]>();
        string g = null;
        try { g = Game(); } catch { }
        if (g != null) known.Add(new[] { g, "<game " + Edition(g) + ">" });
        known.Add(new[] { GodotData, "<Uplink's settings>" });
        known.Add(new[] { Root, "<launcher>" });
        foreach (string e in new[] { "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "USERPROFILE", "OneDrive" })
            known.Add(new[] { Environment.GetEnvironmentVariable(e), "%" + e + "%" });
        known.RemoveAll(x => string.IsNullOrEmpty(x[0]));
        known.Sort((x, y) => y[0].Length.CompareTo(x[0].Length));
        foreach (string[] k in known) t = Unfold(t, k[0], k[1]);
        // any other absolute path: its last name only; and whatever still follows a "Users" folder
        t = Regex.Replace(t, @"(?i)(?<![a-z])[a-z]:[\\/]+(?:[^\\/""<>|:*?\r\n]+[\\/]+)*([^\\/""<>|:*?\s]*)", "<folder>\\$1");
        t = Regex.Replace(t, @"(?i)([\\/]Users[\\/]+)[^\\/""\s]+", "$1<user>");
        foreach (string[] n in names) t = t.Replace(n[0], n[1]);
        foreach (string[] w in new[] { new[] { Environment.UserName, "<user>" }, new[] { Environment.MachineName, "<pc>" } })
            if (!string.IsNullOrEmpty(w[0]) && w[0].Length >= 3)
                t = Regex.Replace(t, @"(?<![A-Za-z0-9])" + Regex.Escape(w[0]) + @"(?![A-Za-z0-9])", w[1], RegexOptions.IgnoreCase);
        t = Regex.Replace(t, @"(?<![0-9a-fA-F.])\d{15,20}(?![0-9])", "<id>");                 // Steam ids, lobby ids
        t = Regex.Replace(t, @"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]+", "<e-mail>");
        return t;
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
        // TN+ settings with no key in them yet: the freelook key said here, so that the game and Uplink agree whatever
        // the TN+ build. A new installation: F, and the keys' version 4 (TN+ then leaves the game's Centre view, on F,
        // without a key); an installation made before: Y, as it always was
        if (!lines.Exists(l => Regex.IsMatch(l, @"^\s*keys?_")))
        {
            lines.Add("key_freelook = " + (Cfg("keys_gen") == "2" ? "21" : "15"));
            if (Cfg("keys_gen") == "2") lines.Add("keys_version = 4");
        }
        File.WriteAllLines(ini, lines);
    }

    // ------------------------------------------------------------------ Controls: every key in one place
    // The list is Uplink's data\controls.txt, which the in-game menu's Controls page reads too (scripts\controls.gd),
    // with the same rules. The game's commands are Terra Nova Plus's (its TNPlus.ini: key_game_<id>, mouse_<id>, its
    // keys' version 4: freelook on F, Centre view without a key; settings with keys from before keep F and Y as they
    // were), written to both TN+ (SyncKeys); Uplink's own keys are this launcher's (key_<id>). A key: a PC scancode
    // (E0xx: the grey block's), modifiers 1 Shift, 2 Ctrl, 4 Alt; -1 / -2 / -3 the middle / side mouse buttons.
    class Cmd { public string Group, Id, Name, Kind, PadDef = "", Pad = ""; public int DefSc, DefMods, Sc, Mods, Mouse; }
    static List<Cmd> cmds = new List<Cmd>();
    static readonly string[] MOUSE_INI = { "", "MID", "M4", "M5", "WHEELUP", "WHEELDOWN", "PGUP", "PGDN", "HOME", "END", "INS", "DEL" };
    static readonly string[] MOUSE_SHORT = { "", "Middle", "Mouse 4", "Mouse 5", "Wheel up", "Wheel down", "PgUp", "PgDn", "Home", "End", "Ins", "Del" };
    static readonly int[] SPARE = { 0x25, 0x26, 0x27, 0x08, 0x09, 0x0A, 0x0B };
    static readonly string[] CONTROL_GROUPS = { "Move", "Fight", "View", "Squad", "Map", "Drone", "System", "Tools", "Gamepad", "Uplink" };

    static int[] KeyParse(string spec)
    {
        string s = (spec ?? "").Trim().ToUpperInvariant();
        if (s == "" || s == "-") return new[] { 0, 0 };
        if (s == "MID") return new[] { -1, 0 };
        if (s == "M4" || s == "M5") return new[] { s == "M4" ? -2 : -3, 0 };
        string[] p = s.Split('+');
        int mods = 0;
        for (int i = 0; i < p.Length - 1; i++) mods |= p[i] == "SHIFT" ? 1 : p[i] == "CTRL" ? 2 : p[i] == "ALT" ? 4 : 0;
        int sc;
        return int.TryParse(p[p.Length - 1], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out sc) ? new[] { sc, mods } : new[] { 0, 0 };
    }

    static string KeySpec(int sc, int mods)
    {
        if (sc == 0) return "";
        if (sc < 0) return new[] { "", "MID", "M4", "M5" }[-sc];
        return ((mods & 1) != 0 ? "SHIFT+" : "") + ((mods & 2) != 0 ? "CTRL+" : "") + ((mods & 4) != 0 ? "ALT+" : "") + sc.ToString(sc > 0xFF ? "X4" : "X2");
    }

    static string KeyLabel(int sc, int mods) { return sc == 0 ? "-" : KeyShort(KeySpec(sc, mods), true); }

    static Cmd FindCmd(string id) { return cmds.Find(c => c.Id == id); }

    // the list, then the player's keys: TN+'s settings read as TN+ reads them, Uplink's from this launcher's settings
    static void ControlsLoad()
    {
        cmds = new List<Cmd>();
        string list = Path.Combine(UplinkDir, "data", "controls.txt");
        if (!File.Exists(list)) return;
        foreach (string raw in File.ReadAllLines(list))
        {
            string l = raw.Trim();
            if (l == "" || l.StartsWith("#")) continue;
            string[] p = l.Split('|');
            if (p.Length < 5) continue;
            int[] d = KeyParse(p[3]);
            if (p[4] != "uplink" && d[0] >= 0x80 && d[0] < 0x100) d[0] = 0xE000 | (d[0] & 0x7F);   // (TN+'s 0x80 + code)
            string pd = p.Length > 5 ? p[5].Trim().ToUpperInvariant() : "";
            cmds.Add(new Cmd { Group = p[0], Id = p[1], Name = p[2], Kind = p[4], DefSc = d[0], DefMods = d[1], Sc = d[0], Mods = d[1], PadDef = pd, Pad = pd });
        }
        PadLoad();
        Dictionary<string, string> vals = new Dictionary<string, string>();
        string ini = KeysIni();
        int kv = 0;
        bool sawKeys = false;
        if (File.Exists(ini))
            foreach (string raw in File.ReadAllLines(ini))
            {
                string l = raw.Trim();
                int e = l.IndexOf('=');
                if (l.StartsWith(";") || e <= 0) continue;
                string k = l.Substring(0, e).Trim().ToLowerInvariant(), v = l.Substring(e + 1).Trim();
                if (k.StartsWith("key_") || k.StartsWith("keys_")) sawKeys = true;
                if (k == "keys_version") int.TryParse(v, out kv);
                vals[k] = v;
            }
        bool old = sawKeys && kv < 4;
        string got;
        foreach (Cmd c in cmds)
        {
            if (c.Kind == "game" || c.Kind == "fixed")
            {
                if (c.Id == "centre" && !old) c.DefSc = 0;
                c.Sc = c.DefSc; c.Mods = c.DefMods;
                if (c.Kind == "game" && vals.TryGetValue("key_game_" + c.Id, out got))
                {
                    int[] k = KeyParse(got);
                    if (k[0] > 0 && k[0] < 0x100 && !(c.Id == "bound" && k[1] != 0))
                    { c.Sc = k[0] >= 0x80 ? 0xE000 | (k[0] & 0x7F) : k[0]; c.Mods = (k[1] & 4) != 0 ? 4 : (k[1] & 2) != 0 ? 2 : k[1] & 1; }
                }
            }
            else if (c.Kind == "tnplus")
            {
                if (c.Id == "freelook" && old) c.DefSc = 0x15;
                c.Sc = vals.TryGetValue("key_" + c.Id, out got) ? KeyParse(got)[0] : c.DefSc;
            }
            else if (c.Kind == "uplink")
            {
                int[] k = KeyParse(c.Id == "menu" ? MenuKey() : c.Id == "order" ? OrderKey() : c.Id == "photo" ? PhotoKey() :
                    c.Id == "oldschool" ? OldKey() : c.Id == "sharp" ? SharpKey() : c.Id == "shot" ? ShotKey() : c.Id == "fps" ? FpsKey() : "");
                c.Sc = k[0]; c.Mods = k[1];
                if (c.Id == "sharp" || c.Id == "shot" || c.Id == "fps")   // (they follow the old school look's key unless set)
                {
                    Cmd o = FindCmd("oldschool");
                    bool plain = o.Mods == 0;
                    int add = c.Id == "sharp" ? 1 : c.Id == "shot" ? 2 : 3;
                    bool has = c.Id == "sharp" ? (o.Mods & 1) == 0 : plain;
                    c.DefSc = has ? o.Sc : 0; c.DefMods = has ? o.Mods | add : 0;
                }
            }
            if (c.Kind == "game" || c.Kind == "tnplus")
                c.Mouse = Math.Max(0, Array.IndexOf(MOUSE_INI, vals.TryGetValue("mouse_" + c.Id, out got) ? got.ToUpperInvariant() : ""));
        }
        // TN+'s ResolveToolClashes: a plain game key on one of its own goes to the first spare key free
        HashSet<int> tools = new HashSet<int>();
        foreach (Cmd c in cmds) if (c.Kind == "tnplus") tools.Add(c.Sc);
        foreach (Cmd c in cmds)
            if (c.Kind == "game" && c.Mods == 0 && c.Sc > 0 && c.Sc < 0x80 && tools.Contains(c.Sc))
                foreach (int f in SPARE)
                    if (!tools.Contains(f) && !cmds.Exists(o => (o.Kind == "game" || o.Kind == "fixed") && o.Sc == f && o.Mods == 0)) { c.Sc = f; break; }
    }

    // The Uplink menu's key (key_menu): F5 unless another is chosen (F10 is the game's Sensor range)
    static string MenuKey() { string k = Cfg("key_menu").ToUpperInvariant(); return KeyOk(k) && k != "" ? k : "3F"; }

    // commands sharing a key (not the game's fixed keys, nor two both as they come: Uplink's F12 is the game's Mission
    // info on purpose)
    static Dictionary<string, string> Conflicts()
    {
        Dictionary<string, string> o = new Dictionary<string, string>();
        foreach (Cmd a in cmds)
        {
            if (a.Kind == "fixed" || a.Sc == 0) continue;
            foreach (Cmd b in cmds)
                if (b != a && b.Kind != "fixed" && b.Sc == a.Sc && b.Mods == a.Mods && !(a.Sc == a.DefSc && a.Mods == a.DefMods && b.Sc == b.DefSc && b.Mods == b.DefMods))
                    o[a.Id] = b.Name;
        }
        return o;
    }

    // TN+'s settings: the game's keys not as they come (version 4), its own keys, the second binds; then the co-op build's
    static void ControlsSave()
    {
        string ini = Path.Combine(TnpDir, "TNPlus.ini");
        if (!File.Exists(ini) && File.Exists(KeysIni())) ini = KeysIni();
        List<string> lines = File.Exists(ini) ? new List<string>(File.ReadAllLines(ini)) : new List<string> { "; Terra Nova Plus settings (written by Terra Nova Uplink)" };
        lines.RemoveAll(l => { string t = l.Trim().ToLowerInvariant(); return t.StartsWith("key_game_") || t.StartsWith("mouse_") || t.StartsWith("keys_version") ||
            t.StartsWith("key_freelook") || t.StartsWith("key_noclip") || t.StartsWith("key_distance") || t.StartsWith("key_stereo"); });
        foreach (Cmd c in cmds) if (c.Kind == "tnplus") lines.Add("key_" + c.Id + " = " + c.Sc.ToString("X2"));
        lines.Add("keys_version = 4");
        foreach (Cmd c in cmds)
        {
            if (c.Kind != "game") continue;
            int ds = c.Id == "centre" ? 0 : c.DefSc, dm = c.Id == "centre" ? 0 : c.DefMods;
            if (c.Sc == ds && c.Mods == dm) continue;
            int code = c.Sc >= 0xE000 ? 0x80 | (c.Sc & 0x7F) : c.Sc;
            lines.Add("key_game_" + c.Id + " = " + ((c.Mods & 4) != 0 ? "ALT+" : (c.Mods & 2) != 0 ? "CTRL+" : (c.Mods & 1) != 0 ? "SHIFT+" : "") + code.ToString("X2"));
        }
        foreach (Cmd c in cmds) if (c.Mouse > 0) lines.Add("mouse_" + c.Id + " = " + MOUSE_INI[c.Mouse]);
        try { Directory.CreateDirectory(Path.GetDirectoryName(ini)); File.WriteAllLines(ini, lines); } catch (Exception e) { Status("The keys could not be saved: " + e.Message, CRed); return; }
        if (ini.StartsWith(TnpDir, StringComparison.OrdinalIgnoreCase)) SyncKeys();
        foreach (Cmd c in cmds)
            if (c.Kind == "uplink")
                Set("key_" + c.Id, c.Sc == c.DefSc && c.Mods == c.DefMods ? "" : KeySpec(c.Sc, c.Mods));
        SaveCfg();
        KeyLabels();
    }

    static KeyList keyList;
    static Switch padBox2;                               // the Co-op page's Gamepad switch, here too
    static TextBox keySearch;

    static void BuildControls(Surface pg)
    {
        pg.Look = delegate(Graphics g) {
            g.Clear(CBack);
            Spaced(g, "CONTROLS", F14s, COrange, 18, 18, 1.2f);
            Str(g, "KEY", F10b, CDim, 18 + 262, 52); Str(g, "MOUSE", F10b, CDim, 18 + 370, 52); Str(g, "GAMEPAD", F10b, CDim, 18 + 466, 52);
        };
        padBox2 = new Switch { Text = "Gamepad", F = F12, Location = new Point(150, 13), Size = new Size(130, 28) };
        padBox2.CheckedChanged += delegate { if (padBox != null && padBox.Checked != padBox2.Checked) padBox.Checked = padBox2.Checked; };
        pg.Controls.Add(padBox2);
        keySearch = new TextBox { Location = new Point(MW - 18 - 220, 14), Size = new Size(220, 24), BackColor = CButton, ForeColor = CText,
            BorderStyle = BorderStyle.FixedSingle, Font = F12 };
        keySearch.TextChanged += delegate { keyList.Filter = keySearch.Text; keyList.Top0 = 0; keyList.Invalidate(); };
        pg.Controls.Add(keySearch);
        pg.Controls.Add(new Txt { Text = "Search", F = F11, Ink = CDim, Location = new Point(MW - 18 - 220 - 50, 16), Size = new Size(48, 20) });
        keyList = new KeyList { Text = "Keys", Location = new Point(18, 68), Size = new Size(MW - 36, 350) };
        pg.Controls.Add(keyList);
        pg.Controls.Add(new Txt { Text = "Keys are places on the keyboard (shown with your keyboard's letters). The game's keys change at the next",
            F = F11, Ink = CDim, Location = new Point(18, 424), Size = new Size(MW - 36, 16) });
        pg.Controls.Add(new Txt { Text = "start of the game, Uplink's at the next start of Uplink (in game: its menu's Controls, at once).",
            F = F11, Ink = CDim, Location = new Point(18, 440), Size = new Size(MW - 36, 16) });
        Btn reset = Key(pg, 18, 460, 170, 28, "Reset to defaults");
        reset.Click += delegate {
            if (!Ask("Put every key back as it comes (freelook on F, Centre view without a key)?")) return;
            foreach (Cmd c in cmds) { c.Sc = c.Id == "centre" ? 0 : c.Id == "freelook" ? 0x21 : c.DefSc; c.Mods = c.Id == "centre" || c.Id == "freelook" ? 0 : c.DefMods; c.Mouse = 0; c.Pad = c.PadDef; }
            padSticks = new Dictionary<string, string>();
            ControlsSave(); PadSave(); keyList.Invalidate(); Status("Every key is as it comes.", CGreen);
        };
        Btn sticks = Key(pg, 18 + 178, 460, 150, 28, "Gamepad sticks...");
        sticks.Click += delegate { using (PadSticks d = new PadSticks()) d.ShowDialog(form); };
        Btn adv = Key(pg, MW - 18 - 190, 460, 190, 28, "Advanced (Terra Nova Plus)...");
        adv.Click += delegate { GameKeys(); };
    }

    // a key asked for, for a command
    static void AskControl(Cmd c)
    {
        using (KeyAsk d = c.Id == "order" ? new KeyAsk(c.Name.ToLowerInvariant(), KeyLabel(c.Sc, c.Mods), true) : new KeyAsk(c.Name.ToLowerInvariant(), KeyLabel(c.Sc, c.Mods)))
        {
            if (d.ShowDialog(form) != DialogResult.OK) return;
            int[] k = d.Spec == "" ? new[] { c.DefSc, c.DefMods } : KeyParse(d.Spec);
            if (c.Kind == "game" && (k[1] & 4) != 0) k[1] = 4;                      // (the game takes one modifier)
            else if (c.Kind == "game" && (k[1] & 2) != 0) k[1] = 2;
            if (c.Kind == "tnplus") k[1] = 0;
            if (c.Kind != "uplink" && k[0] >= 0xE000 && Array.IndexOf(new[] { 0x47, 0x49, 0x4F, 0x51, 0x52, 0x53 }, k[0] & 0xFF) >= 0 && c.Kind == "tnplus")
            { Status("PgUp / PgDn, Home / End, Ins / Del go in the MOUSE column, as a second bind.", CAmber); return; }
            c.Sc = k[0]; c.Mods = k[1];
            ControlsSave();
            string clash;
            Status(c.Name + ": " + KeyLabel(c.Sc, c.Mods) + (Conflicts().TryGetValue(c.Id, out clash) ? ". Also the key of " + clash + "." : "."),
                Conflicts().ContainsKey(c.Id) ? CAmber : CGreen);
        }
        keyList.Invalidate();
    }

    static void AskMouse(Cmd c, Control at, Point p)
    {
        ContextMenuStrip m = Menu();
        for (int i = 0; i < MOUSE_SHORT.Length; i++)
        {
            int k = i;
            ToolStripItem it = m.Items.Add(i == 0 ? "None" : MOUSE_SHORT[i], null, delegate {
                foreach (Cmd o in cmds) if (k != 0 && o.Mouse == k) o.Mouse = 0;
                c.Mouse = k; ControlsSave(); keyList.Invalidate();
            });
            if (i == c.Mouse) it.Font = new Font(it.Font, FontStyle.Bold);
        }
        m.Show(at, p);
    }

    // ------------------------------------------------------------------ the gamepad
    // Uplink reads it (scripts\pad_map.gd), solo, host and co-op guest alike: a button presses the command's key as the
    // player has it, the sticks move and look (the guest's go to the host as his gamepad). The list's sixth column is the
    // binding as it comes; the player's are in Uplink's viewer.cfg, [gamepad] (bind_<id> = "B3" / "A5+" / "": none, and
    // the sticks' settings), which Uplink reads as it starts and its in-game Controls page writes: one place for both.
    // Godot's numbers: B0 A, B1 B, B2 X, B3 Y, B4 Back, B6 Start, B7 / B8 the sticks pressed, B9 LB, B10 RB, B11-B14 the
    // D-pad; A0 / A1 left stick, A2 / A3 right stick, A4 LT, A5 RT.
    static Dictionary<string, string> padSticks = new Dictionary<string, string>();     // sens_x, sens_y, invert_y, dead, swap, trigger
    static readonly string[] PAD_STICK_KEYS = { "sens_x", "sens_y", "invert_y", "dead", "swap", "trigger" };
    static readonly string[] PAD_STICK_DEF = { "1.0", "1.0", "false", "0.2", "false", "0.25" };

    static bool PadOk(Cmd c) { return c.Kind == "game" || c.Kind == "pad" || c.Kind == "uplink" || c.Kind == "tnplus"; }

    static string PadName(string s)
    {
        s = (s ?? "").Trim().ToUpperInvariant();
        if (s == "") return "-";
        if (s == "A4+") return "LT";
        if (s == "A5+") return "RT";
        string[] ax = { "A0-", "Left stick left", "A0+", "Left stick right", "A1-", "Left stick up", "A1+", "Left stick down",
            "A2-", "Right stick left", "A2+", "Right stick right", "A3-", "Right stick up", "A3+", "Right stick down" };
        for (int i = 0; i < ax.Length; i += 2) if (ax[i] == s) return ax[i + 1];
        string[] bn = { "A", "B", "X", "Y", "Back", "Guide", "Start", "Left stick press", "Right stick press", "LB", "RB",
            "D-pad up", "D-pad down", "D-pad left", "D-pad right" };
        int b;
        if (s.StartsWith("B") && int.TryParse(s.Substring(1), out b)) return b >= 0 && b < bn.Length ? bn[b] : "Button " + b;
        return s;
    }

    static Dictionary<string, string> PadConflicts()
    {
        Dictionary<string, string> o = new Dictionary<string, string>();
        foreach (Cmd a in cmds)
            if (PadOk(a) && a.Pad != "")
                foreach (Cmd b in cmds) if (b != a && PadOk(b) && b.Pad == a.Pad) o[a.Id] = b.Name;
        return o;
    }

    static void PadLoad()
    {
        padSticks = new Dictionary<string, string>();
        try
        {
            if (!File.Exists(ViewerCfg)) return;
            bool sec = false;
            foreach (string raw in File.ReadAllLines(ViewerCfg))
            {
                string l = raw.Trim();
                if (l.StartsWith("[")) { sec = l == "[gamepad]"; continue; }
                int e = l.IndexOf('=');
                if (!sec || e <= 0) continue;
                string k = l.Substring(0, e).Trim(), v = l.Substring(e + 1).Trim().Trim('"');
                if (k.StartsWith("bind_")) { Cmd c = FindCmd(k.Substring(5)); if (c != null && PadOk(c)) c.Pad = v.ToUpperInvariant(); }
                else if (Array.IndexOf(PAD_STICK_KEYS, k) >= 0) padSticks[k] = v;
            }
        }
        catch { }
    }

    static string PadStick(string k) { string v; return padSticks.TryGetValue(k, out v) ? v : PAD_STICK_DEF[Array.IndexOf(PAD_STICK_KEYS, k)]; }

    // the [gamepad] section written again (the rest of viewer.cfg kept)
    static void PadSave()
    {
        try
        {
            List<string> keep = new List<string>();
            if (File.Exists(ViewerCfg))
            {
                bool sec = false;
                foreach (string raw in File.ReadAllLines(ViewerCfg))
                {
                    string l = raw.Trim();
                    if (l.StartsWith("[")) sec = l == "[gamepad]";
                    if (!sec) keep.Add(raw);
                }
            }
            while (keep.Count > 0 && keep[keep.Count - 1].Trim() == "") keep.RemoveAt(keep.Count - 1);
            List<string> mine = new List<string>();
            foreach (Cmd c in cmds) if (PadOk(c) && c.Pad != c.PadDef) mine.Add("bind_" + c.Id + "=\"" + c.Pad + "\"");
            for (int i = 0; i < PAD_STICK_KEYS.Length; i++)
            {
                string v = PadStick(PAD_STICK_KEYS[i]);
                if (v != PAD_STICK_DEF[i]) mine.Add(PAD_STICK_KEYS[i] + "=" + v);
            }
            if (mine.Count > 0) { if (keep.Count > 0) keep.Add(""); keep.Add("[gamepad]"); keep.Add(""); keep.AddRange(mine); }
            Directory.CreateDirectory(GodotData);
            File.WriteAllText(ViewerCfg, string.Join("\n", keep.ToArray()) + "\n");
        }
        catch (Exception e) { Status("The gamepad settings could not be saved: " + e.Message, CRed); }
    }

    static void AskPad(Cmd c)
    {
        using (PadAsk d = new PadAsk(c.Name.ToLowerInvariant(), PadName(c.Pad)))
        {
            if (d.ShowDialog(form) != DialogResult.OK) return;
            c.Pad = d.Spec;
            PadSave();
            string clash;
            bool bad = PadConflicts().TryGetValue(c.Id, out clash);
            Status(c.Name + " (gamepad): " + PadName(c.Pad) + (bad ? ". Also on " + clash + ": change one of them." : "."), bad ? CAmber : CGreen);
        }
        keyList.Invalidate();
    }

    [StructLayout(LayoutKind.Sequential)]
    struct XState { public uint Packet; public ushort Buttons; public byte LT, RT; public short LX, LY, RX, RY; }
    [DllImport("xinput1_4.dll", EntryPoint = "XInputGetState")] static extern int XInputGetState(int user, out XState s);

    // what is pressed on the first XInput pad, as Godot names it (B<n>, A<n>+/-); checks: TN_TEST_PAD_INPUT after 1 s
    static HashSet<string> PadNow(DateTime since)
    {
        HashSet<string> o = new HashSet<string>();
        string test = Environment.GetEnvironmentVariable("TN_TEST_PAD_INPUT");
        if (test != null) { if ((DateTime.Now - since).TotalSeconds > 1.0 && test != "") o.Add(test.ToUpperInvariant()); return o; }
        XState s;
        try { if (XInputGetState(0, out s) != 0) return o; } catch { return o; }
        int[,] map = { { 0x1000, 0 }, { 0x2000, 1 }, { 0x4000, 2 }, { 0x8000, 3 }, { 0x20, 4 }, { 0x10, 6 }, { 0x40, 7 }, { 0x80, 8 },
            { 0x100, 9 }, { 0x200, 10 }, { 0x1, 11 }, { 0x2, 12 }, { 0x4, 13 }, { 0x8, 14 } };
        for (int i = 0; i < map.GetLength(0); i++) if ((s.Buttons & map[i, 0]) != 0) o.Add("B" + map[i, 1]);
        if (s.LT > 153) o.Add("A4+");
        if (s.RT > 153) o.Add("A5+");
        const int th = 19660;                                  // (0.6 of the way)
        if (s.LX > th) o.Add("A0+"); if (s.LX < -th) o.Add("A0-");
        if (s.LY > th) o.Add("A1-"); if (s.LY < -th) o.Add("A1+");    // (XInput: up positive; Godot: up negative)
        if (s.RX > th) o.Add("A2+"); if (s.RX < -th) o.Add("A2-");
        if (s.RY > th) o.Add("A3-"); if (s.RY < -th) o.Add("A3+");
        return o;
    }

    // a gamepad input asked for: the first one pressed that was not already held when the window opened
    class PadAsk : Form
    {
        public string Spec;
        System.Windows.Forms.Timer poll;
        HashSet<string> held;
        DateTime t0 = DateTime.Now;
        public PadAsk(string what, string now)
        {
            Text = "Gamepad"; ClientSize = new Size(440, 150); FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false; StartPosition = FormStartPosition.CenterParent; BackColor = CBack; ForeColor = CText;
            Font = form.Font; ShowInTaskbar = false; KeyPreview = true;
            Controls.Add(new Label { Text = "Press a button on the gamepad for " + what + ".", Location = new Point(16, 18), Size = new Size(408, 22),
                Font = Px(14f, 600), ForeColor = CAmber });
            Controls.Add(new Label { Text = "Now: " + now + ".  A button, a trigger, or a stick pushed far.", Location = new Point(16, 48), Size = new Size(408, 20) });
            Controls.Add(new Label { Text = "Esc: change nothing.    Del: none.", Location = new Point(16, 72), Size = new Size(408, 20), ForeColor = CDim });
            held = PadNow(t0);
            poll = new System.Windows.Forms.Timer { Interval = 25 };
            poll.Tick += delegate {
                HashSet<string> n = PadNow(t0);
                foreach (string s in n) if (!held.Contains(s)) { poll.Stop(); Spec = s; DialogResult = DialogResult.OK; return; }
                held.IntersectWith(n);                           // (let go: it may be pressed again)
            };
            poll.Start();
        }
        protected override void OnLoad(EventArgs e) { Dpi(this); base.OnLoad(e); }
        protected override void OnFormClosed(FormClosedEventArgs e) { poll.Stop(); poll.Dispose(); base.OnFormClosed(e); }
        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Escape) { DialogResult = DialogResult.Cancel; return true; }
            if (keyData == Keys.Delete || keyData == Keys.Back) { Spec = ""; DialogResult = DialogResult.OK; return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }
    }

    // the sticks: how fast the look stick turns, up / down inverted, the dead zone, which stick moves, the triggers
    class PadSticks : Form
    {
        public PadSticks()
        {
            Text = "Gamepad sticks"; ClientSize = new Size(440, 330); FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false; StartPosition = FormStartPosition.CenterParent; BackColor = CBack; ForeColor = CText;
            Font = form.Font; ShowInTaskbar = false;
            Controls.Add(new Label { Text = "Gamepad sticks", Location = new Point(16, 14), Size = new Size(408, 22), Font = Px(14f, 600), ForeColor = CAmber });
            int y = 46;
            Slide("Look speed, left / right", "sens_x", 25, 200, 100f, ref y);
            Slide("Look speed, up / down", "sens_y", 25, 200, 100f, ref y);
            Slide("Dead zone", "dead", 0, 60, 100f, ref y);
            Slide("Trigger threshold", "trigger", 5, 95, 100f, ref y);
            Check("Look up / down inverted", "invert_y", ref y);
            Check("Swap the sticks (right stick moves, left looks)", "swap", ref y);
            Button ok = new Button { Text = "Close", Location = new Point(440 - 16 - 100, y + 6), Size = new Size(100, 28), FlatStyle = FlatStyle.Flat, BackColor = CButton };
            ok.Click += delegate { Close(); };
            Controls.Add(ok);
            CancelButton = ok;
        }
        void Slide(string text, string key, int lo, int hi, float scale, ref int y)
        {
            Controls.Add(new Label { Text = text, Location = new Point(16, y + 6), Size = new Size(170, 20) });
            float v;
            float.TryParse(PadStick(key), NumberStyles.Float, CultureInfo.InvariantCulture, out v);
            TrackBar tb = new TrackBar { Minimum = lo, Maximum = hi, Value = Math.Max(lo, Math.Min(hi, (int)Math.Round(v * scale))), TickStyle = TickStyle.None,
                Location = new Point(190, y), Size = new Size(180, 30), Name = "pad_" + key };
            Label n = new Label { Text = (tb.Value / scale).ToString("0.00", CultureInfo.InvariantCulture), Location = new Point(376, y + 6), Size = new Size(50, 20), ForeColor = CDim };
            tb.ValueChanged += delegate {
                padSticks[key] = (tb.Value / scale).ToString("0.0#", CultureInfo.InvariantCulture);
                n.Text = (tb.Value / scale).ToString("0.00", CultureInfo.InvariantCulture);
                PadSave();
            };
            Controls.Add(tb); Controls.Add(n);
            y += 36;
        }
        void Check(string text, string key, ref int y)
        {
            CheckBox c = new CheckBox { Text = text, Checked = PadStick(key) == "true", Location = new Point(16, y + 2), Size = new Size(408, 24), Name = "pad_" + key };
            c.CheckedChanged += delegate { padSticks[key] = c.Checked ? "true" : "false"; PadSave(); };
            Controls.Add(c);
            y += 30;
        }
        protected override void OnLoad(EventArgs e) { Dpi(this); base.OnLoad(e); }
    }


    // the list: group names, then per command its name, its key, its second bind; the mouse wheel scrolls it
    class KeyList : Drawn
    {
        public string Filter = "";
        public int Top0;
        int hotRow = -1, hotCol = -1;
        const int RH = 25;
        public KeyList() : base(true) { }
        List<object> Rows()
        {
            List<object> l = new List<object>();
            string q = (Filter ?? "").Trim().ToLowerInvariant();
            foreach (string g in CONTROL_GROUPS)
            {
                bool any = false;
                foreach (Cmd c in cmds)
                {
                    if (c.Group != g || (q != "" && c.Name.ToLowerInvariant().IndexOf(q) < 0 && g.ToLowerInvariant().IndexOf(q) < 0)) continue;
                    if (!any) { l.Add(g); any = true; }
                    l.Add(c);
                }
            }
            return l;
        }
        int Fits { get { return (int)(H / RH); } }
        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            Top0 = Math.Max(0, Math.Min(Rows().Count - Fits, Top0 - Math.Sign(e.Delta) * 3));
            Invalidate();
        }
        protected override bool IsInputKey(Keys k) { return k == Keys.Up || k == Keys.Down || k == Keys.PageUp || k == Keys.PageDown || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            int n = e.KeyCode == Keys.Down ? 1 : e.KeyCode == Keys.Up ? -1 : e.KeyCode == Keys.PageDown ? Fits : e.KeyCode == Keys.PageUp ? -Fits : 0;
            if (n != 0) { Top0 = Math.Max(0, Math.Min(Rows().Count - Fits, Top0 + n)); Invalidate(); }
        }
        void Hit(MouseEventArgs e, out int row, out int col)
        {
            float x = e.X / K, y = e.Y / K;
            row = Top0 + (int)(y / RH);
            col = x >= 254 && x < 356 ? 1 : x >= 362 && x < 450 ? 2 : x >= 456 && x < 572 ? 3 : 0;
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int r, c; Hit(e, out r, out c);
            if (r != hotRow || c != hotCol) { hotRow = r; hotCol = c; Invalidate(); }
        }
        protected override void OnMouseLeave(EventArgs e) { hotRow = hotCol = -1; base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            int r, col; Hit(e, out r, out col);
            List<object> rows = Rows();
            Cmd c = r >= 0 && r < rows.Count ? rows[r] as Cmd : null;
            if (c == null || c.Kind == "fixed" || e.Button != MouseButtons.Left) return;
            if (col == 1 && c.Kind != "pad") AskControl(c);
            else if (col == 2 && (c.Kind == "game" || c.Kind == "tnplus")) AskMouse(c, this, e.Location);
            else if (col == 3 && PadOk(c)) AskPad(c);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            List<object> rows = Rows();
            Dictionary<string, string> clash = Conflicts(), pclash = PadConflicts();
            if (cmds.Count == 0) { Str(g, "The list comes with Uplink: start once (PLAY or MAP VIEWER) so that it is installed.", F12, CDim, 0, 6); return; }
            for (int i = 0; i < Fits && Top0 + i < rows.Count; i++)
            {
                float y = i * RH;
                string grp = rows[Top0 + i] as string;
                if (grp != null) { Spaced(g, grp.ToUpperInvariant(), F10b, grp == "Uplink" ? CBlue : COrange, 2, y + 8, 1.2f); continue; }
                Cmd c = (Cmd)rows[Top0 + i];
                string cl, pcl;
                bool bad = clash.TryGetValue(c.Id, out cl), pbad = pclash.TryGetValue(c.Id, out pcl);
                StrIn(g, c.Name + (bad ? "   (also " + cl + ")" : pbad ? "   (pad: also " + pcl + ")" : ""), F12, bad || pbad ? CRed : c.Kind == "fixed" ? CDim : CText,
                    new RectangleF(10, y, 240, RH), TFLeft);
                bool hot = Top0 + i == hotRow;
                if (c.Kind != "pad")
                    DrawBox(g, new RectangleF(254, y + 2, 102, RH - 4), KeyLabel(c.Sc, c.Mods), c.Kind == "fixed" ? CDim : c.Sc != c.DefSc || c.Mods != c.DefMods ? COrange : CText,
                        hot && hotCol == 1 && c.Kind != "fixed", c.Kind == "fixed");
                if (c.Kind == "game" || c.Kind == "tnplus")
                    DrawBox(g, new RectangleF(362, y + 2, 88, RH - 4), c.Mouse > 0 ? MOUSE_SHORT[c.Mouse] : "+", c.Mouse > 0 ? CText : CDim, hot && hotCol == 2, false);
                if (PadOk(c))
                    DrawBox(g, new RectangleF(456, y + 2, 116, RH - 4), c.Pad != "" ? PadName(c.Pad) : "+", pbad ? CRed : c.Pad != c.PadDef ? COrange : c.Pad != "" ? CText : CDim,
                        hot && hotCol == 3, false);
            }
            if (rows.Count > Fits)                       // where in the list
            {
                float h = H * Fits / rows.Count, y = (H - h) * Top0 / Math.Max(1, rows.Count - Fits);
                using (Brush b = new SolidBrush(CButtonLine)) g.FillRectangle(b, W - 4, y, 3, h);
            }
        }
        static void DrawBox(Graphics g, RectangleF r, string t, Color ink, bool hot, bool off)
        {
            using (GraphicsPath p = Round(r, 4))
            {
                using (Brush b = new SolidBrush(off ? CBack : hot ? Mix(CButton, Color.White, 0.08f) : CButton)) g.FillPath(b, p);
                using (Pen l = new Pen(hot ? Mix(CButtonLine, Color.White, 0.3f) : CButtonLine)) g.DrawPath(l, p);
            }
            StrIn(g, t, F11, ink, r, TFMid);
        }
    }

    // What the in-game menu changed (its Options, its Controls page's Uplink keys): kept in Uplink's viewer.cfg,
    // [launcher], with the time; taken over here when newer than what this launcher last took (at start, and each
    // time its window comes to the front), and given to Uplink at the next start
    static void AdoptNow()
    {
        if (!AdoptGameSettings() || sizeBox == null) return;
        bool was = loading; loading = true; LoadOptions(); loading = was; KeyLabels();
    }

    static bool AdoptGameSettings()
    {
        Dictionary<string, string> s = new Dictionary<string, string>();
        try
        {
            string f = Path.Combine(GodotData, "viewer.cfg");
            if (!File.Exists(f)) return false;
            bool sec = false;
            foreach (string raw in File.ReadAllLines(f))
            {
                string l = raw.Trim();
                if (l.StartsWith("[")) { sec = l == "[launcher]"; continue; }
                int e = l.IndexOf('=');
                if (sec && e > 0) s[l.Substring(0, e).Trim()] = l.Substring(e + 1).Trim().Trim('"');
            }
        }
        catch { return false; }
        long stamp, had;
        string st;
        if (!s.TryGetValue("stamp", out st) || !long.TryParse(st, out stamp) || (long.TryParse(Cfg("game_stamp"), out had) && had >= stamp)) return false;
        string[] allowed = { "mouse", "old_school", "fx_marks", "fx_lights", "fx_cloud_shadows", "fx_look_down", "fx_cliffs", "fx_stars", "fx_tracks",
            "key_menu", "key_order", "key_photo", "key_oldschool", "key_sharp", "key_shot", "key_fps" };
        foreach (string k in allowed)
        {
            string v;
            if (!s.TryGetValue(k, out v)) continue;
            if (k.StartsWith("key_") && v != "" && !KeyOk(v.ToUpperInvariant()) && v != "MID" && v != "M4" && v != "M5") continue;
            Set(k, v);
        }
        Set("game_stamp", stamp.ToString());
        SaveCfg();
        Log("settings changed in Uplink's menu taken over");
        return true;
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
                Missing("Terra Nova Plus");
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

    // TN+'s freelook key (key_freelook, a PC scancode): in Uplink it gives the game's cursor and takes the mouse back.
    // Uplink is told which (TN_KEY_FREELOOK); the status line names it as this keyboard prints it. Where no TN+
    // settings say (a guest who only joins): F on a new installation, Y on one made before (keys_gen)
    static int FreelookScan()
    {
        string ini = KeysIni();
        if (File.Exists(ini))
            foreach (string l in File.ReadAllLines(ini))
            {
                Match m = Regex.Match(l, @"^\s*key_freelook\s*=\s*([0-9A-Fa-f]{1,2})\s*$");
                if (m.Success) return Convert.ToInt32(m.Groups[1].Value, 16);
            }
        return Cfg("keys_gen") == "2" ? 0x21 : 0x15;
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

    // The order wheel's button (key_order in the ini): the middle mouse button unless another is chosen, a side button
    // (MID, M4, M5) or a key, written as the other keys
    static string OrderKey()
    {
        string k = Cfg("key_order").ToUpperInvariant();
        return k == "M4" || k == "M5" || (KeyOk(k) && k != "") ? k : "MID";
    }

    // The photo mode's key (key_photo in the ini): L unless another is chosen, written as the other keys. O (18) was
    // the first default, but O is the game's own Options key: a saved "18" is taken as L too
    static string PhotoKey()
    {
        string k = Cfg("key_photo").ToUpperInvariant();
        return KeyOk(k) && k != "" && k != "18" ? k : "26";
    }

    // "SHIFT+58" -> "Shift+F12", the key named as this keyboard prints it
    static string KeyName(string spec)
    {
        if (spec == "") return "no key";
        if (spec == "MID") return "Middle mouse button";
        if (spec == "M4" || spec == "M5") return "Mouse button " + spec.Substring(1);
        string[] p = spec.Split('+');
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < p.Length - 1; i++) sb.Append(p[i].Substring(0, 1) + p[i].Substring(1).ToLowerInvariant() + "+");
        return sb + ScanName(Convert.ToInt32(p[p.Length - 1], 16));
    }

    // the same, short, for a key's button: "Shift+F12", "Ctrl + F12", "Middle mouse"
    static string KeyShort(string spec, bool tight)
    {
        if (spec == "") return "None";
        if (spec == "MID") return "Middle mouse";
        if (spec == "M4" || spec == "M5") return "Mouse " + spec.Substring(1);
        string[] p = spec.Split('+');
        for (int i = 0; i < p.Length - 1; i++) p[i] = p[i].Substring(0, 1) + p[i].Substring(1).ToLowerInvariant();
        p[p.Length - 1] = ScanName(Convert.ToInt32(p[p.Length - 1], 16));
        return string.Join(tight ? "+" : " + ", p);
    }

    static void KeyLabels()
    {
        oldKeyBtn.Text = KeyShort(OldKey(), true);
        sharpKeyBtn.Text = KeyShort(SharpKey(), true);
        fpsBox.Em = FpsKey() != "" ? KeyShort(FpsKey(), true) : null;      // (the counter's own key in game, next to its switch)
        fpsBox.Invalidate();
        wheelKeyBtn.Text = KeyShort(OrderKey(), false);
        photoKeyBtn.Text = KeyShort(PhotoKey(), false);
        shotKeyBtn.Text = KeyShort(ShotKey(), false);
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

    static void AskOrderKey()
    {
        using (KeyAsk d = new KeyAsk("the order wheel", KeyName(OrderKey()), true))
        {
            if (d.ShowDialog(form) != DialogResult.OK) return;
            string spec = d.Spec;                             // ("": the middle button it came with)
            if (spec != "" && (spec == OldKey() || spec == SharpKey() || spec == ShotKey() || spec == FpsKey() || spec == PhotoKey()))
            { Status(KeyName(spec) + " is already one of Uplink's keys.", CAmber); return; }
            if (spec == FreelookScan().ToString("X2") || spec == "45")
            { Status(KeyName(spec) + " already swaps the look and the game's cursor.", CAmber); return; }
            Set("key_order", spec);
            SaveCfg();
            KeyLabels();
            string game = spec != "" && spec.IndexOf('+') < 0 && spec[0] != 'M' ? GameUses(Convert.ToInt32(spec, 16)) : null;
            Status("Order wheel: " + KeyName(OrderKey()) + " (from the next time Uplink starts)." +
                (game != null ? " " + KeyName(spec) + " is one of the game's keys too (" + game + "): the game will not get it while the wheel is on." : ""),
                game != null ? CAmber : CGreen);
        }
    }

    static void AskPhotoKey()
    {
        using (KeyAsk d = new KeyAsk("the photo mode", KeyName(PhotoKey())))
        {
            if (d.ShowDialog(form) != DialogResult.OK) return;
            string spec = d.Spec;                             // ("": L, the key it came with)
            string now = spec == "" ? "18" : spec;
            if (now == OldKey() || now == SharpKey() || now == ShotKey() || now == FpsKey() || now == OrderKey())
            { Status(KeyName(now) + " is already one of Uplink's keys.", CAmber); return; }
            if (now == FreelookScan().ToString("X2") || now == "45")
            { Status(KeyName(now) + " already swaps the look and the game's cursor.", CAmber); return; }
            Set("key_photo", spec);
            SaveCfg();
            KeyLabels();
            string game = now.IndexOf('+') < 0 ? GameUses(Convert.ToInt32(now, 16)) : null;
            Status("Photo mode: " + KeyName(PhotoKey()) + " (from the next time Uplink starts)." +
                (game != null ? " " + KeyName(now) + " is one of the game's keys too (" + game + "): the game will not get it in a mission any more." : ""),
                game != null ? CAmber : CGreen);
        }
    }

    // The screenshot's key (key_shot in the ini): Ctrl with the look's key unless another is chosen
    static void AskShotKey()
    {
        using (KeyAsk d = new KeyAsk("a screenshot", KeyName(ShotKey())))
        {
            if (d.ShowDialog(form) != DialogResult.OK) return;
            string spec = d.Spec;                             // ("": Ctrl with the look's key, as it came)
            if (spec != "" && (spec == OldKey() || spec == SharpKey() || spec == FpsKey() || spec == PhotoKey() || spec == OrderKey()))
            { Status(KeyName(spec) + " is already one of Uplink's keys.", CAmber); return; }
            if (spec == FreelookScan().ToString("X2") || spec == "45")
            { Status(KeyName(spec) + " already swaps the look and the game's cursor.", CAmber); return; }
            Set("key_shot", spec);
            SaveCfg();
            KeyLabels();
            string game = spec != "" && spec.IndexOf('+') < 0 ? GameUses(Convert.ToInt32(spec, 16)) : null;
            Status("Screenshot: " + KeyName(ShotKey()) + " (from the next time Uplink starts)." +
                (game != null ? " " + KeyName(spec) + " is one of the game's keys too (" + game + "): the game will not get it any more." : ""),
                game != null ? CAmber : CGreen);
        }
    }

    // "Press a key": the next key pressed, with the Shift, Ctrl or Alt held (Esc: nothing changed, Del: as it came)
    class KeyAsk : Form
    {
        public string Spec;
        Label note;
        bool mouse;                                           // the middle and side mouse buttons can be given too
        public KeyAsk(string what, string now, bool mouse) : this(what, now)
        {
            this.mouse = mouse;
            ClientSize = new Size(500, 150);
            foreach (Control c in Controls)
            {
                c.Width = 468;
                if (c.Text.StartsWith("Now: ")) c.Text = "Now: " + now + ".  A key, or the middle or a side mouse button.";
                c.MouseDown += delegate(object s, MouseEventArgs e) { OnMouseDown(e); };
            }
        }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (!mouse) return;
            string b = e.Button == MouseButtons.Middle ? "MID" : e.Button == MouseButtons.XButton1 ? "M4" : e.Button == MouseButtons.XButton2 ? "M5" : null;
            if (b == null) return;
            Spec = b; DialogResult = DialogResult.OK;
        }
        public KeyAsk(string what, string now)
        {
            Text = "Uplink's keys"; ClientSize = new Size(420, 150); FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false; StartPosition = FormStartPosition.CenterParent; BackColor = CBack; ForeColor = CText;
            Font = form.Font; ShowInTaskbar = false; KeyPreview = true;
            Controls.Add(new Label { Text = "Press the key for " + what + ".", Location = new Point(16, 18), Size = new Size(388, 22),
                Font = Px(14f, 600), ForeColor = CAmber });
            Controls.Add(new Label { Text = "Now: " + now + ".  Alone, or with Shift, Ctrl or Alt held.", Location = new Point(16, 48), Size = new Size(388, 20) });
            Controls.Add(new Label { Text = "Esc: change nothing.    Del: the key it came with.", Location = new Point(16, 72), Size = new Size(388, 20), ForeColor = CDim });
            note = new Label { Location = new Point(16, 108), Size = new Size(388, 20), ForeColor = CRed };
            Controls.Add(note);
        }
        protected override void OnLoad(EventArgs e) { Dpi(this); base.OnLoad(e); }
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
            Missing("Uplink");
            Status("Downloading Uplink...", CAmber);
            Repo(UPLINK_REPO, UPLINK_BRANCH, UplinkDir);
            if (up != null) Set("uplink_sha", up);
            SaveCfg();
        }
        SelfUpdate();
        if (!File.Exists(GodotExe))
        {
            Missing("Godot " + GODOT_VER);
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
                Missing(coop ? "Terra Nova Plus's co-op build (components\\tnplus_coop)" : "Terra Nova Plus");
                Status("Downloading and building Terra Nova Plus" + (coop ? " (co-op build)" : "") + "...", CAmber);
                BuildTnp(coop);
                if (tp != null) Set(key, tp);
                SaveCfg();
            }
            if (!File.Exists(PythonExe) || !File.Exists(Path.Combine(Comp, "python", "Lib", "site-packages", "psutil", "__init__.py")))
            {
                Missing("Python");
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
        Dictionary<string, string> h = Heads();
        string up = Get(h, Head(UPLINK_REPO, UPLINK_BRANCH));
        Ui(delegate {
            if (NoUpdate) { verLabel.Text = "Updates are off here (no_update.txt)"; verLabel.On = CLedOff; }
            else if (up == null) { verLabel.Text = "Couldn't check for updates (offline?)"; verLabel.On = CLedOff; }
            else if (Cfg("uplink_sha") == "") { verLabel.Text = "Uplink " + up.Substring(0, 7) + " will be installed"; verLabel.On = CAmber; }
            else if (up == Cfg("uplink_sha")) { verLabel.Text = "Uplink " + VERSION + ", up to date"; verLabel.On = CGreen; }
            else { verLabel.Text = "Update available at the next start"; verLabel.On = CAmber; }
            verLabel.Invalidate();
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
        string dir = Path.GetDirectoryName(src), outExe = Path.Combine(Root, "Terra Nova Uplink.new.exe"), res = "";
        foreach (string h in HEROES) if (File.Exists(Path.Combine(dir, h))) res += "/resource:" + h + " ";   // (the pages' pictures)
        Process p = Run(Csc(), "/nologo /optimize /target:winexe /win32manifest:app.manifest /win32icon:icon.ico /r:System.Windows.Forms.dll " +
            "/r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Management.dll " + res +
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
        if (NoUpdate) { Status("Updates are off in this folder (no_update.txt): nothing to repair from.", CRed); return; }
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
