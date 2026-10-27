package com.minnnng.dsh_android

import android.content.Context
import android.os.SharedMemory
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.LinkOption
import java.security.MessageDigest
import java.util.UUID
import java.nio.ByteBuffer
import java.util.concurrent.CancellationException
import java.util.function.BooleanSupplier

/** Pinned system image and an independently persisted workspace, never a host directory mount. */
internal class LinuxVmImageStore(private val context: Context) {
    data class Image(val asset: String, val bytes: Int, val sha256: String)
    data class Images(val bios: Image, val kernel: Image, val disk: Image)

    private fun directory(sessionId: String): File {
        IsolatedScriptWire.requireSessionId(sessionId)
        return File(context.noBackupFilesDir, "linux-vm/${sha256(sessionId.toByteArray(Charsets.UTF_8))}")
    }

    /** No directory, lock file, journal or worker is created by observation. */
    fun inspect(sessionId: String, runId: String? = null): JSONObject {
        val root = directory(sessionId)
        runId?.let { require(UUID.fromString(it).toString() == it) { "Invalid Linux run ID" } }
        if (!Files.exists(root.toPath(), LinkOption.NOFOLLOW_LINKS)) return inspectionJson(sessionId,
            LinuxVmRecoveryStore.Snapshot("absent", false, false, runId?.let { false }, false, emptyList()))
        val store = recovery(root, sessionId)
        val owner = File(root, "owner.lock").toPath()
        // Shared observation lock excludes publication without granting any mutation authority.
        if (!Files.isRegularFile(owner, LinkOption.NOFOLLOW_LINKS)) return inspectionJson(sessionId,
            LinuxVmRecoveryStore.Snapshot("unknown", true, true, null, false, emptyList()))
        val snapshot = try {
            FileChannel.open(owner, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { channel ->
                val lock = try { channel.tryLock(0L, Long.MAX_VALUE, true) }
                catch (_: java.nio.channels.OverlappingFileLockException) { null }
                if (lock == null) store.observe(runId, true)
                else try { store.observe(runId, false) } finally { lock.release() }
            }
        } catch (_: IOException) {
            LinuxVmRecoveryStore.Snapshot("unknown", true, true, null, false, emptyList())
        }
        return inspectionJson(sessionId, snapshot)
    }

    private fun recovery(root: File, sessionId: String) = LinuxVmRecoveryStore(root.toPath(), sessionId,
        { path -> syncDirectory(path.toFile()) }, { payload ->
            try {
                val state = JSONObject(String(payload, Charsets.UTF_8))
                require(state.getInt("version") == 2 && state.getInt("workspaceBytes") == WORKSPACE_BYTES
                    && state.getString("baseImage").matches(Regex("[0-9a-f]{64}"))) { "Invalid Linux disk pointer" }
                val blockDirectory = File(root, "blocks")
                require(Files.isDirectory(blockDirectory.toPath(), LinkOption.NOFOLLOW_LINKS)) { "Linux blocks are absent" }
                val blocks = LinuxVmBlockStore(blockDirectory)
                blocks.validate(state.getInt("rootBytes"), decodeBlocks(state.getJSONObject("rootBlocks")))
                blocks.validate(WORKSPACE_BYTES, decodeBlocks(state.getJSONObject("workspaceBlocks")))
            } catch (failure: Exception) { throw IOException("Invalid Linux disk pointer payload", failure) }
        }, object : LinuxVmRecoveryStore.LegacyReader {
            override fun pointer(): ByteArray? {
                val file = File(root, "state.json")
                return if (Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)) readBounded(file, 1_048_576) else null
            }
            override fun records(): List<LinuxVmRecoveryStore.View> {
                val found = linkedMapOf<String, Pair<JSONObject?, JSONObject?>>()
                try {
                    Files.newDirectoryStream(root.toPath()).use { entries ->
                        var count = 0
                        for (path in entries) {
                            require(++count <= LinuxVmRecoveryStore.MAX_RECORDS * 3 + 32) { "Linux recovery scan limit" }
                            val name = path.fileName.toString()
                            if (!(name.startsWith("run-") || name.startsWith("export-")) || !name.endsWith(".json")) continue
                            val export = name.startsWith("export-")
                            val id = name.removePrefix(if (export) "export-" else "run-").removeSuffix(".json")
                            require(UUID.fromString(id).toString() == id) { "Invalid legacy Linux run ID" }
                            val record = JSONObject(String(readBounded(path.toFile(), 16_384), Charsets.UTF_8))
                            require(record.getInt("version") == 1 && record.getString("runId") == id) { "Invalid legacy Linux record" }
                            val prior = found[id] ?: (null to null)
                            found[id] = if (export) prior.first to record else record to prior.second
                            require(found.size <= LinuxVmRecoveryStore.MAX_RECORDS) { "Linux legacy record limit" }
                        }
                    }
                    return found.map { (id, pair) ->
                        val (run, export) = pair
                        // Old terminal labels did not authenticate worker retirement. Preserve only explicit facts.
                        LinuxVmRecoveryStore.View(id, if (export != null) "export" else "unknown", "unknown", null,
                            if (export != null) false else if (run?.optString("state") == "running") null else run?.opt("diskCommitted") as? Boolean,
                            if (export?.optString("state") == "prepared") null else export?.opt("filePublished") as? Boolean,
                            null, "legacy_unconfirmed", true, true)
                    }
                } catch (failure: Exception) { throw IOException("Invalid legacy Linux records", failure) }
            }
        })

    fun recordExport(sessionId: String, runId: String, state: String, fields: JSONObject) {
        IsolatedScriptWire.requireSessionId(sessionId)
        require(UUID.fromString(runId).toString() == runId)
        val directory = File(context.noBackupFilesDir, "linux-vm/${sha256(sessionId.toByteArray(Charsets.UTF_8))}")
        atomicJson(File(directory, "export-$runId.json"), JSONObject(fields.toString())
            .put("runId", runId).put("state", state).put("version", 1))
    }

    private fun image(value: JSONObject, name: String, maximum: Int): Image {
        require(value.getString("asset") == "linux-vm/$name") { "Invalid Linux image asset" }
        val length = value.getLong("bytes")
        require(length in 1..maximum.toLong()) { "Linux image exceeds its size limit" }
        val digest = value.getString("sha256")
        require(digest.matches(Regex("[0-9a-f]{64}"))) { "Invalid Linux image digest" }
        return Image(value.getString("asset"), length.toInt(), digest)
    }

    private fun images(): Images {
        val manifest = context.assets.open("linux-vm/manifest.json").bufferedReader().use { reader ->
            val text = reader.readText()
            require(text.length <= 4096) { "Linux image manifest exceeds limit" }
            JSONObject(text)
        }
        require(manifest.getInt("version") == 1 && manifest.getString("machine") == "riscv64") {
            "Unsupported Linux VM image version"
        }
        return Images(image(manifest.getJSONObject("bios"), "bios.bin", 2 * 1024 * 1024),
            image(manifest.getJSONObject("kernel"), "kernel.bin", 32 * 1024 * 1024),
            image(manifest.getJSONObject("disk"), "disk.bin", 256 * 1024 * 1024))
    }

    /** No caller-selected asset, host path, rootfs, or environment reaches the emulator. */
    fun open(sessionId: String, runId: String, operation: String = "execute"): Lease {
        IsolatedScriptWire.requireSessionId(sessionId)
        require(UUID.fromString(runId).toString() == runId) { "Invalid Linux VM run ID" }
        val images = images()
        val root = directory(sessionId)
        check(root.mkdirs() || root.isDirectory) { "Cannot create Linux VM disk store" }
        check(Files.isDirectory(root.toPath(), LinkOption.NOFOLLOW_LINKS)) { "Invalid Linux disk directory" }
        val channel = FileChannel.open(File(root, "owner.lock").toPath(),
            StandardOpenOption.CREATE, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)
        val lock = try { channel.tryLock() ?: error("Linux VM session is already in use") }
        catch (failure: Exception) { channel.close(); throw failure }
        val memory = ArrayList<SharedMemory>()
        try {
            // Persist newly created ancestor and lock directory entries before accepting a run.
            // A synced journal cannot survive power loss if its session directory disappears.
            channel.force(true)
            syncDirectory(context.noBackupFilesDir)
            syncDirectory(checkNotNull(root.parentFile))
            syncDirectory(root)
            val recovery = recovery(root, sessionId)
            recovery.admit(runId, operation)
            val bios = load(images.bios, null, false).also(memory::add)
            val kernel = load(images.kernel, null, false).also(memory::add)
            val existing = recovery.pointer()?.let { JSONObject(String(it.payload(), Charsets.UTF_8)) }
            val blockDirectory = File(root, "blocks")
            val blocks = LinuxVmBlockStore(blockDirectory)
            val disk = load(images.disk, null, true).also(memory::add)
            val diskMap = disk.mapReadWrite()
            val rootBaseline: Map<Int, String>
            try {
                rootBaseline = blocks.hashes(diskMap)
                // A system-image upgrade starts from its new seed. The data
                // volume below does not depend on that image's identity.
                if (existing?.getString("baseImage") == images.disk.sha256) {
                    require(existing.getInt("rootBytes") == images.disk.bytes) { "Linux system disk size differs" }
                    blocks.overlay(diskMap, decodeBlocks(existing.getJSONObject("rootBlocks")))
                }
            } finally { SharedMemory.unmap(diskMap) }
            val workspace = SharedMemory.create("dsh-linux-workspace", WORKSPACE_BYTES).also(memory::add)
            val workspaceMap = workspace.mapReadWrite()
            val zeroHash = blocks.hashes(ByteBuffer.allocate(LinuxVmBlockStore.BLOCK_BYTES)).getValue(0)
            val workspaceBaseline = (0 until WORKSPACE_BYTES / LinuxVmBlockStore.BLOCK_BYTES).associateWith { zeroHash }
            try {
                if (existing != null) blocks.overlay(workspaceMap, decodeBlocks(existing.getJSONObject("workspaceBlocks")))
            } finally { SharedMemory.unmap(workspaceMap) }
            return Lease(root, runId, images.disk, bios, kernel, disk, workspace, existing == null,
                blocks, blockDirectory, rootBaseline, workspaceBaseline, channel, lock, recovery, operation)
        } catch (failure: Exception) {
            memory.forEach { it.close() }
            lock.release()
            channel.close()
            throw failure
        }
    }

    private fun load(image: Image, file: File?, writable: Boolean): SharedMemory {
        val memory = SharedMemory.create("dsh-linux-image", image.bytes)
        try {
            val mapped = memory.mapReadWrite()
            val digest = MessageDigest.getInstance("SHA-256")
            try {
                (file?.inputStream() ?: context.assets.open(image.asset)).use { input ->
                    val buffer = ByteArray(65536)
                    var total = 0
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(count <= image.bytes - total) { "Linux image length differs" }
                        mapped.put(buffer, 0, count)
                        digest.update(buffer, 0, count)
                        total += count
                    }
                    require(total == image.bytes && hex(digest.digest()) == image.sha256) {
                        "Linux image integrity check failed"
                    }
                }
            } finally { SharedMemory.unmap(mapped) }
            if (!writable) check(memory.setProtect(OsConstants.PROT_READ)) { "Cannot seal Linux boot image" }
            return memory
        } catch (failure: Exception) { memory.close(); throw failure }
    }

    class Lease internal constructor(
        private val directory: File, private val runId: String, private val seed: Image,
        val bios: SharedMemory, val kernel: SharedMemory, val disk: SharedMemory,
        val workspace: SharedMemory, val workspaceFresh: Boolean,
        private val blocks: LinuxVmBlockStore, private val blockDirectory: File,
        private val rootBaseline: Map<Int, String>, private val workspaceBaseline: Map<Int, String>,
        private val channel: FileChannel, private val lock: FileLock,
        private val recovery: LinuxVmRecoveryStore, private val operation: String,
    ) : AutoCloseable {
        private var terminal = false
        private var retired = false

        fun markDispatched() { recovery.dispatched(runId) }
        fun markRetired(status: String, exitCode: Int?) {
            recovery.retired(runId, status, exitCode)
            retired = true
        }
        fun prepareExport() { recovery.prepareExport(runId) }
        fun settleExport(status: String, published: Boolean?) {
            check(retired) { "Linux worker retirement is unconfirmed" }
            terminal = true
            recovery.settle(runId, status, false, published)
        }

        /** Invoke only after the isolated worker has stopped touching every image mapping. */
        fun finish(status: String, commit: Boolean, cancelled: BooleanSupplier = BooleanSupplier { false },
            publish: ((() -> Unit) -> Boolean) = { action -> action(); true }): Boolean {
            check(!terminal) { "Linux disk lease already settled" }
            // A runner failure is not evidence that it never dispatched a command.
            if (!retired) return false
            var committed = false
            if (commit) {
                check(status == "completed") { "Only a completed guest may publish disk changes" }
                try {
                    val rootBlocks = capture(disk, rootBaseline, cancelled)
                    val workspaceBlocks = capture(workspace, workspaceBaseline, cancelled)
                    syncDirectory(blockDirectory)
                    committed = publish {
                        // A rename followed by fsync failure can leave the new
                        // pointer visible. close() must not label it rolled back.
                        terminal = true
                        recovery.publish(runId, JSONObject().put("version", 2)
                            .put("baseImage", seed.sha256).put("rootBytes", seed.bytes)
                            .put("workspaceBytes", WORKSPACE_BYTES)
                            .put("rootBlocks", encodeBlocks(rootBlocks)).put("workspaceBlocks", encodeBlocks(workspaceBlocks))
                            .toString().toByteArray(Charsets.UTF_8))
                    }
                } catch (failure: CancellationException) {
                    if (!cancelled.asBoolean) throw failure
                }
            }
            // Once the disk pointer has committed, a failed journal write is
            // an uncertain report. Never overwrite it as a rolled-back run.
            if (operation != "export") {
                terminal = true
                recovery.settle(runId, if (commit && !committed) "cancelled" else status, committed, null)
            }
            return committed
        }

        private fun capture(memory: SharedMemory, baseline: Map<Int, String>, cancelled: BooleanSupplier): Map<Int, String> {
            val mapped = memory.mapReadOnly()
            try { return blocks.capture(mapped, baseline, cancelled) }
            finally { SharedMemory.unmap(mapped) }
        }

        override fun close() {
            try {
                if (!terminal) recovery.abandonBeforeDispatch(runId)
            } finally {
                bios.close(); kernel.close(); disk.close(); workspace.close()
                lock.release(); channel.close()
            }
        }
    }

    companion object {
        const val WORKSPACE_BYTES = 128 * 1024 * 1024
        private fun readBounded(file: File, maximum: Int): ByteArray {
            require(Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS) && file.length() in 1..maximum.toLong()) {
                "Invalid Linux recovery file"
            }
            return Files.newInputStream(file.toPath(), LinkOption.NOFOLLOW_LINKS).use { stream ->
                val bytes = ByteArray(maximum + 1)
                var count = 0
                while (count < bytes.size) {
                    val n = stream.read(bytes, count, bytes.size - count)
                    if (n < 0) break
                    count += n
                }
                require(count in 1..maximum) { "Linux recovery file exceeds limit" }
                bytes.copyOf(count)
            }
        }
        private fun inspectionJson(sessionId: String, snapshot: LinuxVmRecoveryStore.Snapshot) =
            JSONObject(LinuxVmRecoveryStore.inspectionJson(sessionId, snapshot))
        private fun decodeBlocks(value: JSONObject): Map<Int, String> = value.keys().asSequence().associate { key ->
            val index = key.toIntOrNull()
            require(index != null && index >= 0 && index.toString() == key && value.opt(key) is String) {
                "Invalid Linux disk block map"
            }
            index to value.getString(key)
        }
        private fun encodeBlocks(value: Map<Int, String>) = JSONObject().apply {
            value.forEach { (index, hash) -> put(index.toString(), hash) }
        }
        private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
        private fun sha256(bytes: ByteArray) = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
        private fun atomicJson(file: File, value: JSONObject) {
            val temporary = File(file.parentFile, ".${file.name}-${UUID.randomUUID()}.pending")
            FileOutputStream(temporary).use { output ->
                output.write(value.toString().toByteArray(Charsets.UTF_8)); output.fd.sync()
            }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING)
            syncDirectory(checkNotNull(file.parentFile))
        }
        private fun syncDirectory(directory: File) {
            val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
            try {
                check(OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) { "Linux disk directory changed" }
                Os.fsync(fd)
            } finally { Os.close(fd) }
        }
    }
}
