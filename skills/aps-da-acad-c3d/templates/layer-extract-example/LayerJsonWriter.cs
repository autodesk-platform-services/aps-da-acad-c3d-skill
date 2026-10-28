using System.IO;
using System.Text.Json;
using LayerExtract.Models;

namespace LayerExtract;

public static class LayerJsonWriter
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static void Write(string path, LayerReport report) =>
        File.WriteAllText(path, JsonSerializer.Serialize(report, Options));
}
