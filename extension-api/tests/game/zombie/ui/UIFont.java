package zombie.ui;

/** Synthetic: some of the game's fonts, the distance-field ones (Sdf...) among them. */
public enum UIFont {
    Small, Medium, Large, Massive, Title, SdfRegular, SdfBold, SdfRobertoSans;

    public static UIFont FromString(String name) {
        try { return valueOf(name); } catch (IllegalArgumentException unknown) { return null; }
    }
}
