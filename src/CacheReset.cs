using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace SsmsPatcher;

// VS Shell caches the state of every loaded package under
// AppData/Local/Microsoft/SQL Server Management Studio/20.0_IsoShell/ComponentModelCache.
// Once a package fails to load (Explorer, for example), that state sticks
// and even a fixed assembly keeps getting rejected until the cache is wiped
// and `Ssms.exe /updateconfiguration` regenerates it.
public static class CacheReset
{
    public static int Run(string winePrefix, string ssmsExe, bool skipUpdate)
    {
        if (!Directory.Exists(winePrefix))
        {
            Console.Error.WriteLine($"WINEPREFIX not found: {winePrefix}");
            return 2;
        }

        int removed = 0;
        foreach (var cacheDir in FindCacheDirs(winePrefix))
        {
            try
            {
                Directory.Delete(cacheDir, recursive: true);
                Console.WriteLine($"  [-] removed {cacheDir}");
                removed++;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"  [!] could not remove {cacheDir}: {ex.Message}");
            }
        }

        if (removed == 0)
        {
            Console.WriteLine("no ComponentModelCache directories found (already clean).");
        }

        if (!skipUpdate && !string.IsNullOrEmpty(ssmsExe))
        {
            Console.WriteLine("running Ssms.exe /updateconfiguration ...");
            var wineCmd = Environment.GetEnvironmentVariable("SSMS_WINE") ?? "wine";
            var psi = new ProcessStartInfo(wineCmd, $"\"{ssmsExe}\" /updateconfiguration")
            {
                UseShellExecute = false,
                RedirectStandardOutput = false,
                RedirectStandardError = false,
            };
            psi.Environment["WINEPREFIX"] = winePrefix;
            try
            {
                var p = Process.Start(psi);
                if (p == null)
                {
                    Console.Error.WriteLine("  [!] failed to start wine");
                    return 1;
                }
                // /updateconfiguration should exit within a minute on a warm prefix.
                if (!p.WaitForExit(180_000))
                {
                    Console.Error.WriteLine("  [!] /updateconfiguration timed out after 180s; killing.");
                    try { p.Kill(entireProcessTree: true); } catch { }
                    return 1;
                }
                Console.WriteLine($"  /updateconfiguration exit code: {p.ExitCode}");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"  [!] wine invocation failed: {ex.Message}");
                Console.Error.WriteLine("  (set SSMS_WINE=/path/to/wine if wine is not in PATH)");
                return 1;
            }
        }
        return 0;
    }

    static string[] FindCacheDirs(string winePrefix)
    {
        var usersRoot = Path.Combine(winePrefix, "drive_c", "users");
        if (!Directory.Exists(usersRoot)) return Array.Empty<string>();
        return Directory.EnumerateDirectories(usersRoot)
            .SelectMany(u =>
            {
                var appdata = Path.Combine(u, "AppData", "Local", "Microsoft", "SQL Server Management Studio");
                if (!Directory.Exists(appdata)) return Array.Empty<string>();
                return Directory.EnumerateDirectories(appdata)
                    .Select(v => Path.Combine(v, "ComponentModelCache"))
                    .Where(Directory.Exists);
            })
            .ToArray();
    }
}
