package com.minnnng.dsh_android

import android.content.Context
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Path
import java.util.function.BooleanSupplier

/** App-side implementation of guest file bindings; guest receives only grant IDs and bounded values. */
class IsolatedCapabilityWorkspace(
    context: Context, workspaceRoot: File,
    private val publishGate: IsolatedWorkerWriteback.PublishGate = IsolatedWorkerWriteback.PublishGate(),
) : IsolatedCapabilityBroker.WorkspaceOps {
    private val app = context.applicationContext
    private val writer = IsolatedWorkerWriteback(
        File(app.applicationInfo.dataDir).toPath(), workspaceRoot.toPath(), ::syncDirectory,
    )

    override fun read(filename: String, cancelled: BooleanSupplier): IsolatedCapabilityBroker.ReadData {
        val snapshot = writer.snapshot(filename, cancelled)
        val text = IsolatedWorkerInput.readUtf8(ByteArrayInputStream(snapshot.content()))
        return IsolatedCapabilityBroker.ReadData(snapshot.sha256(), text)
    }

    override fun search(
        filename: String, query: String, maxMatches: Int, cancelled: BooleanSupplier,
    ): IsolatedCapabilityBroker.SearchData {
        val snapshot = writer.snapshot(filename, cancelled)
        val text = IsolatedWorkerInput.readUtf8(ByteArrayInputStream(snapshot.content()))
        val result = IsolatedWorkerTextSearch.search(text, IsolatedWorkerTextSearch.Spec(query, maxMatches))
        if (cancelled.asBoolean) throw IOException("Capability search cancelled")
        return IsolatedCapabilityBroker.SearchData(
            snapshot.sha256(), result.hits().map { IsolatedCapabilityBroker.Hit(it.line(), it.column(), it.preview()) },
            result.truncated(),
        )
    }

    override fun edit(
        filename: String, expectedRevision: String, needle: String, replacement: String,
        maxReplacements: Int, cancelled: BooleanSupplier,
    ): IsolatedCapabilityBroker.EditData {
        val snapshot = writer.snapshot(filename, cancelled)
        if (snapshot.sha256() != expectedRevision) throw IsolatedCapabilityBroker.StaleRevision()
        val text = IsolatedWorkerInput.readUtf8(ByteArrayInputStream(snapshot.content()))
        val next = IsolatedWorkerTextEdit.replace(
            text, IsolatedWorkerTextEdit.Spec(needle, replacement, maxReplacements),
        ).toByteArray(StandardCharsets.UTF_8)
        if (cancelled.asBoolean) throw IOException("Capability edit cancelled")
        val receipt = try { writer.commit(filename, expectedRevision, next, cancelled, publishGate) }
        catch (stale: IsolatedCapabilityBroker.StaleRevision) { throw stale }
        catch (uncertain: IsolatedWorkerWriteback.CommitUncertain) { throw uncertain }
        // An IOException can also come from closing a target after the rename. A
        // changed revision cannot prove whether this call or another writer moved it.
        catch (failure: IOException) { throw IsolatedCapabilityBroker.CommitOutcomeUnknown(failure) }
        return IsolatedCapabilityBroker.EditData(receipt.previousSha256(), receipt.sha256(), receipt.bytes())
    }

    override fun write(
        filename: String, expectedRevision: String, text: String, cancelled: BooleanSupplier,
    ): IsolatedCapabilityBroker.EditData {
        val content = text.toByteArray(StandardCharsets.UTF_8)
        require(content.size <= IsolatedWorkerInput.MAX_TEXT_BYTES)
        val receipt = try { writer.commit(filename, expectedRevision, content, cancelled, publishGate) }
        catch (stale: IsolatedCapabilityBroker.StaleRevision) { throw stale }
        catch (uncertain: IsolatedWorkerWriteback.CommitUncertain) { throw uncertain }
        catch (failure: IOException) { throw IsolatedCapabilityBroker.CommitOutcomeUnknown(failure) }
        return IsolatedCapabilityBroker.EditData(receipt.previousSha256(), receipt.sha256(), receipt.bytes())
    }

    companion object {
        /** Journal is App-private and its first create is followed by directory fsync. */
        fun journal(context: Context): IsolatedCapabilityJournal = IsolatedCapabilityJournal(
            context.applicationContext.filesDir.toPath(), ::syncDirectory,
        )

        private fun syncDirectory(directory: Path) {
            try {
                val descriptor = Os.open(directory.toString(), OsConstants.O_RDONLY, 0)
                try {
                    check(OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)) { "Capability sync target is not a directory" }
                    Os.fsync(descriptor)
                } finally { Os.close(descriptor) }
            } catch (failure: Exception) { throw IOException("Could not sync capability directory", failure) }
        }
    }
}
