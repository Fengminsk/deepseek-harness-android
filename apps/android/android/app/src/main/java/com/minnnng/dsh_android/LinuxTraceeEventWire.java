package com.minnnng.dsh_android;

import java.nio.charset.StandardCharsets;
import java.util.regex.Pattern;

/**
 * Bounded parser for the pinned PRoot DSH_TRACE_V1 pipe. This is evidence only:
 * it never starts a guest, reads app files, or grants a capability.
 */
final class LinuxTraceeEventWire {
    private static final String MAGIC = "DSH_TRACE_V1";
    private static final Pattern RUN_ID = Pattern.compile(
        "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");
    private static final int MAX_FRAME_BYTES = 159; // Native emitter uses char frame[160].
    private static final long MAX_FRAMES = 2L * LinuxTraceeRetirementLedger.MAX_LIFETIMES + 2;

    private enum Phase { ROOT, ARM, TRACE, DRAIN, EOF }

    private final String runId;
    private final byte[] frame = new byte[MAX_FRAME_BYTES];
    private int frameLength;
    private long nextWireSequence = 1;
    private long drainLedgerSequence;
    private int drainExitStatus;
    private int rootPid;
    private Phase phase = Phase.ROOT;
    private LinuxTraceeRetirementLedger ledger;
    private boolean cancelled;
    private String failure;

    LinuxTraceeEventWire(String runId) {
        if (runId == null || !RUN_ID.matcher(runId).matches()) {
            throw new IllegalArgumentException("Noncanonical PRoot run ID");
        }
        this.runId = runId;
    }

    /** The caller must drain the pipe concurrently with the tracer process. */
    boolean accept(byte[] bytes, int offset, int length) {
        if (bytes == null || offset < 0 || length < 0 || offset > bytes.length - length) {
            return reject("Invalid PRoot event chunk");
        }
        if (failure != null) return false;
        if (phase == Phase.EOF) return reject("PRoot event stream continued after EOF");
        for (int index = offset; index < offset + length; index++) {
            int value = bytes[index] & 0xff;
            if (value == '\n') {
                if (frameLength == 0) return reject("Empty PRoot event frame");
                if (!readFrame()) return false;
                frameLength = 0;
            } else {
                if (phase == Phase.DRAIN || value != '\t' && (value < 0x20 || value > 0x7e) ||
                    frameLength >= MAX_FRAME_BYTES - 1) {
                    return reject("Malformed or oversized PRoot event frame");
                }
                frame[frameLength++] = (byte) value;
            }
        }
        return true;
    }

    /** Call only after reading actual pipe EOF and observing the OS process exit. */
    boolean endOfStream(boolean tracerExitedNormally, int tracerExitCode) {
        if (failure != null) return false;
        if (phase != Phase.DRAIN || frameLength != 0 || !tracerExitedNormally ||
            tracerExitCode < 0 || tracerExitCode > 255 || drainExitStatus != 0 ||
            tracerExitCode != 0 || cancelled || ledger == null ||
            !ledger.close(drainLedgerSequence, true, true)) {
            return reject("PRoot exit, pipe drain, or tracee retirement unconfirmed");
        }
        phase = Phase.EOF;
        return true;
    }

    void requestCancellation() {
        cancelled = true;
        if (ledger != null) ledger.requestCancellation();
    }

    boolean mayPublishSuccess() {
        return phase == Phase.EOF && failure == null && !cancelled &&
            ledger != null && ledger.mayPublishSuccess();
    }

    String failure() { return failure != null ? failure : ledger != null ? ledger.failure() : null; }

    private boolean readFrame() {
        if (nextWireSequence > MAX_FRAMES) return reject("PRoot event count exceeded lifetime bound");
        String[] fields = new String(frame, 0, frameLength, StandardCharsets.US_ASCII).split("\t", -1);
        if (fields.length != 6 || !MAGIC.equals(fields[0]) || !runId.equals(fields[1])) {
            return reject("PRoot event identity or grammar changed");
        }
        long sequence = positiveLong(fields[2]);
        if (sequence != nextWireSequence) return reject("PRoot event sequence skipped or repeated");

        String event = fields[3];
        if (phase == Phase.ROOT && "ROOT".equals(event)) {
            int pid = positiveInt(fields[4]);
            if (pid <= 0 || !"0".equals(fields[5])) return reject("Invalid PRoot root event");
            rootPid = pid;
            ledger = new LinuxTraceeRetirementLedger(pid);
            if (cancelled) ledger.requestCancellation();
            phase = Phase.ARM;
        } else if (phase == Phase.ARM && "ARM".equals(event)) {
            int pid = positiveInt(fields[4]);
            int options = positiveInt(fields[5]);
            if (pid <= 0 || options <= 0 || pid != rootPid || !ledger.arm(options)) {
                return reject("PRoot ptrace options were not confirmed for the root");
            }
            phase = Phase.TRACE;
        } else if (phase == Phase.TRACE && ("FORK".equals(event) ||
                    "VFORK".equals(event) || "CLONE".equals(event))) {
            int parent = positiveInt(fields[4]);
            int child = positiveInt(fields[5]);
            if (parent <= 0 || child <= 0 || !ledger.spawned(sequence - 2, parent, child)) {
                return reject("PRoot tracee creation was not confirmed");
            }
        } else if (phase == Phase.TRACE && "REAP".equals(event)) {
            int pid = positiveInt(fields[4]);
            int status = nonnegativeInt(fields[5]);
            if (pid <= 0 || !finalWaitStatus(status) || !ledger.reaped(sequence - 2, pid)) {
                return reject("PRoot final waitpid event was not confirmed");
            }
        } else if (phase == Phase.TRACE && "DRAIN".equals(event)) {
            int status = signedDrainStatus(fields[4]);
            if (status < -1 || !"0".equals(fields[5])) {
                return reject("Invalid PRoot waitpid drain event");
            }
            drainExitStatus = status;
            drainLedgerSequence = sequence - 2;
            phase = Phase.DRAIN;
        } else {
            return reject("Unexpected PRoot event or ordering");
        }
        nextWireSequence++;
        return true;
    }

    private static boolean finalWaitStatus(int status) {
        if (status < 0 || status > 0xffff) return false;
        int low = status & 0x7f;
        return low == 0 || low < 0x7f; // WIFEXITED or WIFSIGNALED, never WIFSTOPPED.
    }

    private static int positiveInt(String text) {
        long value = positiveLong(text);
        return value > 0 && value <= Integer.MAX_VALUE ? (int) value : -1;
    }

    private static int nonnegativeInt(String text) {
        long value = decimal(text);
        return value >= 0 && value <= Integer.MAX_VALUE ? (int) value : -1;
    }

    private static int signedDrainStatus(String text) {
        if ("-1".equals(text)) return -1;
        int value = nonnegativeInt(text);
        return value <= 255 ? value : -2;
    }

    private static long positiveLong(String text) {
        long value = decimal(text);
        return value > 0 ? value : -1;
    }

    private static long decimal(String text) {
        if (text == null || text.isEmpty() || (text.length() > 1 && text.charAt(0) == '0')) return -1;
        long value = 0;
        for (int index = 0; index < text.length(); index++) {
            char digit = text.charAt(index);
            if (digit < '0' || digit > '9' || value > (Long.MAX_VALUE - (digit - '0')) / 10) return -1;
            value = value * 10 + digit - '0';
        }
        return value;
    }

    private boolean reject(String reason) {
        if (failure == null) failure = reason;
        return false;
    }
}
