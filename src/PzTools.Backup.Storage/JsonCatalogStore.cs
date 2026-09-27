using System.Text.Json;
using System.Text.Json.Serialization;
using PzTools.Backup.Core;

namespace PzTools.Backup.Storage;

public sealed class JsonCatalogStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public async Task SaveAsync(
        string catalogPath,
        FileCatalog catalog,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(catalogPath);
        ArgumentNullException.ThrowIfNull(catalog);

        var fullPath = Path.GetFullPath(catalogPath);
        var directory = Path.GetDirectoryName(fullPath)
            ?? throw new ArgumentException("The catalog path must include a directory.", nameof(catalogPath));
        Directory.CreateDirectory(directory);

        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");

        try
        {
            await using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                64 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                await JsonSerializer.SerializeAsync(stream, catalog, SerializerOptions, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, fullPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    public async Task<FileCatalog> LoadAsync(
        string catalogPath,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(catalogPath);

        await using var stream = new FileStream(
            Path.GetFullPath(catalogPath),
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            64 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);

        var catalog = await JsonSerializer.DeserializeAsync<FileCatalog>(
            stream,
            SerializerOptions,
            cancellationToken) ?? throw new InvalidDataException("The catalog is empty or invalid.");

        if (catalog.FormatVersion != FileCatalog.CurrentFormatVersion)
        {
            throw new InvalidDataException(
                $"Unsupported catalog version {catalog.FormatVersion}; expected {FileCatalog.CurrentFormatVersion}.");
        }

        _ = CatalogDiffer.Diff(catalog, catalog);
        return catalog;
    }
}

