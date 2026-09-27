using System.Text;

namespace PzTools.App.Core;

internal static class EditableConfigurationTemplates
{
    public static string Read(string component)
    {
        var assembly = typeof(EditableConfigurationTemplates).Assembly;
        var suffix = $".EditableTemplates.{component.Replace('-', '_')}.default.toml";
        var resource = assembly.GetManifestResourceNames().SingleOrDefault(name =>
            name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException(
                $"Editable configuration template is missing: {component}.");
        using var stream = assembly.GetManifestResourceStream(resource)!;
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    public static Task EnsureAsync(string path, string template,
        CancellationToken cancellationToken) =>
        File.Exists(path)
            ? Task.CompletedTask
            : AtomicTextFile.CreateIfAbsentAsync(path, template, cancellationToken);
}
