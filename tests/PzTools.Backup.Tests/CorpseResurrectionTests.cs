using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.Sqlite;
using PzTools.Process.Hosting;
using PzTools.Zomboid.Recovery;
using static PzTools.Backup.Tests.CharacterRecoveryTests;

namespace PzTools.Backup.Tests;

public sealed class CorpseResurrectionTests
{
    [Fact]
    public void EmptyHandSentinel_IsNotTreatedAsAnItemId()
    {
        var id = Guid.NewGuid();
        var player = Stamp(EmptyPlayer().Player, id, -1, -1);
        player = PlayerHealthEditor.Heal(player, 249, out var layout);
        var zombie = Zombie("Test", false);
        var item = zombie.AsSpan().IndexOf(BagPayload);
        Assert.True(item >= 0);
        BinaryPrimitives.WriteInt32BigEndian(zombie.AsSpan(item + 3), -1);
        zombie = Stamp(zombie, id, -1, -1);
        var restored = ZombieInventoryRecovery.Recover(player, layout, "Test Person", ZombieFile(zombie), Registry).Player;
        PlayerHealthEditor.Heal(restored, 249, out var after);
        Assert.Equal(-1, BinaryPrimitives.ReadInt32BigEndian(restored.AsSpan(after.Hands)));
        Assert.Equal(-1, BinaryPrimitives.ReadInt32BigEndian(restored.AsSpan(after.Hands + 4)));
        Assert.Equal(-1, BinaryPrimitives.ReadInt16BigEndian(restored.AsSpan(after.WornEnd)));
        Assert.Equal(-1, BinaryPrimitives.ReadInt16BigEndian(restored.AsSpan(after.WornEnd + 2)));
        Assert.Contains(FindGroups(restored), group => group.Ids.Contains(-1));
    }
    [Fact]
    public void ReanimatedInventory_DoesNotNeedOrInspectAnIdentityCard()
    {
        var (player,layout)=EmptyPlayer();
        var bytes=ZombieFile(Zombie("Test",includeCard:false));
        var result=ZombieInventoryRecovery.Recover(player,layout,"Test Person",bytes,Registry);
        Assert.Equal(2,result.Items);Assert.Equal(ZombieFile(),result.Zombies);
        Assert.Contains(FindGroups(result.Player),g=>g.Type=="Base.Bag"&&g.Ids.SequenceEqual([44]));
        Assert.DoesNotContain(FindGroups(result.Player),g=>g.Type=="Base.IDcard");
        Assert.True(result.Player.AsSpan().IndexOf(BagPayload)>=0);
        Assert.Equal(result.Player,PlayerHealthEditor.Heal(result.Player,249));
    }

    [Fact]
    public void PersistentCharacterId_FindsMovedZombie_AndRestoresSavedHandItemIds()
    {
        var (plain,_)=EmptyPlayer();var token=Guid.NewGuid();var player=Stamp(plain,token,44,22);
        player=PlayerHealthEditor.Heal(player,249,out var layout);
        var zombie=Stamp(Zombie("Other appearance",false),token,44,22);
        BinaryPrimitives.WriteSingleBigEndian(zombie.AsSpan(10),1234.5f);
        var result=ZombieInventoryRecovery.Recover(player,layout,"Test Person",ZombieFile(zombie),Registry);
        Assert.Equal(2,result.Items);PlayerHealthEditor.Heal(result.Player,249,out var restored);
        Assert.Equal(1,BinaryPrimitives.ReadInt32BigEndian(result.Player.AsSpan(restored.Hands)));
        Assert.Equal(0,BinaryPrimitives.ReadInt32BigEndian(result.Player.AsSpan(restored.Hands+4)));
        Assert.Equal(1,BinaryPrimitives.ReadInt16BigEndian(result.Player.AsSpan(restored.WornEnd)));
        Assert.Equal(0,BinaryPrimitives.ReadInt16BigEndian(result.Player.AsSpan(restored.WornEnd+2)));
        Assert.Equal(token.ToString("D"),CharacterIdentity.Player(result.Player).Metadata.Token);
        Assert.Throws<InvalidDataException>(()=>ZombieInventoryRecovery.Recover(player,layout,"Test Person",
            ZombieFile(Stamp(Zombie("Test",false),Guid.NewGuid(),44,22)),Registry));
    }

    [Fact]
    public async Task CorpseRecovery_MovesExactItemsAndWear_RemovesOnlyItsRecord_AndIsRepeatable()
    {
        using var f=new Fixture();var corpse=Body("Test",female:true);var other=Body("Other",female:true);
        var map=Chunk([other,corpse],Body("Decoy",true));
        await f.CreateAsync(map);
        var old=f.Player;
        var result=await new CharacterRecoveryService().RecoverAsync(f.Root,"Sandbox/Test");
        Assert.True(result.Resurrected);Assert.Equal(2,result.RecoveredItems);
        var after=await f.ReadPlayerAsync();Assert.False(after.Dead);
        Assert.Equal(Chunk([other],Body("Decoy",true)),File.ReadAllBytes(f.ChunkPath));
        Assert.Equal(0,FindGroups(after.Bytes).Count(g=>g.Type is "Base.IDcard"||g.Type.StartsWith("Base.Wound_",StringComparison.Ordinal)));
        Assert.True(after.Bytes.AsSpan().IndexOf(BagPayload)>=0);
        Assert.True(after.Bytes.AsSpan().IndexOf(Sample.Create().TraitsAndXp)>=0);
        PlayerHealthEditor.Heal(after.Bytes,249,out var layout);
        Assert.Equal(0,BinaryPrimitives.ReadInt16BigEndian(after.Bytes.AsSpan(layout.WornEnd-2)));
        var worldAfter=File.ReadAllBytes(f.ChunkPath);
        var second=await new CharacterRecoveryService().RecoverAsync(f.Root,"Sandbox/Test");
        Assert.False(second.Resurrected);Assert.Equal(0,second.RecoveredItems);
        Assert.Equal(after.Bytes,(await f.ReadPlayerAsync()).Bytes);Assert.Equal(worldAfter,File.ReadAllBytes(f.ChunkPath));
        Assert.False(SaveFileEditTransaction.IsPending(f.Save));
        Assert.Equal(old,f.Player); // Fixture input was not mutated by the editor.
        Assert.Empty(Directory.GetDirectories(Path.GetDirectoryName(f.Save)!,".*"));
    }

    [Fact]
    public async Task Heal_OfABittenLivingCharacter_TakesTheWoundModelOffInTheSave()
    {
        using var f=new Fixture();await f.CreateAsync([]);
        var (bitten,_)=DressedPlayer([(2,21),(3,22),(4,25)],[("Torso",0),("Wound",1),("Back",2)],primary:2,secondary:-1);
        await f.SetPlayerAsync(bitten,dead:false);
        var result=await new CharacterRecoveryService().RecoverAsync(f.Root,"Sandbox/Test");
        Assert.False(result.Resurrected);Assert.Equal(0,result.RecoveredItems);
        var after=await f.ReadPlayerAsync();
        Assert.Equal(["Base.Shirt","Base.Bag"],FindGroups(after.Bytes).Select(g=>g.Type));
        PlayerHealthEditor.Heal(after.Bytes,249,out var layout);
        Assert.Equal(1,BinaryPrimitives.ReadInt32BigEndian(after.Bytes.AsSpan(layout.Hands)));
    }

    [Theory]
    [InlineData("duplicate")]
    [InlineData("wrong-person")]
    [InlineData("decoy-only")]
    [InlineData("crc")]
    [InlineData("truncated")]
    public async Task UncertainOrCorruptWorld_NeverModifiesPlayerOrChunk(string kind)
    {
        using var f=new Fixture();byte[][] bodies=kind switch
        {
            "duplicate"=>[Body("Test",true),Body("Test",true)],
            "wrong-person"=>[Body("Other",true)],
            "decoy-only"=>[],
            _=>[Body("Test",true)],
        };
        var chunk=Chunk(bodies,Body("Test",true));
        if(kind=="crc")chunk[^1]^=1;
        if(kind=="truncated")chunk=chunk[..^1];
        await f.CreateAsync(chunk);
        var dbBefore=File.ReadAllBytes(f.Database);var chunkBefore=File.ReadAllBytes(f.ChunkPath);
        await Assert.ThrowsAsync<InvalidDataException>(()=>new CharacterRecoveryService().RecoverAsync(f.Root,"Sandbox/Test"));
        Assert.Equal(dbBefore,File.ReadAllBytes(f.Database));Assert.Equal(chunkBefore,File.ReadAllBytes(f.ChunkPath));
        Assert.False(SaveFileEditTransaction.IsPending(f.Save));
    }

    [Fact]
    public async Task IdentifiedCorpseWithoutInventory_ResurrectsWithoutInventingItems()
    {
        using var f = new Fixture();
        var body = Body("Test", true);
        var r = new RemainsReader(body, 2);
        RemainsFormat.Moving(r, out _);
        r.Skip(11); // gender/zombie/animal, ObjectID, server flag, persistent outfit
        Assert.True(r.Bool()); RemainsFormat.Descriptor(r);
        Assert.Equal(0, r.Byte()); RemainsFormat.HumanVisual(r);
        var start = r.Position;
        Assert.True(r.Bool()); r.Int(); var inventory = RemainsFormat.Inventory(r, Registry);
        RemainsFormat.Worn(r, inventory.Count); RemainsFormat.Worn(r, inventory.Count);
        var withoutInventory = RemainsFormat.Replace(body, start, r.Position, [0]);
        await f.CreateAsync(Chunk([withoutInventory], []));
        var result = await new CharacterRecoveryService().RecoverAsync(f.Root, "Sandbox/Test");
        Assert.True(result.Resurrected); Assert.Equal(0, result.RecoveredItems);
        Assert.Empty(FindGroups((await f.ReadPlayerAsync()).Bytes));
        Assert.Equal(Chunk([], []), File.ReadAllBytes(f.ChunkPath));
    }

    [Fact]
    public void ChunkCrc_UsesTheGamePolynomial_AndBodyParsingIsStrict()
    {
        Assert.Equal(0xcbf43926U,CorpseChunkReader.Crc("123456789"u8));
        var b=Body("Test",true);var chunk=Chunk([b],[]);
        var records=new CorpseChunkReader(chunk,Registry).Read();var body=Assert.Single(records);
        Assert.Equal("Test Person",body.Identity.Descriptor!.Name);
        Assert.Equal(b,chunk[body.Start..body.End]);
        Assert.Equal(Chunk([],[]),CorpseChunkReader.Remove(chunk,body));
        foreach(var offset in new[]{0,1,5,9,17,chunk.Length-1})
        {
            var damaged=chunk.ToArray();damaged[offset]^=0x7f;
            Assert.Throws<InvalidDataException>(()=>new CorpseChunkReader(damaged,Registry).Read());
        }
    }

    [Fact]
    public async Task ChunkAndPlayerEdit_RecoversTogetherAfterInterruptedPublication()
    {
        using var f=new Fixture();await f.CreateAsync(Chunk([Body("Test",true)],[]));
        var before=File.ReadAllBytes(f.ChunkPath);var target=Chunk([],[]);
        var preparedMap=Path.Combine(f.Work,"new-map");var preparedDb=Path.Combine(f.Work,"new-db");
        File.WriteAllBytes(preparedMap,target);File.Copy(f.Database,preparedDb);
        await using(var c=new SqliteConnection($"Data Source={preparedDb};Pooling=False")){await c.OpenAsync();await using var q=c.CreateCommand();q.CommandText="UPDATE localPlayers SET isDead=0;";await q.ExecuteNonQueryAsync();}
        var files=new[]{new PreparedSaveFile("map/0/0.bin",preparedMap,Hash(before)),new PreparedSaveFile("players.db",preparedDb,Hash(File.ReadAllBytes(f.Database)))};
        using(var blocked=new FileStream(f.Database,FileMode.Open,FileAccess.Read,FileShare.Read))
            Assert.Equal("save-edit-pending",(await Assert.ThrowsAsync<IOException>(()=>SaveFileEditTransaction.CommitAsync(f.Save,files,default))).Message);
        Assert.Equal(target,File.ReadAllBytes(f.ChunkPath));Assert.True((await f.ReadPlayerAsync()).Dead);
        Assert.True(await SaveFileEditTransaction.RecoverAsync(f.Save));
        Assert.Equal(target,File.ReadAllBytes(f.ChunkPath));Assert.False((await f.ReadPlayerAsync()).Dead);
        Assert.False(SaveFileEditTransaction.IsPending(f.Save));
    }

    [Theory]
    [InlineData("../outside.bin")]
    [InlineData("map/1/../../players.db")]
    [InlineData("map/1/2.bin:stream")]
    [InlineData("map/01/2.bin")]
    [InlineData("map\\1\\2.bin")]
    public async Task MultiFileEdit_RejectsAnythingExceptCanonicalChunkPaths(string name)
    {
        using var f=new Fixture();await f.CreateAsync(Chunk([],[]));
        var source=Path.Combine(f.Work,"payload");File.WriteAllBytes(source,[1]);var before=File.ReadAllBytes(f.Database);
        await Assert.ThrowsAsync<InvalidDataException>(()=>SaveFileEditTransaction.CommitAsync(f.Save,
            [new(name,source,Hash([1]))],default));
        Assert.Equal(before,File.ReadAllBytes(f.Database));Assert.False(SaveFileEditTransaction.IsPending(f.Save));
    }

    internal static byte[] Body(string first,bool female)
    {
        var inventory=ZombieInventoryRecovery.ReadAll(ZombieFile(Zombie("Test",false)),Registry)[0].Inventory;
        var w=new BigEndianWriter();w.Byte(1);w.Byte(11);w.Zeros(24);w.Byte(0);
        w.Byte(female?(byte)1:(byte)0);w.Byte(0);w.Byte(0);w.Short(0);w.Byte(0);w.Byte(0);w.Int(0);
        w.Byte(1);Descriptor(w,first,"Person");w.Byte(0);Visual(w,"Test");w.Byte(1);w.Int(123);
        w.Bytes(inventory.Header);w.Short(inventory.Groups.Count);foreach(var group in inventory.Groups)w.Bytes(group.Encoded);w.Bytes(inventory.Trailer);
        w.Byte(1);w.String("Torso");w.Short(1);w.Byte(1);w.String("Back");w.Short(2);
        w.Float(120.5f);w.Float(-1);w.Byte(0);w.Byte(0);w.Float(0);w.Byte(255);w.Byte(255);w.String("");w.String("");
        w.Byte(0);w.Byte(0);w.Byte(1);w.Int(1);w.Int(42);for(var i=0;i<10;i++)w.Float(i);
        return w.ToArray();
    }
    internal static byte[] Chunk(byte[][] corpses,byte[] embeddedDecoy)
    {
        var w=new BigEndianWriter();w.Byte(0);w.Int(249);w.Int(0);w.Zeros(8);
        w.Byte(1);w.Byte(15);w.Byte(0);w.Byte(1);w.Byte(15);w.Short(0);w.Int(0);w.Int(0);w.Int(0);
        w.Int(1);w.Int(0); // ground-floor bit in the 64-bit level mask
        w.Byte(0);w.Byte(embeddedDecoy.Length==0?(byte)65:(byte)67); // erosion empty; one/two static objects + extra
        w.Byte(0);w.Byte(1);w.Byte(0);w.Int(123);w.Byte(0); // unrelated ordinary tile
        if(embeddedDecoy.Length!=0)
        {
            w.Byte(4);w.Byte(1);w.Byte(6);w.Zeros(20);w.Int(embeddedDecoy.Length+8);
            w.Short(2);w.Byte(255);w.Int(919);w.Byte(0);w.Bytes(embeddedDecoy);w.Zeros(8);w.Byte(0);
        }
        w.Byte(1);w.Short(corpses.Length);foreach(var corpse in corpses)w.Bytes(corpse);w.Byte(1);
        w.Zeros(63*8);w.Byte(0);w.Short(0);w.Short(0);w.Int(0);w.Short(0);
        var bytes=w.ToArray();BinaryPrimitives.WriteInt32BigEndian(bytes.AsSpan(5),bytes.Length);
        BinaryPrimitives.WriteInt64BigEndian(bytes.AsSpan(9),CorpseChunkReader.Crc(bytes.AsSpan(17)));return bytes;
    }
    internal static byte[] Stamp(byte[] character,Guid id,int primary,int secondary)
    {
        var r=new RemainsReader(character,26);var has=r.Bool();var start=r.Position;var count=has?BinaryPrimitives.ReadInt32BigEndian(character.AsSpan(start)):0;
        if(has)r.Table();var end=r.Position;var w=new BigEndianWriter();w.Byte(1);w.Int(count+3);
        if(has)w.Bytes(character[(start+4)..end]);
        w.Byte(0);w.String("pztools.recovery.id");w.Byte(0);w.String(id.ToString("D"));
        w.Byte(0);w.String("pztools.recovery.primary");w.Byte(1);w.Double(primary);
        w.Byte(0);w.String("pztools.recovery.secondary");w.Byte(1);w.Double(secondary);
        return [..character.AsSpan(0,26),..w.ToArray(),..character.AsSpan(end)];
    }
    private static IReadOnlyList<InventoryGroup> FindGroups(byte[] player)
    {PlayerHealthEditor.Heal(player,249,out var layout);return RemainsFormat.Inventory(new RemainsReader(player,layout.Start),Registry).Groups;}
    private static string Hash(byte[] bytes)=>Convert.ToHexString(SHA256.HashData(bytes));
    internal static byte[] DictionaryBytes()
    {
        var w=new BigEndianWriter();w.Int(1);w.Zeros(7);w.Int(0);w.Int(1);w.String("Base");w.Int(Registry.Count);
        foreach(var item in Registry){w.Short(item.Key);w.Byte(0);w.String(item.Value[5..]);w.Byte(0);}return w.ToArray();
    }
    private sealed class Fixture : IDisposable
    {
        public string Work {get;}=Path.Combine(Path.GetTempPath(),"pztools-corpse-"+Guid.NewGuid().ToString("N"));
        public string Root=>Path.Combine(Work,"Saves");public string Save=>Path.Combine(Root,"Sandbox","Test");
        public string Database=>Path.Combine(Save,"players.db");public string ChunkPath=>Path.Combine(Save,"map","0","0.bin");
        public byte[] Player {get;}=EmptyPlayer().Player;
        public async Task CreateAsync(byte[] chunk)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(ChunkPath)!);File.WriteAllBytes(ChunkPath,chunk);
            File.WriteAllBytes(Path.Combine(Save,"WorldDictionary.bin"),DictionaryBytes());
            await using var c=new SqliteConnection($"Data Source={Database};Pooling=False");await c.OpenAsync();await using var q=c.CreateCommand();
            q.CommandText="CREATE TABLE localPlayers(id INTEGER PRIMARY KEY,name TEXT,worldversion INTEGER,data BLOB,isDead BOOLEAN); INSERT INTO localPlayers VALUES(1,'Test Person',249,$data,1);";
            q.Parameters.AddWithValue("$data",Player);await q.ExecuteNonQueryAsync();
        }
        public async Task SetPlayerAsync(byte[] data,bool dead)
        {
            await using var c=new SqliteConnection($"Data Source={Database};Pooling=False");await c.OpenAsync();await using var q=c.CreateCommand();
            q.CommandText="UPDATE localPlayers SET data=$data,isDead=$dead;";q.Parameters.AddWithValue("$data",data);q.Parameters.AddWithValue("$dead",dead);
            Assert.Equal(1,await q.ExecuteNonQueryAsync());
        }
        public async Task<(byte[] Bytes,bool Dead)> ReadPlayerAsync()
        {
            await using var c=new SqliteConnection($"Data Source={Database};Pooling=False");await c.OpenAsync();await using var q=c.CreateCommand();q.CommandText="SELECT data,isDead FROM localPlayers;";
            await using var read=await q.ExecuteReaderAsync();Assert.True(await read.ReadAsync());return ((byte[])read[0],read.GetBoolean(1));
        }
        public void Dispose()=>Directory.Delete(Work,true);
    }
}
