using System.Collections.Generic;

namespace LayerExtract.Models;

/// <summary>One layer table record, flattened to plain values so writers need no AutoCAD types.</summary>
public sealed record LayerRecord
{
    public required string Name { get; init; }
    public string Description { get; init; } = "";
    /// <summary>AutoCAD color as shown in the Layer Manager: ACI number, color name, or "R,G,B".</summary>
    public required string Color { get; init; }
    public required string Linetype { get; init; }
    /// <summary>Line weight in hundredths of a mm; negative values are the AutoCAD special weights.</summary>
    public int LineWeight { get; init; }
    public bool IsOff { get; init; }
    public bool IsFrozen { get; init; }
    public bool IsLocked { get; init; }
    public bool IsPlottable { get; init; }
}

public sealed record LayerReport
{
    public required string Drawing { get; init; }
    public required int LayerCount { get; init; }
    public required IReadOnlyList<LayerRecord> Layers { get; init; }
}
