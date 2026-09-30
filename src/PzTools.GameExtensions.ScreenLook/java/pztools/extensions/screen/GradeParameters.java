package pztools.extensions.screen;

import java.util.Locale;
import java.util.Map;

/**
 * What a screen grade looks like, as plain numbers. A preset is a named set of them; the user
 * chooses a preset and one strength, and everything here follows from that.
 *
 * <p>All values are baked into the shader text as constants, so the text itself identifies a
 * grade: two equal parameter sets give the same shader and nothing is rebuilt.
 */
public record GradeParameters(
        double strength,
        double contrast, double pivot, double saturation,
        double shadowGain, double highlightRoll,
        double[] shadowTint, double[] highlightTint,
        double clarity,
        double seasonAmount, double seasonSaturation, double[] seasonTint) {

    public static final int SPRING = 1, SUMMER = 2, LATE_SUMMER = 3, AUTUMN = 4, WINTER = 5;
    private static final double[] NONE = { 0, 0, 0 }, WHITE = { 1, 1, 1 };

    /** The user's request, validated once when settings arrive and never on the game thread. */
    public record Request(String preset, double strength, boolean seasonal, double clarityScale, double seasonalAmount) {
        /** Nothing wanted: what a retired module asks for. */
        public static final Request OFF = new Request("realistic", 0, false, 1, 0.8);
        private static final java.util.Set<String> KEYS =
            java.util.Set.of("schema_version", "preset", "strength", "seasonal", "clarity_scale", "seasonal_amount");

        /** The module's whole configuration. An unknown key is a mistake, not something to ignore. */
        public static Request parse(Map<String, String> values) {
            for (String key : values.keySet())
                if (!KEYS.contains(key)) throw new IllegalArgumentException("Unknown screen look setting: " + key);
            if (!values.getOrDefault("schema_version", "1").equals("1")) throw new IllegalArgumentException("schema_version must be 1");
            String preset = values.getOrDefault("preset", "realistic");
            if (!preset.equals("realistic") && !preset.equals("vivid") && !preset.equals("cinematic"))
                throw new IllegalArgumentException("preset must be realistic, vivid or cinematic");
            double strength = number(values.get("strength"), "strength", 60, 0, 100) / 100.0;
            boolean seasonal = flag(values.get("seasonal"), "seasonal", false);
            double clarity = number(values.get("clarity_scale"), "clarity_scale", 1, 0, 2);
            double amount = number(values.get("seasonal_amount"), "seasonal_amount", 0.8, 0, 1);
            return new Request(preset, strength, seasonal, clarity, amount);
        }

        /** Nothing to draw: every part turned down to nothing. */
        public boolean idle() { return strength <= 0 && !seasonal; }

        private static boolean flag(String value, String key, boolean fallback) {
            if (value == null) return fallback;
            if (value.equals("true")) return true;
            if (value.equals("false")) return false;
            throw new IllegalArgumentException(key + " must be true or false");
        }
        private static double number(String text, String key, double fallback, double min, double max) {
            if (text == null) return fallback;
            double value;
            try { value = Double.parseDouble(text); }
            catch (NumberFormatException invalid) { throw new IllegalArgumentException("Invalid screen setting: " + key, invalid); }
            if (!Double.isFinite(value) || value < min || value > max)
                throw new IllegalArgumentException(key + " must be between " + min + " and " + max);
            return value;
        }
    }

    /**
     * @param season the game's season number; anything unknown leaves the seasonal part out
     */
    public static GradeParameters of(Request request, int season) {
        double clarity;
        double contrast, pivot, saturation, shadowGain, roll;
        double[] shadows, highlights;
        switch (request.preset()) {
            // Colourful and crisp: more saturation and local contrast, shadows left almost alone.
            case "vivid" -> {
                contrast = 1.12; pivot = 0.50; saturation = 1.22; shadowGain = 0.96; roll = 0.15;
                shadows = NONE; highlights = NONE; clarity = 0.8;
            }
            // Film look: cool shadows against warm highlights, strong contrast, soft highlight shoulder.
            case "cinematic" -> {
                contrast = 1.14; pivot = 0.47; saturation = 0.95; shadowGain = 0.90; roll = 0.35;
                shadows = new double[] { -0.012, 0.004, 0.016 }; highlights = new double[] { 0.018, 0.008, -0.012 };
                clarity = 0.4;
            }
            // Subdued and natural: a little less colour, deeper shadows, barely tinted.
            default -> {
                contrast = 1.08; pivot = 0.45; saturation = 0.88; shadowGain = 0.88; roll = 0.25;
                shadows = new double[] { -0.004, 0.0, 0.006 }; highlights = new double[] { 0.006, 0.003, -0.004 };
                clarity = 0.6;
            }
        }
        double seasonSaturation = 1;
        double[] seasonTint = WHITE;
        boolean known = true;
        switch (season) {
            case SPRING -> { seasonSaturation = 1.08; seasonTint = new double[] { 0.98, 1.03, 0.97 }; }
            case SUMMER, LATE_SUMMER -> { seasonSaturation = 1.04; seasonTint = new double[] { 1.04, 1.01, 0.94 }; }
            case AUTUMN -> { seasonSaturation = 0.90; seasonTint = new double[] { 1.06, 0.99, 0.90 }; }
            case WINTER -> { seasonSaturation = 0.80; seasonTint = new double[] { 0.94, 0.99, 1.06 }; }
            default -> known = false;
        }
        return new GradeParameters(request.strength(), contrast, pivot, saturation, shadowGain, roll, shadows, highlights,
            clarity * request.clarityScale(),
            request.seasonal() && known ? request.seasonalAmount() : 0, seasonSaturation, seasonTint);
    }

    static String literal(double value) { return String.format(Locale.ROOT, "%.5f", value); }
    static String literal(double[] value) {
        return "vec3(" + literal(value[0]) + ", " + literal(value[1]) + ", " + literal(value[2]) + ")";
    }
}
