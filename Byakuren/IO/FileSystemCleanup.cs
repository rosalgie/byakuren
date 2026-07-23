namespace Byakuren.IO;

internal static class FileSystemCleanup
{
    public static void DeleteFile(
        string path,
        Action<string, Exception> reportWarning)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (IsRecoverableFileSystemError(exception))
        {
            reportWarning($"Could not delete file '{path}'.", exception);
        }
    }

    public static void DeleteDirectory(
        string path,
        bool recursive,
        Action<string, Exception> reportWarning)
    {
        try
        {
            Directory.Delete(path, recursive);
        }
        catch (Exception exception) when (IsRecoverableFileSystemError(exception))
        {
            reportWarning($"Could not delete directory '{path}'.", exception);
        }
    }

    public static void DeleteFiles(
        string directory,
        string searchPattern,
        Action<string, Exception> reportWarning)
    {
        try
        {
            foreach (string path in Directory.EnumerateFiles(directory, searchPattern))
                DeleteFile(path, reportWarning);
        }
        catch (Exception exception) when (IsRecoverableFileSystemError(exception))
        {
            reportWarning(
                $"Could not enumerate cleanup files matching '{searchPattern}' in '{directory}'.",
                exception);
        }
    }

    private static bool IsRecoverableFileSystemError(Exception exception) =>
        exception is IOException or UnauthorizedAccessException;
}
