package com.minnnng.dsh_android

/** One Node instance is owned by the dedicated AgentService process. */
object NativeRuntime {
    init { System.loadLibrary("dsh_runtime") }
    external fun socketPair(): IntArray
    external fun start(runtime: String, home: String, cache: String, libraries: String, descriptor: Int): Int
}
