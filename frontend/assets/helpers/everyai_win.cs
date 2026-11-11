// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.
//
// everyai-win: the Windows counterpart of everyai-ax (macOS), for the `app` tool's desktop windows. Same commands and
// JSON. EveryAI compiles it on first use with the C# compiler every Windows has (.NET Framework 4, C# 5: keep this
// file to C# 5). UI Automation for the element tree and its actions (no pointer needed), PrintWindow for pictures,
// and SendInput for real pointer and keyboard input, which is guarded like on macOS.
//
//   windows [--pid N]...                        top-level windows, frontmost first
//   procs                                       [{pid, ppid, exe}] for every process
//   tree --pid N [--window W]                   a window's UI Automation tree, in AX terms (pixels)
//   act --pid N --path P --action A [--text T | --text-stdin]  AXPress, AXShowMenu, AXIncrement, AXDecrement, focus, select, show,
//                                               setvalue
//   click --pid N --x X --y Y [--count C] [--right] [--front]
//   drag --pid N --x X --y Y --to-x X2 --to-y Y2 [--front]
//   scroll --pid N --x X --y Y --dy D [--front]
//   key --pid N (--text T | --text-stdin | --keyname K) [--mods ctrl,shift,alt,win] [--front]
//   raise --pid N [--window W]
//   shot --window ID --out FILE                 a PNG of the window with its pop-ups over it
//   stream --window ID [--fps F] [--scale S]    JPEG frames as multipart on stdout
//   trusted                                     {"ax": true, "screen": true}
//
// Real input waits while the user is using the mouse or keyboard, goes to a point only where the app's own window is
// on top, and keys only while the app is in front and the focused field isn't a password field (exit 7 or 8).

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

static class Native
{
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder s, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT r, int size);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int v, int size);
    [DllImport("kernel32.dll")] public static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder s, ref int size);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion u; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PROCESSENTRY32
    {
        public uint dwSize, cntUsage, th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
}

static class Program
{
    static List<string> args;

    static string Value(string name)
    {
        int i = args.IndexOf("--" + name);
        return i >= 0 && i + 1 < args.Count ? args[i + 1] : null;
    }

    static bool Flag(string name) { return args.Contains("--" + name); }

    // The text to type or set: from stdin with --text-stdin (a saved password never reaches the process list), else
    // --text.
    static string TextArg()
    {
        if (Flag("text-stdin"))
        {
            using (var r = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)))
            {
                return r.ReadToEnd();
            }
        }
        return Value("text");
    }

    static double? Number(string name)
    {
        string v = Value(name);
        double d;
        if (v != null && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) return d;
        return null;
    }

    static void Emit(object o)
    {
        var sb = new StringBuilder();
        Json(sb, o);
        var stdout = Console.OpenStandardOutput();
        var bytes = new UTF8Encoding(false).GetBytes(sb.ToString());
        stdout.Write(bytes, 0, bytes.Length);
        stdout.Flush();
    }

    static void Fail(string message, int code)
    {
        Console.Error.WriteLine("error: " + message);
        Environment.Exit(code);
    }

    static void Json(StringBuilder sb, object o)
    {
        if (o == null) { sb.Append("null"); return; }
        if (o is string)
        {
            sb.Append('"');
            foreach (char c in (string)o)
            {
                if (c == '"') sb.Append("\\\"");
                else if (c == '\\') sb.Append("\\\\");
                else if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                else sb.Append(c);
            }
            sb.Append('"');
            return;
        }
        if (o is bool) { sb.Append((bool)o ? "true" : "false"); return; }
        if (o is int || o is long || o is uint) { sb.Append(Convert.ToInt64(o).ToString(CultureInfo.InvariantCulture)); return; }
        if (o is double) { sb.Append(((double)o).ToString("R", CultureInfo.InvariantCulture)); return; }
        var dict = o as IDictionary<string, object>;
        if (dict != null)
        {
            sb.Append('{');
            bool first = true;
            foreach (var kv in dict)
            {
                if (!first) sb.Append(',');
                first = false;
                Json(sb, kv.Key);
                sb.Append(':');
                Json(sb, kv.Value);
            }
            sb.Append('}');
            return;
        }
        var list = o as IEnumerable;
        if (list != null)
        {
            sb.Append('[');
            bool first = true;
            foreach (var item in list)
            {
                if (!first) sb.Append(',');
                first = false;
                Json(sb, item);
            }
            sb.Append(']');
            return;
        }
        Json(sb, o.ToString());
    }

    // ---- windows and processes

    class Win
    {
        public IntPtr Hwnd;
        public uint Pid;
        public string Title, Class;
        public Native.RECT Rect;
    }

    static Native.RECT Bounds(IntPtr hwnd)
    {
        Native.RECT r;
        // The visible frame (GetWindowRect includes the invisible resize borders).
        if (Native.DwmGetWindowAttribute(hwnd, 9, out r, Marshal.SizeOf(typeof(Native.RECT))) != 0)
            Native.GetWindowRect(hwnd, out r);
        return r;
    }

    static bool Cloaked(IntPtr hwnd)
    {
        int v;
        return Native.DwmGetWindowAttribute(hwnd, 14, out v, 4) == 0 && v != 0;
    }

    /// Visible top-level windows, frontmost first; [popups] keeps tool and pop-up windows (menus, drop-down lists).
    static List<Win> TopLevels(bool popups)
    {
        var all = new List<Win>();
        Native.EnumWindows(delegate (IntPtr h, IntPtr l)
        {
            if (!Native.IsWindowVisible(h) || Native.IsIconic(h) || Cloaked(h)) return true;
            int ex = Native.GetWindowLong(h, -20);
            if (!popups && (ex & 0x80) != 0) return true; // WS_EX_TOOLWINDOW
            var r = Bounds(h);
            if (r.Right - r.Left < 2 || r.Bottom - r.Top < 2) return true;
            uint pid;
            Native.GetWindowThreadProcessId(h, out pid);
            var t = new StringBuilder(512);
            Native.GetWindowText(h, t, t.Capacity);
            var c = new StringBuilder(256);
            Native.GetClassName(h, c, c.Capacity);
            if (!popups && t.Length == 0) return true;
            all.Add(new Win { Hwnd = h, Pid = pid, Title = t.ToString(), Class = c.ToString(), Rect = r });
            return true;
        }, IntPtr.Zero);
        return all;
    }

    static string ExeOf(uint pid)
    {
        IntPtr h = Native.OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return "";
        try
        {
            var sb = new StringBuilder(1024);
            int size = sb.Capacity;
            return Native.QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : "";
        }
        finally { Native.CloseHandle(h); }
    }

    static Dictionary<string, object> Describe(Win w)
    {
        string exe = ExeOf(w.Pid);
        var d = new Dictionary<string, object>();
        d["id"] = w.Hwnd.ToInt64();
        d["pid"] = (long)w.Pid;
        d["app"] = exe.Length > 0 ? Path.GetFileNameWithoutExtension(exe) : "";
        d["title"] = w.Title;
        d["x"] = (long)w.Rect.Left;
        d["y"] = (long)w.Rect.Top;
        d["w"] = (long)(w.Rect.Right - w.Rect.Left);
        d["h"] = (long)(w.Rect.Bottom - w.Rect.Top);
        d["exe"] = exe;
        return d;
    }

    static List<Win> WindowsOf(uint pid)
    {
        var mine = new List<Win>();
        foreach (var w in TopLevels(false)) if (w.Pid == pid) mine.Add(w);
        return mine;
    }

    static Win Pick(uint pid, string title)
    {
        var mine = WindowsOf(pid);
        if (mine.Count == 0) Fail("the app has no window open", 4);
        if (!string.IsNullOrEmpty(title))
        {
            foreach (var w in mine) if (w.Title == title || w.Hwnd.ToInt64().ToString() == title) return w;
            foreach (var w in mine) if (w.Title.IndexOf(title, StringComparison.OrdinalIgnoreCase) >= 0) return w;
        }
        Win best = mine[0];
        foreach (var w in mine)
        {
            long a = (long)(w.Rect.Right - w.Rect.Left) * (w.Rect.Bottom - w.Rect.Top);
            long b = (long)(best.Rect.Right - best.Rect.Left) * (best.Rect.Bottom - best.Rect.Top);
            if (a > b) best = w;
        }
        return best;
    }

    static List<object> Procs()
    {
        var list = new List<object>();
        IntPtr snap = Native.CreateToolhelp32Snapshot(2, 0);
        if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return list;
        try
        {
            var e = new Native.PROCESSENTRY32();
            e.dwSize = (uint)Marshal.SizeOf(typeof(Native.PROCESSENTRY32));
            if (!Native.Process32FirstW(snap, ref e)) return list;
            do
            {
                var d = new Dictionary<string, object>();
                d["pid"] = (long)e.th32ProcessID;
                d["ppid"] = (long)e.th32ParentProcessID;
                d["exe"] = ExeOf(e.th32ProcessID);
                list.Add(d);
            } while (Native.Process32NextW(snap, ref e));
        }
        finally { Native.CloseHandle(snap); }
        return list;
    }

    // ---- the UI Automation tree

    static readonly TreeWalker Walker = TreeWalker.ControlViewWalker;

    static string Role(AutomationElement e, out string subrole)
    {
        subrole = null;
        var t = e.Current.ControlType;
        if (t == ControlType.Button || t == ControlType.HeaderItem) return "AXButton";
        if (t == ControlType.SplitButton) return "AXMenuButton";
        if (t == ControlType.Edit)
        {
            if (e.Current.IsPassword) subrole = "AXSecureTextField";
            return "AXTextField";
        }
        if (t == ControlType.Document) return "AXTextArea";
        if (t == ControlType.ComboBox)
        {
            object p;
            return e.TryGetCurrentPattern(ValuePattern.Pattern, out p) && !((ValuePattern)p).Current.IsReadOnly
                ? "AXComboBox" : "AXPopUpButton";
        }
        if (t == ControlType.CheckBox) return "AXCheckBox";
        if (t == ControlType.RadioButton) return "AXRadioButton";
        if (t == ControlType.TabItem) { subrole = "AXTabButton"; return "AXRadioButton"; }
        if (t == ControlType.Slider || t == ControlType.ScrollBar) return "AXSlider";
        if (t == ControlType.Spinner) return "AXIncrementor";
        if (t == ControlType.Hyperlink) return "AXLink";
        if (t == ControlType.MenuItem) return "AXMenuItem";
        if (t == ControlType.Text) return "AXStaticText";
        if (t == ControlType.Image) return "AXImage";
        if (t == ControlType.ListItem || t == ControlType.DataItem || t == ControlType.TreeItem) return "AXRow";
        if (t == ControlType.TitleBar) return "AXTitleBar";
        return "AXGroup";
    }

    static Dictionary<string, object> Node(AutomationElement e, string path)
    {
        var c = e.Current;
        string sub;
        string role = Role(e, out sub);
        var n = new Dictionary<string, object>();
        n["path"] = path;
        n["role"] = role;
        if (sub != null) n["subrole"] = sub;
        if (c.ControlType == ControlType.ScrollBar)
            n["desc"] = (c.Orientation == OrientationType.Horizontal ? "horizontal" : "vertical") + " scroll bar";
        else if (!string.IsNullOrEmpty(c.Name)) n[role == "AXStaticText" ? "value" : "title"] = Cut(c.Name);
        if (!string.IsNullOrEmpty(c.HelpText)) n["help"] = Cut(c.HelpText);
        if (!string.IsNullOrEmpty(c.AutomationId)) n["identifier"] = Cut(c.AutomationId);
        var acts = new List<object>();
        object p;
        if (e.TryGetCurrentPattern(ValuePattern.Pattern, out p) && !c.IsPassword && role != "AXStaticText")
        {
            string v = ((ValuePattern)p).Current.Value;
            if (!string.IsNullOrEmpty(v)) n["value"] = Cut(v);
        }
        if (e.TryGetCurrentPattern(TogglePattern.Pattern, out p))
        {
            n["value"] = ((TogglePattern)p).Current.ToggleState == ToggleState.On ? "1" : "0";
            acts.Add("AXPress");
        }
        if (e.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p))
        {
            bool sel = ((SelectionItemPattern)p).Current.IsSelected;
            n["selected"] = sel;
            if (role == "AXRadioButton") n["value"] = sel ? "1" : "0";
            if (!acts.Contains("AXPress")) acts.Add("AXPress");
        }
        if (e.TryGetCurrentPattern(InvokePattern.Pattern, out p) && !acts.Contains("AXPress")) acts.Add("AXPress");
        if (e.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out p))
        {
            acts.Add("AXShowMenu");
            if (!acts.Contains("AXPress")) acts.Add("AXPress");
        }
        if (e.TryGetCurrentPattern(RangeValuePattern.Pattern, out p) || c.ControlType == ControlType.ScrollBar)
        {
            acts.Add("AXIncrement");
            acts.Add("AXDecrement");
            if (p is RangeValuePattern) n["value"] = ((RangeValuePattern)p).Current.Value.ToString(CultureInfo.InvariantCulture);
        }
        if (acts.Count > 0) n["actions"] = acts;
        n["enabled"] = c.IsEnabled;
        if (c.HasKeyboardFocus) n["focused"] = true;
        var r = c.BoundingRectangle;
        if (!c.IsOffscreen && !r.IsEmpty)
        {
            n["x"] = r.X;
            n["y"] = r.Y;
            n["w"] = r.Width;
            n["h"] = r.Height;
        }
        return n;
    }

    static string Cut(string s) { return s.Length > 500 ? s.Substring(0, 500) : s; }

    static void Tree(uint pid, string title)
    {
        var w = Pick(pid, title);
        var nodes = new List<object>();
        var root = AutomationElement.FromHandle(w.Hwnd);
        Walk(root, w.Hwnd.ToInt64().ToString(), 0, nodes);
        var o = new Dictionary<string, object>();
        o["nodes"] = nodes;
        o["window"] = w.Hwnd.ToInt64();
        o["x"] = (long)w.Rect.Left;
        o["y"] = (long)w.Rect.Top;
        o["w"] = (long)(w.Rect.Right - w.Rect.Left);
        o["h"] = (long)(w.Rect.Bottom - w.Rect.Top);
        o["title"] = w.Title;
        Emit(o);
    }

    static void Walk(AutomationElement e, string path, int depth, List<object> nodes)
    {
        if (nodes.Count >= 4000 || depth > 60) return;
        try { nodes.Add(Node(e, path)); } catch (ElementNotAvailableException) { return; }
        int i = 0;
        AutomationElement child;
        try { child = Walker.GetFirstChild(e); } catch (ElementNotAvailableException) { return; }
        while (child != null)
        {
            Walk(child, path + "." + i, depth + 1, nodes);
            i++;
            try { child = Walker.GetNextSibling(child); } catch (ElementNotAvailableException) { break; }
        }
    }

    static AutomationElement Element(string path)
    {
        var parts = path.Split('.');
        long hwnd;
        if (!long.TryParse(parts[0], out hwnd)) Fail("no element at " + path + ": take a new tree", 4);
        AutomationElement e = null;
        try { e = AutomationElement.FromHandle(new IntPtr(hwnd)); } catch (Exception) { }
        if (e == null) Fail("no element at " + path + ": take a new tree", 4);
        for (int k = 1; k < parts.Length; k++)
        {
            int index = int.Parse(parts[k], CultureInfo.InvariantCulture);
            var c = Walker.GetFirstChild(e);
            for (int j = 0; j < index && c != null; j++) c = Walker.GetNextSibling(c);
            if (c == null) Fail("no element at " + path + ": take a new tree", 4);
            e = c;
        }
        return e;
    }

    static void Act(string path, string action, string text)
    {
        var e = Element(path);
        object p;
        try
        {
            switch (action)
            {
                case "AXPress":
                    if (e.TryGetCurrentPattern(InvokePattern.Pattern, out p)) ((InvokePattern)p).Invoke();
                    else if (e.TryGetCurrentPattern(TogglePattern.Pattern, out p)) ((TogglePattern)p).Toggle();
                    else if (e.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p)) ((SelectionItemPattern)p).Select();
                    else if (e.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out p)) ToggleExpand((ExpandCollapsePattern)p);
                    else Fail("the element can't be pressed", 5);
                    break;
                case "AXShowMenu":
                    if (e.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out p)) ((ExpandCollapsePattern)p).Expand();
                    else Fail("the element has no menu to open", 5);
                    break;
                case "AXIncrement":
                case "AXDecrement":
                    Step(e, action == "AXIncrement");
                    break;
                case "AXConfirm":
                    Fail("no confirm action on Windows", 5);
                    break;
                case "focus":
                    e.SetFocus();
                    break;
                case "select":
                    if (e.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p)) ((SelectionItemPattern)p).Select();
                    else Fail("the element can't be selected", 5);
                    break;
                case "show":
                    if (e.TryGetCurrentPattern(ScrollItemPattern.Pattern, out p)) ((ScrollItemPattern)p).ScrollIntoView();
                    break;
                case "setvalue":
                    if (e.Current.IsPassword) Fail("a password field: EveryAI never types into one", 5);
                    if (e.TryGetCurrentPattern(ValuePattern.Pattern, out p)) ((ValuePattern)p).SetValue(text ?? "");
                    else Fail("the element has no value to set", 5);
                    break;
                default:
                    if (Fail2("unknown action " + action)) return;
                    break;
            }
        }
        catch (InvalidOperationException ex) { Fail(action + " failed: " + ex.Message, 5); }
        catch (ElementNotAvailableException) { Fail("the element went away: take a new tree", 4); }
        var ok = new Dictionary<string, object>();
        ok["ok"] = true;
        Emit(ok);
    }

    static bool Fail2(string m) { Fail(m, 5); return true; }

    static void ToggleExpand(ExpandCollapsePattern p)
    {
        if (p.Current.ExpandCollapseState == ExpandCollapseState.Expanded) p.Collapse(); else p.Expand();
    }

    static void Step(AutomationElement e, bool up)
    {
        object p;
        if (e.TryGetCurrentPattern(RangeValuePattern.Pattern, out p))
        {
            var r = (RangeValuePattern)p;
            double step = r.Current.SmallChange > 0 ? r.Current.SmallChange : 1;
            double v = r.Current.Value + (up ? step : -step);
            r.SetValue(Math.Max(r.Current.Minimum, Math.Min(r.Current.Maximum, v)));
            return;
        }
        // A scroll bar without a range: scroll its container.
        var horizontal = e.Current.Orientation == OrientationType.Horizontal;
        for (var c = Walker.GetParent(e); c != null; c = Walker.GetParent(c))
        {
            if (c.TryGetCurrentPattern(ScrollPattern.Pattern, out p))
            {
                var amount = up ? ScrollAmount.SmallIncrement : ScrollAmount.SmallDecrement;
                if (horizontal) ((ScrollPattern)p).ScrollHorizontal(amount);
                else ((ScrollPattern)p).ScrollVertical(amount);
                return;
            }
        }
        Fail("nothing to scroll here", 5);
    }

    // ---- real input

    static void WaitForUser()
    {
        for (int i = 0; i < 80; i++)
        {
            var info = new Native.LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(Native.LASTINPUTINFO));
            if (!Native.GetLastInputInfo(ref info) || unchecked(Native.GetTickCount() - info.dwTime) >= 600) return;
            Thread.Sleep(100);
        }
        Fail("the user is using the mouse or keyboard: try again in a moment", 8);
    }

    static void Raise(uint pid)
    {
        var w = Pick(pid, Value("window"));
        uint front;
        Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out front);
        if (front == pid && Value("window") == null) return;
        // Windows only lets the process that has the last input move the focus: a released Alt key counts.
        KeyEvent(0x12, false);
        if (Native.IsIconic(w.Hwnd)) Native.ShowWindow(w.Hwnd, 9);
        Native.SetForegroundWindow(w.Hwnd);
        for (int i = 0; i < 20; i++)
        {
            Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out front);
            if (front == pid) break;
            Thread.Sleep(25);
        }
        Thread.Sleep(60);
    }

    static void GuardPointer(uint pid, params Native.POINT[] points)
    {
        WaitForUser();
        Raise(pid);
        foreach (var pt in points)
        {
            IntPtr h = Native.GetAncestor(Native.WindowFromPoint(pt), 2); // GA_ROOT
            uint owner = 0;
            if (h != IntPtr.Zero) Native.GetWindowThreadProcessId(h, out owner);
            if (owner != pid)
            {
                string where = "outside the app's windows";
                if (h != IntPtr.Zero)
                {
                    string exe = ExeOf(owner);
                    where = "under " + (exe.Length > 0 ? Path.GetFileNameWithoutExtension(exe) : "another app") + "'s window";
                }
                Fail("nothing was sent: that point is " + where + " right now, so a click there would miss the app", 7);
            }
        }
    }

    static void GuardKeys(uint pid)
    {
        WaitForUser();
        Raise(pid);
        uint front;
        Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out front);
        if (front != pid) Fail("the app didn't come to the front, so the keys would go to another app: nothing was sent", 7);
        try
        {
            var f = AutomationElement.FocusedElement;
            if (f != null && f.Current.IsPassword) Fail("a password field has the focus: EveryAI never types into password fields", 7);
        }
        catch (Exception) { }
    }

    static void Send(params Native.INPUT[] inputs)
    {
        Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Native.INPUT)));
    }

    static Native.INPUT Mouse(uint flags, int x, int y, uint data)
    {
        var i = new Native.INPUT();
        i.type = 0;
        i.u.mi.dx = x;
        i.u.mi.dy = y;
        i.u.mi.mouseData = data;
        i.u.mi.dwFlags = flags;
        return i;
    }

    static void MoveTo(double x, double y)
    {
        // Absolute coordinates over the whole virtual desktop, 0..65535.
        int vx = Native.GetSystemMetrics(76), vy = Native.GetSystemMetrics(77);
        int vw = Math.Max(1, Native.GetSystemMetrics(78)), vh = Math.Max(1, Native.GetSystemMetrics(79));
        int ax = (int)Math.Round((x - vx) * 65535.0 / (vw - 1));
        int ay = (int)Math.Round((y - vy) * 65535.0 / (vh - 1));
        Send(Mouse(0x0001 | 0x8000 | 0x4000, ax, ay, 0)); // MOVE | ABSOLUTE | VIRTUALDESK
    }

    static void Click(uint pid, double x, double y, int count, bool right)
    {
        if (Flag("front")) GuardPointer(pid, Pt(x, y));
        MoveTo(x, y);
        uint down = right ? 0x0008u : 0x0002u, up = right ? 0x0010u : 0x0004u;
        for (int i = 0; i < Math.Max(1, count); i++)
        {
            Send(Mouse(down, 0, 0, 0), Mouse(up, 0, 0, 0));
            Thread.Sleep(30);
        }
    }

    static Native.POINT Pt(double x, double y)
    {
        var p = new Native.POINT();
        p.X = (int)Math.Round(x);
        p.Y = (int)Math.Round(y);
        return p;
    }

    static void Drag(uint pid, double x, double y, double tx, double ty)
    {
        if (Flag("front")) GuardPointer(pid, Pt(x, y), Pt(tx, ty));
        MoveTo(x, y);
        Send(Mouse(0x0002, 0, 0, 0));
        for (int i = 1; i <= 16; i++)
        {
            double t = i / 16.0;
            MoveTo(x + (tx - x) * t, y + (ty - y) * t);
            Thread.Sleep(16);
        }
        Send(Mouse(0x0004, 0, 0, 0));
    }

    static void Scroll(uint pid, double x, double y, double dy)
    {
        if (Flag("front")) GuardPointer(pid, Pt(x, y));
        MoveTo(x, y);
        int notches = Math.Max(1, Math.Min(30, (int)Math.Round(Math.Abs(dy) / 40)));
        int data = (dy > 0 ? -120 : 120) * notches;
        Send(Mouse(0x0800, 0, 0, unchecked((uint)data))); // WHEEL
    }

    static void KeyEvent(ushort vk, bool down)
    {
        var i = new Native.INPUT();
        i.type = 1;
        i.u.ki.wVk = vk;
        i.u.ki.dwFlags = down ? 0u : 0x0002u;
        Send(i);
    }

    static readonly Dictionary<string, ushort> Keys = new Dictionary<string, ushort>
    {
        { "enter", 0x0D }, { "return", 0x0D }, { "escape", 0x1B }, { "esc", 0x1B }, { "tab", 0x09 }, { "space", 0x20 },
        { "backspace", 0x08 }, { "delete", 0x2E }, { "home", 0x24 }, { "end", 0x23 }, { "pageup", 0x21 },
        { "pagedown", 0x22 }, { "up", 0x26 }, { "down", 0x28 }, { "left", 0x25 }, { "right", 0x27 },
        { "arrowup", 0x26 }, { "arrowdown", 0x28 }, { "arrowleft", 0x25 }, { "arrowright", 0x27 }, { "menu", 0x5D },
    };

    static readonly Dictionary<string, ushort> Mods = new Dictionary<string, ushort>
    {
        { "ctrl", 0x11 }, { "control", 0x11 }, { "cmd", 0x11 }, { "command", 0x11 }, { "shift", 0x10 }, { "alt", 0x12 },
        { "option", 0x12 }, { "win", 0x5B }, { "super", 0x5B }, { "meta", 0x5B },
    };

    static ushort? Vk(string name)
    {
        string n = name.ToLowerInvariant();
        ushort vk;
        if (Keys.TryGetValue(n, out vk)) return vk;
        if (n.Length == 1 && n[0] >= 'a' && n[0] <= 'z') return (ushort)char.ToUpperInvariant(n[0]);
        if (n.Length == 1 && n[0] >= '0' && n[0] <= '9') return (ushort)n[0];
        int f;
        if (n.Length >= 2 && n[0] == 'f' && int.TryParse(n.Substring(1), out f) && f >= 1 && f <= 24) return (ushort)(0x70 + f - 1);
        return null;
    }

    static void Key(uint pid, string text, string name, string mods)
    {
        if (Flag("front")) GuardKeys(pid);
        var held = new List<ushort>();
        foreach (var m in (mods ?? "").Split(','))
        {
            ushort vk;
            if (Mods.TryGetValue(m.Trim().ToLowerInvariant(), out vk)) held.Add(vk);
        }
        foreach (var vk in held) KeyEvent(vk, true);
        try
        {
            if (name != null)
            {
                var vk = Vk(name);
                if (vk == null) Fail("unknown key \"" + name + "\"", 2);
                KeyEvent(vk.Value, true);
                KeyEvent(vk.Value, false);
                return;
            }
            foreach (char c in text ?? "")
            {
                var down = new Native.INPUT();
                down.type = 1;
                down.u.ki.wScan = c;
                down.u.ki.dwFlags = 0x0004; // UNICODE
                var up = down;
                up.u.ki.dwFlags = 0x0004 | 0x0002;
                Send(down, up);
                Thread.Sleep(4);
            }
        }
        finally
        {
            held.Reverse();
            foreach (var vk in held) KeyEvent(vk, false);
        }
    }

    // ---- pictures

    /// The window as a bitmap, with the same app's pop-ups (menus, drop-down lists) drawn over it.
    static Bitmap Grab(IntPtr hwnd)
    {
        var frame = Bounds(hwnd);
        int w = frame.Right - frame.Left, h = frame.Bottom - frame.Top;
        if (w <= 0 || h <= 0) Fail("no window " + hwnd.ToInt64(), 4);
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        uint pid;
        Native.GetWindowThreadProcessId(hwnd, out pid);
        var layers = new List<Win>();
        foreach (var t in TopLevels(true))
        {
            if (t.Hwnd == hwnd) break; // frontmost first: what came before it is over it
            if (t.Pid == pid && t.Rect.Left < frame.Right && t.Rect.Right > frame.Left && t.Rect.Top < frame.Bottom &&
                t.Rect.Bottom > frame.Top) layers.Add(t);
        }
        layers.Reverse();
        using (var g = Graphics.FromImage(bmp))
        {
            Paint(g, hwnd, frame);
            foreach (var l in layers) Paint(g, l.Hwnd, frame);
        }
        return bmp;
    }

    static void Paint(Graphics g, IntPtr hwnd, Native.RECT frame)
    {
        Native.RECT full;
        Native.GetWindowRect(hwnd, out full);
        int w = full.Right - full.Left, h = full.Bottom - full.Top;
        if (w <= 0 || h <= 0) return;
        using (var part = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        {
            using (var pg = Graphics.FromImage(part))
            {
                IntPtr dc = pg.GetHdc();
                try { Native.PrintWindow(hwnd, dc, 2); } // PW_RENDERFULLCONTENT
                finally { pg.ReleaseHdc(dc); }
            }
            g.DrawImage(part, full.Left - frame.Left, full.Top - frame.Top);
        }
    }

    static void Shot(IntPtr hwnd, string output)
    {
        using (var bmp = Grab(hwnd))
        {
            bmp.Save(output, ImageFormat.Png);
            var o = new Dictionary<string, object>();
            o["ok"] = true;
            o["width"] = (long)bmp.Width;
            o["height"] = (long)bmp.Height;
            Emit(o);
        }
    }

    static void Stream(IntPtr hwnd, double fps, double scale)
    {
        var stdout = Console.OpenStandardOutput();
        ImageCodecInfo jpeg = null;
        foreach (var c in ImageCodecInfo.GetImageEncoders()) if (c.MimeType == "image/jpeg") jpeg = c;
        var ps = new EncoderParameters(1);
        ps.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 70L);
        var ascii = Encoding.ASCII;
        while (true)
        {
            var started = Environment.TickCount;
            byte[] data;
            using (var bmp = Grab(hwnd))
            using (var small = new Bitmap(bmp, Math.Max(1, (int)(bmp.Width * scale)), Math.Max(1, (int)(bmp.Height * scale))))
            using (var ms = new MemoryStream())
            {
                small.Save(ms, jpeg, ps);
                data = ms.ToArray();
            }
            try
            {
                var head = ascii.GetBytes("--everyaiframe\r\nContent-Type: image/jpeg\r\nContent-Length: " + data.Length + "\r\n\r\n");
                stdout.Write(head, 0, head.Length);
                stdout.Write(data, 0, data.Length);
                stdout.Write(new byte[] { 13, 10 }, 0, 2);
                stdout.Flush();
            }
            catch (IOException) { return; }
            int wait = (int)(1000 / Math.Max(1, fps)) - (Environment.TickCount - started);
            if (wait > 0) Thread.Sleep(wait);
        }
    }

    // ---- main

    static uint NeedPid()
    {
        uint pid;
        if (!uint.TryParse(Value("pid"), out pid)) Fail("--pid is needed", 1);
        return pid;
    }

    static int Main(string[] argv)
    {
        args = new List<string>(argv);
        string command = args.Count > 0 ? args[0] : "help";
        if (args.Count > 0) args.RemoveAt(0);
        // Pixels everywhere (UI Automation, window frames, input), whatever the display scaling.
        Native.SetProcessDPIAware();
        var ok = new Dictionary<string, object>();
        ok["ok"] = true;
        switch (command)
        {
            case "trusted":
                var t = new Dictionary<string, object>();
                t["ax"] = true;
                t["screen"] = true;
                Emit(t);
                break;
            case "windows":
                var pids = new HashSet<uint>();
                for (int i = 0; i + 1 < args.Count; i++)
                {
                    uint p;
                    if (args[i] == "--pid" && uint.TryParse(args[i + 1], out p)) pids.Add(p);
                }
                var list = new List<object>();
                foreach (var w in TopLevels(false)) if (pids.Count == 0 || pids.Contains(w.Pid)) list.Add(Describe(w));
                Emit(list);
                break;
            case "procs":
                Emit(Procs());
                break;
            case "tree":
                Tree(NeedPid(), Value("window"));
                break;
            case "act":
                if (Value("path") == null || Value("action") == null) Fail("act needs --path and --action", 1);
                NeedPid();
                Act(Value("path"), Value("action"), TextArg());
                break;
            case "click":
                if (Number("x") == null || Number("y") == null) Fail("click needs --x and --y", 1);
                Click(NeedPid(), Number("x").Value, Number("y").Value, (int)(Number("count") ?? 1), Flag("right"));
                Emit(ok);
                break;
            case "drag":
                if (Number("x") == null || Number("y") == null || Number("to-x") == null || Number("to-y") == null)
                    Fail("drag needs --x, --y, --to-x and --to-y", 1);
                Drag(NeedPid(), Number("x").Value, Number("y").Value, Number("to-x").Value, Number("to-y").Value);
                Emit(ok);
                break;
            case "scroll":
                if (Number("x") == null || Number("y") == null || Number("dy") == null) Fail("scroll needs --x, --y and --dy", 1);
                Scroll(NeedPid(), Number("x").Value, Number("y").Value, Number("dy").Value);
                Emit(ok);
                break;
            case "key":
                Key(NeedPid(), TextArg(), Value("keyname"), Value("mods"));
                Emit(ok);
                break;
            case "raise":
                Raise(NeedPid());
                Emit(ok);
                break;
            case "shot":
                if (Value("window") == null || Value("out") == null) Fail("shot needs --window and --out", 1);
                Shot(new IntPtr(long.Parse(Value("window"), CultureInfo.InvariantCulture)), Value("out"));
                break;
            case "stream":
                if (Value("window") == null) Fail("stream needs --window", 1);
                Stream(new IntPtr(long.Parse(Value("window"), CultureInfo.InvariantCulture)), Number("fps") ?? 8, Number("scale") ?? 0.5);
                break;
            default:
                Console.Error.WriteLine("usage: everyai-win windows|procs|tree|act|click|drag|scroll|key|raise|shot|stream|trusted ...");
                return 2;
        }
        return 0;
    }
}
