using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

internal static class Launcher
{
    private const string WindowTitle = "LRCDF";
    private const int Restore = 9;
    private const uint NoMove = 0x0002;
    private const uint NoSize = 0x0001;
    private const uint NoActivate = 0x0010;
    private static readonly IntPtr Top = IntPtr.Zero;

    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr window, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(
        IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

    private static bool BringRunningWindowForward(string python)
    {
        IntPtr window = IntPtr.Zero;
        EnumWindows(delegate(IntPtr candidate, IntPtr parameter)
        {
            if (!IsWindowVisible(candidate))
                return true;
            StringBuilder title = new StringBuilder(256);
            GetWindowText(candidate, title, title.Capacity);
            if (!title.ToString().StartsWith("LRCDF", StringComparison.Ordinal))
                return true;

            uint ownerId;
            GetWindowThreadProcessId(candidate, out ownerId);
            if (ownerId == 0)
                return true;
            try
            {
                using (Process owner = Process.GetProcessById((int)ownerId))
                {
                    if (!string.Equals(owner.MainModule.FileName, python, StringComparison.OrdinalIgnoreCase))
                        return true;
                }
            }
            catch (ArgumentException)
            {
                return true; // The window closed while we were locating it.
            }
            catch (Win32Exception)
            {
                return true; // The identically titled window could not be identified.
            }
            window = candidate;
            return false;
        }, IntPtr.Zero);
        if (window == IntPtr.Zero)
            return false;

        if (IsIconic(window))
            ShowWindowAsync(window, Restore);
        // The user just asked Lightroom to open LRCDF. Activate the existing app
        // immediately, while the launcher still has the foreground entitlement.
        if (!SetForegroundWindow(window))
            SetWindowPos(window, Top, 0, 0, 0, 0, NoMove | NoSize | NoActivate);
        return true;
    }

    private static bool UpdateInProgress(string root)
    {
        string marker = Path.Combine(root, @".update\installing");
        if (!File.Exists(marker))
            return false;
        try
        {
            using (File.Open(marker, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                return false;
        }
        catch (FileNotFoundException)
        {
            return false;
        }
        catch (IOException)
        {
            return true; // Update-Windows.ps1 owns the exclusive handle until it can reopen the app.
        }
    }

    [STAThread]
    private static int Main()
    {
        string appDirectory = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
        string root = Path.GetFullPath(Path.Combine(appDirectory, @"..\.."));
        if (UpdateInProgress(root))
            return 0;
        string python = Path.Combine(root, @"python\pythonw.exe");
        if (BringRunningWindowForward(python))
            return 0;

        try
        {
            using (Process.Start(new ProcessStartInfo
            {
                FileName = python,
                Arguments = "-s -X utf8 -m windows",
                WorkingDirectory = appDirectory,
                UseShellExecute = false
            }))
            {
                return 0;
            }
        }
        catch (Win32Exception error)
        {
            MessageBox.Show(error.Message, WindowTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
