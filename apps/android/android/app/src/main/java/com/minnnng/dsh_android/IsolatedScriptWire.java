package com.minnnng.dsh_android;

import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Objects;
import java.util.UUID;

/** Versioned, bounded Binder values for one isolated JavaScript guest run. */
public final class IsolatedScriptWire {
    public static final int VERSION = 1;
    public static final int RUN = 61;
    public static final int RESULT = 62;
    public static final int RETIRE = 63;
    public static final int CANCEL = 64;
    public static final int HOST_CALL = 65;
    public static final int HOST_RESULT = 66;
    public static final String KEY_VERSION = "version";
    public static final String KEY_RUN = "runId";
    public static final String KEY_NONCE = "nonce";
    public static final String KEY_PROGRAM = "program";
    public static final String KEY_INPUT = "inputJson";
    public static final String KEY_DEADLINE = "deadlineMillis";
    public static final String KEY_STATUS = "status";
    public static final String KEY_OUTPUT = "outputJson";
    public static final String KEY_LOGS = "logsJson";
    public static final String KEY_DETAIL = "detail";
    public static final String KEY_UID = "uid";
    public static final String KEY_HOST_GRANTS = "hostGrantsJson";
    public static final String KEY_HOST_SEQUENCE = "hostSequence";
    public static final String KEY_HOST_REQUEST = "hostRequestJson";
    public static final String KEY_HOST_REPLY = "hostReplyJson";
    public static final int MAX_DETAIL_BYTES = 256;
    public static final int MAX_HOST_CALLS = 128;

    public record Request(String runId, String nonce, String program, String inputJson,
                          int deadlineMillis) {
        public Request {
            requireUuid(runId);
            requireUuid(nonce);
            // The App controller checks the execution class before constructing
            // this Binder value; the isolated process receives no authority to
            // upgrade an ordinary script into a workflow.
            PtcScriptEngine.validateWorkflow(program, inputJson, deadlineMillis);
            utf8Bytes(program);
            utf8Bytes(inputJson);
        }
    }

    public record Reply(String runId, String nonce, PtcScriptEngine.Status status,
                        String outputJson, String logsJson, String detail) {
        public Reply(String runId, String nonce, PtcScriptEngine.Status status,
                     String outputJson, String detail) {
            this(runId, nonce, status, outputJson,
                    status == PtcScriptEngine.Status.COMPLETED ? "[]" : null, detail);
        }
        public Reply {
            requireUuid(runId);
            requireUuid(nonce);
            Objects.requireNonNull(status);
            if (status == PtcScriptEngine.Status.COMPLETED) {
                if (outputJson == null || logsJson == null
                        || !logsJson.startsWith("[") || !logsJson.endsWith("]")
                        || utf8Bytes(logsJson) > PtcScriptEngine.MAX_LOG_BYTES
                        || utf8Bytes(outputJson) > PtcScriptEngine.MAX_OUTPUT_BYTES - utf8Bytes(logsJson)) {
                    throw new IllegalArgumentException("Script completion needs bounded JSON");
                }
            } else if (outputJson != null || logsJson != null) {
                throw new IllegalArgumentException("Failed script cannot carry output or logs");
            }
            if (detail != null && utf8Bytes(detail) > MAX_DETAIL_BYTES) {
                throw new IllegalArgumentException("Script detail exceeds Binder limit");
            }
        }
    }

    /** Sequence identifies a bounded in-flight host request; capability callId is separate. */
    public record HostRequest(String runId, String nonce, int sequence, String requestJson) {
        public HostRequest {
            requireUuid(runId);
            requireUuid(nonce);
            if (sequence < 1 || sequence > MAX_HOST_CALLS
                    || requestJson == null || utf8Bytes(requestJson) > PtcScriptEngine.MAX_HOST_REQUEST_BYTES)
                throw new IllegalArgumentException("Invalid script host request");
        }
    }

    public record HostReply(String runId, String nonce, int sequence, String replyJson) {
        public HostReply {
            requireUuid(runId);
            requireUuid(nonce);
            if (sequence < 1 || sequence > MAX_HOST_CALLS
                    || replyJson == null || utf8Bytes(replyJson) > PtcScriptEngine.MAX_HOST_REPLY_BYTES)
                throw new IllegalArgumentException("Invalid script host reply");
        }
    }

    private IsolatedScriptWire() {}

    public static void requireUuid(String value) {
        if (value == null) throw new IllegalArgumentException("Missing run identity");
        try {
            if (!UUID.fromString(value).toString().equals(value)) {
                throw new IllegalArgumentException("Noncanonical run identity");
            }
        } catch (IllegalArgumentException failure) {
            throw new IllegalArgumentException("Invalid run identity", failure);
        }
    }

    public static int utf8Bytes(String value) {
        Objects.requireNonNull(value);
        try {
            ByteBuffer encoded = StandardCharsets.UTF_8.newEncoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .encode(java.nio.CharBuffer.wrap(value));
            return encoded.remaining();
        } catch (CharacterCodingException failure) {
            throw new IllegalArgumentException("Malformed UTF-16 in script wire value", failure);
        }
    }
}
