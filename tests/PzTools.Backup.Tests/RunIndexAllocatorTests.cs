using Microsoft.Data.Sqlite;
using PzTools.Control;

namespace PzTools.Backup.Tests;

public sealed class RunIndexAllocatorTests
{
    [Fact]
    public async Task ConcurrentAllocations_AreUniqueAndIncreasing()
    {
        using var temp = new TempDirectory();
        var allocator = new RunIndexAllocator(temp.GetPath("control.db"));

        var values = await Task.WhenAll(Enumerable.Range(0, 32)
            .Select(_ => allocator.AllocateAsync()));

        Assert.Equal(values.Length, values.Distinct().Count());
        var ordered = values.Order().ToArray();
        Assert.All(ordered.Zip(ordered.Skip(1)), pair => Assert.True(pair.First < pair.Second));
    }

    [Fact]
    public async Task Allocation_HonorsExclusiveFloor()
    {
        using var temp = new TempDirectory();
        var allocator = new RunIndexAllocator(temp.GetPath("control.db"));

        var value = await allocator.AllocateAsync(900_000_000_000_000_000L);

        Assert.Equal(900_000_000_000_000_001L, value);
    }

    [Fact]
    public async Task FutureSchema_IsRejectedWithoutFallback()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("control.db");
        var allocator = new RunIndexAllocator(path);
        await allocator.AllocateAsync();
        await using (var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Pooling = false,
            }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "UPDATE control_info SET schema_version=999 WHERE singleton=1;";
            await command.ExecuteNonQueryAsync();
        }

        await Assert.ThrowsAsync<InvalidDataException>(() => allocator.AllocateAsync());
    }
}
