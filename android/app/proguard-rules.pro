# NewPipe's extractor (YouTube Music's audio) runs YouTube's player JavaScript in Rhino,
# which finds classes by reflection: keep both whole.
-keep class org.schabi.newpipe.extractor.** { *; }
-keep class org.mozilla.javascript.** { *; }
-keep class org.mozilla.classfile.** { *; }
# Desktop Java parts Rhino can use and Android lacks.
-dontwarn java.beans.**
-dontwarn javax.script.**
-dontwarn jdk.dynalink.**
