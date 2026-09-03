# Unity Ads keep rules
-keep class com.unity3d.ads.** { *; }
-keep class com.unity3d.services.** { *; }
-keepattributes SourceFile,LineNumberTable

# Flutter keep rules
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Supabase keep rules
-keep class io.supabase.** { *; }

# Firebase keep rules
-keep class com.google.firebase.** { *; }

# Play Core / SplitCompat keep rules (required by Flutter)
-keep class com.google.android.play.core.** { *; }
-keep class com.google.android.play.core.splitcompat.** { *; }
-keep class com.google.android.play.core.splitinstall.** { *; }

# Kotlin coroutines keep rules
-keep class kotlinx.coroutines.** { *; }

# Gson keep rules (used by various plugins)
-keep class com.google.gson.** { *; }