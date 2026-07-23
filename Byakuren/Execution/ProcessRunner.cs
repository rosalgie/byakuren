using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace Byakuren.Execution;

public sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError)
{
    public string CombinedOutput => StandardOutput + StandardError;
}

public sealed class ProcessRunner
{
    public Action<string>? CommandObserver { get; set; }
    public Action<string>? OutputObserver { get; set; }
    public Action<string>? WarningObserver { get; set; }

    public static ProcessStartInfo CreateStartInfo(
        string fileName,
        IEnumerable<string> arguments,
        string? workingDirectory = null)
    {
        ProcessStartInfo startInfo = new()
        {
            FileName = fileName,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = workingDirectory ?? ""
        };
        foreach (string argument in arguments)
            startInfo.ArgumentList.Add(argument);

        return startInfo;
    }

    public async Task<ProcessResult> RunAsync(
        string fileName,
        IEnumerable<string> arguments,
        CancellationToken cancellationToken,
        string? workingDirectory = null)
    {
        CommandObserver?.Invoke(FormatCommand(fileName, arguments));
        using Process process = new() { StartInfo = CreateStartInfo(fileName, arguments, workingDirectory) };
        if (!process.Start())
            throw new InvalidOperationException($"Could not start '{fileName}'.");

        Task<string> stdoutTask = ReadOutputAsync(
            process.StandardOutput,
            OutputObserver,
            cancellationToken);
        Task<string> stderrTask = ReadOutputAsync(
            process.StandardError,
            OutputObserver,
            cancellationToken);
        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException cancellationException)
        {
            try
            {
                if (!process.HasExited)
                    process.Kill(entireProcessTree: true);
            }
            catch (Exception terminationException) when (
                terminationException is InvalidOperationException or
                    NotSupportedException or
                    Win32Exception)
            {
                cancellationException.Data["ProcessTerminationException"] = terminationException;
                ReportWarning(
                    $"Could not terminate process '{fileName}' after cancellation.",
                    terminationException);
            }

            throw;
        }

        string standardOutput = await stdoutTask.ConfigureAwait(false);
        string standardError = await stderrTask.ConfigureAwait(false);
        return new ProcessResult(process.ExitCode, standardOutput, standardError);
    }

    private static async Task<string> ReadOutputAsync(
        StreamReader reader,
        Action<string>? observer,
        CancellationToken cancellationToken)
    {
        StringBuilder output = new();
        while (await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false) is { } line)
        {
            output.AppendLine(line);
            observer?.Invoke(line);
        }

        return output.ToString();
    }

    public async Task<ProcessResult> RunCheckedAsync(
        string fileName,
        IEnumerable<string> arguments,
        CancellationToken cancellationToken,
        string? workingDirectory = null)
    {
        ProcessResult result = await RunAsync(
            fileName,
            arguments,
            cancellationToken,
            workingDirectory).ConfigureAwait(false);

        if (result.ExitCode != 0)
            throw new InvalidOperationException($"{fileName} exited with {result.ExitCode}: {LastUsefulLine(result.StandardError)}");
        return result;
    }

    private static string LastUsefulLine(string value) =>
        value.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.Trim() ?? "no diagnostic output";

    internal void ReportWarning(string message, Exception exception)
    {
        string detail = string.IsNullOrWhiteSpace(exception.Message)
            ? exception.GetType().Name
            : $"{exception.GetType().Name}: {exception.Message}";
        string warning = $"Warning: {message} {detail}";
        if (WarningObserver is not null)
            WarningObserver(warning);
        else
            Console.Error.WriteLine(warning);
    }

    private static string FormatCommand(string fileName, IEnumerable<string> arguments)
    {
        List<string> formattedArguments = [fileName];
        foreach (string argument in arguments)
        {
            if (argument.Any(char.IsWhiteSpace))
                formattedArguments.Add($"\"{argument.Replace("\"", "\\\"")}\"");
            else
                formattedArguments.Add(argument);
        }

        return string.Join(' ', formattedArguments);
    }
}
