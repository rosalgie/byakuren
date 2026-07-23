using System.Text.Json;
using Byakuren.Models;

namespace Byakuren.Results;

public sealed class PlanLogger(CompressionRequest request)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = false };
    private readonly SemaphoreSlim _gate = new(1, 1);

    public async Task WriteAsync(string eventName, object value, CancellationToken cancellationToken)
    {
        if (!request.EnablePlanLogging)
            return;

        string mediaPath = request.OutputPath ?? request.InputPath;
        string defaultPath = Path.ChangeExtension(mediaPath, ".plans.jsonl");
        string path = Path.GetFullPath(request.PlanLogPath ?? defaultPath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);

        object logEntry = new
        {
            TimestampUtc = DateTimeOffset.UtcNow,
            Event = eventName,
            Value = value
        };
        string line = JsonSerializer.Serialize(logEntry, JsonOptions) + Environment.NewLine;

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await File
                .AppendAllTextAsync(path, line, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }
}
