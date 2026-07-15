using System.Text.Json;
using Byakuren.Models;

namespace Byakuren.Results;

public sealed class PlanLogger(CompressionRequest request)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = false };
    private readonly SemaphoreSlim _gate = new(1, 1);

    public async Task WriteAsync(string eventName, object value, CancellationToken cancellationToken)
    {
        if (!request.EnablePlanLogging) return;
        string path = Path.GetFullPath(request.PlanLogPath ?? Path.ChangeExtension(request.OutputPath ?? request.InputPath, ".plans.jsonl"));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string line = JsonSerializer.Serialize(new { TimestampUtc = DateTimeOffset.UtcNow, Event = eventName, Value = value }, JsonOptions) + Environment.NewLine;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await File.AppendAllTextAsync(path, line, cancellationToken).ConfigureAwait(false); }
        finally { _gate.Release(); }
    }
}
