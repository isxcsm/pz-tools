using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace PzTools.App;

/// <summary>작업 알림을 잠시 표시하고 새 알림이 오면 표시 시간을 다시 시작합니다.</summary>
internal sealed class TransientNotification
{
    private readonly Border card;
    private readonly TextBlock titleText;
    private readonly TextBlock messageText;
    private readonly DispatcherQueueTimer timer;

    public TransientNotification(Border card, TextBlock titleText, TextBlock messageText)
    {
        this.card = card;
        this.titleText = titleText;
        this.messageText = messageText;
        timer = card.DispatcherQueue.CreateTimer();
        timer.IsRepeating = false;
        timer.Tick += (_, _) => Hide();
        card.Unloaded += (_, _) => Hide();
    }

    public void Show(InfoBarSeverity severity, string title, string message)
    {
        timer.Stop();
        titleText.Text = title;
        messageText.Text = message;
        card.Visibility = Visibility.Visible;
        var runtime = ((App)Application.Current).Host?.RuntimeOptions ?? new PzTools.App.Core.AppRuntimeOptions();
        timer.Interval = TimeSpan.FromSeconds(severity is InfoBarSeverity.Error or InfoBarSeverity.Warning
            ? runtime.FailureCardSeconds : runtime.SuccessCardSeconds);
        timer.Start();
    }

    public void Hide()
    {
        timer.Stop();
        card.Visibility = Visibility.Collapsed;
    }
}
