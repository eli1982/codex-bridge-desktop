using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

[assembly: AssemblyTitle("Codex Bridge")]
[assembly: AssemblyDescription("Codex ChatGPT Bridge tray host")]
[assembly: AssemblyProduct("Codex Bridge")]

internal static class BridgeLauncher
{
    private const uint KillOnJobClose = 0x00002000;
    private const int JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation
    {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job, int informationClass, ref ExtendedLimitInformation information, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static void ShowExistingTray()
    {
        try
        {
            using (var signal = System.Threading.EventWaitHandle.OpenExisting(
                @"Local\CodexChatGPTBridgeTrayShow"))
                signal.Set();
        }
        catch { }
    }

    [STAThread]
    private static int Main()
    {
        bool created;
        using (var mutex = new System.Threading.Mutex(true, @"Local\CodexBridgeHost", out created))
        {
            if (!created)
            {
                ShowExistingTray();
                return 0;
            }

            IntPtr job = IntPtr.Zero;
            Process tray = null;
            try
            {
                string directory = AppDomain.CurrentDomain.BaseDirectory;
                string trayScript = Path.Combine(directory, "bridge-tray.ps1");
                if (!File.Exists(trayScript))
                    throw new FileNotFoundException("bridge-tray.ps1 must be beside Codex Bridge.exe.");

                job = CreateJobObject(IntPtr.Zero, null);
                if (job == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot create the bridge process group.");
                var limits = new ExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags = KillOnJobClose;
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                    ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimitInformation))))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot secure the bridge process group.");

                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    @"System32\WindowsPowerShell\v1.0\powershell.exe");
                var start = new ProcessStartInfo
                {
                    FileName = powershell,
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + trayScript + "\"",
                    WorkingDirectory = directory,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                tray = Process.Start(start);
                if (tray == null)
                    throw new InvalidOperationException("The bridge tray did not start.");
                if (!tray.HasExited && !AssignProcessToJobObject(job, tray.Handle))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot attach the tray to the bridge process group.");

                tray.WaitForExit();
                return tray.ExitCode;
            }
            catch (Exception error)
            {
                if (tray != null && !tray.HasExited) tray.Kill();
                MessageBox.Show(error.Message, "Codex Bridge", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                if (tray != null) tray.Dispose();
                if (job != IntPtr.Zero) CloseHandle(job);
                mutex.ReleaseMutex();
            }
        }
    }
}