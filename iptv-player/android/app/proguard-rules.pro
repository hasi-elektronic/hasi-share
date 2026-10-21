# Release builds log nothing below WARN (CONTRACT §10, docs/SECURITY.md §2):
# verbose/debug/info calls are removed by R8 together with their string building.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
    public static boolean isLoggable(java.lang.String, int);
}
-assumenosideeffects class io.iptvplayer.shared.log.SafeLog {
    public static void v(...);
    public static void d(...);
    public static void i(...);
}

# Play Billing ships its own consumer rules; Media3 and Room as well.
-dontwarn org.xmlpull.v1.**
-dontwarn org.kxml2.**
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
