using System;
using System.Collections.Generic;
using Autodesk.AutoCAD.DatabaseServices;
using LayerExtract.Models;

namespace LayerExtract;

/// <summary>Reads the layer table of a database into plain records.</summary>
public static class LayerReader
{
    /// <summary>
    /// Opens the layer table read-only inside its own transaction. Layers are returned sorted by name.
    /// Erased (deleted) records are skipped; xref-dependent layers are included.
    /// </summary>
    public static List<LayerRecord> Read(Database db)
    {
        var layers = new List<LayerRecord>();
        using var tr = db.TransactionManager.StartTransaction();

        var table = (LayerTable)tr.GetObject(db.LayerTableId, OpenMode.ForRead);
        foreach (ObjectId id in table)
        {
            var layer = (LayerTableRecord)tr.GetObject(id, OpenMode.ForRead);
            var linetype = (LinetypeTableRecord)tr.GetObject(layer.LinetypeObjectId, OpenMode.ForRead);

            layers.Add(new LayerRecord
            {
                Name = layer.Name,
                Description = layer.Description,
                Color = DescribeColor(layer.Color),
                Linetype = linetype.Name,
                LineWeight = (int)layer.LineWeight,
                IsOff = layer.IsOff,
                IsFrozen = layer.IsFrozen,
                IsLocked = layer.IsLocked,
                IsPlottable = layer.IsPlottable,
            });
        }

        tr.Commit();
        layers.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
        return layers;
    }

    private static string DescribeColor(Autodesk.AutoCAD.Colors.Color color)
    {
        if (color.IsByAci) return color.ColorIndex.ToString();
        if (color.IsByLayer) return "ByLayer";
        if (color.IsByBlock) return "ByBlock";
        return $"{color.Red},{color.Green},{color.Blue}"; // true color or color-book color
    }
}
