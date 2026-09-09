using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Mono.Cecil;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Formats.Png;
using SixLabors.ImageSharp.Processing.Processors.Quantization;

namespace SsmsPatcher;

public static class GifPatcher
{
    public sealed class Options
    {
        public bool DryRun { get; set; }
        public bool SkipPackages { get; set; } = true;
        public bool ForceStrongNamed { get; set; }
        public List<string> ExcludeGlobs { get; set; } = new();
    }

    public sealed class Report
    {
        public int Scanned;
        public int Modified;
        public int SkippedPackage;
        public int SkippedStrongName;
        public int SkippedExcluded;
        public int SkippedFailed;
        public int GifsFound;
        public int GifsReplaced;
        public List<string> Warnings { get; } = new();
    }

    public static Report Run(string ideDir, Options opt)
    {
        var r = new Report();
        Console.WriteLine($"scanning {ideDir} for DLLs with embedded GIFs...");

        foreach (var dll in Directory.EnumerateFiles(ideDir, "*.dll", SearchOption.AllDirectories))
        {
            r.Scanned++;
            string rel = Path.GetRelativePath(ideDir, dll);

            if (opt.ExcludeGlobs.Any(g => GlobMatch(g, rel) || GlobMatch(g, Path.GetFileName(dll))))
            {
                r.SkippedExcluded++;
                continue;
            }

            byte[] bytes;
            try { bytes = File.ReadAllBytes(dll); } catch { r.SkippedFailed++; continue; }
            if (!HasGifMagic(bytes)) continue;

            bool isPackage = opt.SkipPackages && PathResolver.IsPackageAssembly(dll);
            bool isStrong = PathResolver.HasStrongName(dll);

            if (isPackage)
            {
                r.SkippedPackage++;
                string msg = $"skip (VS package + strong-name risk): {rel}";
                r.Warnings.Add(msg);
                Console.WriteLine($"  [~] {msg}");
                continue;
            }
            if (isStrong && !opt.ForceStrongNamed)
            {
                r.SkippedStrongName++;
                string msg = $"skip (strong-named, use --force-strong to patch anyway): {rel}";
                r.Warnings.Add(msg);
                Console.WriteLine($"  [~] {msg}");
                continue;
            }

            byte[] patched = ProcessDll(bytes, out int found, out int replaced);
            r.GifsFound += found;

            if (replaced > 0)
            {
                r.GifsReplaced += replaced;
                r.Modified++;
                if (opt.DryRun)
                {
                    Console.WriteLine($"  [dry] {rel}: {replaced}/{found} GIFs would be replaced");
                }
                else
                {
                    string backup = dll + ".orig-gif";
                    if (!File.Exists(backup)) File.Copy(dll, backup);
                    File.WriteAllBytes(dll, patched);
                    Console.WriteLine($"  [+] {rel}: {replaced}/{found} GIFs replaced");
                }
            }
        }

        Console.WriteLine();
        Console.WriteLine($"patch-gifs {(opt.DryRun ? "(dry-run)" : "complete")}: " +
                          $"{r.Modified} DLLs {(opt.DryRun ? "would be modified" : "modified")}, " +
                          $"{r.GifsReplaced}/{r.GifsFound} GIFs replaced.");
        if (r.SkippedPackage > 0 || r.SkippedStrongName > 0 || r.SkippedExcluded > 0)
        {
            Console.WriteLine($"  skipped: {r.SkippedPackage} package, " +
                              $"{r.SkippedStrongName} strong-named, {r.SkippedExcluded} excluded.");
        }
        return r;
    }

    static bool HasGifMagic(byte[] d)
    {
        for (int i = 0; i < d.Length - 5; i++)
            if (d[i] == 'G' && d[i + 1] == 'I' && d[i + 2] == 'F' && d[i + 3] == '8' &&
                (d[i + 4] == '7' || d[i + 4] == '9') && d[i + 5] == 'a')
                return true;
        return false;
    }

    static byte[] ProcessDll(byte[] input, out int found, out int replaced)
    {
        found = 0; replaced = 0;
        try
        {
            using var ms = new MemoryStream(input);
            using var asm = AssemblyDefinition.ReadAssembly(ms);
            var resources = asm.MainModule.Resources;
            bool any = false;
            for (int i = 0; i < resources.Count; i++)
            {
                if (resources[i] is EmbeddedResource er && er.Name.EndsWith(".gif", StringComparison.OrdinalIgnoreCase))
                {
                    var png = TryConvertGifToPng(er.GetResourceData(), int.MaxValue);
                    if (png != null)
                    {
                        resources[i] = new EmbeddedResource(er.Name, er.Attributes, png);
                        replaced++; found++; any = true;
                    }
                }
                else if (resources[i] is EmbeddedResource er2 && er2.Name.EndsWith(".resources", StringComparison.OrdinalIgnoreCase))
                {
                    byte[] raw = er2.GetResourceData();
                    byte[] rewritten = ByteLevelReplaceInPlace(raw, out int f1, out int r1);
                    found += f1;
                    if (r1 > 0)
                    {
                        resources[i] = new EmbeddedResource(er2.Name, er2.Attributes, rewritten);
                        replaced += r1; any = true;
                    }
                }
            }
            if (any)
            {
                using var outMs = new MemoryStream();
                asm.Write(outMs);
                return outMs.ToArray();
            }
            return input;
        }
        catch
        {
            return ByteLevelReplaceInPlace(input, out found, out replaced);
        }
    }

    static byte[] TryConvertGifToPng(byte[] gif, int maxSize)
    {
        if (gif.Length < 6 || gif[0] != 'G' || gif[1] != 'I' || gif[2] != 'F') return null;
        try
        {
            using var img = Image.Load(gif);

            byte[] try1;
            using (var m = new MemoryStream())
            {
                img.SaveAsPng(m, new PngEncoder { CompressionLevel = PngCompressionLevel.BestCompression });
                try1 = m.ToArray();
            }
            if (try1.Length <= maxSize) return try1;

            byte[] try2;
            using (var m = new MemoryStream())
            {
                img.SaveAsPng(m, new PngEncoder
                {
                    CompressionLevel = PngCompressionLevel.BestCompression,
                    ColorType = PngColorType.Palette,
                    BitDepth = PngBitDepth.Bit8,
                    Quantizer = new WuQuantizer(new QuantizerOptions { MaxColors = 256 })
                });
                try2 = m.ToArray();
            }
            if (try2.Length <= maxSize) return try2;

            byte[] try3;
            using (var m = new MemoryStream())
            {
                img.SaveAsPng(m, new PngEncoder
                {
                    CompressionLevel = PngCompressionLevel.BestCompression,
                    ColorType = PngColorType.Palette,
                    BitDepth = PngBitDepth.Bit4,
                    Quantizer = new WuQuantizer(new QuantizerOptions { MaxColors = 16 })
                });
                try3 = m.ToArray();
            }
            if (try3.Length <= maxSize) return try3;
            return null;
        }
        catch { return null; }
    }

    static byte[] ByteLevelReplaceInPlace(byte[] data, out int found, out int replaced)
    {
        found = 0; replaced = 0;
        var result = new byte[data.Length];
        Array.Copy(data, result, data.Length);
        int i = 0;
        while (i < data.Length - 13)
        {
            if (data[i] == 'G' && data[i + 1] == 'I' && data[i + 2] == 'F' && data[i + 3] == '8'
                && (data[i + 4] == '7' || data[i + 4] == '9') && data[i + 5] == 'a')
            {
                found++;
                int end = FindGifEnd(data, i);
                if (end > i)
                {
                    int gifLen = end - i;
                    byte[] gifBytes = new byte[gifLen];
                    Array.Copy(data, i, gifBytes, 0, gifLen);
                    byte[] png = TryConvertGifToPng(gifBytes, gifLen);
                    if (png != null)
                    {
                        byte[] padded = PadPngToSize(png, gifLen);
                        if (padded != null && padded.Length == gifLen)
                        {
                            Array.Copy(padded, 0, result, i, gifLen);
                            i = end; replaced++; continue;
                        }
                    }
                }
            }
            i++;
        }
        return result;
    }

    static int FindGifEnd(byte[] data, int start)
    {
        int max = Math.Min(data.Length, start + 32768);
        for (int j = start + 13; j < max; j++) if (data[j] == 0x3B) return j + 1;
        return -1;
    }

    static byte[] PadPngToSize(byte[] png, int targetSize)
    {
        if (png.Length == targetSize) return png;
        if (png.Length > targetSize) return null;
        int pad = targetSize - png.Length;
        if (pad < 12) return null;
        int dataLen = pad - 12;
        int iendStart = png.Length - 12;
        if (!(png[iendStart + 4] == 0x49 && png[iendStart + 5] == 0x45 && png[iendStart + 6] == 0x4E && png[iendStart + 7] == 0x44)) return null;
        var chunk = new byte[pad];
        chunk[0] = (byte)((dataLen >> 24) & 0xFF); chunk[1] = (byte)((dataLen >> 16) & 0xFF);
        chunk[2] = (byte)((dataLen >> 8) & 0xFF); chunk[3] = (byte)(dataLen & 0xFF);
        chunk[4] = (byte)'p'; chunk[5] = (byte)'r'; chunk[6] = (byte)'V'; chunk[7] = (byte)'t';
        uint crc = Crc32(chunk, 4, 4 + dataLen);
        chunk[8 + dataLen] = (byte)((crc >> 24) & 0xFF); chunk[9 + dataLen] = (byte)((crc >> 16) & 0xFF);
        chunk[10 + dataLen] = (byte)((crc >> 8) & 0xFF); chunk[11 + dataLen] = (byte)(crc & 0xFF);
        var result = new byte[targetSize];
        Array.Copy(png, 0, result, 0, iendStart);
        Array.Copy(chunk, 0, result, iendStart, pad);
        Array.Copy(png, iendStart, result, iendStart + pad, 12);
        return result;
    }

    static readonly uint[] crcTable = BuildCrcTable();
    static uint[] BuildCrcTable()
    {
        var t = new uint[256];
        for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1); t[n] = c; }
        return t;
    }
    static uint Crc32(byte[] data, int offset, int length)
    {
        uint c = 0xFFFFFFFF;
        for (int i = 0; i < length; i++) c = crcTable[(c ^ data[offset + i]) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFF;
    }

    // Minimal glob: supports * and ? only (no ** / character classes).
    static bool GlobMatch(string glob, string s)
    {
        int gi = 0, si = 0, star = -1, mark = 0;
        while (si < s.Length)
        {
            if (gi < glob.Length && (glob[gi] == '?' || glob[gi] == s[si])) { gi++; si++; }
            else if (gi < glob.Length && glob[gi] == '*') { star = gi++; mark = si; }
            else if (star != -1) { gi = star + 1; si = ++mark; }
            else return false;
        }
        while (gi < glob.Length && glob[gi] == '*') gi++;
        return gi == glob.Length;
    }
}
