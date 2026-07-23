using System.CommandLine;
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

    private static async Task<int> RunCompressionAsync(
        CompressionRequest request,
        CancellationToken cancellationToken)
    {
        try
        {
            CompressionWorker worker = new();
            Progress<string> progress = new(Console.WriteLine);
            CompressionOutcome outcome = await worker
                .RunAsync(request, progress, cancellationToken)
                .ConfigureAwait(false);

            Console.WriteLine($"Output: {outcome.OutputPath}");
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
