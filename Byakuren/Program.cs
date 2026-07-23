using System.CommandLine;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using Byakuren.CLI;
using Byakuren.Models;
using Byakuren.Worker;

namespace Byakuren;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        using CancellationTokenSource cancellation = new();

        ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        };

        Console.CancelKeyPress += cancelHandler;

        try
        {
            CLIOptions options = new();
            RootCommand command = options.CreateRootCommand(RunCompressionAsync);
            ParseResult parseResult = command.Parse(args);

            InvocationConfiguration configuration = new();
            return await parseResult
                .InvokeAsync(configuration, cancellation.Token)
                .ConfigureAwait(false);
        }
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
        }
    }

    [SuppressMessage(
        "Design",
        "CA1031:Do not catch general exception types",
        Justification = "This is the application boundary that translates unhandled failures into a nonzero exit code.")]
    private static async Task<int> RunCompressionAsync(
        CompressionRequest request,
        CancellationToken cancellationToken)
    {
        try
        {
            CompressionWorker worker = new();
            Progress<string> progress = new(Console.WriteLine);
            Stopwatch stopwatch = Stopwatch.StartNew();
            CompressionOutcome outcome = await worker
                .RunAsync(request, progress, cancellationToken)
                .ConfigureAwait(false);
            stopwatch.Stop();

            Console.WriteLine($"Output: {outcome.OutputPath}");
            Console.WriteLine(
                $"Compression time: {(int)stopwatch.Elapsed.TotalHours:00}:{stopwatch.Elapsed:mm\\:ss\\.fff}"
            );
            return 0;
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Compression cancelled.");
            return 130;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }
}
