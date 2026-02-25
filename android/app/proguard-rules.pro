# Flutter Secure Storage R8 Fix
-dontwarn javax.annotation.**
-dontwarn javax.annotation.concurrent.**

# Keep Tink classes
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# Keep annotations
-keepattributes *Annotation*
