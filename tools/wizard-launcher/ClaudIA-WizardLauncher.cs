// ===========================================================================
// ClaudIA-WizardLauncher.cs - tiny native launcher for the ClaudIA setup
// wizard. Compiled by tools\Build-WizardExe.ps1 with the C# compiler that
// ships inside the .NET Framework on every Windows machine (no SDK needed).
//
// What it does (and nothing more):
//   1. Finds the ClaudIA repository root (its own folder, or the parent when
//      it runs from dist\).
//   2. Finds PowerShell 7 (pwsh.exe); offers to install it with winget if
//      missing.
//   3. Starts:  pwsh -NoProfile -ExecutionPolicy Bypass -File
//               <root>\Setup-ClaudIA-Wizard.ps1
//      and propagates the wizard's exit code.
//
// All deployment logic stays in the audited PowerShell scripts; this binary
// contains no credentials, no network calls and no elevation.
// Kept C# 5 compatible on purpose (in-box csc.exe v4.0.30319).
// ===========================================================================
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace ClaudIA
{
    internal static class WizardLauncher
    {
        private const string WizardFile = "Setup-ClaudIA-Wizard.ps1";
        private const string Title = "ClaudIA setup wizard";

        [STAThread]
        private static int Main()
        {
            try
            {
                string root = FindRepoRoot();
                if (root == null)
                {
                    MessageBox.Show(
                        WizardFile + " was not found next to this launcher (or up to two folders up)." +
                        Environment.NewLine + Environment.NewLine +
                        "Keep the launcher inside the ClaudIA repository (root or dist folder) and try again.",
                        Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 1;
                }

                string pwsh = FindPwsh();
                if (pwsh == null)
                {
                    DialogResult answer = MessageBox.Show(
                        "PowerShell 7 is required by the ClaudIA wizard and was not found." +
                        Environment.NewLine + Environment.NewLine +
                        "Install it now with winget? (a console window will open)",
                        Title, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                    if (answer == DialogResult.Yes)
                    {
                        RunVisible("winget",
                            "install --id Microsoft.PowerShell --source winget " +
                            "--accept-package-agreements --accept-source-agreements");
                        pwsh = FindPwsh();
                    }
                    if (pwsh == null)
                    {
                        MessageBox.Show(
                            "PowerShell 7 is still not available. Install it from https://aka.ms/powershell then run this launcher again.",
                            Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 1;
                    }
                }

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = pwsh;
                psi.Arguments = string.Format(
                    "-NoProfile -ExecutionPolicy Bypass -File \"{0}\"",
                    Path.Combine(root, WizardFile));
                psi.WorkingDirectory = root;
                psi.UseShellExecute = false;
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit();
                    return p.ExitCode;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "The launcher hit an unexpected error:" + Environment.NewLine + ex.Message,
                    Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        // Repo root = folder containing Setup-ClaudIA-Wizard.ps1. Checked in
        // order: the exe's folder, its parent (dist\ case), its grandparent.
        private static string FindRepoRoot()
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            for (int i = 0; i < 3 && dir != null; i++)
            {
                if (File.Exists(Path.Combine(dir, WizardFile))) { return dir; }
                DirectoryInfo parent = new DirectoryInfo(dir).Parent; // null at a drive root
                dir = (parent == null) ? null : parent.FullName;
            }
            return null;
        }

        private static string FindPwsh()
        {
            string pathEnv = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            foreach (string raw in pathEnv.Split(';'))
            {
                string seg = raw.Trim();
                if (seg.Length == 0) { continue; }
                try
                {
                    string candidate = Path.Combine(seg, "pwsh.exe");
                    if (File.Exists(candidate)) { return candidate; }
                }
                catch (ArgumentException) { } // invalid chars in a PATH segment
            }
            string programFiles = Environment.GetEnvironmentVariable("ProgramFiles");
            if (!string.IsNullOrEmpty(programFiles))
            {
                string standard = Path.Combine(programFiles, @"PowerShell\7\pwsh.exe");
                if (File.Exists(standard)) { return standard; }
            }
            return null;
        }

        // Runs a console tool in its own visible window and waits, so the user
        // can watch winget's progress. Errors are reported by the caller's
        // post-install recheck instead of the exit code.
        private static void RunVisible(string file, string args)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = file;
                psi.Arguments = args;
                psi.UseShellExecute = true;
                using (Process p = Process.Start(psi)) { p.WaitForExit(); }
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Could not start winget: " + ex.Message +
                    Environment.NewLine + "Install PowerShell 7 manually from https://aka.ms/powershell.",
                    Title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }
    }
}
