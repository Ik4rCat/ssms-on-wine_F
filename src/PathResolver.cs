using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace SsmsPatcher;

// Locates SSMS binaries inside a Common7/IDE directory regardless of the
// version-specific layout. SSMS 20.0.x kept most assemblies at the root of
// IDE/; 20.2.x moved package assemblies into Extensions/Application/ and
// typelibs into Automation/. Rather than hard-code paths we walk the tree.
public sealed class IdeLayout
{
    public string IdeDir { get; init; } = "";
    public string SsmsExePath { get; init; } = "";
    public string SsmsVersion { get; init; } = "unknown";
    public string ExplorerDll { get; init; } = "";
    public Dictionary<string, string> Typelibs { get; init; } = new();
    public List<string> PackageAssemblyDirs { get; init; } = new();

    public bool HasExplorer => !string.IsNullOrEmpty(ExplorerDll);
    public bool HasTypelibs => Typelibs.Count > 0;
}

public static class PathResolver
{
    // Names patch-nav needs. The list stays small on purpose — new
    // targets are added deliberately, not discovered by heuristic.
    public static readonly string[] NavTargets =
    {
        "Microsoft.SqlServer.Management.SqlStudio.Explorer.dll",
    };

    public static readonly string[] TypelibNames =
    {
        "dte80.olb", "dte80a.olb", "dte90.olb", "dte90a.olb", "dte100.olb",
    };

    public static IdeLayout Resolve(string ideDir)
    {
        if (!Directory.Exists(ideDir))
            throw new DirectoryNotFoundException($"IDE dir not found: {ideDir}");

        var ssmsExe = Path.Combine(ideDir, "Ssms.exe");
        var version = "unknown";
        if (File.Exists(ssmsExe))
        {
            try
            {
                var fvi = FileVersionInfo.GetVersionInfo(ssmsExe);
                if (!string.IsNullOrWhiteSpace(fvi.FileVersion))
                    version = fvi.FileVersion.Trim();
            }
            catch
            {
                // FileVersionInfo can fail on non-PE files or with weird
                // resources — non-fatal, we keep "unknown".
            }
        }

        string explorer = FindFirst(ideDir, NavTargets[0]);

        var typelibs = new Dictionary<string, string>();
        foreach (var name in TypelibNames)
        {
            var p = FindFirst(ideDir, name);
            if (!string.IsNullOrEmpty(p)) typelibs[name] = p;
        }

        var pkgDirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var pkgdef in Directory.EnumerateFiles(ideDir, "*.pkgdef", SearchOption.AllDirectories))
            {
                var d = Path.GetDirectoryName(pkgdef);
                if (!string.IsNullOrEmpty(d)) pkgDirs.Add(d);
            }
        }
        catch { /* readdir failures are non-fatal */ }

        return new IdeLayout
        {
            IdeDir = ideDir,
            SsmsExePath = File.Exists(ssmsExe) ? ssmsExe : "",
            SsmsVersion = version,
            ExplorerDll = explorer,
            Typelibs = typelibs,
            PackageAssemblyDirs = pkgDirs.OrderBy(x => x).ToList(),
        };
    }

    public static string FindFirst(string root, string fileName)
    {
        try
        {
            return Directory.EnumerateFiles(root, fileName, SearchOption.AllDirectories)
                .FirstOrDefault() ?? "";
        }
        catch
        {
            return "";
        }
    }

    // A DLL is considered a "VS package assembly" if a .pkgdef with the same
    // stem sits next to it. Cecil-rewriting these tends to invalidate the
    // strong-name / manifest hash cached by VS Shell (see task problem 2).
    public static bool IsPackageAssembly(string dllPath)
    {
        var dir = Path.GetDirectoryName(dllPath);
        if (string.IsNullOrEmpty(dir)) return false;
        var stem = Path.GetFileNameWithoutExtension(dllPath);
        return File.Exists(Path.Combine(dir, stem + ".pkgdef"));
    }

    public static bool HasStrongName(string dllPath)
    {
        try
        {
            using var fs = File.OpenRead(dllPath);
            using var asm = Mono.Cecil.AssemblyDefinition.ReadAssembly(fs);
            return asm.Name.HasPublicKey && asm.Name.PublicKey.Length > 0;
        }
        catch
        {
            return false;
        }
    }
}
