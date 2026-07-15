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
            CompressionRequest request = CLIOptions.Parse(args);
            CompressionWorker worker = new();
            Progress<string> progress = new(message => Console.WriteLine(message));
            CompressionOutcome outcome = await worker.RunAsync(request, progress, cancellation.Token).ConfigureAwait(false);
            Console.WriteLine($"Output: {outcome.OutputPath}");
            return 0;
        }
        catch (HelpRequestedException)
        {
            Console.WriteLine(CLIOptions.HelpText);
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
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
        }
    }
}
