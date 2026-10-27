package com.minnnng.dsh_android

import android.content.Context
import android.system.Os
import android.system.OsConstants
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.UUID

/** Exercises publication on the device filesystem using only uniquely owned test files. */
internal object LinuxVmFilePublisherAcceptance {
    fun run(target: Context, results: JSONArray) {
        val prefix = "publisher-acceptance-${UUID.randomUUID()}"
        val workspace = File(target.noBackupFilesDir.canonicalFile, "dsh/workspace")
        check(workspace.isDirectory) { "Production workspace must already exist" }
        val owned = File(workspace, prefix)
        check(owned.mkdir())
        val staging = LinuxVmFilePublisher.stagingDirectory(target)
        check(staging.mkdirs() || Files.isDirectory(staging.toPath(), LinkOption.NOFOLLOW_LINKS))
        val staged = mutableListOf<File>()
        fun stage(label: String, bytes: ByteArray = "private-export".toByteArray()): File {
            val source = File(staging, "$prefix-$label")
            check(source.createNewFile())
            staged.add(source)
            FileOutputStream(source).use { stream -> stream.write(bytes); stream.fd.sync() }
            return source
        }
        fun record(name: String, fields: JSONObject = JSONObject()) {
            results.put(fields.put("case", name).put("passed", true))
        }
        fun rejected(source: File, destination: String) {
            try {
                val outcome = LinuxVmFilePublisher.publish(target, source, destination)
                check(outcome.published == false && !outcome.directorySynced && outcome.errno != 0) {
                    "Expected an unpublished result: $outcome"
                }
            } catch (error: IllegalArgumentException) {
                // Kotlin validation rejects invalid paths and non-regular staging sources before JNI.
                check(error.message != null)
            }
            check(Files.exists(source.toPath(), LinkOption.NOFOLLOW_LINKS)) { "Rejected source disappeared" }
        }
        try {
            val bytes = byteArrayOf(0, 1, 2, 127, -128, -1)
            val unicode = stage("源-📦.bin", bytes)
            val destination = "$prefix/导出/📦.bin"
            val published = LinuxVmFilePublisher.publish(target, unicode, destination)
            check(published.published == true && published.directorySynced && published.errno == 0)
            check(!unicode.exists() && File(workspace, destination).readBytes().contentEquals(bytes))
            record("non_bmp_source_and_destination")

            val duplicate = stage("duplicate.bin")
            val original = duplicate.readBytes()
            val conflict = LinuxVmFilePublisher.publish(target, duplicate, destination)
            check(conflict.published == false && !conflict.directorySynced && conflict.errno == OsConstants.EEXIST)
            check(duplicate.readBytes().contentEquals(original) && File(workspace, destination).readBytes().contentEquals(bytes))
            record("existing_destination_preserves_both_files")

            val escaped = File(owned, "symlink-target")
            check(escaped.mkdir())
            val parentLink = File(owned, "parent-link")
            Os.symlink(escaped.path, parentLink.path)
            val throughLink = stage("parent-link.bin")
            rejected(throughLink, "$prefix/parent-link/escaped.bin")
            check(!File(escaped, "escaped.bin").exists())
            record("destination_parent_symlink_rejected")

            val blockedParent = File(owned, "ordinary-parent")
            blockedParent.writeText("ordinary-file")
            rejected(stage("ordinary-parent.bin"), "$prefix/ordinary-parent/child.bin")
            check(blockedParent.readText() == "ordinary-file")
            record("destination_parent_file_rejected")

            val fifo = File(staging, "$prefix-source.fifo")
            Os.mkfifo(fifo.path, 384)
            staged.add(fifo)
            rejected(fifo, "$prefix/fifo.bin")
            check(!File(owned, "fifo.bin").exists())
            record("source_fifo_rejected")

            val external = File(owned, "outside-staging.bin")
            external.writeText("outside-staging")
            rejected(external, "$prefix/external.bin")
            check(external.readText() == "outside-staging" && !File(owned, "external.bin").exists())
            record("source_outside_staging_rejected")

            val sourceLink = File(staging, "$prefix-source-link")
            Os.symlink(external.path, sourceLink.path)
            staged.add(sourceLink)
            rejected(sourceLink, "$prefix/source-link.bin")
            check(external.readText() == "outside-staging" && !File(owned, "source-link.bin").exists())
            record("source_symlink_rejected")

            val invalid = stage("invalid-path.bin")
            for (path in listOf("/absolute", "../outside", "$prefix/../outside", "$prefix//empty",
                "$prefix/./dot", "$prefix/back\\slash", "$prefix/colon:name", "$prefix/control\u0001",
                "$prefix/\uD800", "a".repeat(4097))) {
                rejected(invalid, path)
            }
            record("invalid_destination_paths_rejected")

            // Warm both JNI and directory enumeration before measuring failed-call descriptor retention.
            rejected(duplicate, destination)
            val before = descriptorCount()
            repeat(100) {
                val outcome = LinuxVmFilePublisher.publish(target, duplicate, destination)
                check(outcome.published == false && outcome.errno == OsConstants.EEXIST)
            }
            val after = descriptorCount()
            check(after <= before) { "Failed publication leaked descriptors: $before -> $after" }
            check(duplicate.readBytes().contentEquals(original) && File(workspace, destination).readBytes().contentEquals(bytes))
            record("repeated_conflicts_close_descriptors", JSONObject().put("attempts", 100)
                .put("descriptorsBefore", before).put("descriptorsAfter", after))
        } finally {
            for (source in staged) Files.deleteIfExists(source.toPath())
            deleteOwnedTree(owned)
        }
    }

    private fun descriptorCount(): Int = checkNotNull(File("/proc/self/fd").list()).size

    /** Does not follow symlinks, including the deliberately created escape-link fixture. */
    private fun deleteOwnedTree(file: File) {
        if (Files.isDirectory(file.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            for (child in checkNotNull(file.listFiles())) deleteOwnedTree(child)
        }
        Files.deleteIfExists(file.toPath())
    }
}
