using PzTools.Projections;

namespace PzTools.App.Core;

public enum SaveListPlaceholder { None, Loading, Empty, Unavailable }

/// <summary>Shared by the shell and tests: zero rows alone never prove an empty save folder.</summary>
public static class SaveListPresentation
{
    public static SaveListPlaceholder Resolve(SaveListView? view, bool stateUnavailable = false)
    {
        // A background refresh/failure must not cover an already usable list.
        if (view is { Saves.Count: > 0 }) return SaveListPlaceholder.None;
        if (stateUnavailable) return SaveListPlaceholder.Unavailable;
        return view?.LoadState switch
        {
            null or SaveListLoadState.Loading => SaveListPlaceholder.Loading,
            SaveListLoadState.Ready => SaveListPlaceholder.Empty,
            _ => SaveListPlaceholder.Unavailable,
        };
    }
}
