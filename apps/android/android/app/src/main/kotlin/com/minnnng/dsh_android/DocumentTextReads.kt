package com.minnnng.dsh_android

import android.os.CancellationSignal
import org.json.JSONObject
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Prepared text reads retain their slot until both the reader and provider cleanup have stopped. */
internal class DocumentTextReads(
    private val readPage: (JSONObject, CancellationSignal, DocumentSearchJob) -> JSONObject,
) : Closeable {
    private class Job(val root: String) {
        val signal = CancellationSignal()
        val lifecycle = DocumentSearchJob { signal.cancel() }
        @Volatile var cancelled = false
        @Volatile var expired = false
        val cleanup = ArrayList<java.util.concurrent.Future<*>>()
        var deadline: java.util.concurrent.ScheduledFuture<*>? = null
    }
    private val jobs = HashMap<String, Job>()
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private val closers = Executors.newCachedThreadPool()
    private var closed = false

    @Synchronized fun prepare(params: JSONObject): JSONObject {
        check(!closed) { "文件读取服务已关闭，请重新连接" }
        val id = params.getString("id")
        require(UUID.fromString(id).toString() == id) { "无效的文件读取请求" }
        val root = params.getString("root")
        require(root.matches(Regex("[0-9a-f]{64}"))) { "无效的文件授权" }
        val timeout = params.getLong("timeoutMs")
        require(timeout in 100L..300000L) { "文件读取时限无效" }
        check(!jobs.containsKey(id) && jobs.size < 4) { "文件请求过多，请等待已有请求停止" }
        val job = Job(root)
        jobs[id] = job
        try { job.deadline = timer.schedule({ job.expired = true; requestCancel(job) }, timeout, TimeUnit.MILLISECONDS) }
        catch (failure: Throwable) { jobs.remove(id); throw failure }
        return JSONObject().put("prepared", true)
    }

    fun run(params: JSONObject): JSONObject {
        val job = synchronized(this) { jobs[params.getString("id")] }
            ?: error("文件读取请求不存在，请重新打开文件")
        check(job.root == params.getString("root")) { "文件读取请求不属于此授权" }
        if (!job.lifecycle.start()) throw CancellationException("文件读取已取消或超时")
        try {
            val result = readPage(params, job.signal, job.lifecycle)
            job.lifecycle.check()
            return result
        } catch (failure: Exception) {
            if (job.cancelled && failure !is SecurityException) throw java.io.IOException(
                if (job.expired) "文件读取超过时限，请重试或选择较小的文件"
                else "文件读取已取消，请重新打开文件后重试", failure)
            throw failure
        } finally {
            job.deadline?.cancel(false)
            job.lifecycle.finish()
        }
    }

    private fun requestCancel(job: Job) = synchronized(job) {
        job.cancelled = true
        job.deadline?.cancel(false)
        job.lifecycle.requestCancel(Executor { action -> job.cleanup.add(closers.submit(action)) })
    }

    private fun retire(id: String, job: Job, deadline: Long): Boolean {
        requestCancel(job)
        val remaining = { TimeUnit.NANOSECONDS.toMillis((deadline - System.nanoTime()).coerceAtLeast(0)) }
        if (!job.lifecycle.awaitStopped(remaining())) return false
        val tasks = synchronized(job) { job.cleanup.toList() }
        for (task in tasks) {
            try { task.get(remaining(), TimeUnit.MILLISECONDS) }
            catch (_: java.util.concurrent.TimeoutException) { return false }
        }
        synchronized(this) { jobs.remove(id, job) }
        return true
    }

    fun cancel(id: String): JSONObject {
        val job = synchronized(this) { jobs[id] }
        val stopped = job == null || retire(id, job, System.nanoTime() + TimeUnit.SECONDS.toNanos(5))
        return JSONObject().put("cancelled", stopped).put("stopping", !stopped)
    }

    fun revokeRoot(root: String): Boolean = retireAll(root)

    private fun retireAll(root: String?): Boolean {
        val selected = synchronized(this) { jobs.filterValues { root == null || it.root == root }.toList() }
        selected.forEach { requestCancel(it.second) }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        var stopped = true
        selected.forEach { (id, job) -> if (!retire(id, job, deadline)) stopped = false }
        return stopped
    }

    override fun close() {
        synchronized(this) { closed = true }
        timer.shutdownNow()
        val stopped = retireAll(null)
        closers.shutdown()
        check(stopped && timer.awaitTermination(5, TimeUnit.SECONDS) && closers.awaitTermination(5, TimeUnit.SECONDS)) {
            "文件提供方尚未停止读取，请重新连接后确认状态"
        }
    }
}
