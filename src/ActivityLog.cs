using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Xml;

namespace SsmsPatcher;

// Parses VS Shell's ActivityLog.xml, which SSMS writes to
// AppData/Roaming/Microsoft/AppEnv/15.0/ActivityLog.xml as UTF-16 LE.
// The upstream troubleshooting docs point users at this file but never
// tell them how to read it — the raw XML has hundreds of "SetSite" spam
// entries. We surface only failures.
public static class ActivityLog
{
    public static int Run(string logPath, bool onlyErrors)
    {
        if (!File.Exists(logPath))
        {
            Console.Error.WriteLine($"ActivityLog.xml not found: {logPath}");
            Console.Error.WriteLine("hint: SSMS creates this after the first launch under " +
                                    "AppData/Roaming/Microsoft/AppEnv/15.0/ActivityLog.xml");
            return 2;
        }

        // The file is UTF-16 LE with a BOM. XmlReader can auto-detect, but
        // if the BOM is missing (Wine sometimes writes without one) we
        // fall back to a StreamReader configured for UTF-16.
        Stream stream;
        try
        {
            var bytes = File.ReadAllBytes(logPath);
            if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
                stream = new MemoryStream(bytes);
            else
                stream = new MemoryStream(Encoding.Convert(Encoding.Unicode, Encoding.UTF8, bytes));
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"read failed: {ex.Message}");
            return 1;
        }

        int errors = 0, warnings = 0, printed = 0;
        try
        {
            using var reader = XmlReader.Create(stream, new XmlReaderSettings
            {
                IgnoreWhitespace = true,
                IgnoreComments = true,
                DtdProcessing = DtdProcessing.Ignore,
            });
            while (reader.Read())
            {
                if (reader.NodeType != XmlNodeType.Element || reader.LocalName != "entry") continue;
                using var sub = reader.ReadSubtree();
                var entry = new System.Xml.Linq.XElement(System.Xml.Linq.XElement.Load(sub));
                string type = (string)entry.Element("type") ?? "";
                if (type == "Error") errors++;
                else if (type == "Warning") warnings++;
                if (onlyErrors && type != "Error") continue;

                string time = (string)entry.Element("time") ?? "";
                string source = (string)entry.Element("source") ?? "";
                string desc = ((string)entry.Element("description") ?? "").Trim();
                string guid = (string)entry.Element("guid") ?? "";
                string path = (string)entry.Element("path") ?? "";

                Console.WriteLine($"[{type}] {time}  source={source}");
                if (!string.IsNullOrEmpty(guid)) Console.WriteLine($"  package: {guid}");
                if (!string.IsNullOrEmpty(path)) Console.WriteLine($"  path:    {path}");
                if (!string.IsNullOrEmpty(desc)) Console.WriteLine($"  {desc}");
                Console.WriteLine();
                printed++;
            }
        }
        catch (XmlException ex)
        {
            Console.Error.WriteLine($"xml parse failed at line {ex.LineNumber}: {ex.Message}");
            return 1;
        }

        Console.WriteLine($"summary: {errors} error(s), {warnings} warning(s), {printed} entries shown.");
        return errors > 0 ? 3 : 0;
    }
}
