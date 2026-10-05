using System.Buffers.Binary;
using System.Text;
using Microsoft.Data.Sqlite;
using PzTools.Zomboid.Recovery;

namespace PzTools.Backup.Tests;

public sealed class CharacterRecoveryTests
{
    [Fact]
    public void ZombieInventory_MovesOpaqueRecordsAndRemapsClothingWithoutChangingTraits()
    {
        var (player, layout) = EmptyPlayer();
        var zombie = Zombie("Test");
        var result = ZombieInventoryRecovery.Recover(player, layout, "Test", ZombieFile(zombie), Registry);
        Assert.Equal(3, result.Items); // card, shirt and bag; no wound overlay
        Assert.Equal(ZombieFile(), result.Zombies);
        Assert.True(result.Player.AsSpan().IndexOf(BagPayload) >= 0);
        Assert.True(result.Player.AsSpan().IndexOf(Sample.Create().TraitsAndXp) >= 0);
        Assert.Equal(result.Player, PlayerHealthEditor.Heal(result.Player, 249, out var after));
        Assert.Equal(new byte[] { 1, 0, 5, (byte)'T', (byte)'o', (byte)'r', (byte)'s', (byte)'o', 0, 1 },
            result.Player[after.WornStart..after.WornEnd]);
        Assert.All(result.Player[after.Hands..(after.Hands + 8)], b => Assert.Equal(255, b));
    }

    [Fact]
    public void ZombieInventory_RejectsAmbiguityWrongIdentityMovedZombieAndTruncation()
    {
        var (player, layout) = EmptyPlayer();
        var zombie = Zombie("Test");
        Assert.Throws<InvalidDataException>(() => ZombieInventoryRecovery.Recover(player, layout, "Test",
            ZombieFile(zombie, zombie), Registry));
        Assert.Throws<InvalidDataException>(() => ZombieInventoryRecovery.Recover(player, layout, "Test",
            ZombieFile(Zombie("Other Test")), Registry));
        var moved = zombie.ToArray(); BinaryPrimitives.WriteSingleBigEndian(moved.AsSpan(10), 1);
        Assert.Throws<InvalidDataException>(() => ZombieInventoryRecovery.Recover(player, layout, "Test", ZombieFile(moved), Registry));
        var bytes = ZombieFile(zombie);
        for (var length = 0; length < bytes.Length; length++)
            Assert.Throws<InvalidDataException>(() => ZombieInventoryRecovery.Recover(player, layout, "Test", bytes[..length], Registry));
        var result = ZombieInventoryRecovery.Recover(player, layout, "Test", ZombieFile(Zombie("Someone"), zombie), Registry);
        Assert.Equal(ZombieFile(Zombie("Someone")), result.Zombies);
    }

    // Reported by a player: a bite healed outside the game kept its wound on the character, because the game takes a
    // wound or bandage model off only when it sees the body part change during play.
    [Fact]
    public void Heal_TakesOffWoundAndBandageModelsAndRenumbersWornAndHeldItems()
    {
        var registry = new Dictionary<int, string>(Registry) { [5] = "Base.Bandage_Neck_Blood", [6] = "Base.Bandage" };
        var (player, layout) = DressedPlayer([(2, 21), (3, 22), (5, 23), (6, 24), (4, 25)],
            [("Torso", 0), ("Wound", 1), ("Wound", 2), ("Back", 4)], primary: 4, secondary: 3);

        var result = RemainsFormat.RemoveBodyModels(player, layout, registry);

        Assert.Equal(result, PlayerHealthEditor.Heal(result, 249, out var after));
        Assert.Equal(["Base.Shirt", "Base.Bandage", "Base.Bag"],
            RemainsFormat.Inventory(new RemainsReader(result, after.Start), registry).Groups.Select(g => g.Type));
        var worn = new RemainsReader(result, after.WornStart);
        Assert.Equal([new WornReference("Torso", 0), new WornReference("Back", 2)], RemainsFormat.Worn(worn, 3));
        Assert.Equal((2, 1), (worn.Short(), worn.Short()));
        Assert.Equal(2, BinaryPrimitives.ReadInt32BigEndian(result.AsSpan(after.Hands)));
        Assert.Equal(1, BinaryPrimitives.ReadInt32BigEndian(result.AsSpan(after.Hands + 4)));
        // Nothing to take off: the same player, untouched.
        Assert.Same(result, RemainsFormat.RemoveBodyModels(result, after, registry));
    }

    [Fact]
    public void BodyModels_AreTheWoundAndBandageModelsOnly()
    {
        Assert.True(RemainsFormat.IsBodyModel("Base.Wound_LHand_Bite_Male"));
        Assert.True(RemainsFormat.IsBodyModel("Base.Bandage_LeftHand_Blood"));
        Assert.False(RemainsFormat.IsBodyModel("Base.Bandage"));
        Assert.False(RemainsFormat.IsBodyModel("Base.BandageDirty"));
        Assert.False(RemainsFormat.IsBodyModel("Base.AlcoholBandage"));
    }

    // A player carrying the given items (registry id, item id), wearing some of them, holding two by index.
    internal static (byte[] Player, InventoryLayout Layout) DressedPlayer((int Registry, int Id)[] items,
        (string Where, int Index)[] wearing, int primary, int secondary)
    {
        var (player, layout) = EmptyPlayer();
        var worn = new BigEndianWriter(); worn.Byte((byte)wearing.Length);
        foreach (var (where, index) in wearing) { worn.String(where); worn.Short(index); }
        worn.Short(primary); worn.Short(secondary);
        player = [.. player.AsSpan(0, layout.WornStart), .. worn.ToArray(), .. player.AsSpan(layout.WornEnd + 4)];
        BinaryPrimitives.WriteInt32BigEndian(player.AsSpan(layout.Hands), primary);
        BinaryPrimitives.WriteInt32BigEndian(player.AsSpan(layout.Hands + 4), secondary);
        var inventory = new BigEndianWriter(); inventory.String("none"); inventory.Byte(0); inventory.Short(items.Length);
        foreach (var (registry, id) in items)
        {
            var item = new BigEndianWriter(); item.Short(registry); item.Byte(255); item.Int(id); item.Byte(0);
            inventory.Int(1); inventory.Int(item.ToArray().Length); inventory.Bytes(item.ToArray());
        }
        inventory.Zeros(5);
        player = [.. player.AsSpan(0, layout.Start), .. inventory.ToArray(), .. player.AsSpan(layout.End)];
        player = PlayerHealthEditor.Heal(player, 249, out layout);
        return (player, layout);
    }

    internal static readonly IReadOnlyDictionary<int, string> Registry = new Dictionary<int, string>
    { [1] = "Base.IDcard", [2] = "Base.Shirt", [3] = "Base.Wound_Neck_Bite_Female", [4] = "Base.Bag" };
    internal static readonly byte[] BagPayload = [0, 4, 255, 0, 0, 0, 44, 0, 99, 98, 97, 96, 95];

    internal static (byte[] Player, InventoryLayout Layout) EmptyPlayer()
    {
        var player = PlayerHealthEditor.Heal(Sample.Create().Bytes, 249, out var layout);
        var w = new BigEndianWriter(); w.String("none"); w.Byte(0); w.Short(0); w.Zeros(5);
        player = [.. player.AsSpan(0, layout.Start), .. w.ToArray(), .. player.AsSpan(layout.End)];
        player = PlayerHealthEditor.Heal(player, 249, out layout);
        return (player, layout);
    }

    // Seen in a real save: a woman with human skin 4 rose with skin 3, as there are only four zombie skins.
    [Fact]
    public void ZombieInventory_MatchesAZombieWhoseSkinTheGameRenumbered()
    {
        var (player, layout) = EmptyPlayer();
        var result = ZombieInventoryRecovery.Recover(player, layout, "Test", ZombieFile(Zombie("Test", skinTexture: 1)), Registry);
        Assert.Equal(3, result.Items);
        Assert.Throws<InvalidDataException>(() => ZombieInventoryRecovery.Recover(player, layout, "Test",
            ZombieFile(Zombie("Other Test", skinTexture: 1)), Registry));
    }

    internal static byte[] Zombie(string name, bool includeCard = true, byte skinTexture = 2)
    {
        var w = new BigEndianWriter(); w.Byte(1); w.Byte(3); w.Zeros(24); w.Byte(0); w.Byte(1);
        Descriptor(w, "None", "None"); Visual(w, name, skinTexture);
        w.String("inventoryfemale"); w.Byte(0); w.Short(includeCard ? 4 : 3);
        var card = new BigEndianWriter(); card.Short(1); card.Byte(255); card.Int(11); card.Byte(64);
        card.Int(8); card.String("ID card: " + name);
        foreach (var item in new[] { card.ToArray(), new byte[] { 0, 3, 255, 0, 0, 0, 33, 0 },
            new byte[] { 0, 2, 255, 0, 0, 0, 22, 0 }, BagPayload }.Skip(includeCard ? 0 : 1))
        { w.Int(1); w.Int(item.Length); w.Bytes(item); }
        w.Zeros(5); w.Zeros(5 + 33); w.Int(0); w.Zeros(4); w.Int(0); w.Zeros(31);
        w.Int(0); w.Int(0); w.Zeros(8); w.Int(0); w.Int(1); w.Zeros(8);
        w.Byte(3); w.String("Wound"); w.Short(includeCard ? 1 : 0); w.String("Wound"); w.Short(includeCard ? 1 : 0);
        w.String("Torso"); w.Short(includeCard ? 2 : 1);
        return w.ToArray();
    }

    internal static void Descriptor(BigEndianWriter w, string first, string last)
    {
        w.Int(0); w.String(first); w.String(last); w.String("Kate"); w.Int(1);
        w.String("base:unemployed"); w.Int(0); w.Int(0); w.String("VoiceFemale"); w.Zeros(8);
    }
    internal static void Visual(BigEndianWriter w, string variant, byte skinTexture = 2)
    {
        w.Byte(44); w.Byte(variant == "Test" ? (byte)70 : (byte)90); w.Byte(40); w.Byte(20);
        w.Byte(255); w.Byte(200); w.Byte(100); w.Byte(0); w.Byte(skinTexture); w.Byte(255);
        w.String("Short"); w.Zeros(4); w.String(""); w.Byte(4); w.Byte(70); w.Byte(40); w.Byte(20);
    }
    internal static byte[] ZombieFile(params byte[][] zombies)
    {
        var w = new BigEndianWriter(); w.Int(249); w.Int(zombies.Length);
        foreach (var zombie in zombies) w.Bytes(zombie);
        return w.ToArray();
    }

    [Fact]
    public void Heal_PreservesTraitsProgressInventoryAndUnknownModData()
    {
        var sample = Sample.Create();
        var original = sample.Bytes.ToArray();
        var healed = PlayerHealthEditor.Heal(original, 249);
        Assert.Equal(original, sample.Bytes);
        Assert.True(healed.AsSpan(0, sample.Stats - 5).SequenceEqual(original.AsSpan(0, sample.Stats - 5)));
        Assert.Equal(.43f, BinaryPrimitives.ReadSingleBigEndian(healed.AsSpan(sample.Stats + 5 * 4)));
        for (var i = 0; i < 24; i++)
        {
            if (i == 5) continue;
            Assert.Equal(i switch { 3 or 10 or 15 => 1f, 18 => 37f, _ => 0f },
                BinaryPrimitives.ReadSingleBigEndian(healed.AsSpan(sample.Stats + i * 4)));
        }
        // Locate the intact trait/XP record, exercise regularity and nutrition by exact bytes.
        Assert.True(healed.AsSpan().IndexOf(sample.TraitsAndXp) >= 0);
        Assert.True(healed.AsSpan().IndexOf(sample.Regularity) >= 0);
        Assert.True(healed.AsSpan().IndexOf(sample.Nutrition) >= 0);
        Assert.True(healed.AsSpan().IndexOf(Encoding.UTF8.GetBytes("pending-soreness")) < 0);
        Assert.Equal(healed, PlayerHealthEditor.Heal(healed, 249));
        var body = sample.Stats + 96;
        for (var i = 0; i < 17; i++)
        {
            var part = healed.AsSpan(body + i * 93, 93).ToArray();
            Assert.Equal(100, BinaryPrimitives.ReadSingleBigEndian(part.AsSpan(8)));
            Assert.Equal(1, part[42]); Assert.Equal(1, part[48]); Assert.Equal(1, part[49]);
            part.AsSpan(8, 4).Clear(); part[42] = part[48] = part[49] = 0;
            Assert.All(part, value => Assert.Equal(0, value));
        }
        Assert.Equal(-1, BinaryPrimitives.ReadSingleBigEndian(healed.AsSpan(body + 17 * 93 + 26)));
        Assert.Equal(-1, BinaryPrimitives.ReadSingleBigEndian(healed.AsSpan(body + 17 * 93 + 30)));
        var thermal = body + 17 * 93 + 39;
        Assert.Equal(37, BinaryPrimitives.ReadSingleBigEndian(healed.AsSpan(thermal)));
        Assert.Equal(1.5f, BinaryPrimitives.ReadSingleBigEndian(healed.AsSpan(thermal + 8)));
        for (var i = 0; i < 17; i++)
        {
            var node = thermal + 40 + i * 40;
            Assert.Equal(i, BinaryPrimitives.ReadInt32BigEndian(healed.AsSpan(node)));
            Assert.Equal(i == 6 ? 37 : 35, BinaryPrimitives.ReadSingleBigEndian(healed.AsSpan(node + 4)));
            Assert.Equal(12, BinaryPrimitives.ReadSingleBigEndian(healed.AsSpan(node + 24))); // insulation preserved
            Assert.Equal(0, BinaryPrimitives.ReadSingleBigEndian(healed.AsSpan(node + 32))); // body wetness
        }
    }

    [Fact]
    public void UnsupportedMalformedAndTruncatedDataAreRejected()
    {
        var sample = Sample.Create().Bytes;
        Assert.Throws<InvalidDataException>(() => PlayerHealthEditor.Heal(sample, 250));
        for (var length = 0; length < sample.Length; length++)
            Assert.Throws<InvalidDataException>(() => PlayerHealthEditor.Heal(sample[..length], 249));
        Assert.Throws<InvalidDataException>(() => PlayerHealthEditor.Heal([.. sample, 0], 249));
    }

    [Fact]
    public async Task Service_ResurrectsAtomicallyWithoutLeavingExtraCopies()
    {
        using var workspace = new RecoveryWorkspace();
        var blob = Sample.Create().Bytes;
        await workspace.CreateDatabase(blob);
        var result = await new CharacterRecoveryService().RecoverAsync(workspace.Root, "Sandbox/Test");
        Assert.True(result.Resurrected);
        workspace.AssertNoExtraCopies();
        await using var connection = new SqliteConnection($"Data Source={workspace.Database};Pooling=False");
        await connection.OpenAsync();
        var query = connection.CreateCommand();
        query.CommandText = "SELECT isDead FROM localPlayers;";
        Assert.Equal(0L, await query.ExecuteScalarAsync());
        query.CommandText = "SELECT data FROM localPlayers;";
        Assert.Equal(PlayerHealthEditor.Heal(blob, 249), (byte[])(await query.ExecuteScalarAsync())!);
        Assert.Empty(Directory.GetDirectories(Path.GetDirectoryName(Path.GetDirectoryName(workspace.Database)!)!, ".*"));
    }

    // v0.1.0 report: a save whose only character is not id 1 could not be revived.
    [Fact]
    public async Task Service_RecoversTheOnlyCharacterWhateverItsId()
    {
        using var workspace = new RecoveryWorkspace();
        var blob = Sample.Create().Bytes;
        await workspace.CreateDatabase(blob, id: 3);
        var result = await new CharacterRecoveryService().RecoverAsync(workspace.Root, "Sandbox/Test");
        Assert.True(result.Resurrected);
        var row = Assert.Single(await workspace.ReadRows());
        Assert.Equal((3L, false), (row.Id, row.Dead));
        Assert.Equal(PlayerHealthEditor.Heal(blob, 249), row.Data);
        workspace.AssertNoExtraCopies();
    }

    [Theory]
    [InlineData(1L)]
    [InlineData(2L)]
    public async Task Service_RecoversOnlyTheChosenCharacter(long chosen)
    {
        using var workspace = new RecoveryWorkspace();
        var blob = Sample.Create().Bytes;
        await workspace.CreateDatabase(blob, multiple: true);
        var result = await new CharacterRecoveryService().RecoverAsync(workspace.Root, "Sandbox/Test", chosen);
        Assert.Equal(chosen == 1 ? "Test" : "Other", result.Name);
        var rows = await workspace.ReadRows();
        Assert.Equal([1L, 2L], rows.Select(row => row.Id));
        foreach (var row in rows)
        {
            Assert.Equal(row.Id != chosen, row.Dead);
            Assert.Equal(row.Id == chosen ? PlayerHealthEditor.Heal(blob, 249) : blob, row.Data);
        }
    }

    [Fact]
    public async Task Service_RefusesAChosenCharacterThatIsGone()
    {
        using var workspace = new RecoveryWorkspace();
        await workspace.CreateDatabase(Sample.Create().Bytes);
        var original = await File.ReadAllBytesAsync(workspace.Database);
        var error = await Assert.ThrowsAsync<InvalidDataException>(() => new CharacterRecoveryService()
            .RecoverAsync(workspace.Root, "Sandbox/Test", 2));
        Assert.Equal("recovery-character-missing", error.Message);
        Assert.Equal(original, await File.ReadAllBytesAsync(workspace.Database));
        workspace.AssertNoExtraCopies();
    }

    [Fact]
    public async Task CharacterList_ListsEveryLocalCharacterById()
    {
        using var workspace = new RecoveryWorkspace();
        await workspace.CreateDatabase(Sample.Create().Bytes, multiple: true, id: 4);
        var characters = await new PzTools.Zomboid.State.CharacterNameReader().ListLocalAsync(workspace.Database);
        Assert.Equal([(4L, "Test", true), (5L, "Other", true)], characters.Select(c => (c.Id, c.Name, c.Dead)));
    }

    [Theory]
    [InlineData("playing")]
    [InlineData("journal")]
    [InlineData("unsupported")]
    [InlineData("ambiguous")]
    [InlineData("network-player")]
    public async Task Service_FailureNeverChangesTheOriginal(string kind)
    {
        using var workspace = new RecoveryWorkspace();
        await workspace.CreateDatabase(Sample.Create().Bytes, kind == "unsupported" ? 250 : 249, kind == "ambiguous");
        if (kind == "network-player")
        {
            await using var connection = new SqliteConnection($"Data Source={workspace.Database};Pooling=False");
            await connection.OpenAsync();
            var query = connection.CreateCommand();
            query.CommandText = "CREATE TABLE networkPlayers(id INTEGER); INSERT INTO networkPlayers VALUES(1);";
            await query.ExecuteNonQueryAsync();
        }
        var original = await File.ReadAllBytesAsync(workspace.Database);
        if (kind == "journal") await File.WriteAllBytesAsync(workspace.Database + "-wal", [1]);
        using (var handle = kind == "playing"
            ? File.Open(workspace.Database, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite) : null)
            await Assert.ThrowsAnyAsync<Exception>(() => new CharacterRecoveryService()
                .RecoverAsync(workspace.Root, "Sandbox/Test"));
        Assert.Equal(original, await File.ReadAllBytesAsync(workspace.Database));
    }

    [RequiresEnvironmentFact("PZTOOLS_TOOLS_DIR")]
    public async Task PublishedWorker_WhenProvided_UsesTheProcessContract()
    {
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        using var workspace = new RecoveryWorkspace();
        await workspace.CreateDatabase(Sample.Create().Bytes);
        var executable = Path.Combine(tools, "PzTools.Zomboid.Recovery.Cli.exe");
        Assert.True(File.Exists(executable), executable);
        var start = new System.Diagnostics.ProcessStartInfo(executable)
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in new[] { "--saves-root", workspace.Root, "--save-id", "Sandbox/Test",
            "--repository", Path.Combine(workspace.Root, "repository"),
            "--run-index", "1", "--telemetry-identity", Path.Combine(workspace.Root, "telemetry") })
            start.ArgumentList.Add(arg);
        using var process = System.Diagnostics.Process.Start(start)!;
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
        var output = await outputTask;
        Assert.True(process.ExitCode == 0, output + await errorTask);
        Assert.Contains("character-recovery", output);
        Assert.Single(Directory.GetFiles(workspace.Root, "players.db", SearchOption.AllDirectories));
        Assert.DoesNotContain("BackupDirectory", output, StringComparison.OrdinalIgnoreCase);
    }

    [RequiresEnvironmentFact("PZTOOLS_RECOVERY_SAMPLES")]
    public async Task RealSaveSamples_WhenProvided_AreEditedOnlyInCopies()
    {
        var samples = Environment.GetEnvironmentVariable("PZTOOLS_RECOVERY_SAMPLES")!;
        foreach (var path in samples.Split(';'))
        {
            // Explicit read-only input. Test mutations are limited to the isolated temporary workspace.
            await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
            await connection.OpenAsync();
            var query = connection.CreateCommand();
            query.CommandText = "SELECT data,worldversion FROM localPlayers WHERE id=1;";
            await using var reader = await query.ExecuteReaderAsync();
            Assert.True(await reader.ReadAsync());
            var blob = (byte[])reader.GetValue(0);
            var version = reader.GetInt64(1);
            var healed = PlayerHealthEditor.Heal(blob, version);
            Assert.Equal(healed, PlayerHealthEditor.Heal(healed, version));
            using var workspace = new RecoveryWorkspace();
            File.Copy(path, workspace.Database);
            await new CharacterRecoveryService().RecoverAsync(workspace.Root, "Sandbox/Test");
            workspace.AssertNoExtraCopies();
        }
    }

    private sealed class RecoveryWorkspace : IDisposable
    {
        private readonly string directory = Path.Combine(Path.GetTempPath(), "pztools-recovery-test-" + Guid.NewGuid().ToString("N"));
        public string Root => Path.Combine(directory, "Saves");
        public string Database => Path.Combine(Root, "Sandbox", "Test", "players.db");
        public void AssertNoExtraCopies() =>
            Assert.Equal([Database], Directory.GetFiles(directory, "*", SearchOption.AllDirectories));
        public RecoveryWorkspace() => Directory.CreateDirectory(Path.GetDirectoryName(Database)!);
        public async Task CreateDatabase(byte[] blob, int version = 249, bool multiple = false, long id = 1)
        {
            await using var connection = new SqliteConnection($"Data Source={Database};Pooling=False");
            await connection.OpenAsync();
            var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE localPlayers(id INTEGER PRIMARY KEY,name TEXT,worldversion INTEGER,data BLOB,isDead BOOLEAN); "
                + "INSERT INTO localPlayers VALUES($id,'Test',$version,$data,1);";
            command.Parameters.AddWithValue("$id", id);
            command.Parameters.AddWithValue("$version", version); command.Parameters.AddWithValue("$data", blob);
            await command.ExecuteNonQueryAsync();
            if (multiple) { command.CommandText = "INSERT INTO localPlayers SELECT $id+1,'Other',worldversion,data,isDead FROM localPlayers;"; await command.ExecuteNonQueryAsync(); }
        }

        public async Task<List<(long Id, bool Dead, byte[] Data)>> ReadRows()
        {
            await using var connection = new SqliteConnection($"Data Source={Database};Pooling=False");
            await connection.OpenAsync();
            var query = connection.CreateCommand();
            query.CommandText = "SELECT id,isDead,data FROM localPlayers ORDER BY id;";
            var rows = new List<(long, bool, byte[])>();
            await using var reader = await query.ExecuteReaderAsync();
            while (await reader.ReadAsync()) rows.Add((reader.GetInt64(0), reader.GetBoolean(1), (byte[])reader.GetValue(2)));
            return rows;
        }
        public void Dispose() => Directory.Delete(directory, true);
    }

    internal sealed record Sample(byte[] Bytes, int Stats, byte[] TraitsAndXp, byte[] Regularity, byte[] Nutrition)
    {
        public static Sample Create()
        {
            var w = new BigEndianWriter();
            w.Zeros(26); w.Byte(1); w.Int(1); // opaque Lua mod data
            w.Byte(0); w.String("negative-mod-trait"); w.Byte(0); w.String("keep-me");
            w.Byte(1); Descriptor(w, "Test", "Person");
            Visual(w, "Test");
            w.String("inventory"); w.Byte(0); w.Short(1); w.Int(1); w.Int(8); w.Double(123456.25); w.Zeros(5);
            w.Byte(1); w.Float(8); var stats = w.Position;
            for (var i = 0; i < 24; i++) w.Float(.43f);
            for (var part = 0; part < 17; part++)
            {
                for (var i = 0; i < 8; i++) w.Byte(1);
                w.Float(3); w.Float(20); w.Byte(1); w.Float(9);
                for (var i = 0; i < 7; i++) w.Float(11);
                w.Byte(1); w.Byte(1); w.Byte(1); w.Float(4); w.Byte(1); w.Byte(1); w.Float(9);
                w.Byte(1); w.Float(3); w.Byte(1); w.Float(4); w.Byte(1); w.Float(10);
                w.String("splint"); w.String("bandage"); for (var i = 0; i < 6; i++) w.Float(12);
            }
            w.Float(5); w.Byte(1); w.Float(6); w.Int(80); w.Byte(1);
            for (var i = 0; i < 6; i++) w.Float(100);
            w.Byte(1); for (var i = 0; i < 9; i++) w.Float(3);
            w.Int(17); for (var i = 0; i < 17; i++) { w.Int(i); for (var n = 0; n < 9; n++) w.Float(12); }
            var traitStart = w.Position;
            w.Int(4); foreach (var trait in new[] { "Smoker", "Cowardly", "Underweight", "CustomNegative" }) w.String(trait);
            w.Float(287.5f); w.Int(2); w.Int(3);
            w.Int(1); w.String("Fitness"); w.Float(456.5f);
            w.Int(1); w.String("Strength"); w.Int(7);
            w.Int(1); w.String("Axe"); w.Float(1.25f); w.Byte(2); w.Byte(3);
            var traitEnd = w.Position;
            w.Zeros(8); w.Byte(1); for (var i = 0; i < 8; i++) w.Float(22);
            w.Int(1); w.String("read-book"); w.Int(97); w.Float(11);
            w.Int(1); w.String("learned-recipe"); w.Int(13); w.Float(100); w.Float(67); w.Float(89);
            w.Zeros(14); w.Byte(1); w.Int(0); w.Int(0); w.Zeros(8); w.Int(2); w.Byte(5); w.Byte(9);
            w.Double(77.125); w.Int(123); w.Byte(1); w.String("Torso"); w.Short(0); w.Short(0); w.Short(0); w.Int(1);
            var nutrition = w.Position; foreach (var f in new[] { -1001f, 42f, 52f, 62f, 53.5f }) w.Float(f);
            w.Byte(0); w.String("tag"); w.Zeros(12); w.String("display"); w.Zeros(4); w.Byte(0); w.Int(0);
            w.Int(1); w.String("pending-soreness"); w.Float(42);
            w.Int(1); w.String("pending-soreness"); w.Int(120);
            var reg = w.Position; w.Int(1); w.String("preserved-regularity"); w.Float(63.25f); var regEnd = w.Position;
            w.Int(1); w.String("pending-soreness");
            w.Int(1); w.String("exercise-timestamp"); w.Zeros(8);
            w.Short(1); w.Short(77); w.Short(1); w.String("media-line"); w.Byte(1); w.Int(1);
            w.Int(2); w.Short('A'); w.Short('B'); w.Int(3); w.Double(51);
            var bytes = w.ToArray();
            return new(bytes, stats, bytes[traitStart..traitEnd], bytes[reg..regEnd], bytes[nutrition..(nutrition + 20)]);
        }
    }

    internal sealed class BigEndianWriter
    {
        private readonly MemoryStream stream = new();
        public int Position => (int)stream.Position;
        public void Byte(byte value) => stream.WriteByte(value);
        public void Bytes(byte[] bytes) => stream.Write(bytes);
        public void Zeros(int count) => stream.Write(new byte[count]);
        public void Short(int value) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteInt16BigEndian(b, (short)value); stream.Write(b); }
        public void Int(int value) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteInt32BigEndian(b, value); stream.Write(b); }
        public void Float(float value) => Int(BitConverter.SingleToInt32Bits(value));
        public void Double(double value) { Span<byte> b = stackalloc byte[8]; BinaryPrimitives.WriteDoubleBigEndian(b, value); stream.Write(b); }
        public void String(string value) { var bytes = Encoding.UTF8.GetBytes(value); Short(bytes.Length); stream.Write(bytes); }
        public byte[] ToArray() => stream.ToArray();
    }
}
