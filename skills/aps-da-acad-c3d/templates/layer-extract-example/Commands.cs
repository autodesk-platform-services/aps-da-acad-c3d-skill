using System.IO;
using Autodesk.AutoCAD.ApplicationServices.Core;
using Autodesk.AutoCAD.EditorInput;
using Autodesk.AutoCAD.Runtime;
using LayerExtract.Models;

[assembly: CommandClass(typeof(LayerExtract.Commands))]

namespace LayerExtract;

public class Commands
{
    /// <summary>Name of the output file the Activity maps to its outputFile parameter.</summary>
    public const string OutputFileName = "layers.json";

    /// <summary>
    /// Writes every layer of the active drawing to layers.json in the working directory.
    /// No prompts, no parameter file: the script only has to run the command by name.
    /// </summary>
    [CommandMethod("EXTRACTLAYERS", CommandFlags.Modal)]
    public void ExtractLayers()
    {
        // WriteMessage only: DA captures the console as the WorkItem report.
        Editor ed = Application.DocumentManager.MdiActiveDocument.Editor;
        try
        {
            var db = Application.DocumentManager.MdiActiveDocument.Database;
            var layers = LayerReader.Read(db);
            var report = new LayerReport
            {
                Drawing = Path.GetFileName(db.Filename),
                LayerCount = layers.Count,
                Layers = layers,
            };

            string outputPath = Path.Combine(Directory.GetCurrentDirectory(), OutputFileName);
            LayerJsonWriter.Write(outputPath, report);
            ed.WriteMessage($"\nEXTRACTLAYERS: wrote {layers.Count} layers to {outputPath}");
        }
        catch (System.Exception ex)
        {
            ed.WriteMessage($"\nEXTRACTLAYERS failed: {ex}");
            throw; // a swallowed error would look like success in a WorkItem
        }
    }
}
