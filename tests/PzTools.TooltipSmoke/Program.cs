using System.Reflection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PzTools.App;

namespace PzTools.TooltipSmoke;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(parameters =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new SmokeApp(args.Single());
        });
    }
}

internal sealed class SmokeApp(string resultPath) : Application
{
    private Window? window;
    private readonly List<string> queueFailures = [];

    private sealed class QueueProbeException : Exception;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        UnhandledException += (_, error) =>
        {
            // The UI queue's failures must arrive here, where the app writes its crash report.
            if (error.Exception is QueueProbeException probe)
            {
                error.Handled = true;
                queueFailures.Add(probe.Source!);
                return;
            }
            File.WriteAllText(resultPath, "FAIL: " + error.Exception);
        };
        window = new Window();
        var owner = new Border { Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Child = new Button { Content = "Disabled action", IsEnabled = false }, Width = 200, Height = 40 };
        AppToolTip.SetTip(owner, "Unavailable while playing");
        owner.Loaded += async (_, _) =>
        {
            try
            {
                // No app host, scheduler, game connection, or user save is involved.
                window.AppWindow.Hide();
                var tooltip = ToolTipService.GetToolTip(owner) as ToolTip
                    ?? throw new InvalidOperationException("Tooltip owner is not registered.");
                ShowPresenter(owner);
                Check(tooltip.IsOpen, "First open on loaded WinUI tree");
                for (var i = 0; i < 100; i++) AppToolTip.SetTip(owner, "Unavailable while playing");
                Check(ReferenceEquals(tooltip, ToolTipService.GetToolTip(owner)), "Stable registration");
                await Task.Delay(750);
                Check(tooltip.IsOpen, "Popup remains open after repeated refreshes");
                AppToolTip.SetTip(owner, "Changed explanation");
                Check(tooltip.IsOpen && (string)tooltip.Content == "Changed explanation", "Open content update");
                AppToolTip.CloseCurrent();
                Check(!tooltip.IsOpen, "Dismiss");
                ShowPresenter(owner);
                Check(tooltip.IsOpen, "Reopen");
                AppToolTip.SetTip(owner, null);
                Check(!tooltip.IsOpen && ToolTipService.GetToolTip(owner) is null, "Clear reason");
                AppToolTip.SetTip(owner, "Available again");
                ShowPresenter(owner);
                Check(tooltip.IsOpen && ReferenceEquals(tooltip, ToolTipService.GetToolTip(owner)), "Reuse after clear");
                AppToolTip.CloseCurrent();
                var queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
                queue.Enqueue(() => throw new QueueProbeException { Source = "queued" });
                var timer = queue.Timer(() => throw new QueueProbeException { Source = "timer" });
                timer.Interval = TimeSpan.FromMilliseconds(50);
                timer.IsRepeating = false;
                timer.Start();
                await Task.Delay(500);
                Check(queueFailures.Order().SequenceEqual(["queued", "timer"]), "Queued and timer failures reach UnhandledException");
                File.WriteAllText(resultPath,
                    "PASS: first open, stable registration, repeated refresh, content update, dismiss, reopen, clear, reuse, queue failures reported");
            }
            catch (Exception error)
            {
                File.WriteAllText(resultPath, "FAIL: " + error);
                Environment.ExitCode = 1;
            }
            finally { window.Close(); Exit(); }
        };
        window.Content = owner;
        window.Activate();
    }

    private static void ShowPresenter(FrameworkElement owner)
    {
        var table = typeof(AppToolTip).GetField("Presenters", BindingFlags.Static | BindingFlags.NonPublic)!.GetValue(null)!;
        object?[] arguments = [owner, null];
        Check((bool)table.GetType().GetMethod("TryGetValue")!.Invoke(table, arguments)!, "Presenter exists");
        arguments[1]!.GetType().GetMethod("Show", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(arguments[1], [false]);
    }

    private static void Check(bool condition, string name)
    {
        if (!condition) throw new InvalidOperationException(name);
    }
}
