package com.minnnng.dsh_android

/** One Node instance is owned by the dedicated AgentService process. */
object NativeRuntime {
    init { System.loadLibrary("dsh_runtime") }
    external fun socketPair(): IntArray
    fun start(runtime: String, home: String, cache: String, libraries: String, descriptor: Int): Int =
        startNode(runtime, home, cache, libraries, descriptor, BuildConfig.LINUX_VM_ENABLED)

    private external fun startNode(runtime: String, home: String, cache: String, libraries: String,
        descriptor: Int, linuxVmEnabled: Boolean): Int
}
