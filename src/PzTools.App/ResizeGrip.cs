using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;

namespace PzTools.App;

/// <summary>A thin handle between two areas; the pointer turns into the up-down resize arrow over it.</summary>
public sealed partial class ResizeGrip : Grid
{
    public ResizeGrip() => ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeNorthSouth);
}
