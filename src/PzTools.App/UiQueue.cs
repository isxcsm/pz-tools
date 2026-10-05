using System.Runtime.ExceptionServices;
using Microsoft.UI.Dispatching;

namespace PzTools.App;

/// <summary>
/// Work for the UI thread's queue, run so that a failure is reported. WinUI passes a failure in a DispatcherQueue
/// callback (a queued action, a timer's tick) to nothing: the app ends at once, without Application.UnhandledException
/// and so without a crash report. Thrown again through the thread's SynchronizationContext, it does reach that handler,
/// as failures in XAML's own events, in its DispatcherTimer and after an await already do.
/// The app queues work only through these; a test keeps TryEnqueue and CreateTimer out of it.
/// </summary>
internal static class UiQueue
{
    public static bool Enqueue(this DispatcherQueue queue, Action work) => queue.TryEnqueue(() => Run(work));

    public static bool Enqueue(this DispatcherQueue queue, DispatcherQueuePriority priority, Action work) =>
        queue.TryEnqueue(priority, () => Run(work));

    /// <summary>A timer, stopped, that runs <paramref name="tick"/> on each tick. It repeats unless told not to.</summary>
    public static DispatcherQueueTimer Timer(this DispatcherQueue queue, Action tick)
    {
        var timer = queue.CreateTimer();
        timer.Tick += (_, _) => Run(tick);
        return timer;
    }

    private static void Run(Action work)
    {
        try { work(); }
        catch (Exception exception) when (SynchronizationContext.Current is { } context)
        {
            var failure = ExceptionDispatchInfo.Capture(exception);
            context.Post(_ => failure.Throw(), null);
        }
    }
}
