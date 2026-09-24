using System.Collections.ObjectModel;

namespace PzTools.App.Core;

public static class IncrementalListReconciler
{
    public static void Reconcile<T>(ObservableCollection<T> items, IReadOnlyList<T> desired)
        where T : class
    {
        for (var index = 0; index < desired.Count; index++)
        {
            if (index < items.Count && ReferenceEquals(items[index], desired[index])) continue;
            var existingIndex = items.IndexOf(desired[index]);
            if (existingIndex >= 0)
                items.Move(existingIndex, index);
            else
                items.Insert(index, desired[index]);
        }
        while (items.Count > desired.Count) items.RemoveAt(items.Count - 1);
    }
}
