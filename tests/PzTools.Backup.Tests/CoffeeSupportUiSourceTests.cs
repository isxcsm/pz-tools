using System.Xml.Linq;

namespace PzTools.Backup.Tests;

/// <summary>Source contracts; native pointer/focus rendering remains a user E2E check.</summary>
public sealed class CoffeeSupportUiSourceTests
{
    private static readonly XNamespace Xaml = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
    private static readonly XNamespace Names = "http://schemas.microsoft.com/winfx/2006/xaml";

    [Fact]
    public void NativeLinkRestoresTheOriginalTwoLineTypographyWithoutAccentText()
    {
        var shell = XDocument.Parse(Source("MainWindowShell.xaml"));
        var button = shell.Descendants(Xaml + "HyperlinkButton").Single(element =>
            (string?)element.Attribute(Names + "Name") == "CoffeeSupportButton");
        Assert.Equal("Transparent", (string?)button.Attribute("Background"));
        Assert.Equal("{ThemeResource TextFillColorSecondaryBrush}", (string?)button.Attribute("Foreground"));
        Assert.Null(button.Attribute("Style"));
        Assert.Empty(button.Elements(Xaml + "HyperlinkButton.Template"));
        Assert.NotEqual("False", (string?)button.Attribute("UseSystemFocusVisuals"));
        var copy = button.Descendants(Xaml + "StackPanel").Single();
        Assert.Equal("CoffeeSupportCopy", (string?)copy.Attribute(Names + "Name"));
        Assert.Equal("3", (string?)copy.Attribute("Spacing"));
        Assert.Equal(2, copy.Elements(Xaml + "TextBlock").Count());
        var message = copy.Elements(Xaml + "TextBlock").First();
        Assert.Equal("CoffeeSupportMessage", (string?)message.Attribute(Names + "Name"));
        Assert.Equal("11", (string?)message.Attribute("FontSize"));
        Assert.Equal("Wrap", (string?)message.Attribute("TextWrapping"));
        Assert.Equal("{ThemeResource TextFillColorSecondaryBrush}", (string?)message.Attribute("Foreground"));
        var title = copy.Elements(Xaml + "TextBlock").Last();
        Assert.Equal("CoffeeSupportTitle", (string?)title.Attribute(Names + "Name"));
        Assert.Equal("12", (string?)title.Attribute("FontSize"));
        Assert.Equal("Normal", (string?)title.Attribute("FontWeight"));
        Assert.Equal("Wrap", (string?)title.Attribute("TextWrapping"));
        Assert.Equal("{ThemeResource TextFillColorPrimaryBrush}", (string?)title.Attribute("Foreground"));
        Assert.Null(copy.Parent!.Attribute("ColumnSpacing")); // No empty gap after the copy collapses.
        Assert.Equal("10,0,0,0", (string?)copy.Attribute("Margin"));
        Assert.Contains("CoffeeSupportCopy.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;",
            Source("MainWindowShell.xaml.cs"));
        Assert.Equal("12,8,12,4", (string?)button.Parent!.Attribute("Margin"));
        Assert.Contains("CoffeeSupportArea.Margin = expanded ? new Thickness(12, 8, 12, 4) : new Thickness(4, 8, 4, 4);",
            Source("MainWindowShell.xaml.cs"));
    }

    [Fact]
    public void CupRedrawsTheVectorInsideAFixedUnclippedSlot()
    {
        var shell = XDocument.Parse(Source("MainWindowShell.xaml"));
        var button = shell.Descendants(Xaml + "HyperlinkButton").Single(element =>
            (string?)element.Attribute(Names + "Name") == "CoffeeSupportButton");
        var icon = button.Descendants(Xaml + "Path").Single();
        Assert.Equal("{ThemeResource TextFillColorSecondaryBrush}", (string?)icon.Attribute("Fill"));
        Assert.Equal("20", (string?)icon.Attribute("Width"));
        Assert.Equal("28", (string?)icon.Attribute("Height"));
        Assert.Equal("Uniform", (string?)icon.Attribute("Stretch"));
        Assert.Equal("False", (string?)icon.Attribute("UseLayoutRounding"));
        Assert.Equal("0", (string?)icon.Attribute("Canvas.Left"));
        Assert.Equal("0", (string?)icon.Attribute("Canvas.Top"));
        Assert.StartsWith("F1 M", (string?)icon.Attribute("Data"));
        var viewport = icon.Parent!;
        Assert.Equal(Xaml + "Canvas", viewport.Name);
        Assert.Null(viewport.Attribute("Clip"));
        Assert.Equal("20", (string?)viewport.Attribute("Width"));
        Assert.Equal("28", (string?)viewport.Attribute("Height"));
        var source = Source("HyperlinkIconFeedback.cs");
        Assert.DoesNotContain("RenderTransform", source);
        Assert.DoesNotContain("CompositeTransform", source);
        Assert.Contains("AddMotion(nameof(FrameworkElement.Width), previousWidth, width);", source);
        Assert.Contains("AddMotion(nameof(FrameworkElement.Height), previousHeight, height);", source);
        Assert.Contains("AddMotion(\"(Canvas.Left)\", previousLeft, left);", source);
        Assert.Contains("AddMotion(\"(Canvas.Top)\", previousTop, top);", source);
        Assert.Contains("EnableDependentAnimation = true", source);
        Assert.Contains("Math.Round(value * rasterScale) / rasterScale", source);
    }

    [Theory]
    [InlineData("Default", "#C3A574")]
    [InlineData("Light", "#8B6B42")]
    [InlineData("HighContrast", "{ThemeResource SystemColorWindowTextColor}")]
    public void HoverAndPressedIconUseMutedThemeColorsOrTheHighContrastSystemColor(string theme, string color)
    {
        var shell = XDocument.Parse(Source("MainWindowShell.xaml"));
        var button = shell.Descendants(Xaml + "HyperlinkButton").Single(element =>
            (string?)element.Attribute(Names + "Name") == "CoffeeSupportButton");
        var dictionary = button.Descendants(Xaml + "ResourceDictionary").Single(element =>
            (string?)element.Attribute(Names + "Key") == theme);
        Assert.Equal(2, dictionary.Elements().Count());
        foreach (var state in new[] { "PointerOver", "Pressed" })
            Assert.Equal(color, (string?)dictionary.Elements(Xaml + "SolidColorBrush").Single(element =>
                (string?)element.Attribute(Names + "Key") == "HyperlinkButtonForeground" + state).Attribute("Color"));
    }

    [Fact]
    public void SupportDestinationAndAccessibleLabelRemainWithoutTooltips()
    {
        var source = Source("MainWindowShell.Support.cs");
        Assert.Contains("https://buymeacoffee.com/iou3019", source);
        Assert.Contains("CoffeeSupportButton.NavigateUri = SupportPage;", source);
        Assert.Contains("CoffeeSupportMessage.Text = Localizer.Get(\"CoffeeSupport.Message\");", source);
        Assert.Contains("var label = $\"{CoffeeSupportMessage.Text} {CoffeeSupportTitle.Text}\";", source);
        Assert.Contains("AutomationProperties.SetName(CoffeeSupportButton, label);", source);
        Assert.DoesNotContain("ToolTip", source);
        Assert.DoesNotContain("ToolTipService", Source("MainWindowShell.xaml"));
    }

    [Fact]
    public void FeedbackObservesPublicNativeStateWithoutUnsupportedSettingsEventsOrDeferredVisualStates()
    {
        var source = Source("HyperlinkIconFeedback.cs");
        foreach (var unsupportedEvent in new[] { "ColorValuesChanged", "HighContrastChanged", "AnimationsEnabledChanged" })
            Assert.DoesNotContain(unsupportedEvent, source);
        Assert.DoesNotContain("GetVisualStateGroups", source);
        Assert.DoesNotContain("CurrentStateChanged", source);
        Assert.Contains("Observe(presenter, ContentPresenter.ForegroundProperty);", source);
        Assert.Contains("Observe(button, ButtonBase.IsPointerOverProperty);", source);
        Assert.Contains("Observe(button, ButtonBase.IsPressedProperty);", source);
        Assert.Contains("Observe(button, ButtonBase.IsEnabledProperty);", source);
        Assert.Contains("!button.IsEnabled ? \"Disabled\" : button.IsPressed ? \"Pressed\"", source);
        Assert.Contains("button.IsPointerOver ? \"PointerOver\" : \"Normal\"", source);
        Assert.Contains("uiSettings.AnimationsEnabled && !accessibility.HighContrast", source);
    }

    [Fact]
    public void FeedbackInitializationKeepsAnInstanceAvailableToRollbackPartialSetup()
    {
        var source = Source("HyperlinkIconFeedback.cs");
        var constructorStart = source.IndexOf("private HyperlinkIconFeedback(", StringComparison.Ordinal);
        var initializeStart = source.IndexOf("private void Initialize()", StringComparison.Ordinal);
        var observeStart = source.IndexOf("private void Observe(", StringComparison.Ordinal);
        Assert.True(constructorStart > 0 && initializeStart > constructorStart && observeStart > initializeStart);
        var attach = source[..constructorStart];
        Assert.Contains("HyperlinkIconFeedback? feedback = null;", attach);
        Assert.True(attach.IndexOf("feedback = new(", StringComparison.Ordinal)
            < attach.IndexOf("feedback.Initialize();", StringComparison.Ordinal));
        Assert.Contains("catch (Exception exception) when (IsFeedbackFailure(exception))", attach);
        Assert.Contains("feedback?.Dispose();", attach);
        var constructor = source[constructorStart..initializeStart];
        Assert.DoesNotContain("icon.Fill = brush;", constructor);
        Assert.DoesNotContain("RegisterPropertyChangedCallback", constructor);
        Assert.DoesNotContain("+=", constructor);
        var initialize = source[initializeStart..observeStart];
        Assert.True(initialize.IndexOf("cleanup.Add(", StringComparison.Ordinal)
            < initialize.IndexOf("icon.Fill = brush;", StringComparison.Ordinal));
        Assert.Contains("Update(animate: false);", initialize);
    }

    [Fact]
    public void FeedbackCleanupIndependentlyReleasesCallbacksAndRestoresTheNativeAppearance()
    {
        var source = Source("HyperlinkIconFeedback.cs");
        Assert.Contains("icon.ClearValue(Shape.FillProperty)", source);
        Assert.Contains("icon.SetValue(Shape.FillProperty, originalFill)", source);
        Assert.Contains("cleanup.Add(() => icon.Width = originalWidth);", source);
        Assert.Contains("cleanup.Add(() => icon.Height = originalHeight);", source);
        Assert.Contains("cleanup.Add(() => Canvas.SetLeft(icon, originalLeft));", source);
        Assert.Contains("cleanup.Add(() => Canvas.SetTop(icon, originalTop));", source);
        Assert.Contains("cleanup.Add(() => owner.UnregisterPropertyChangedCallback(property, token));", source);
        Assert.Contains("cleanup.Add(() => button.ActualThemeChanged -= ThemeChanged);", source);
        var dispose = source[source.IndexOf("public void Dispose()", StringComparison.Ordinal)..];
        Assert.Contains("if (disposed) return;", dispose);
        Assert.True(dispose.IndexOf("disposed = true;", StringComparison.Ordinal)
            < dispose.IndexOf("TryCleanup(", StringComparison.Ordinal));
        Assert.Contains("TryCleanup(() => transition?.Stop());", dispose);
        Assert.Contains("for (var index = cleanup.Count - 1; index >= 0; index--) TryCleanup(cleanup[index]);", dispose);
        Assert.Contains("cleanup.Clear();", dispose);
        Assert.Contains("try { action(); }", dispose);
        Assert.Contains("catch (Exception exception) when (IsFeedbackFailure(exception))", dispose);
        Assert.Contains("exception is not OutOfMemoryException", dispose);
    }

    [Fact]
    public void FeedbackCoalescesPendingUpdatesAndIsolatesBothDispatchAndAnimationFailures()
    {
        var source = Source("HyperlinkIconFeedback.cs");
        var request = source[source.IndexOf("private void RequestUpdate(", StringComparison.Ordinal)
            ..source.IndexOf("private void Update(", StringComparison.Ordinal)];
        Assert.Contains("settlePending |= !animate;", request);
        Assert.Contains("if (updatePending) return;", request);
        Assert.True(request.IndexOf("updatePending = true;", StringComparison.Ordinal)
            < request.IndexOf("DispatcherQueue.TryEnqueue(", StringComparison.Ordinal));
        Assert.Equal(1, request.Split("DispatcherQueue.TryEnqueue(", StringSplitOptions.None).Length - 1);
        Assert.Contains("if (disposed) return;", request);
        Assert.Contains("try { Update(useAnimation); }", request);
        Assert.Equal(2, request.Split("catch (Exception exception) when (IsFeedbackFailure(exception))",
            StringSplitOptions.None).Length - 1);
        Assert.Equal(2, request.Split("DisableFeedback(exception);", StringSplitOptions.None).Length - 1);
        Assert.Contains("updatePending = settlePending = false;", source);
        Assert.True(source.IndexOf("transition?.Stop();", StringComparison.Ordinal)
            < source.IndexOf("transition = new Storyboard", StringComparison.Ordinal));
    }

    private static string Source(string name)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln")))
                return File.ReadAllText(Path.Combine(directory.FullName, "src", "PzTools.App", name));
        throw new DirectoryNotFoundException("Repository source is required for support button contracts.");
    }
}
