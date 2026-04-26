# ─── flutter_local_notifications ─────────────────────────────────────────────
# إبقاء كل كلاسات الإشعارات — هذا يحل خطأ:
# "Missing type parameter at l2.a.<init>"
# الذي يظهر عند loadScheduledNotifications / cancelAllNotifications
-keep class com.dexterous.** { *; }
-keepclassmembers class com.dexterous.** { *; }

# ─── Generic type parameters (الإصلاح الجوهري) ───────────────────────────────
# R8 يحذف معاملات النوع العام (generic type parameters) من الـ bytecode
# عند التصغير. هذه القواعد تجبره على الإبقاء عليها.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# ─── Gson (تُستخدم داخلياً بواسطة flutter_local_notifications) ───────────────
-keep class com.google.gson.** { *; }
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# ─── WorkManager ─────────────────────────────────────────────────────────────
-keep class androidx.work.** { *; }
-keepclassmembers class * extends androidx.work.Worker { *; }
-keepclassmembers class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}

# ─── Flutter & Dart ───────────────────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# ─── OneSignal ────────────────────────────────────────────────────────────────
-keep class com.onesignal.** { *; }

# ─── Google Play Core (مطلوب بواسطة Flutter deferred components) ─────────────
# هذه الكلاسات يُشير إليها Flutter engine لكنها غير مُضمَّنة في APK عادي
# (تُستخدم فقط مع Play Store dynamic delivery)
# الحل: تجاهلها بدلاً من إيقاف التصغير كله
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
-dontwarn com.google.android.play.core.**
