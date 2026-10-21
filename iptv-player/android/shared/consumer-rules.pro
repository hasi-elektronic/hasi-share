# kotlinx.serialization models of core/shared are referenced reflectively via generated serializers.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class io.iptvplayer.** {
    *** Companion;
}
-keepclasseswithmembers class io.iptvplayer.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-dontwarn org.xmlpull.v1.**
-dontwarn org.kxml2.**
