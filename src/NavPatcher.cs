using System;
using System.IO;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;

namespace SsmsPatcher;

public static class NavPatcher
{
    // Rewrites NavigationService.Initialize/GetView/GetEntity to be no-ops
    // in Explorer.dll. Works around a VS Shell IServiceContainer walk that
    // returns null under Wine (see APPDB entry, "Bug 3").
    public static int Run(string ideDir, bool dryRun)
    {
        var layout = PathResolver.Resolve(ideDir);
        if (!layout.HasExplorer)
        {
            Console.Error.WriteLine("target DLL not found anywhere under IDE_DIR: " +
                                    PathResolver.NavTargets[0]);
            Console.Error.WriteLine("hint: run `ssms-patcher locate <IDE_DIR>` to see the map.");
            return 1;
        }

        string target = layout.ExplorerDll;
        string rel = Path.GetRelativePath(ideDir, target);
        Console.WriteLine($"patch-nav target: {rel}");

        if (dryRun)
        {
            Console.WriteLine("  [dry] would rewrite Initialize/GetView/GetEntity to no-op");
            return 0;
        }

        string backup = target + ".preinject";
        if (!File.Exists(backup)) File.Copy(target, backup);
        else File.Copy(backup, target, true); // idempotent: re-apply on top of the pristine copy

        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(Path.GetDirectoryName(target));
        var rp = new ReaderParameters { InMemory = true, AssemblyResolver = resolver };
        using var asm = AssemblyDefinition.ReadAssembly(target, rp);
        var module = asm.MainModule;

        var navSvc = module.Types.FirstOrDefault(t =>
            t.FullName == "Microsoft.SqlServer.Management.SqlStudio.Explorer.NavigationService");
        if (navSvc == null)
        {
            Console.Error.WriteLine("NavigationService type not found in " + rel);
            return 1;
        }

        int patched = 0;
        foreach (var m in navSvc.Methods)
        {
            if (!m.HasBody) continue;
            if (m.Name == "Initialize" && m.Parameters.Count == 0 && m.ReturnType.FullName == "System.Void")
            {
                m.Body = new MethodBody(m);
                m.Body.GetILProcessor().Emit(OpCodes.Ret);
                Console.WriteLine($"  [+] {m.Name} -> no-op");
                patched++;
            }
            else if ((m.Name == "GetView" || m.Name == "GetEntity") && m.Parameters.Count == 1)
            {
                m.Body = new MethodBody(m);
                var il = m.Body.GetILProcessor();
                il.Emit(OpCodes.Ldnull);
                il.Emit(OpCodes.Ret);
                Console.WriteLine($"  [+] {m.Name}(string) -> null");
                patched++;
            }
        }

        asm.Write(target);
        Console.WriteLine($"\npatch-nav complete: {patched} method(s) rewritten in {Path.GetFileName(target)}");
        return 0;
    }
}
