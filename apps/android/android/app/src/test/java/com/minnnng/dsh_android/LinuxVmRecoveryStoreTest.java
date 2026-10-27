package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

/** Real files/atomic moves and child-process death; Android directory fsync still needs device evidence. */
public final class LinuxVmRecoveryStoreTest {
    private static final String SESSION = "linux-recovery-fixture";
    private static final byte[] PAYLOAD = "disk-v1:verified".getBytes(java.nio.charset.StandardCharsets.UTF_8);
    private static final List<String> CASES = new ArrayList<>();
    private static final Map<String, String> CONTRACT = new LinkedHashMap<>();
    private static Path root;
    private interface Checked { void run() throws Exception; }
    private static final LinuxVmRecoveryStore.LegacyReader EMPTY = new LinuxVmRecoveryStore.LegacyReader() {
        public byte[] pointer() { return null; }
        public List<LinuxVmRecoveryStore.View> records() { return List.of(); }
    };
    public static void main(String[] args) throws Exception {
        if (args.length == 3) { child(args[0], Path.of(args[1]), args[2]); return; }
        Path cache = Path.of(".cache/android/linux-vm-recovery-tests").toAbsolutePath();
        Files.createDirectories(cache); root = Files.createTempDirectory(cache, "run-");
        test("admitted_without_dispatch_is_reviewable_but_never_replayed", () -> {
            Path dir = dir("admitted"); var store = store(dir); String id = id(); store.admit(id, "execute");
            var snap = store(dir).observe(id, false); var v = only(snap);
            check(v.state().equals("interrupted") && Boolean.TRUE.equals(v.retirementConfirmed()) && Boolean.FALSE.equals(v.diskCommitted()), "unstarted facts");
            check(snap.needsReview(), "admission loss must remain visible"); blocked(() -> store(dir).admit(id(), "execute"));
            var before = contents(dir); store(dir).observe(id, false); check(before.equals(contents(dir)), "inspection must be read-only");
        });
        test("dispatched_survives_owner_lock_release_as_unknown", () -> {
            Path dir = dir("dispatched"); String id = id(); var store = store(dir);
            try (var channel = FileChannel.open(dir.resolve("owner.lock"), StandardOpenOption.CREATE, StandardOpenOption.WRITE); var lock = channel.lock()) {
                store.admit(id, "execute"); store.dispatched(id);
            }
            var snap = store(dir).observe(id, false); var v = only(snap);
            check(snap.blocked() && v.retirementConfirmed() == null && v.diskCommitted() == null, "lock release is not retirement");
            store(dir).abandonBeforeDispatch(id); check(only(store(dir).observe(id, false)).retirementConfirmed() == null, "cleanup must not erase dispatch");
            blocked(() -> store(dir).admit(id(), "execute")); contract("dispatched_unknown", snap);
        });
        test("dispatch_move_before_sync_failure_is_not_unstarted", () -> {
            Path dir = dir("dispatch-sync"); String id = id(); store(dir).admit(id, "execute");
            fails(() -> faulty(dir, "run_1_after_move").dispatched(id));
            check(only(store(dir).observe(id, false)).retirementConfirmed() == null, "post-move dispatch stays unknown");
        });
        test("retirement_move_before_sync_failure_preserves_known_retirement", () -> {
            Path dir = dir("retire-sync"); String id = dispatched(dir, "execute");
            fails(() -> faulty(dir, "run_2_after_move").retired(id, "completed", 0));
            var v = only(store(dir).observe(id, false)); check(Boolean.TRUE.equals(v.retirementConfirmed()) && Boolean.FALSE.equals(v.diskCommitted()), "retired facts survive thrown sync");
        });
        test("retired_before_pointer_requires_review_and_blocks_successor", () -> {
            Path dir = dir("retired"); String id = retired(dir, "execute");
            var snap = store(dir).observe(id, false); check(snap.needsReview() && !snap.blocked() && Boolean.FALSE.equals(only(snap).diskCommitted()), "known interruption");
            blocked(() -> store(dir).admit(id(), "execute"));
        });
        test("pointer_failure_before_move_has_no_commit", () -> {
            Path dir = dir("pointer-before"); String id = retired(dir, "execute");
            fails(() -> faulty(dir, "pointer_before_move").publish(id, PAYLOAD));
            check(Boolean.FALSE.equals(only(store(dir).observe(id, false)).diskCommitted()), "old pointer retained");
        });
        test("pointer_move_before_sync_failure_is_committed", () -> {
            Path dir = dir("pointer-after"); String id = retired(dir, "execute");
            fails(() -> faulty(dir, "pointer_after_move").publish(id, PAYLOAD));
            var snap = store(dir).observe(id, false); var v = only(snap);
            check(v.state().equals("recovered_committed") && Boolean.TRUE.equals(v.diskCommitted()) && snap.needsReview(), "must recover commit");
            blocked(() -> store(dir).admit(id(), "execute")); fails(() -> store(dir).settle(id, "failed", false, null)); contract("recovered_commit", snap);
        });
        test("terminal_failure_does_not_erase_committed_pointer", () -> {
            Path dir = dir("terminal-before"); String id = retired(dir, "execute"); store(dir).publish(id, PAYLOAD);
            fails(() -> faulty(dir, "run_3_before_move").settle(id, "completed", true, null));
            check(Boolean.TRUE.equals(only(store(dir).observe(id, false)).diskCommitted()), "commit survives terminal failure");
        });
        test("completed_run_attribution_survives_successor_commit", () -> {
            Path dir = dir("successor"); String first = retired(dir, "execute"); store(dir).publish(first, PAYLOAD); store(dir).settle(first, "completed", true, null);
            String second = retired(dir, "execute"); store(dir).publish(second, PAYLOAD); store(dir).settle(second, "completed", true, null);
            var snap = store(dir).observe(first, false); check(Boolean.TRUE.equals(only(snap).diskCommitted()) && !snap.needsReview(), "first commit retained after second");
            contract("ready_terminal", snap);
        });
        test("completed_without_persistence_is_known_false", () -> {
            Path dir = dir("no-persist"); String id = retired(dir, "execute"); store(dir).settle(id, "completed", false, null);
            check(Boolean.FALSE.equals(only(store(dir).observe(id, false)).diskCommitted()), "nonpersistent terminal");
        });
        test("prepared_export_does_not_infer_publication_from_matching_file", () -> {
            Path dir = dir("export-unknown"); String id = retired(dir, "export"); Files.write(dir.resolve("same-content.txt"), PAYLOAD);
            store(dir).prepareExport(id); var v = only(store(dir).observe(id, false));
            check(v.filePublished() == null && Boolean.FALSE.equals(v.diskCommitted()) && v.needsReview(), "preexisting bytes cannot attribute publication");
            blocked(() -> store(dir).admit(id(), "execute"));
        });
        test("export_terminal_preserves_file_effect_separate_from_disk", () -> {
            Path dir = dir("export-known"); String id = retired(dir, "export"); store(dir).prepareExport(id);
            Files.write(dir.resolve("export-target"), PAYLOAD); store(dir).settle(id, "completed", false, true);
            var v = only(store(dir).observe(id, false)); check(Boolean.TRUE.equals(v.filePublished()) && Boolean.FALSE.equals(v.diskCommitted()), "export facts");
        });
        test("export_never_gets_disk_publication_authority", () -> {
            Path dir = dir("export-no-disk"); String id = retired(dir, "export"); fails(() -> store(dir).publish(id, PAYLOAD));
            fails(() -> store(dir).settle(id, "completed", true, true));
        });
        test("corrupt_run_never_claims_requested_id_found", () -> {
            Path dir = dir("corrupt-run"); String id = dispatched(dir, "execute"); Files.write(dir.resolve("runs-v2").resolve(id + ".bin"), new byte[]{1, 2, 3});
            var snap = store(dir).observe(id, false); check(snap.status().equals("unknown") && snap.requestedRunFound() == null, "unknown existence");
            check(only(snap).diskCommitted() == null && only(snap).retirementConfirmed() == null, "no synthetic facts"); contract("corrupt_query", snap);
        });
        test("corrupt_new_pointer_never_falls_back_to_legacy", () -> {
            Path dir = dir("corrupt-pointer"); String id = retired(dir, "execute"); store(dir).publish(id, PAYLOAD);
            byte[] pointer = Files.readAllBytes(dir.resolve("state-v3.bin")); pointer[pointer.length - 1] ^= 1; Files.write(dir.resolve("state-v3.bin"), pointer);
            check(store(dir).observe(id, false).status().equals("unknown"), "checksum corruption blocked"); blocked(() -> store(dir).admit(id(), "execute"));
        });
        test("session_identity_mismatch_blocks_all_records", () -> {
            Path dir = dir("wrong-session"); String id = dispatched(dir, "execute");
            var other = new LinuxVmRecoveryStore(dir, "other-session", path -> {}, payload -> {}, EMPTY);
            check(other.observe(id, false).status().equals("unknown"), "session pinned"); blocked(() -> other.admit(id(), "execute"));
        });
        test("unknown_uuid_is_absent_only_after_complete_scan", () -> {
            Path dir = dir("missing-id"); var snap = store(dir).observe(id(), false);
            check(snap.status().equals("absent") && Boolean.FALSE.equals(snap.requestedRunFound()) && snap.records().isEmpty(), "complete empty scan");
        });
        test("legacy_unknown_is_not_rewritten_or_retired", () -> {
            Path dir = dir("legacy"); String id = id(); Path old = dir.resolve("run-" + id + ".json"); Files.writeString(old, "{\"version\":1,\"state\":\"running\",\"diskCommitted\":false}");
            var legacy = new LinuxVmRecoveryStore.LegacyReader() {
                public byte[] pointer() { return null; }
                public List<LinuxVmRecoveryStore.View> records() throws IOException {
                    check(Files.readString(old).contains("running"), "legacy bytes retained");
                    return List.of(new LinuxVmRecoveryStore.View(id, "unknown", "unknown", null, null, null, null, "legacy_unconfirmed", true, true));
                }
            };
            var store = new LinuxVmRecoveryStore(dir, SESSION, path -> {}, payload -> {}, legacy); var before = contents(dir);
            check(store.observe(id, false).blocked(), "legacy unknown blocks"); blocked(() -> store.admit(id(), "execute")); check(before.equals(contents(dir)), "legacy not rewritten");
        });
        test("scan_is_bounded_and_never_silently_truncates_admission_check", () -> {
            Path dir = dir("scan-limit"); Files.createDirectory(dir.resolve("runs-v2"));
            for (int i = 0; i <= LinuxVmRecoveryStore.MAX_RECORDS; i++) Files.write(dir.resolve("runs-v2/." + i + ".pending"), new byte[0]);
            check(store(dir).observe(null, false).blocked(), "full scan incomplete blocks"); blocked(() -> store(dir).admit(id(), "execute"));
        });
        test("display_limit_does_not_hide_old_blocking_record", () -> {
            Path dir = dir("bounded-display");
            for (int i = 0; i < 33; i++) { String id = retired(dir, "execute"); store(dir).settle(id, "completed", false, null); }
            String blocked = dispatched(dir, "execute"); var snap = store(dir).observe(null, false);
            check(snap.truncated() && snap.records().size() == 32 && snap.blocked() && snap.records().get(0).runId().equals(blocked), "review records prioritized");
        });
        test("real_child_process_death_after_dispatch_has_no_safe_retry", () -> {
            Path dir = dir("death-dispatch"); String id = id(); die("dispatch", dir, id);
            check(only(store(dir).observe(id, false)).retirementConfirmed() == null, "dead host is not proof of dead worker"); blocked(() -> store(dir).admit(id(), "execute"));
        });
        test("real_child_process_death_after_pointer_move_recovers_commit", () -> {
            Path dir = dir("death-pointer"); String id = id(); die("pointer", dir, id);
            check(Boolean.TRUE.equals(only(store(dir).observe(id, false)).diskCommitted()), "actual process death commit recovered");
        });
        test("pointer_payload_validator_blocks_invalid_disk", () -> {
            Path dir = dir("payload-invalid"); String id = retired(dir, "execute"); fails(() -> store(dir).publish(id, new byte[]{9}));
            check(Boolean.FALSE.equals(only(store(dir).observe(id, false)).diskCommitted()), "invalid payload not published");
        });
        test("block_recovery_validation_checks_real_files_without_overlay", () -> {
            Path dir = dir("block-validation"); var blocks = new LinuxVmBlockStore(dir.toFile()); ByteBuffer disk = ByteBuffer.allocate(65_536);
            var base = blocks.hashes(disk); disk.put(3, (byte) 7); var manifest = blocks.capture(disk, base); blocks.validate(65_536, manifest);
            Path file = dir.resolve("block-" + manifest.get(0) + ".bin"); Files.write(file, new byte[65_536]); fails(() -> blocks.validate(65_536, manifest));
        });
        StringBuilder contract = new StringBuilder("{"); boolean first = true;
        for (var entry : CONTRACT.entrySet()) { if (!first) contract.append(','); first = false; contract.append('"').append(entry.getKey()).append("\":").append(entry.getValue()); }
        contract.append('}'); Files.writeString(Path.of(".cache/android/linux-recovery-native-contract.json"), contract);
        Files.writeString(root.resolve("report.json"), "{\"passed\":" + CASES.size() + ",\"deviceEvidence\":false,\"directoryFsync\":\"not exercised on Windows host\",\"cases\":[\"" + String.join("\",\"", CASES) + "\"]}");
        System.out.println("Linux recovery: " + CASES.size() + "/" + CASES.size() + " PASS; evidence=" + root);
    }
    private static void child(String mode, Path dir, String id) throws Exception {
        var store = store(dir); store.admit(id, "execute");
        if (mode.equals("dispatch")) { halting(dir, "run_1_after_move").dispatched(id); }
        else { store.dispatched(id); store.retired(id, "completed", 0); halting(dir, "pointer_after_move").publish(id, PAYLOAD); }
        throw new AssertionError("Child failed to terminate at boundary");
    }
    private static void die(String mode, Path dir, String id) throws Exception {
        Path java = Path.of(System.getProperty("java.home"), "bin", System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java");
        Process child = new ProcessBuilder(java.toString(), "-cp", System.getProperty("java.class.path"), LinuxVmRecoveryStoreTest.class.getName(), mode, dir.toString(), id).inheritIO().start();
        check(child.waitFor(15, TimeUnit.SECONDS), "child timed out"); check(child.exitValue() == 73, "child must halt at boundary");
    }
    private static LinuxVmRecoveryStore halting(Path dir, String point) {
        return new LinuxVmRecoveryStore(dir, SESSION, path -> {}, LinuxVmRecoveryStoreTest::validate, EMPTY,
                hit -> { if (hit.equals(point)) Runtime.getRuntime().halt(73); });
    }
    private static LinuxVmRecoveryStore faulty(Path dir, String point) {
        return new LinuxVmRecoveryStore(dir, SESSION, path -> {}, LinuxVmRecoveryStoreTest::validate, EMPTY,
                hit -> { if (hit.equals(point)) throw new IOException("Injected " + point); });
    }
    private static LinuxVmRecoveryStore store(Path dir) { return new LinuxVmRecoveryStore(dir, SESSION, path -> {}, LinuxVmRecoveryStoreTest::validate, EMPTY); }
    private static void validate(byte[] payload) throws IOException { if (!Arrays.equals(payload, PAYLOAD)) throw new IOException("Disk payload rejected"); }
    private static String dispatched(Path dir, String operation) throws Exception { String id = id(); var store = store(dir); store.admit(id, operation); store.dispatched(id); return id; }
    private static String retired(Path dir, String operation) throws Exception { String id = dispatched(dir, operation); store(dir).retired(id, "completed", 0); return id; }
    private static String id() { return UUID.randomUUID().toString(); }
    private static Path dir(String name) throws IOException { return Files.createDirectory(root.resolve(name)); }
    private static LinuxVmRecoveryStore.View only(LinuxVmRecoveryStore.Snapshot snapshot) { check(snapshot.records().size() == 1, "expected one record"); return snapshot.records().get(0); }
    private static void contract(String name, LinuxVmRecoveryStore.Snapshot snapshot) { CONTRACT.put(name, LinuxVmRecoveryStore.inspectionJson(SESSION, snapshot)); }
    private static Map<String, String> contents(Path dir) throws IOException {
        Map<String, String> files = new LinkedHashMap<>(); try (var paths = Files.walk(dir)) {
            for (Path path : paths.filter(Files::isRegularFile).sorted().toList()) files.put(dir.relativize(path).toString(), LinuxVmRecoveryStore.digest(Files.readAllBytes(path)));
        } return files;
    }
    private static void test(String name, Checked body) throws Exception { body.run(); CASES.add(name); System.out.println("PASS " + name); }
    private static void check(boolean valid, String message) { if (!valid) throw new AssertionError(message); }
    private static void fails(Checked action) throws Exception { try { action.run(); } catch (IOException | IllegalArgumentException expected) { return; } throw new AssertionError("Expected failure"); }
    private static void blocked(Checked action) throws Exception { try { action.run(); } catch (LinuxVmRecoveryStore.BarrierException expected) { return; } throw new AssertionError("Expected recovery barrier"); }
}
