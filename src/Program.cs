using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace SsmsPatcher;

// Entry point + argument parsing. Command implementations live in the
// per-concern modules (GifPatcher, NavPatcher, PathResolver, CacheReset,
// ActivityLog).
//
// Usage:
//   ssms-patcher locate      <IDE_DIR>
//   ssms-patcher patch-gifs  <IDE_DIR> [--dry-run] [--exclude <glob>] [--force-strong]
//   ssms-patcher patch-nav   <IDE_DIR> [--dry-run]
//   ssms-patcher restore     <IDE_DIR> [--file <path>]
//   ssms-patcher verify      <IDE_DIR>
//   ssms-patcher reset-cache <WINEPREFIX> [--ssms-exe <PATH>] [--skip-update]
//   ssms-patcher parse-log   <ActivityLog.xml> [--all]
//   ssms-patcher --help
static class Program
{
    static int Main(string[] args)
    {
        if (args.Length == 0 || args[0] is "--help" or "-h" or "help")
        {
            PrintUsage();
            return args.Length == 0 ? 2 : 0;
        }
        string cmd = args[0];
        try
        {
            return cmd switch
            {
                "locate" => Locate(args),
                "patch-gifs" => PatchGifs(args),
                "patch-nav" => PatchNav(args),
                "restore" => Restore(args),
                "verify" => Verify(args),
                "reset-cache" => ResetCache(args),
                "parse-log" => ParseLog(args),
                _ => Unknown(cmd),
            };
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"fatal: {e.GetType().Name}: {e.Message}");
            if (Environment.GetEnvironmentVariable("SSMS_PATCHER_TRACE") == "1")
                Console.Error.WriteLine(e.StackTrace);
            return 1;
        }
    }

    static int Unknown(string cmd)
    {
        Console.Error.WriteLine($"unknown command: {cmd}");
        PrintUsage();
        return 2;
    }

    static void PrintUsage()
    {
        Console.Error.WriteLine("ssms-patcher — SSMS 20 on Wine binary patcher");
        Console.Error.WriteLine();
        Console.Error.WriteLine("commands:");
        Console.Error.WriteLine("  locate      <IDE_DIR>                       print SSMS version + resolved target paths");
        Console.Error.WriteLine("  patch-gifs  <IDE_DIR> [flags]               replace embedded GIF resources with PNG");
        Console.Error.WriteLine("              --dry-run          preview without writing");
        Console.Error.WriteLine("              --exclude <glob>   skip matching DLLs (repeatable)");
        Console.Error.WriteLine("              --force-strong     patch strong-named DLLs (dangerous, may break VS packages)");
        Console.Error.WriteLine("  patch-nav   <IDE_DIR> [--dry-run]           no-op NavigationService methods");
        Console.Error.WriteLine("  restore     <IDE_DIR> [--file <path>]       revert all backups or a single file");
        Console.Error.WriteLine("  verify      <IDE_DIR>                       report which DLLs are currently patched");
        Console.Error.WriteLine("  reset-cache <WINEPREFIX> [flags]            wipe ComponentModelCache + /updateconfiguration");
        Console.Error.WriteLine("              --ssms-exe <PATH>  path to Ssms.exe inside the prefix");
        Console.Error.WriteLine("              --skip-update      skip the /updateconfiguration invocation");
        Console.Error.WriteLine("  parse-log   <ActivityLog.xml> [--all]       show ActivityLog errors (or all entries)");
        Console.Error.WriteLine();
        Console.Error.WriteLine("IDE_DIR is .../Microsoft SQL Server Management Studio 20/Common7/IDE");
    }

    // ------- argument helpers -------
    static string RequiredPositional(string[] args, int index, string name)
    {
        int seen = 0;
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i].StartsWith("--")) { i++; if (i < args.Length && !args[i].StartsWith("--")) continue; else { i--; continue; } }
            if (seen == index) return args[i];
            seen++;
        }
        Console.Error.WriteLine($"missing argument: {name}");
        Environment.Exit(2);
        return "";
    }

    static bool HasFlag(string[] args, string flag)
    {
        return args.Any(a => a == flag);
    }

    static string FlagValue(string[] args, string flag)
    {
        for (int i = 1; i < args.Length - 1; i++)
            if (args[i] == flag) return args[i + 1];
        return "";
    }

    static List<string> FlagValues(string[] args, string flag)
    {
        var r = new List<string>();
        for (int i = 1; i < args.Length - 1; i++)
            if (args[i] == flag) r.Add(args[i + 1]);
        return r;
    }

    // ------- commands -------
    static int Locate(string[] args)
    {
        string ideDir = RequiredPositional(args, 0, "IDE_DIR");
        var layout = PathResolver.Resolve(ideDir);

        Console.WriteLine($"IDE dir:      {layout.IdeDir}");
        Console.WriteLine($"Ssms.exe:     {(string.IsNullOrEmpty(layout.SsmsExePath) ? "(missing!)" : layout.SsmsExePath)}");
        Console.WriteLine($"SSMS version: {layout.SsmsVersion}");
        Console.WriteLine();
        Console.WriteLine("nav targets:");
        Console.WriteLine($"  {PathResolver.NavTargets[0]}");
        Console.WriteLine($"    -> {(layout.HasExplorer ? Path.GetRelativePath(ideDir, layout.ExplorerDll) : "(not found)")}");
        Console.WriteLine();
        Console.WriteLine("typelibs:");
        foreach (var name in PathResolver.TypelibNames)
        {
            string found = layout.Typelibs.TryGetValue(name, out var p) ? Path.GetRelativePath(ideDir, p) : "(not found)";
            Console.WriteLine($"  {name,-14} -> {found}");
        }
        Console.WriteLine();
        Console.WriteLine($"VS package assembly dirs: {layout.PackageAssemblyDirs.Count}");
        foreach (var d in layout.PackageAssemblyDirs.Take(20))
            Console.WriteLine($"  - {Path.GetRelativePath(ideDir, d)}");
        if (layout.PackageAssemblyDirs.Count > 20)
            Console.WriteLine($"  ... and {layout.PackageAssemblyDirs.Count - 20} more");
        return layout.HasExplorer ? 0 : 3;
    }

    static int PatchGifs(string[] args)
    {
        string ideDir = RequiredPositional(args, 0, "IDE_DIR");
        var opt = new GifPatcher.Options
        {
            DryRun = HasFlag(args, "--dry-run"),
            ForceStrongNamed = HasFlag(args, "--force-strong"),
            ExcludeGlobs = FlagValues(args, "--exclude"),
        };
        var r = GifPatcher.Run(ideDir, opt);
        return r.SkippedFailed > 0 ? 4 : 0;
    }

    static int PatchNav(string[] args)
    {
        string ideDir = RequiredPositional(args, 0, "IDE_DIR");
        return NavPatcher.Run(ideDir, HasFlag(args, "--dry-run"));
    }

    static int Restore(string[] args)
    {
        string ideDir = RequiredPositional(args, 0, "IDE_DIR");
        string singleFile = FlagValue(args, "--file");

        if (!string.IsNullOrEmpty(singleFile))
            return RestoreSingle(ideDir, singleFile);

        int count = 0;
        foreach (var bk in Directory.EnumerateFiles(ideDir, "*.orig-gif", SearchOption.AllDirectories))
            if (RestoreOne(bk, ".orig-gif")) count++;
        foreach (var bk in Directory.EnumerateFiles(ideDir, "*.preinject", SearchOption.AllDirectories))
            if (RestoreOne(bk, ".preinject")) count++;
        Console.WriteLine($"restored {count} DLLs");
        return 0;
    }

    static int RestoreSingle(string ideDir, string fileArg)
    {
        // Accept either the DLL path or the backup path.
        string full = Path.IsPathRooted(fileArg) ? fileArg : Path.Combine(ideDir, fileArg);
        string candidateBackup = full;
        if (!full.EndsWith(".orig-gif") && !full.EndsWith(".preinject"))
        {
            var g = full + ".orig-gif";
            var n = full + ".preinject";
            if (File.Exists(g)) candidateBackup = g;
            else if (File.Exists(n)) candidateBackup = n;
        }
        if (!File.Exists(candidateBackup))
        {
            Console.Error.WriteLine($"no backup found for: {fileArg}");
            return 1;
        }
        string ext = candidateBackup.EndsWith(".orig-gif") ? ".orig-gif" : ".preinject";
        if (RestoreOne(candidateBackup, ext))
        {
            Console.WriteLine($"restored: {Path.GetRelativePath(ideDir, candidateBackup)[..^ext.Length]}");
            return 0;
        }
        return 1;
    }

    static bool RestoreOne(string backup, string ext)
    {
        try
        {
            string orig = backup[..^ext.Length];
            File.Copy(backup, orig, true);
            File.Delete(backup);
            return true;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"  [!] restore failed for {backup}: {e.Message}");
            return false;
        }
    }

    static int Verify(string[] args)
    {
        string ideDir = RequiredPositional(args, 0, "IDE_DIR");
        var layout = PathResolver.Resolve(ideDir);

        var gifPatched = Directory.EnumerateFiles(ideDir, "*.orig-gif", SearchOption.AllDirectories).ToList();
        var navPatched = Directory.EnumerateFiles(ideDir, "*.preinject", SearchOption.AllDirectories).ToList();

        Console.WriteLine($"SSMS version:      {layout.SsmsVersion}");
        Console.WriteLine($"GIF-patched DLLs:  {gifPatched.Count}");
        foreach (var b in gifPatched.Take(10))
            Console.WriteLine($"  - {Path.GetRelativePath(ideDir, b[..^".orig-gif".Length])}");
        if (gifPatched.Count > 10) Console.WriteLine($"  ... and {gifPatched.Count - 10} more");
        Console.WriteLine($"Nav-patched DLLs:  {navPatched.Count}");
        foreach (var b in navPatched)
            Console.WriteLine($"  - {Path.GetRelativePath(ideDir, b[..^".preinject".Length])}");
        return 0;
    }

    static int ResetCache(string[] args)
    {
        string prefix = RequiredPositional(args, 0, "WINEPREFIX");
        string ssmsExe = FlagValue(args, "--ssms-exe");
        bool skipUpdate = HasFlag(args, "--skip-update");

        if (string.IsNullOrEmpty(ssmsExe) && !skipUpdate)
        {
            // Guess the standard install location.
            var guess = Path.Combine(prefix, "drive_c", "Program Files (x86)",
                "Microsoft SQL Server Management Studio 20", "Common7", "IDE", "Ssms.exe");
            if (File.Exists(guess)) ssmsExe = guess;
        }
        return CacheReset.Run(prefix, ssmsExe, skipUpdate);
    }

    static int ParseLog(string[] args)
    {
        string log = RequiredPositional(args, 0, "ActivityLog.xml");
        bool all = HasFlag(args, "--all");
        return ActivityLog.Run(log, onlyErrors: !all);
    }
}
