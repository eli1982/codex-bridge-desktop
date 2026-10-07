using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Kill Codex Bridge")]
[assembly: AssemblyDescription("Stop the Codex Bridge tray, local server, and tunnel")]
[assembly: AssemblyProduct("Codex Bridge")]

internal static class KillBridgeLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        bool quiet = args.Length > 0 && args[0] == "--quiet";
        try
        {
            string directory = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(directory, "bridge-kill.ps1");
            if (!File.Exists(script))
                throw new FileNotFoundException("bridge-kill.ps1 must be beside Kill Codex Bridge.exe.");

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            var start = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"",
                WorkingDirectory = directory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var process = Process.Start(start))
            {
                if (process == null || !process.WaitForExit(90000))
                {
                    if (process != null) process.Kill();
                    throw new TimeoutException("Shutdown did not finish within 90 seconds.");
                }
                string output = process.StandardOutput.ReadToEnd().Trim();
                string error = process.StandardError.ReadToEnd().Trim();
                if (process.ExitCode != 0)
                    throw new InvalidOperationException(
                        string.IsNullOrEmpty(error) ? output : error);
            }

            return 0;
        }
        catch (Exception error)
        {
            if (!quiet) MessageBox.Show("Could not confirm full shutdown.\n\n" + error.Message,
                "Kill Codex Bridge", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}