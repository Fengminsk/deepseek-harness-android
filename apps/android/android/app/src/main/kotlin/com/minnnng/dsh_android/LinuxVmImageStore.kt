package com.minnnng.dsh_android

import android.content.Context
import android.os.SharedMemory
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.UUID
import java.nio.ByteBuffer
import java.util.concurrent.CancellationException
import java.util.function.BooleanSupplier

/** Pinned system image and an independently persisted workspace, never a host directory mount. */
internal class LinuxVmImageStore(private val context: Context) {
    data class Image(val asset: String, val bytes: Int, val sha256: String)
    data class Images(val bios: Image, val kernel: Image, val disk: Image)

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
    fun open(sessionId: String, runId: String): Lease {
        IsolatedScriptWire.requireSessionId(sessionId)
        require(UUID.fromString(runId).toString() == runId) { "Invalid Linux VM run ID" }
        val images = images()
        val key = sha256(sessionId.toByteArray(Charsets.UTF_8))
        val root = File(context.noBackupFilesDir, "linux-vm/$key")
        check(root.mkdirs() || root.isDirectory) { "Cannot create Linux VM disk store" }
        val channel = FileChannel.open(File(root, "owner.lock").toPath(),
            StandardOpenOption.CREATE, StandardOpenOption.WRITE)
        val lock = try { channel.tryLock() ?: error("Linux VM session is already in use") }
        catch (failure: Exception) { channel.close(); throw failure }
        val memory = ArrayList<SharedMemory>()
        try {
            val bios = load(images.bios, null, false).also(memory::add)
            val kernel = load(images.kernel, null, false).also(memory::add)
            val metadataFile = File(root, "state.json")
            val existing = if (metadataFile.exists()) {
                require(metadataFile.length() in 1..1_048_576) { "Linux VM state exceeds its limit" }
                JSONObject(metadataFile.readText()).also { state ->
                    require(state.getInt("version") == 2 && state.getInt("workspaceBytes") == WORKSPACE_BYTES
                        && state.getString("baseImage").matches(Regex("[0-9a-f]{64}"))) { "Linux VM state differs" }
                }
            } else null
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
            // An interrupted invocation owns only a memory copy. Its former
            // journal remains visible; the previous committed disk is reused.
            atomicJson(File(root, "run-$runId.json"), JSONObject().put("version", 1)
                .put("runId", runId).put("state", "running").put("diskCommitted", false))
            return Lease(root, runId, images.disk, bios, kernel, disk, workspace, existing == null,
                blocks, blockDirectory, rootBaseline, workspaceBaseline, channel, lock)
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
    ) : AutoCloseable {
        private var terminal = false

        /** Invoke only after the isolated worker has stopped touching every image mapping. */
        fun finish(status: String, commit: Boolean, cancelled: BooleanSupplier = BooleanSupplier { false },
            publish: ((() -> Unit) -> Boolean) = { action -> action(); true }): Boolean {
            check(!terminal) { "Linux disk lease already settled" }
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
                        atomicJson(File(directory, "state.json"), JSONObject().put("version", 2)
                            .put("baseImage", seed.sha256).put("rootBytes", seed.bytes)
                            .put("workspaceBytes", WORKSPACE_BYTES)
                            .put("rootBlocks", encodeBlocks(rootBlocks)).put("workspaceBlocks", encodeBlocks(workspaceBlocks)))
                    }
                } catch (failure: CancellationException) {
                    if (!cancelled.asBoolean) throw failure
                }
            }
            // Once the disk pointer has committed, a failed journal write is
            // an uncertain report. Never overwrite it as a rolled-back run.
            terminal = true
            atomicJson(File(directory, "run-$runId.json"), JSONObject().put("version", 1)
                .put("runId", runId).put("state", if (commit && !committed) "cancelled" else status)
                .put("diskCommitted", committed))
            return committed
        }

        private fun capture(memory: SharedMemory, baseline: Map<Int, String>, cancelled: BooleanSupplier): Map<Int, String> {
            val mapped = memory.mapReadOnly()
            try { return blocks.capture(mapped, baseline, cancelled) }
            finally { SharedMemory.unmap(mapped) }
        }

        override fun close() {
            try {
                if (!terminal) finish("interrupted", false)
            } finally {
                bios.close(); kernel.close(); disk.close(); workspace.close()
                lock.release(); channel.close()
            }
        }
    }

    companion object {
        const val WORKSPACE_BYTES = 128 * 1024 * 1024
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
