namespace Byakuren.IO;

internal sealed class FilePublication(
    Action<string, Exception> reportWarning) : IDisposable
{
    private readonly List<Entry> _entries = [];
    private bool _published;

    public string Add(string destination)
    {
        string fullPath = Path.GetFullPath(destination);
        if (_entries.Any(entry =>
                entry.Destination.Equals(fullPath, StringComparison.OrdinalIgnoreCase)))
        {
            throw new ArgumentException(
                $"More than one artifact cannot be published to '{fullPath}'.",
                nameof(destination));
        }

        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        string stagingPath = fullPath + $".{Guid.NewGuid():N}.tmp";
        _entries.Add(new Entry(fullPath, stagingPath));
        return stagingPath;
    }

    public void Publish()
    {
        foreach (Entry entry in _entries)
        {
            if (!File.Exists(entry.StagingPath))
            {
                throw new FileNotFoundException(
                    "A staged publication artifact was not found.",
                    entry.StagingPath);
            }
        }

        try
        {
            foreach (Entry entry in _entries)
            {
                if (File.Exists(entry.Destination))
                {
                    entry.BackupPath = entry.Destination + $".{Guid.NewGuid():N}.bak";
                    File.Replace(entry.StagingPath, entry.Destination, entry.BackupPath);
                }
                else
                {
                    File.Move(entry.StagingPath, entry.Destination);
                }
                entry.WasPublished = true;
            }

            _published = true;
        }
        catch (Exception publicationException)
        {
            List<Exception> rollbackErrors = RollBack();
            if (rollbackErrors.Count > 0)
            {
                throw new AggregateException(
                    "Artifact publication failed and one or more prior files could not be restored.",
                    [publicationException, .. rollbackErrors]);
            }

            throw;
        }

        foreach (Entry entry in _entries)
        {
            if (entry.BackupPath is not null)
                FileSystemCleanup.DeleteFile(entry.BackupPath, reportWarning);
        }
    }

    public void Dispose()
    {
        foreach (Entry entry in _entries)
            FileSystemCleanup.DeleteFile(entry.StagingPath, reportWarning);

        if (_published)
        {
            foreach (Entry entry in _entries)
            {
                if (entry.BackupPath is not null)
                    FileSystemCleanup.DeleteFile(entry.BackupPath, reportWarning);
            }
        }
    }

    private List<Exception> RollBack()
    {
        List<Exception> errors = [];
        foreach (Entry entry in _entries.AsEnumerable().Reverse())
        {
            try
            {
                if (!entry.WasPublished)
                    continue;

                if (entry.BackupPath is not null && File.Exists(entry.BackupPath))
                    File.Replace(entry.BackupPath, entry.Destination, null);
                else
                    File.Delete(entry.Destination);
            }
            catch (Exception exception) when (
                exception is IOException or UnauthorizedAccessException)
            {
                errors.Add(exception);
            }
        }

        return errors;
    }

    private sealed class Entry(string destination, string stagingPath)
    {
        public string Destination { get; } = destination;
        public string StagingPath { get; } = stagingPath;
        public string? BackupPath { get; set; }
        public bool WasPublished { get; set; }
    }
}
