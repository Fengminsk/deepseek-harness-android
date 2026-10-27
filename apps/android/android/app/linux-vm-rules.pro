# Native callbacks resolve these names with JNI inside the isolated process.
-keep class com.minnnng.dsh_android.LinuxVmConsole {
    synchronized int read(byte[], int);
    synchronized void write(byte[]);
}
-keepclasseswithmembernames,includedescriptorclasses class com.minnnng.dsh_android.LinuxVmEngine {
    native <methods>;
}
-keepclasseswithmembernames,includedescriptorclasses class com.minnnng.dsh_android.LinuxVmFilePublisher {
    native <methods>;
}
