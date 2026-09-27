using PzTools.Backup.Core;

namespace PzTools.Backup.Tests;

public sealed class BackupPathTests
{
    [Theory]
    [InlineData("C:/absolute/file.txt")]
    [InlineData("C:\\absolute\\file.txt")]
    [InlineData("/absolute/file.txt")]
    [InlineData("\\\\server\\share\\file.txt")]
    public void NormalizeRelative_RejectsAbsolutePaths(string path)
    {
        Assert.Throws<ArgumentException>(() => BackupPath.NormalizeRelative(path));
    }

    [Theory]
    [InlineData("folder\\file.bin", "folder/file.bin")]
    [InlineData("folder/file.bin/", "folder/file.bin")]
    [InlineData("한글/파일.dat", "한글/파일.dat")]
    public void NormalizeRelative_ReturnsCanonicalPath(string input, string expected)
    {
        Assert.Equal(expected, BackupPath.NormalizeRelative(input));
    }

    [Theory]
    [InlineData("")]
    [InlineData(".")]
    [InlineData("..")]
    [InlineData("folder/../file")]
    public void NormalizeRelative_RejectsUnsafePath(string input)
    {
        Assert.Throws<ArgumentException>(() => BackupPath.NormalizeRelative(input));
    }
}
