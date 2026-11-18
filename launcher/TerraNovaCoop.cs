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

static partial class Uplink
{
    const string TITLE = "Terra Nova Uplink";
    const string VERSION = "2.8.0-beta.1";
    const string UPLINK_REPO = "skw-1337/terra-nova-uplink", TNPLUS_REPO = "skw-1337/terra-nova-plus";
    // the branches checked by each repo's .github/workflows/stable.yml (main once its checks have passed, never a broken
    // push): Uplink's, TN+'s (PLAY) and TN+'s co-op build (HOST)
    const string UPLINK_BRANCH = "stable", TNPLUS_BRANCH = "stable", TNPLUS_COOP_BRANCH = "coop-stable";
    const string DISCORD = "https://discord.gg/UqtEpuUZh3";
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
        if (Environment.GetCommandLineArgs().Length > 1 && Environment.GetCommandLineArgs()[1] == "--selftest")
        { Console.WriteLine(TITLE + " " + VERSION); return; }   // (a launcher just built by an update: it starts, says its version)
        Root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        Comp = Path.Combine(Root, "components");
        Ini = Path.Combine(Root, "TerraNovaUplink.ini");
        Directory.CreateDirectory(Path.Combine(Comp, "logs"));
        LogPath = Path.Combine(Comp, "logs", "launcher.log");
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;   // TLS 1.2 (GitHub, python.org, PyPI)
        Migrate();
        bool had = File.Exists(Ini);
        LoadCfg();
        UpdStartup();                                          // (release channels: the launcher this one replaced; --rollback)
        AdoptGameSettings();                                   // (what Uplink's own menu changed since: its viewer.cfg)
        // The keys a new installation comes with (2: freelook on F), as against one that was already there (1: on
        // Y): said once, when the settings do not say yet, so that nobody's key changes with an update
        if (Cfg("keys_gen") != "1" && Cfg("keys_gen") != "2") Set("keys_gen", had && cfg.Count > 0 ? "1" : "2");
        // 2.7 saved gamepad = 1 for everybody (its switch showed on unless "0"): an installation made before this
        // version gets it off once, as a new one has it (pad_gen = 2: done; switched on afterwards, it stays on)
        if (Cfg("pad_gen") != "2")
        {
            bool upgrade = had && cfg.Count > 0;
            if (upgrade) Set("gamepad", "0");
            Set("pad_gen", "2");
            if (upgrade) SaveCfg();
        }
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
        if (args.Length > 1 && args[1] == "--conflicts")   // checks: the Controls page's keys and the clashes it shows
        {
            ControlsLoad();
            Dictionary<string, string> cl = Conflicts();
            foreach (Cmd c in cmds) Console.WriteLine(c.Id + "=" + KeySpec(c.Sc, c.Mods) + (cl.ContainsKey(c.Id) ? "  CLASH " + cl[c.Id] : ""));
            Console.WriteLine("clashes " + cl.Count);
            Environment.Exit(0);
        }
        if (args.Length > 1 && args[1] == "--awe")         // checks: the music device, the AWE32 ROM, a dump found elsewhere
        {
            string where, seen = AweLook(out where);
            Console.WriteLine("music=" + MUSIC[Music()] + "\nrom=" + (AweHave() ? "yes" : "no") + "\nseen=" + (seen ?? "") + "\nwhere=" + (where ?? ""));
            Environment.Exit(0);
        }
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
        form.FormClosing += delegate { AdoptNow(); loading = false; SaveOptions(); stopping = true; quitting = true; };
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
    // A side bar (the seven pages, What's new and Help at its foot) and one page at a time, 610 x 500. Play, Co-op and
    // Maps lie on a picture of Uplink's own (bg_play.jpg, bg_coop.jpg, bg_maps.jpg: see LoadHero); In game,
    // Graphics and Settings are cards (Graphics' previews: see PvImage). Everything is drawn here (switches, lists, sliders, key buttons): no Windows control shows.
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
    // (own_body: his legs and feet when he looks past the game's limit; the deeper look itself is look_down)
    static readonly string[] FX = { "marks", "lights", "cloud_shadows", "look_down", "cliffs", "stars", "tracks", "own_body" };
    static readonly string[] FX_NAMES = { "Impact marks", "Light from shots", "Cloud shadows", "Look further down", "Unstretched cliffs", "Sharp stars", "Footprints, tracks", "Own body" };
    static Switch[] fxTicks = new Switch[8];
    static readonly string[] PAGES = { "Play", "Co-op", "Maps", "In game", "Graphics", "Controls", "Settings" };
    const int SB = 150, MW = 610, MH = 500;                   // the side bar's width, a page's size
    const int P_WHEEL = 7;                                    // the order wheel's page (opened from In game)
    const int P_GRAPHICS = 4, P_CONTROLS = 5, P_SETTINGS = 6;
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

    // the page shown last time: its name, or (an ini of 2.7 or before) its number then, when Graphics was not there
    static int PageAtStart()
    {
        int n = Array.IndexOf(PAGES, Cfg("page"));
        if (n >= 0) return n;
        string[] old = { "Play", "Co-op", "Maps", "In game", "Controls", "Settings" };
        return int.TryParse(Cfg("page"), out n) && n >= 0 && n < old.Length ? Array.IndexOf(PAGES, old[n]) : 0;
    }

    static void ShowPage(int k)
    {
        pageNow = k;
        for (int i = 0; i < pages.Length; i++) pages[i].Visible = i == k;
        int nav = k == P_WHEEL ? 3 : k;
        for (int i = 0; i < navs.Length; i++) { navs[i].On = i == nav; navs[i].Invalidate(); }
        Set("page", PAGES[nav]);                              // (by its name: up to 2.7 its number, see PageAtStart)
        if (k == 3) ReadSharp();
        if (k == P_GRAPHICS) PreviewShow(null);
        if (k == P_SETTINGS) MusicUi();
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
        UpdBadgeAt(side, 18, 404);                           // the beta's badge (RELEASE CHANNELS)

        BuildPlay(pages[0]);
        BuildCoop(pages[1]);
        BuildMaps(pages[2]);
        BuildInGame(pages[3]);
        BuildGraphics(pages[P_GRAPHICS]);
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
        ShowPage(PageAtStart());
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
        Surface c = Card(pg, "DISPLAY", COrange, null, 18, 16, CW, 192);
        int y = 32;
        // the old school look's key (the look itself: a switch of the Graphics page, TN_OLDSCHOOL); its pixel size,
        // kept by Uplink itself (see ReadSharp)
        c.Controls.Add(new Txt { Text = "Old school look", Em = "key", Location = new Point(X, y), Size = new Size(150, RH) });
        oldKeyBtn = Key(c, X + IW - 137, y, 137); oldKeyBtn.Click += delegate { AskKey(false); };
        y += RH;
        c.Controls.Add(new Txt { Text = "Pixels", Ink = Color.FromArgb(185, 199, 193), Location = new Point(X + 8, y), Size = new Size(46, RH) });
        sharpSeg = new Seg { Items = new[] { "1×", "2×", "3×", "Max" }, Text = "Pixels", Location = new Point(X + IW - 137, y + 3), Size = new Size(137, 23) };
        sharpSeg.Changed += delegate { WriteSharp(); };
        c.Controls.Add(sharpSeg);
        sharpKeyBtn = Key(c, X + IW - 137 - 8 - 62, y, 62); sharpKeyBtn.Click += delegate { AskKey(true); };
        y += RH;
        c.Controls.Add(new Txt { Text = "Crosshair", Location = new Point(X, y), Size = new Size(120, RH) });      // (the look mode's)
        crossBox = new Drop { Text = "Crosshair", Items = new List<string> { "The game's", "A dot", "None" }, Location = new Point(X + IW - 104, y + 3), Size = new Size(104, 23) };
        crossBox.Changed += save;
        c.Controls.Add(crossBox); y += RH;
        c.Controls.Add(new Txt { Text = "Frame limit", Location = new Point(X, y), Size = new Size(120, RH) });
        capBox = new Drop { Text = "Frame limit", Location = new Point(X + IW - 104, y + 3), Size = new Size(104, 23) };
        capBox.Changed += delegate { PickCap(); };
        c.Controls.Add(capBox); y += RH;
        fpsBox = Row(c, "Frame counter", X, y, IW, COrange, save);

        c = Card(pg, "CONTROLS", COrange, null, 18 + CW + 12, 16, CW, 192);
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

        // squad orders on one button, held: Uplink's order wheel (off unless asked; TN_ORDER_WHEEL, TN_ORDER_KEY). The
        // squadmates' subtitles are on the Settings page (Accessibility)
        c = Card(pg, "SQUAD", CBlue, null, 18, 220, MW - 36, 74);
        wheelTick = Row(c, "Order wheel", X, 32, 296, CBlue, save);
        wheelKeyBtn = Key(c, X + 296 - 38 - 92, 32, 92); wheelKeyBtn.Click += delegate { AskOrderKey(); };
        Btn custom = Key(c, X + 296 - 38 - 92 - 8 - 74, 32, 74);
        custom.Text = "Customise"; custom.Line = CBlue; custom.Ink = Color.FromArgb(156, 196, 255);
        custom.Click += delegate { ShowPage(P_WHEEL); };
        Link subsLink = new Link { Text = "Subtitles: Settings > Accessibility", Ink = CBlue, Location = new Point(X + 296 + 26, 37), Size = new Size(230, 18) };
        subsLink.Click += delegate { ShowPage(P_SETTINGS); ScrollTo(accCard); };
        c.Controls.Add(subsLink);

        // the look (old school, HUD colours, Uplink's extras): on the Graphics page; here the preset in use and the way there
        igGfxCard = Card(pg, "GRAPHICS", COrange, null, 18, 306, MW - 36, 178);
        Action<Graphics> card = igGfxCard.Look;
        igGfxCard.Look = delegate(Graphics g) {
            card(g);
            int i = Array.IndexOf(PRESET_IDS, PresetNow());
            Str(g, "Preset", F11, CDim, 13, 36);
            Spaced(g, PRESET_NAMES[i].ToUpperInvariant(), F16b, Color.White, 13, 52, 1.2f);
            Str(g, PRESET_LINES[i], F115, CSoft, 13, 78);
            StrIn(g, "Old school look, HUD colours and Uplink's extras, each with a preview.", F11, CDim,
                new RectangleF(13, 102, 236, 34), TFWrap);
            DrawCover(g, PvImage("preset_" + (i < 4 ? PRESET_IDS[i] : "modern") + ".jpg"), new RectangleF(MW - 36 - 13 - 296, 13, 296, 152), i == 4);
        };
        Btn go = Key(igGfxCard, 13, 137, 140, 28, "Graphics page");
        go.Click += delegate { ShowPage(P_GRAPHICS); };
    }

    // ---- Graphics: a preset (five tiles), the switches it sets, and a picture of what the pointer or the keyboard is
    // on: a switch off and on at the same instant, or a preset's look. A preset picked sets the switches; a switch
    // changed afterwards makes it Custom. Kept as gfx_preset (and told to Uplink: TN_GFX_PRESET, its Esc menu has the
    // same five, scripts\uplink_menu.gd PRESETS); an ini without it: Custom if it holds switches of an earlier
    // launcher (they are never changed), else a new installation, Modern.
    static readonly string[] PRESET_IDS = { "original", "classic", "modern", "light", "custom" };
    static readonly string[] PRESET_NAMES = { "Original", "Classic+", "Modern", "Light", "Custom" };
    static readonly string[] PRESET_LINES = { "As in 1996", "Old look, small extras", "Everything on", "For older PCs", "Your own mix" };
    // each preset's switches, in GFX_KEYS' order (ini keys: old_school, hud_colours, fx_<the rest>)
    static readonly string[] GFX_KEYS = { "old_school", "hud_colours", "marks", "lights", "cloud_shadows", "look_down", "cliffs", "stars", "tracks", "own_body" };
    static readonly int[][] PRESET_VALUES = {
        new[] { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0 },      // Original: the game's look; the deeper look down stays (no body)
        new[] { 1, 0, 1, 1, 0, 1, 0, 0, 1, 1 },      // Classic+: old school with marks, light from shots, footprints
        new[] { 0, 1, 1, 1, 1, 1, 1, 1, 1, 1 },      // Modern: everything
        new[] { 0, 1, 1, 1, 0, 1, 0, 1, 0, 1 } };    // Light: the costliest off (measured: see the commit)
    // what each switch shows in the preview: its name and one line
    static readonly Dictionary<string, string[]> PV_TEXT = new Dictionary<string, string[]> {
        { "old_school", new[] { "Old school look", "The game's own pixels and palette over Uplink's view." } },
        { "hud_colours", new[] { "Uplink HUD colours", "An orange energy bar and a light blue armour indicator." } },
        { "marks", new[] { "Impact marks", "Shots leave scorch marks where they hit." } },
        { "lights", new[] { "Light from shots", "Gun flashes, bolts and blasts light up what is around them." } },
        { "cloud_shadows", new[] { "Cloud shadows", "The sky's clouds cast drifting shadows on the ground." } },
        { "look_down", new[] { "Look further down", "The view goes on down past the game's 45 degrees." } },
        { "cliffs", new[] { "Unstretched cliffs", "Steep faces textured along the slope, not stretched tiles." } },
        { "stars", new[] { "Sharp stars", "The stars of airless skies as sharp points at your resolution." } },
        { "tracks", new[] { "Footprints, tracks", "Suits and mechs leave footprints, vehicles leave tracks." } },
        { "own_body", new[] { "Own body", "Your own legs and feet when you look down." } } };
    static PresetTile[] presetTiles = new PresetTile[5];
    static Switch[] gfxSw = new Switch[10];                   // GFX_KEYS' switches (oldBox, hudTick, fxTicks)
    static bool presetting;                                   // the switches set by a preset: not the player's change
    static Surface pvCard, igGfxCard;
    static string pvKey;                                      // what the preview shows (null: the preset in use)
    static System.Windows.Forms.Timer pvTimer;
    static Dictionary<Control, string> pvOf = new Dictionary<Control, string>();
    static Dictionary<string, Image> pvImages = new Dictionary<string, Image>();

    static void BuildGraphics(Surface pg)
    {
        const int X = 13;
        Surface c = Card(pg, "GRAPHICS PRESET", COrange, "Point at one to see it", 18, 16, MW - 36, 106);
        const int TW = (MW - 36 - 2 * X - 4 * 8) / 5;
        for (int i = 0; i < 5; i++)
        {
            int k = i;
            presetTiles[i] = new PresetTile { Text = PRESET_NAMES[i], Line = PRESET_LINES[i], Location = new Point(X + i * (TW + 8), 34), Size = new Size(TW, 60) };
            presetTiles[i].Click += delegate { PickPreset(k); };
            c.Controls.Add(presetTiles[i]);
            Hover(presetTiles[i], "preset_" + PRESET_IDS[i]);
        }
        // the switches, three columns of four rows; the old school look and the HUD colours lead (the In game page
        // keeps the old school key and its pixel size)
        c = Card(pg, "WHAT IT SETS", COrange, "Change one: Custom", 18, 134, MW - 36, 154);
        string[] order = { "old_school", "hud_colours", "cloud_shadows", "marks", "lights", "tracks", "look_down", "own_body", "cliffs", "stars" };
        const int SW = (MW - 36 - 2 * X - 2 * 16) / 3;
        EventHandler changed = delegate { GfxTouched(); SaveOptions(); };
        for (int i = 0; i < order.Length; i++)
        {
            int at = Array.IndexOf(GFX_KEYS, order[i]);
            Switch s = Row(c, PV_TEXT[order[i]][0], X + (SW + 16) * (i % 3), 32 + 29 * (i / 3), SW, COrange, changed);
            gfxSw[at] = s;
            Hover(s, order[i]);
            if (order[i] == "old_school") oldBox = s;
            else if (order[i] == "hud_colours") hudTick = s;
            else fxTicks[Array.IndexOf(FX, order[i])] = s;
        }
        c.Controls.Add(new Txt { Text = "Uplink's own extras: none of them is in the game.", F = F11, Ink = CDim,
            Location = new Point(X + SW + 16, 32 + 29 * 3), Size = new Size(2 * SW + 16, 29) });

        // the preview: a picture of the switch off and on, or of the preset
        pvCard = new Surface { Location = new Point(18, 300), Size = new Size(MW - 36, 184) };
        pvCard.Look = PreviewLook;
        pg.Controls.Add(pvCard);
        pvTimer = new System.Windows.Forms.Timer { Interval = 220 };
        pvTimer.Tick += delegate {                            // (the pointer left: what has the keyboard, else the preset)
            pvTimer.Stop();
            string k = null;
            foreach (KeyValuePair<Control, string> kv in pvOf) { Drawn d = kv.Key as Drawn; if (d != null && d.KeyFocus) k = kv.Value; }
            PreviewShow(k);
        };
    }

    static void Hover(Control c, string key)
    {
        pvOf[c] = key;
        c.MouseEnter += delegate { PreviewShow(key); };
        c.GotFocus += delegate { PreviewShow(key); };
        c.MouseLeave += delegate { pvTimer.Stop(); pvTimer.Start(); };
        c.LostFocus += delegate { pvTimer.Stop(); pvTimer.Start(); };
    }

    static void PreviewShow(string key)
    {
        if (pvTimer != null) pvTimer.Stop();
        if (pvCard == null || pvKey == key) return;
        pvKey = key;
        pvCard.Dirty();
    }

    static void PreviewLook(Graphics g)
    {
        float w = MW - 36, h = 184;
        using (GraphicsPath p = Round(new Rectangle(0, 0, (int)w - 1, (int)h - 1), 7))
        using (Brush b = new SolidBrush(CPanel))
        using (Pen l = new Pen(CLine))
        { g.FillPath(b, p); g.DrawPath(l, p); }
        string key = pvKey ?? "preset_" + PresetNow();
        RectangleF all = new RectangleF(13, 32, w - 26, h - 32 - 13);
        if (key.StartsWith("preset_"))
        {
            int i = Array.IndexOf(PRESET_IDS, key.Substring(7));
            float tw = Spaced(g, PRESET_NAMES[i].ToUpperInvariant(), F10b, COrange, 13, 11, 1.2f);
            Str(g, PRESET_LINES[i] + (pvKey == null ? "  ·  in use" : ""), F11, CDim, 13 + tw + 10, 10);
            DrawCover(g, PvImage("preset_" + (i < 4 ? PRESET_IDS[i] : "modern") + ".jpg"), all, i == 4);
            if (i == 4) StrIn(g, "Your own mix: point at a switch to see what it does.", F125, CText, all, TFMid);
            return;
        }
        string[] t = PV_TEXT[key];
        float tw2 = Spaced(g, t[0].ToUpperInvariant(), F10b, COrange, 13, 11, 1.2f);
        Str(g, t[1], F11, CDim, 13 + tw2 + 10, 10);
        float iw = (all.Width - 10) / 2f;
        for (int k = 0; k < 2; k++)
        {
            RectangleF r = new RectangleF(all.X + k * (iw + 10), all.Y, iw, all.Height);
            DrawCover(g, PvImage(key + (k == 0 ? "_off.jpg" : "_on.jpg")), r, false);
            string chip = k == 0 ? "OFF" : "ON";
            float cw = Spaced(g, chip, F95b, Color.Empty, 0, 0, 1.2f) + 14;
            using (GraphicsPath p = Round(new RectangleF(r.X + 8, r.Y + 8, cw, 18), 3))
            using (Brush b = new SolidBrush(Color.FromArgb(214, 8, 17, 15))) g.FillPath(b, p);
            Spaced(g, chip, F95b, k == 0 ? CSoft : COrange, r.X + 15, r.Y + 11, 1.2f);
        }
    }

    // a picture over a place, cut to fill it (not squeezed), corners rounded; dimmed (Custom's) or "no picture"
    static void DrawCover(Graphics g, Image img, RectangleF r, bool dim)
    {
        GraphicsState st = g.Save();
        using (GraphicsPath p = Round(r, 5))
        {
            g.SetClip(p);
            if (img == null)
            {
                using (Brush b = new SolidBrush(Color.FromArgb(10, 20, 18))) g.FillPath(b, p);
                g.Restore(st);
                StrIn(g, "No picture", F11, CDim, r, TFMid);
                return;
            }
            float k = Math.Max(r.Width / img.Width, r.Height / img.Height), w = img.Width * k, h = img.Height * k;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            using (System.Drawing.Imaging.ImageAttributes ia = new System.Drawing.Imaging.ImageAttributes())
            {
                ia.SetWrapMode(WrapMode.TileFlipXY);                  // (no grey seam at the edges)
                g.DrawImage(img, Rectangle.Round(new RectangleF(r.X + (r.Width - w) / 2f, r.Y + (r.Height - h) / 2f, w, h)), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, ia);
            }
            if (dim) using (Brush b = new SolidBrush(Color.FromArgb(170, 8, 17, 15))) g.FillPath(b, p);
            using (Pen l = new Pen(Color.FromArgb(40, 255, 255, 255))) g.DrawPath(l, p);
        }
        g.Restore(st);
    }

    // the preview pictures: Uplink's own (components\uplink\launcher\previews: new pictures come with an Uplink
    // update), else the copy built into this exe (build.bat: previews\*.jpg)
    static Image PvImage(string name)
    {
        Image img;
        if (pvImages.TryGetValue(name, out img)) return img;
        try
        {
            string f = Path.Combine(Path.Combine(UplinkDir, "launcher"), Path.Combine("previews", name));
            if (File.Exists(f)) img = Image.FromStream(new MemoryStream(File.ReadAllBytes(f)));
        }
        catch { }
        try
        {
            Stream s = img == null ? typeof(Uplink).Assembly.GetManifestResourceStream("previews." + name) : null;
            if (s != null) img = Image.FromStream(s);
        }
        catch { }
        pvImages[name] = img;
        return img;
    }

    static bool HadGfx()
    {
        if (Cfg("old_school") != "" || Cfg("hud_colours") != "") return true;
        foreach (string f in FX) if (Cfg("fx_" + f) != "") return true;
        return false;
    }

    // the preset in use: the one saved; none yet: Custom over an earlier launcher's switches, Modern for a new one
    static string PresetNow()
    {
        string p = Cfg("gfx_preset");
        return Array.IndexOf(PRESET_IDS, p) >= 0 ? p : HadGfx() ? "custom" : "modern";
    }

    static void PickPreset(int i)
    {
        Set("gfx_preset", PRESET_IDS[i]);
        if (i < PRESET_VALUES.Length)
        {
            presetting = true;
            for (int j = 0; j < GFX_KEYS.Length; j++) gfxSw[j].Checked = PRESET_VALUES[i][j] == 1;
            presetting = false;
        }
        PresetUi();
        SaveOptions();
    }

    // a switch changed by the player: the preset becomes Custom (the switches stay as they are)
    static void GfxTouched()
    {
        if (loading || presetting || PresetNow() == "custom") return;
        Set("gfx_preset", "custom");
        PresetUi();
    }

    static void PresetUi()
    {
        string p = PresetNow();
        for (int i = 0; i < presetTiles.Length; i++)
            if (presetTiles[i] != null) { presetTiles[i].On = PRESET_IDS[i] == p; presetTiles[i].Invalidate(); }
        if (pvCard != null && (pvKey == null || pvKey.StartsWith("preset_"))) pvCard.Dirty();
        if (igGfxCard != null) igGfxCard.Dirty();
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

        // the game: its folder; its music device (TN+'s "music": see Music) and whether the AWE32 ROM that AWE32
        // needs is where TN+ looks for it
        c = Card(pg, "GAME", COrange, null, 18, 246, MW - 36, 102);
        gameLine2 = new GameLine { Location = new Point(X, 32), Size = new Size(MW - 36 - 26 - 78, RH) };
        gameLine2.Click += delegate { GamesMenu(gameLine2); };
        c.Controls.Add(gameLine2);
        gameBtn2 = Key(c, MW - 36 - 13 - 70, 32, 70, 23, "Change");
        gameBtn2.Click += delegate { GamesMenu(gameLine2); };
        c.Controls.Add(new Txt { Text = "Music", Location = new Point(X, 61), Size = new Size(46, RH) });
        musicBox = new Drop { Text = "Music", Items = new List<string>(MUSIC_NAMES), Location = new Point(X + 50, 64), Size = new Size(104, 23) };
        musicBox.Changed += delegate { PickMusic(); };
        c.Controls.Add(musicBox);
        aweLed = new LedLine { Text = "AWE32 ROM not found", F = F12, Location = new Point(X + 50 + 104 + 14, 61), Size = new Size(MW - 36 - 13 - 78 - (X + 50 + 104 + 14), RH) };
        c.Controls.Add(aweLed);
        aweUse = Key(c, MW - 36 - 13 - 70 - 8 - 54, 64, 54, 23, "Use it");
        aweUse.Click += delegate { if (aweSeen != null) AweTake(aweSeen); };
        aweUse.Visible = false;
        aweBtn = Key(c, MW - 36 - 13 - 70, 64, 70, 23, "Browse…");
        aweBtn.Click += delegate { AweBrowse(); };
        ToolTip tip = new ToolTip { AutoPopDelay = 12000 };
        foreach (Control t in new Control[] { aweLed, aweBtn, aweUse }) tip.SetToolTip(t, AWE_TIP);

        int ay = BuildAccessibility(pg, 360) + 12;

        c = Card(pg, "UPDATES", COrange, null, 18, ay, CW, 124);
        verLabel = new LedLine { Text = "Uplink " + VERSION, Location = new Point(X, 30), Size = new Size(IW, 27) };
        c.Controls.Add(verLabel);
        UpdSettingsRow(c, X, 54, IW);                         // Beta updates (RELEASE CHANNELS)
        checkBtn = Key(c, X, 84, 123, 28, "Check now");
        checkBtn.Click += delegate { UpdCheckNow(); };
        Key(c, X + 123 + 9, 84, 123, 28, "What's new").Click += delegate { WhatsNew(); };

        c = Card(pg, "COMMUNITY", CBlue, null, 18 + CW + 12, ay, CW, 124);
        c.Controls.Add(new Txt { Text = "Questions, co-op partners, bug reports.", F = F115, Ink = CDim, Location = new Point(X, 32), Size = new Size(IW, RH) });
        Key(c, X, 84, 79, 28, "Discord").Click += delegate { Open(DISCORD); };
        Key(c, X + 88, 84, 79, 28, "GitHub").Click += delegate { Open("https://github.com/" + UPLINK_REPO); };
        Key(c, X + 176, 84, 79, 28, "Report a bug").Click += delegate { Report(); };
        ScrollPage(pg);
    }

    // ---- Settings > ACCESSIBILITY: the squadmates' subtitles (TN_SUBTITLES; their radio lines, under the crosshair),
    // their size (TN_SUBTITLE_SIZE 0-2: Normal, Large, Larger) and the colour-blind mode (TN_COLOUR_VISION: protan,
    // deutan, tritan; none: off), Uplink's colour_vision.gd. All off / Normal unless asked for. The same in Uplink's
    // Esc menu (Accessibility), at once there, taken over from viewer.cfg as its other settings (AdoptAccessibility).
    static Seg subSizeSeg;
    static Surface accCard;
    static Drop cvBox;
    static Txt cvNote;
    static readonly string[] CV_MODES = { "", "protan", "deutan", "tritan" };
    static readonly string[] CV_NAMES = { "Off", "Protanopia", "Deuteranopia", "Tritanopia" };
    static readonly string[] CV_NOTES = {
        "Uplink's marks in the game's colours.",
        "Red-green (red weak): target green turns cyan, hostile red raspberry, a triangle over hostiles.",
        "Red-green (green weak): target green turns cyan, hostile red magenta, a triangle over hostiles.",
        "Blue-yellow: target green turns yellow-green, a triangle over hostile units." };

    // the card at y on the Settings page; returns its bottom
    static int BuildAccessibility(Surface pg, int y)
    {
        const int X = 13, RH = 29, H = 122;
        EventHandler save = delegate { SaveOptions(); };
        Surface c = accCard = Card(pg, "ACCESSIBILITY", CBlue, null, 18, y, MW - 36, H);
        subsTick = Row(c, "Squadmates' subtitles", X, 32, 262, CBlue, save);
        c.Controls.Add(new Txt { Text = "Subtitle size", Location = new Point(X + 262 + 22, 32), Size = new Size(88, RH) });
        subSizeSeg = new Seg { Items = new[] { "Normal", "Large", "Larger" }, Text = "Subtitle size", Location = new Point(MW - 36 - 13 - 168, 35), Size = new Size(168, 23) };
        subSizeSeg.Changed += save;
        c.Controls.Add(subSizeSeg);
        c.Controls.Add(new Txt { Text = "Colour-blind mode", Location = new Point(X, 32 + RH), Size = new Size(160, RH) });
        cvBox = new Drop { Text = "Colour-blind mode", Items = new List<string>(CV_NAMES), Location = new Point(MW - 36 - 13 - 168, 35 + RH), Size = new Size(168, 23) };
        cvBox.Changed += delegate { CvNote(); SaveOptions(); };
        c.Controls.Add(cvBox);
        cvNote = new Txt { Text = CV_NOTES[0], F = F11, Ink = CDim, Location = new Point(X, 32 + 2 * RH + 2), Size = new Size(MW - 36 - 26, 20) };
        c.Controls.Add(cvNote);
        return y + H;
    }

    static void CvNote() { cvNote.Text = CV_NOTES[Math.Max(0, cvBox.Selected)]; cvNote.Invalidate(); }

    static void AccessLoad()
    {
        subsTick.Checked = Cfg("subtitles") == "1";              // (off unless asked for)
        int z;
        subSizeSeg.Selected = int.TryParse(Cfg("subtitle_size"), out z) ? Math.Max(0, Math.Min(2, z)) : 0;
        cvBox.Selected = Math.Max(0, Array.IndexOf(CV_MODES, Cfg("colour_vision")));
        CvNote();
    }

    static void AccessSave()
    {
        Set("subtitles", subsTick.Checked ? "1" : "0");
        Set("subtitle_size", subSizeSeg.Selected.ToString());
        Set("colour_vision", CV_MODES[Math.Max(0, cvBox.Selected)]);
    }

    static void AccessEnv(Dictionary<string, string> env)
    {
        env["TN_SUBTITLES"] = Cfg("subtitles") == "1" ? "1" : "0";
        env["TN_SUBTITLE_SIZE"] = Cfg("subtitle_size") == "" ? "0" : Cfg("subtitle_size");
        env["TN_COLOUR_VISION"] = Cfg("colour_vision");
    }

    // the settings of Uplink's Esc menu (Accessibility), as AdoptGameSettings takes the others
    static void AdoptAccessibility(Dictionary<string, string> s)
    {
        string v;
        if (s.TryGetValue("subtitle_size", out v) && (v == "0" || v == "1" || v == "2")) Set("subtitle_size", v);
        if (s.TryGetValue("colour_vision", out v) && Array.IndexOf(CV_MODES, v) >= 0) Set("colour_vision", v);
    }

    // a card of a page that scrolls (ScrollPage) brought into view
    static void ScrollTo(Control card)
    {
        ScrollableControl host = card != null && card.Parent != null ? card.Parent.Parent as ScrollableControl : null;
        if (host != null) { host.ScrollControlIntoView(card); host.Invalidate(true); }
    }

    // a page taller than the window: its cards in a panel that scrolls (the mouse wheel, the bar on the right); the
    // cards keep their places, the bar takes no width from them
    static void ScrollPage(Surface pg)
    {
        int bottom = 0;
        foreach (Control k in pg.Controls) bottom = Math.Max(bottom, k.Bottom);
        if (bottom + 16 <= MH) return;
        Panel host = new Panel { Location = new Point(0, 0), Size = new Size(MW, MH), BackColor = CBack };
        Surface inner = new Surface { Location = new Point(0, 0), Size = new Size(MW - 18, bottom + 16) };
        inner.Look = delegate(Graphics g) { g.Clear(CBack); };
        Control[] all = new Control[pg.Controls.Count];
        pg.Controls.CopyTo(all, 0);
        foreach (Control k in all) { pg.Controls.Remove(k); inner.Controls.Add(k); }
        host.Controls.Add(inner);
        host.AutoScroll = false;
        host.HorizontalScroll.Enabled = false;
        host.HorizontalScroll.Visible = false;
        host.HorizontalScroll.Maximum = 0;
        host.AutoScroll = true;
        host.Scroll += delegate { host.Invalidate(true); };
        host.MouseWheel += delegate { host.Invalidate(true); };
        pg.Controls.Add(host);
        try { SetWindowTheme(host.Handle, "DarkMode_Explorer", null); } catch { }
    }

    static void Open(string url) { try { Process.Start(url); } catch { } }

    // ---- the game's music device. It is Terra Nova Plus's setting ("music = ROLAND | FM | GAME'S OWN | AWE32" in the
    // TNPlus.ini next to its exe; no line: ROLAND), read from and written to the TN+ of PLAY (components\tnplus) and
    // the one of HOST (components\tnplus_coop): shown from the first of the two that says, written to both. A TN+
    // that is not installed yet gets the choice when its settings are first written (WriteTnpIni; "music" in our ini).
    // AWE32 plays the game's own AWE32 bank (SOUND\FF.SBK) with the samples of the card's ROM: TN+ wants the player's
    // own dump of that ROM as "awe32.raw" next to its TNPlus.exe, exactly 1 048 576 bytes (it checks nothing else),
    // and plays ROLAND when it is not there. That file is Creative's: never downloaded, never part of anything
    // of ours; the launcher only copies the player's own next to each TN+ it uses.
    static readonly string[] MUSIC = { "ROLAND", "FM", "GAME'S OWN", "AWE32" };
    static readonly string[] MUSIC_NAMES = { "Roland / GS", "FM", "Game's own", "AWE32" };
    const string AWE_FILE = "awe32.raw";
    const int AWE_SIZE = 1048576;
    const string AWE_TIP = "Your own dump of the AWE32 sound ROM (awe32.raw, 1 MB). Not included.";
    static Drop musicBox;
    static LedLine aweLed;
    static Btn aweBtn, aweUse;
    static string aweSeen, aweWhere;                          // a dump found elsewhere on the PC, and where in a word

    // a setting of a TNPlus.ini as TN+ reads it (the last line that says wins); null: no such line
    static string IniGet(string ini, string key)
    {
        string v = null;
        try
        {
            if (!File.Exists(ini)) return null;
            foreach (string l in File.ReadAllLines(ini))
            {
                Match m = Regex.Match(l, "^\\s*" + Regex.Escape(key) + "\\s*=(.*)$", RegexOptions.IgnoreCase);
                if (m.Success) v = m.Groups[1].Value.Trim();
            }
        }
        catch { }
        return v;
    }

    // ... and written: its line changed where it is, added when there is none (the rest of the file kept)
    static void IniSet(string ini, string key, string value)
    {
        List<string> lines = new List<string>(File.ReadAllLines(ini));
        string line = key + " = " + value;
        bool had = false;
        for (int i = 0; i < lines.Count; i++)
            if (Regex.IsMatch(lines[i], "^\\s*" + Regex.Escape(key) + "\\s*=", RegexOptions.IgnoreCase)) { lines[i] = line; had = true; }
        if (!had) lines.Add(line);
        File.WriteAllLines(ini, lines);
    }

    static int Music()
    {
        string v = IniGet(Path.Combine(TnpDir, "TNPlus.ini"), "music") ?? IniGet(Path.Combine(TnpCoopDir, "TNPlus.ini"), "music") ?? Cfg("music");
        return Math.Max(0, Array.IndexOf(MUSIC, v.ToUpperInvariant()));        // (anything else: ROLAND, as TN+ takes it)
    }

    static bool AweOk(string file)
    {
        try { return File.Exists(file) && new FileInfo(file).Length == AWE_SIZE; }
        catch { return false; }
    }

    // The ROM where TN+ will look: next to the TNPlus.exe of PLAY (and of HOST, once that build is there). One of
    // the two has it and not the other: copied across (both folders are the launcher's own)
    static bool AweHave()
    {
        string a = Path.Combine(TnpDir, AWE_FILE), b = Path.Combine(TnpCoopDir, AWE_FILE);
        try
        {
            if (AweOk(a) && !AweOk(b) && Directory.Exists(TnpCoopDir)) File.Copy(a, b, true);
            else if (AweOk(b) && !AweOk(a)) { Directory.CreateDirectory(TnpDir); File.Copy(b, a, true); }
        }
        catch (Exception e) { Log("AWE32 ROM, from one Terra Nova Plus to the other: " + e.GetType().Name); }
        return AweOk(a) && (AweOk(b) || !Directory.Exists(TnpCoopDir));
    }

    // A dump the player already has, in the likely places: the launcher's folder, the game's (a TN+ of his own kept
    // there, in it or in a folder of it), the folder of the TN+ whose keys were imported, his desktop, downloads and
    // documents (and their folders, one level). Only the name and the size are looked at.
    static string AweLook(out string where)
    {
        List<string[]> at = new List<string[]> { new[] { Root, "the launcher's folder", "0" } };
        string g = Cfg("game_dir"), own = Cfg("tnplus_own"), home = Environment.GetEnvironmentVariable("USERPROFILE");
        if (IsGame(g)) { at.Add(new[] { g, "the game folder", "1" }); at.Add(new[] { Path.Combine(g, "TNOVA"), "the game folder", "0" }); }
        if (own != "") at.Add(new[] { own, "your Terra Nova Plus", "0" });
        if (!string.IsNullOrEmpty(home))
            foreach (string sub in new[] { "", "OneDrive\\" })
                foreach (string d in new[] { "Downloads", "Desktop", "Documents" })
                    at.Add(new[] { Path.Combine(home, sub + d), d == "Desktop" ? "your desktop" : d, "1" });
        foreach (string[] a in at)
        {
            try
            {
                if (!Directory.Exists(a[0])) continue;
                List<string> dirs = new List<string> { a[0] };
                if (a[2] == "1") dirs.AddRange(Directory.GetDirectories(a[0]));
                foreach (string d in dirs)
                    if (AweOk(Path.Combine(d, AWE_FILE))) { where = a[1]; return Path.Combine(d, AWE_FILE); }
            }
            catch { }
        }
        where = null;
        return null;
    }

    // the Music line of the Settings page: the device, the light of the ROM, what Browse and "Use it" offer
    static void MusicUi()
    {
        if (musicBox == null) return;
        bool was = loading;
        loading = true;
        int m = Music();
        musicBox.Selected = m;
        loading = was;
        bool have = AweHave();
        aweSeen = have ? null : AweLook(out aweWhere);
        aweLed.On = have ? CGreen : aweSeen != null || m == 3 ? CAmber : CLedOff;
        aweLed.Text = have ? "AWE32 ROM found" : aweSeen != null ? "AWE32 ROM found in " + aweWhere : "AWE32 ROM not found";
        aweLed.Em = have || aweSeen != null ? null : m == 3 ? "Roland / GS plays instead" : "your own dump, not included";
        aweUse.Visible = aweSeen != null;
        aweLed.Width = (aweSeen != null ? aweUse.Left : aweBtn.Left) - S(8) - aweLed.Left;
        aweLed.Invalidate();
    }

    static void PickMusic()
    {
        if (loading) return;
        int m = musicBox.Selected;
        try { WriteMusic(m); }
        catch (Exception e) { Status("The music setting could not be written: " + e.Message, CRed); MusicUi(); return; }
        MusicUi();
        string next = busy ? " From the game's next start." : "";
        if (m == 3 && !AweHave())
            Status("AWE32 needs your own dump of the AWE32 sound ROM (awe32.raw, 1 MB, not included): " +
                   (aweSeen != null ? "one was found in " + aweWhere + ", click Use it." : "pick it with Browse.") + " Until then the game plays Roland / GS.", CAmber);
        else Status("Music: " + MUSIC_NAMES[m] + (m == 3 ? ", the game's own AWE32 bank with your ROM." : m == 2 ? ", as the game's own setup says." : ".") + next, CGreen);
    }

    // the device kept here and written to the TNPlus.ini of each TN+ there is (PLAY's and HOST's)
    static void WriteMusic(int m)
    {
        Set("music", MUSIC[m]); SaveCfg();
        foreach (string dir in new[] { TnpDir, TnpCoopDir })
            if (File.Exists(Path.Combine(dir, "TNPlus.ini"))) IniSet(Path.Combine(dir, "TNPlus.ini"), "music", MUSIC[m]);
    }

    static void AweBrowse()
    {
        using (OpenFileDialog d = new OpenFileDialog())
        {
            d.Title = "Pick your own dump of the AWE32 sound ROM (awe32.raw, 1 MB, not included)";
            d.Filter = "AWE32 ROM dump (awe32.raw, *.raw, *.bin, *.rom)|*.raw;*.bin;*.rom|All files|*.*";
            d.FileName = AWE_FILE;
            if (d.ShowDialog(form) != DialogResult.OK) return;
            AweTake(d.FileName);
        }
    }

    // the player's own dump copied next to each TN+ the launcher uses, under the name TN+ looks for. Nothing but its
    // size says what it is to TN+; the ROM's name in it ("1MGM", in its third or fourth word) is looked at for a warning
    static void AweTake(string file)
    {
        try
        {
            long n = File.Exists(file) ? new FileInfo(file).Length : -1;
            if (n != AWE_SIZE)
            {
                Status(n < 0 ? "That file could not be read." : "That file is " + n.ToString("N0", CultureInfo.InvariantCulture).Replace(",", " ") +
                       " bytes: a dump of the AWE32 ROM is exactly 1 048 576 bytes (1 MB). Nothing was copied.", CRed);
                return;
            }
            byte[] head = new byte[16];
            using (FileStream f = File.OpenRead(file)) f.Read(head, 0, 16);
            string h = Encoding.ASCII.GetString(head, 4, 8);
            bool named = h.StartsWith("M1MG") || h.Substring(2).StartsWith("M1MG");
            Directory.CreateDirectory(TnpDir);
            foreach (string dir in new[] { TnpDir, TnpCoopDir })
            {
                string to = Path.Combine(dir, AWE_FILE);
                if (Directory.Exists(dir) && !string.Equals(Path.GetFullPath(file), Path.GetFullPath(to), StringComparison.OrdinalIgnoreCase)) File.Copy(file, to, true);
            }
            Log("AWE32 ROM: the player's own dump copied next to Terra Nova Plus");
            MusicUi();
            Status("AWE32 ROM copied next to Terra Nova Plus." + (Music() == 3 ? " AWE32 music from the game's next start." : " Pick AWE32 in Music to hear it.") +
                   (named ? "" : " (It does not carry the ROM's name, 1MGM: if the music sounds wrong, it is another dump.)"), named ? CGreen : CAmber);
        }
        catch (Exception e) { Status("The AWE32 ROM could not be copied: " + e.Message, CRed); MusicUi(); }
    }

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
        public bool KeyFocus { get { return Cue; } }          // (focus reached with the keyboard)
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

    // a graphics preset: its name and a line under it; the one in use edged in orange, a bar on its left
    class PresetTile : Drawn
    {
        public string Line;
        public bool On;
        public PresetTile() : base(true) { }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            RectangleF r = new RectangleF(0.5f, 0.5f, W - 1, H - 1);
            using (GraphicsPath p = Round(r, 6))
            {
                using (Brush b = new SolidBrush(On ? Color.FromArgb(30, 52, 44) : over ? Color.FromArgb(20, 38, 34) : Color.FromArgb(13, 26, 23))) g.FillPath(b, p);
                if (On)
                {
                    GraphicsState st = g.Save();
                    g.SetClip(p);
                    using (Brush b = new SolidBrush(COrange)) g.FillRectangle(b, 0, 0, 3, H);
                    g.Restore(st);
                }
                using (Pen l = new Pen(Cue ? Color.White : On ? COrange : over ? Mix(CLine, Color.White, 0.25f) : CLine, On || Cue ? 1.5f : 1f)) g.DrawPath(l, p);
            }
            Str(g, Text, F14s, On ? Color.White : over ? Color.White : CText, 12, 9);
            StrIn(g, Line, F11, On ? CSoft : CDim, new RectangleF(12, 31, W - 18, H - 33), TFWrap);
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
        public string Em;                                     // a few words after it, dimmed
        public LedLine() : base(false) { }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = Begin(e);
            float cy = H / 2f;
            bool lit = On != CLedOff;
            if (lit) using (Brush h = new SolidBrush(Color.FromArgb(46, On))) g.FillEllipse(h, -2, cy - 7, 14, 14);
            using (Brush b = new SolidBrush(On)) g.FillEllipse(b, 1, cy - 4, 8, 8);
            StrIn(g, Text, F, lit ? CText : CDim, new RectangleF(17, 0, W - 17, H - 1), TFLeft);
            float ex = 17 + StrW(g, Text, F) + 8;
            if (Em != null && ex < W - 20) StrIn(g, Em, F11, CDim, new RectangleF(ex, 1, W - ex, H - 1), TFLeft);
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
            // Where it covers nothing: on a page with a picture, at its top right under the page's first line (Co-op:
            // under the session's line); the pages of cards and lists are full, so there it sits in the side bar,
            // between the pages' names and What's new, as narrow as the bar
            bool side = pageNow > 2;
            Size sz = TextRenderer.MeasureText(GM, msg, F12, new Size(side ? S(SB - 16 - 28) : S(330), 2000), TFWrap);
            ClientSize = new Size(side ? S(SB - 16) : sz.Width + S(28), sz.Height + S(17));
            using (GraphicsPath p = Round(new Rectangle(0, 0, Width, Height), 5)) Region = new Region(p);
            Location = form.PointToScreen(side ? new Point(S(8), S(436) - Height)
                                               : new Point(S(SB + MW - 18) - Width, S(pageNow == 1 ? 82 : 56)));
            Invalidate();
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
        oldBox.Checked = Cfg("old_school") == "1";          // off unless the player turned it on (2.8: new installs start modern)
        wheelTick.Checked = Cfg("order_wheel") == "1";           // (off unless asked for)
        AccessLoad();
        for (int i = 0; i < FX.Length; i++) fxTicks[i].Checked = Cfg("fx_" + FX[i]) != "0";   // (the extras: on unless turned off)
        // the graphics preset: none saved yet, Custom over an earlier launcher's switches (kept as they are), a new
        // installation Modern (its values set)
        if (Array.IndexOf(PRESET_IDS, Cfg("gfx_preset")) < 0)
        {
            string p = PresetNow();
            Set("gfx_preset", p);
            if (p != "custom")
            {
                int pi = Array.IndexOf(PRESET_IDS, p);
                for (int j = 0; j < GFX_KEYS.Length; j++) gfxSw[j].Checked = PRESET_VALUES[pi][j] == 1;
            }
        }
        PresetUi();
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
        AccessSave();
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
        if (!loading) MusicUi();                              // (a ROM dump kept in that game's folder)
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
        // (the folder shortened here, "...\" in its middle, its last name kept: Windows' own path ellipsis let a long
        // one run past the list's edge at 150 %)
        Rectangle r = new Rectangle(x, e.Bounds.Y, e.Bounds.Right - x - S(8), e.Bounds.Height);
        TextFormatFlags tf = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;
        TextRenderer.DrawText(e.Graphics, d == "" ? "Another folder... (the one that contains TNOVA)" : FitPath(e.Graphics, d, FBody, r.Width, tf), FBody,
            r, d == "" ? CSoft : sel ? Color.White : CText, tf | TextFormatFlags.EndEllipsis);
    }

    static string FitPath(IDeviceContext g, string path, Font f, int width, TextFormatFlags tf)
    {
        Func<string, bool> fits = t => TextRenderer.MeasureText(g, t, f, new Size(int.MaxValue, 100), tf).Width <= width;
        if (fits(path)) return path;
        int cut = path.LastIndexOf('\\');
        string tail = cut > 0 ? path.Substring(cut) : "";
        for (int a = (cut > 0 ? cut : path.Length) - 1; a >= 3; a--)
        {
            string t = path.Substring(0, a).TrimEnd('\\', ' ') + "..." + tail;
            if (fits(t)) return t;
        }
        return path;                                              // (then cut at its end: EndEllipsis)
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
                "Uplink is open: click in its window to take the mouse, Esc for Uplink's menu, " + ScanName(FreelookScan()) + " for the game's cursor, " + KeyName(OldKey()) +
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
        env["TN_OLDSCHOOL"] = "0";                             // ("Old school look" is the live game's: here its key turns it on)
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
        env["TN_OLDSCHOOL"] = Cfg("old_school") == "1" ? "1" : "0";
        env["TN_GFX_PRESET"] = PresetNow();                    // (the Esc menu's Graphics page shows it)
        env["TN_NO_PAD"] = Cfg("gamepad") == "1" ? "0" : "1";
        env["TN_ORDER_WHEEL"] = Cfg("order_wheel") == "1" ? "1" : "0";
        AccessEnv(env);
        // the music device and whether the AWE32 ROM is there: shown by Uplink's menu (Options), changed there for the
        // game's next start (taken over in AdoptGameSettings, which writes it to the TNPlus.ini files)
        env["TN_MUSIC"] = MUSIC[Music()];
        env["TN_AWE32"] = AweOk(Path.Combine(TnpDir, AWE_FILE)) || AweOk(Path.Combine(TnpCoopDir, AWE_FILE)) ? "1" : "0";
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

    // STOP's work on a thread of its own, a foreground one: the window closed meanwhile goes at once, the process stays
    // (with no window) until everything it started is closed. Closing the window also cuts the waits short (quitting)
    static Thread stopper;
    static volatile bool quitting;

    static void StopNow()
    {
        if (stopper != null && stopper.IsAlive) return;
        stopper = new Thread(StopAll) { IsBackground = false };
        stopper.Start();
    }

    static void StopAll()
    {
        stopping = true;
        Log("stopping what this launcher started");
        lock (mine)
        {
            foreach (Process p in mine)
                try
                {
                    if (p.HasExited) continue;
                    p.CloseMainWindow();
                    for (int t = 0; t < 1500 && !quitting && !p.WaitForExit(100); t += 100) { }
                    if (!p.HasExited) { p.Kill(); p.WaitForExit(2000); }
                }
                catch { }
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
            info.AppendLine("music: " + MUSIC[Music()] + ", AWE32 ROM found: " + (AweHave() ? "yes" : "no"));
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
        // the music device picked on the Settings page, for a TN+ whose settings do not say yet (a TN+ just installed:
        // what the launcher's other TN+ plays, or what was picked before there was any)
        string music = IniGet(other, "music") ?? Cfg("music");
        if (music != "" && !lines.Exists(l => Regex.IsMatch(l, @"^\s*music\s*=", RegexOptions.IgnoreCase))) lines.Add("music = " + music);
        AweHave();                                            // (and the player's ROM dump next to this TN+ too)
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
                if (c.Id == "oldschool" && Cfg("keys_gen") == "1") { c.DefSc = 0x58; c.DefMods = 0; }   // (see OldKey)
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

    // commands sharing a key (not the game's fixed keys), keys as they come included: none of those share one (the old
    // school look left F12, the game's Mission info, for \; Centre view has no key, F being the freelook's)
    static Dictionary<string, string> Conflicts()
    {
        Dictionary<string, string> o = new Dictionary<string, string>();
        foreach (Cmd a in cmds)
        {
            if (a.Kind == "fixed" || a.Sc == 0) continue;
            foreach (Cmd b in cmds)
                if (b != a && b.Kind != "fixed" && b.Sc == a.Sc && b.Mods == a.Mods)
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
        pg.Controls.Add(new Txt { Text = "start of the game, Uplink's at the next start of Uplink (in game: Esc, then Controls: at once).",
            F = F11, Ink = CDim, Location = new Point(18, 440), Size = new Size(MW - 36, 16) });
        Btn reset = Key(pg, 18, 460, 170, 28, "Reset to defaults");
        reset.Click += delegate {
            if (!Ask("Put every key back as it comes (freelook on F, the old school look on \\, Centre view without a key)?")) return;
            foreach (Cmd c in cmds)
            {
                bool now = c.Id == "centre" || c.Id == "freelook" || c.Id == "oldschool";    // (as a new installation has them)
                c.Sc = c.Id == "centre" ? 0 : c.Id == "freelook" ? 0x21 : c.Id == "oldschool" ? 0x2B : c.DefSc; c.Mods = now ? 0 : c.DefMods; c.Mouse = 0; c.Pad = c.PadDef;
            }
            padSticks = new Dictionary<string, string>();
            ControlsSave(); PadSave(); ControlsLoad(); keyList.Invalidate(); Status("Every key is as it comes.", CGreen);   // (read again: the old school look's three companions follow its key)
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
            col = x >= 254 && x < 356 ? 1 : x >= 362 && x < 450 ? 2 : x >= 456 && x < 562 ? 3 : 0;
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
                    DrawBox(g, new RectangleF(456, y + 2, 106, RH - 4), c.Pad != "" ? PadName(c.Pad) : "+", pbad ? CRed : c.Pad != c.PadDef ? COrange : c.Pad != "" ? CText : CDim,
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
        bool was = loading; loading = true; LoadOptions(); loading = was; KeyLabels(); MusicUi();
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
        string[] allowed = { "mouse", "old_school", "fx_marks", "fx_lights", "fx_cloud_shadows", "fx_look_down", "fx_cliffs", "fx_stars", "fx_tracks", "fx_own_body", "gfx_preset",
            "key_menu", "key_order", "key_photo", "key_oldschool", "key_sharp", "key_shot", "key_fps",
            "hud_colours", "crosshair", "fps_cap", "fps_counter", "window",          // (its Graphics page)
            "subtitles", "invert_y", "gamepad", "shift_run", "order_wheel", "skip_intro" };   // (its Options page)
        foreach (string k in allowed)
        {
            string v;
            if (!s.TryGetValue(k, out v)) continue;
            if (k.StartsWith("key_") && v != "" && !KeyOk(v.ToUpperInvariant()) && v != "MID" && v != "M4" && v != "M5") continue;
            Set(k, v);
        }
        AdoptAccessibility(s);
        // the music device (its Options page, for the game's next start): written to the TNPlus.ini files as the
        // Settings page does (only here: Uplink never writes into Terra Nova Plus's own files)
        string mu;
        if (s.TryGetValue("music", out mu) && Array.IndexOf(MUSIC, mu.ToUpperInvariant()) >= 0 && Array.IndexOf(MUSIC, mu.ToUpperInvariant()) != Music())
        {
            try { WriteMusic(Array.IndexOf(MUSIC, mu.ToUpperInvariant())); }
            catch (Exception e) { Log("the music device from Uplink's menu could not be written: " + e.Message); }
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
            Set("tnplus_own", Path.GetDirectoryName(d.FileName)); SaveCfg();    // (his own TN+: where his AWE32 ROM dump may be)
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
    // The old school look on / off (\, see OldKey) and its pixel size (Shift with it) are keys of Uplink's window, not of
    // the game: TN+'s KEYBOARD page does not have them. Each can be put on another key, alone or
    // with Shift, Ctrl or Alt (TerraNovaUplink.ini: key_oldschool, key_sharp = [SHIFT+][CTRL+][ALT+]scancode, as TN+
    // writes its keys; E0xx: a key of the grey block). Uplink is told when it starts (TN_KEY_OLDSCHOOL, TN_KEY_SHARP).
    static bool KeyOk(string k) { return Regex.IsMatch(k ?? "", @"^((SHIFT|CTRL|ALT)\+)*[0-9A-F]{1,4}$"); }

    // Its key as it comes: \ (2B, the key above Enter, or next to it on an ISO keyboard), which neither the game, nor
    // TN+, nor Uplink's other keys use (F12 was the game's Mission info). An installation made before this version
    // keeps F12 (keys_gen 1: nobody's key changes with an update; the Controls page shows that clash)
    static string OldKey()
    {
        string k = Cfg("key_oldschool").ToUpperInvariant();
        return KeyOk(k) && k != "" ? k : Cfg("keys_gen") == "1" ? "58" : "2B";
    }

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
        int upd = UpdInstall(mode);                        // release.json (RELEASE CHANNELS, at the end): 1 = Uplink, TN+, the launcher done there
        Dictionary<string, string> heads = upd == 0 ? Heads() : new Dictionary<string, string>();
        string up = Get(heads, Head(UPLINK_REPO, UPLINK_BRANCH));
        if (upd == 0 && (!File.Exists(Path.Combine(UplinkDir, "project.godot")) || (up != null && up != Cfg("uplink_sha"))))
        {
            Missing("Uplink");
            Status("Downloading Uplink...", CAmber);
            Repo(UPLINK_REPO, UPLINK_BRANCH, UplinkDir);
            if (up != null) Set("uplink_sha", up);
            SaveCfg();
        }
        if (upd == 0) SelfUpdate();
        if (!File.Exists(GodotExe))
        {
            Missing("Godot " + GODOT_VER);
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
        if (UpdCheck()) return;                            // (release.json: RELEASE CHANNELS)
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
        if (args.Length > 2 && args[1] == "--cooptext")      // checks: the session line said for Uplink's co-op lines
        {
            for (int i = 2; i < args.Length; i++) Console.WriteLine(UpdCoopText(args[i]));
            Environment.Exit(0);
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
        if (f.Success) return "Your friend is on " + f.Groups[1].Value.Trim() + ": both need the same version (Beta updates, in Settings).";
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
                "(in Settings) if it is a beta, or your friend goes back to stable.";
            return "Your friend is on an older Uplink (" + (name ?? "protocol " + theirs) + "): both need the same version. Your friend updates (PLAY " +
                "updates it), or you go back to stable (Beta updates, in Settings).";
        }
        if (theirs == "older") return "Your friend is on an older Uplink: both need the same version (your friend updates with PLAY).";
        return "Different versions: both of you need the same Uplink (Beta updates, in Settings).";
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
// RELEASE CHANNELS, host glue: where this launcher's window shows them (Settings > Updates, the side bar's foot)
// ====================================================================================================================
static partial class Uplink
{
    static Switch betaSwitch;
    static bool betaLoading;
    static float UpdScale() { return K; }
    static void UpdLabel(string s, Color c) { Ui(delegate { if (verLabel == null) return; verLabel.Text = s; verLabel.On = c; verLabel.Invalidate(); }); }
    static void UpdToggle(bool on) { Ui(delegate { if (betaSwitch == null) return; betaLoading = true; betaSwitch.Checked = on; betaLoading = false; }); }
    static void UpdSettingsRow(Control card, int x, int y, int w)
    {
        betaSwitch = new Switch { Text = "Beta updates", Em = "new versions early", Location = new Point(x, y), Size = new Size(w, 26), Name = "beta_updates" };
        betaSwitch.Checked = Cfg("beta_updates") == "1";
        betaSwitch.CheckedChanged += delegate { if (!betaLoading) UpdBetaSwitched(betaSwitch.Checked); };
        card.Controls.Add(betaSwitch);
    }
    static void UpdBadgeAt(Control bar, int x, int y)
    {
        badge = new UBadge { Location = new Point(x, y), Size = new Size(114, 26) };
        bar.Controls.Add(badge);
    }
}
