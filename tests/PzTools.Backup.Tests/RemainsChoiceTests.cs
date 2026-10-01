using System.Buffers.Binary;
using Microsoft.Data.Sqlite;
using PzTools.Zomboid.Recovery;
using static PzTools.Backup.Tests.CharacterRecoveryTests;
using static PzTools.Backup.Tests.CorpseResurrectionTests;

namespace PzTools.Backup.Tests;

/// <summary>
/// A character who died without a recovery ID: their zombie is offered by lasting appearance wherever it
/// walked, the user chooses among lookalikes, and nothing is taken that the user did not choose.
/// </summary>
public sealed class RemainsChoiceTests
{
    [Fact]
    public async Task WalkedAwayZombie_IsOffered_AndRecoveredByItsKey()
    {
        using var f = new Fixture();
        // Walked 1000 tiles, and the game renumbered its skin when it rose.
        await f.CreateAsync(Moved(Zombie("Test", skinTexture: 1), 1000), Moved(Zombie("Other Test"), 5));
        var preview = await f.PreviewAsync();
        Assert.True(preview.SearchesRemains);
        var candidate = Assert.Single(preview.Candidates);
        Assert.Equal((RemainsKind.Zombie, 3, 1000), (candidate.Kind, candidate.Items, candidate.Distance));
        var result = await f.RecoverAsync(candidate.Key);
        Assert.Equal((true, 3), (result.Resurrected, result.RecoveredItems));
        Assert.Equal(ZombieFile(Moved(Zombie("Other Test"), 5)), File.ReadAllBytes(f.Zombies));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public async Task TwoLookalikes_AreBothOffered_AndOnlyTheChosenOneIsTaken(int chosen)
    {
        using var f = new Fixture();
        byte[][] zombies = [Moved(Zombie("Test"), 100), Moved(Zombie("Test"), 200)];
        await f.CreateAsync(zombies);
        var candidates = (await f.PreviewAsync()).Candidates;
        Assert.Equal([100, 200], candidates.Select(c => c.Distance));
        // Without a choice the two cannot be told apart.
        var database = File.ReadAllBytes(f.Database);
        Assert.Equal("recovery-inventory-ambiguous",
            (await Assert.ThrowsAsync<InvalidDataException>(() => f.RecoverAsync(null))).Message);
        Assert.Equal(database, File.ReadAllBytes(f.Database));
        await f.RecoverAsync(candidates[chosen].Key);
        Assert.Equal(ZombieFile(zombies[1 - chosen]), File.ReadAllBytes(f.Zombies));
    }

    [Fact]
    public async Task ProvenRemains_HideLookalikes()
    {
        using var f = new Fixture();
        await f.CreateAsync(Moved(Zombie("Test"), 300), Zombie("Test")); // the second stands where they died
        var candidate = Assert.Single((await f.PreviewAsync()).Candidates);
        Assert.Equal(0, candidate.Distance);
    }

    [Fact]
    public async Task CorpseOfAKilledZombie_IsNeverOfferedByLookAlone()
    {
        using var f = new Fixture();
        // Any killed zombie leaves such a corpse; random zombies share the game's few colours.
        var corpse = Body("Test", female: true);
        corpse[28] = 1; // wasZombie
        BinaryPrimitives.WriteSingleBigEndian(corpse.AsSpan(10), 50);
        await f.CreateWithChunkAsync([], Chunk([corpse], []));
        var preview = await f.PreviewAsync();
        Assert.True(preview.SearchesRemains);
        Assert.Empty(preview.Candidates);
    }

    [Fact]
    public async Task ChosenRemains_ThatChangedSince_AreRefused()
    {
        using var f = new Fixture();
        await f.CreateAsync(Moved(Zombie("Test"), 100));
        var key = Assert.Single((await f.PreviewAsync()).Candidates).Key;
        File.WriteAllBytes(f.Zombies, ZombieFile(Moved(Zombie("Test"), 100), Zombie("Someone")));
        var database = File.ReadAllBytes(f.Database);
        Assert.Equal("recovery-remains-changed",
            (await Assert.ThrowsAsync<InvalidDataException>(() => f.RecoverAsync(key))).Message);
        Assert.Equal(database, File.ReadAllBytes(f.Database));
    }

    [Fact]
    public async Task WithoutRemains_RevivesEmptyHanded_AndLeavesTheWorld()
    {
        using var f = new Fixture();
        await f.CreateAsync(Moved(Zombie("Test"), 100));
        var world = File.ReadAllBytes(f.Zombies);
        var result = await f.RecoverAsync(CharacterRecoveryService.NoRemains);
        Assert.Equal((true, 0), (result.Resurrected, result.RecoveredItems));
        Assert.Equal(world, File.ReadAllBytes(f.Zombies));
        Assert.Equal(0L, await f.ScalarAsync("SELECT isDead FROM localPlayers;"));
    }

    private static byte[] Moved(byte[] zombie, float x)
    {
        var moved = zombie.ToArray();
        BinaryPrimitives.WriteSingleBigEndian(moved.AsSpan(10), x);
        return moved;
    }

    private sealed class Fixture : IDisposable
    {
        private string Work { get; } = Path.Combine(Path.GetTempPath(), "pztools-remains-" + Guid.NewGuid().ToString("N"));
        private string Root => Path.Combine(Work, "Saves");
        private string Save => Path.Combine(Root, "Sandbox", "Test");
        public string Database => Path.Combine(Save, "players.db");
        public string Zombies => Path.Combine(Save, "reanimated.bin");

        public Task CreateAsync(params byte[][] zombies) => CreateWithChunkAsync(zombies, Chunk([], []));

        public async Task CreateWithChunkAsync(byte[][] zombies, byte[] chunk)
        {
            Directory.CreateDirectory(Path.Combine(Save, "map", "0"));
            File.WriteAllBytes(Path.Combine(Save, "map", "0", "0.bin"), chunk);
            File.WriteAllBytes(Zombies, ZombieFile(zombies));
            File.WriteAllBytes(Path.Combine(Save, "WorldDictionary.bin"), DictionaryBytes());
            await using var c = new SqliteConnection($"Data Source={Database};Pooling=False");
            await c.OpenAsync();
            await using var q = c.CreateCommand();
            q.CommandText = "CREATE TABLE localPlayers(id INTEGER PRIMARY KEY,name TEXT,worldversion INTEGER,data BLOB,isDead BOOLEAN); "
                + "INSERT INTO localPlayers VALUES(1,'Test Person',249,$data,1);";
            q.Parameters.AddWithValue("$data", EmptyPlayer().Player);
            await q.ExecuteNonQueryAsync();
        }

        public Task<CharacterRecoveryPreview> PreviewAsync() =>
            new CharacterRecoveryService().PreviewAsync(Root, "Sandbox/Test", null);

        public Task<CharacterRecoveryResult> RecoverAsync(string? remains) =>
            new CharacterRecoveryService().RecoverAsync(Root, "Sandbox/Test", null, remains, default);

        public async Task<object?> ScalarAsync(string sql)
        {
            await using var c = new SqliteConnection($"Data Source={Database};Pooling=False");
            await c.OpenAsync();
            await using var q = c.CreateCommand();
            q.CommandText = sql;
            return await q.ExecuteScalarAsync();
        }

        public void Dispose() => Directory.Delete(Work, true);
    }
}
