package com.minnnng.dsh_android;

import java.nio.charset.StandardCharsets;

/** Host parser checks; event production and whole-tree retirement still need a device. */
public final class LinuxTraceeEventWireTest {
    private static final String ID = "01234567-89ab-cdef-0123-456789abcdef";

    public static void main(String[] args) {
        acceptsACompleteSplitPipeStream();
        rejectsIdentityGrammarAndBounds();
        rejectsOrderingAndMissingEvents();
        rejectsLifetimeOverflow();
        requiresExitAndEof();
        cancellationNeverPublishesSuccess();
        System.out.println("LinuxTraceeEventWireTest passed");
    }

    private static void acceptsACompleteSplitPipeStream() {
        LinuxTraceeEventWire parser = new LinuxTraceeEventWire(ID);
        String stream = frame(1, "ROOT", 100, 0) + frame(2, "ARM", 100,
            LinuxTraceeRetirementLedger.REQUIRED_OPTIONS) +
            frame(3, "FORK", 100, 101) + frame(4, "VFORK", 101, 102) +
            frame(5, "CLONE", 100, 103) + frame(6, "REAP", 100, 0) +
            frame(7, "REAP", 101, 768) + frame(8, "REAP", 102, 9) +
            frame(9, "REAP", 103, 0) + frame(10, "DRAIN", 0, 0);
        byte[] bytes = stream.getBytes(StandardCharsets.US_ASCII);
        for (int index = 0; index < bytes.length; index++) {
            require(parser.accept(bytes, index, 1));
            require(!parser.mayPublishSuccess());
        }
        require(parser.endOfStream(true, 0));
        require(parser.mayPublishSuccess());
        require(parser.failure() == null);
        reject(parser, frame(11, "REAP", 103, 0));
        require(!parser.mayPublishSuccess());
    }

    private static void rejectsIdentityGrammarAndBounds() {
        try {
            new LinuxTraceeEventWire("01234567-89AB-cdef-0123-456789abcdef");
            throw new AssertionError("Noncanonical run ID was accepted");
        } catch (IllegalArgumentException expected) { /* expected */ }
        reject(new LinuxTraceeEventWire(ID), frame(1, "ROOT", 100, 0).replace(ID,
            "fedcba98-7654-3210-fedc-ba9876543210"));
        reject(new LinuxTraceeEventWire(ID), frame(1, "ROOT", 100, 0).replace("TRACE_V1", "TRACE_V2"));
        reject(new LinuxTraceeEventWire(ID), frame(1, "ROOT", 100, 0).replace("\t1\tROOT", "\t01\tROOT"));
        reject(new LinuxTraceeEventWire(ID), frame(1, "ROOT", 100, 0).replace("\t100\t", "\t2147483648\t"));
        reject(new LinuxTraceeEventWire(ID), frame(1, "ROOT", 100, 0).replace("\t100\t", "\t-100\t"));
        reject(new LinuxTraceeEventWire(ID), frame(1, "ROOT", 100, 0).replace("\n", "\t0\n"));
        reject(new LinuxTraceeEventWire(ID), "\n");
        reject(new LinuxTraceeEventWire(ID), "X".repeat(160));
        reject(new LinuxTraceeEventWire(ID), frame(1, "ROOT", 100, 0).replace("ROOT", "RÓOT"));
        reject(new LinuxTraceeEventWire(ID), frame(1, "ROOT", 100, 0).replace("\t1\tROOT", "\t9223372036854775808\tROOT"));
        LinuxTraceeEventWire chunk = new LinuxTraceeEventWire(ID);
        require(!chunk.accept(new byte[1], 0, 2));
        require(chunk.failure() != null);
    }

    private static void rejectsLifetimeOverflow() {
        LinuxTraceeEventWire parser = new LinuxTraceeEventWire(ID);
        feed(parser, ready());
        for (int created = 1; created < LinuxTraceeRetirementLedger.MAX_LIFETIMES; created++) {
            feed(parser, frame(created + 2L, "FORK", 100, 2000 + created));
        }
        reject(parser, frame(LinuxTraceeRetirementLedger.MAX_LIFETIMES + 2L,
            "CLONE", 100, 2000 + LinuxTraceeRetirementLedger.MAX_LIFETIMES));
    }

    private static void rejectsOrderingAndMissingEvents() {
        reject(new LinuxTraceeEventWire(ID), frame(2, "ROOT", 100, 0));
        reject(new LinuxTraceeEventWire(ID), frame(1, "ARM", 100,
            LinuxTraceeRetirementLedger.REQUIRED_OPTIONS));
        reject(new LinuxTraceeEventWire(ID), frame(1, "ROOT", 100, 0) +
            frame(2, "ARM", 101, LinuxTraceeRetirementLedger.REQUIRED_OPTIONS));
        reject(new LinuxTraceeEventWire(ID), frame(1, "ROOT", 100, 0) +
            frame(2, "ARM", 100, LinuxTraceeRetirementLedger.TRACE_EXIT));
        reject(new LinuxTraceeEventWire(ID), ready() + frame(3, "FORK", 100, 101) +
            frame(3, "REAP", 101, 0));
        reject(new LinuxTraceeEventWire(ID), ready() + frame(3, "SPAWN", 100, 101));
        reject(new LinuxTraceeEventWire(ID), ready() + frame(3, "REAP", 100, 127));
        reject(new LinuxTraceeEventWire(ID), ready() + frame(3, "REAP", 100, 65536));
        reject(new LinuxTraceeEventWire(ID), ready() + frame(3, "REAP", 999, 0));
        LinuxTraceeEventWire liveChild = new LinuxTraceeEventWire(ID);
        feed(liveChild, ready() + frame(3, "FORK", 100, 101) +
            frame(4, "REAP", 100, 0) + frame(5, "DRAIN", 0, 0));
        require(!liveChild.endOfStream(true, 0));
        require(!liveChild.mayPublishSuccess());
        LinuxTraceeEventWire earlyDrain = new LinuxTraceeEventWire(ID);
        feed(earlyDrain, ready() + frame(3, "REAP", 100, 0) + frame(4, "DRAIN", 0, 0));
        reject(earlyDrain, frame(5, "DRAIN", 0, 0));
    }

    private static void requiresExitAndEof() {
        String complete = ready() + frame(3, "REAP", 100, 0) + frame(4, "DRAIN", 0, 0);
        LinuxTraceeEventWire noEof = new LinuxTraceeEventWire(ID);
        feed(noEof, complete);
        require(!noEof.mayPublishSuccess());
        require(!noEof.endOfStream(false, 0));
        LinuxTraceeEventWire exitMismatch = new LinuxTraceeEventWire(ID);
        feed(exitMismatch, complete);
        require(!exitMismatch.endOfStream(true, 1));
        LinuxTraceeEventWire guestError = new LinuxTraceeEventWire(ID);
        feed(guestError, ready() + frame(3, "REAP", 100, 256) + frame(4, "DRAIN", 1, 0));
        require(!guestError.endOfStream(true, 1));
        LinuxTraceeEventWire terminated = new LinuxTraceeEventWire(ID);
        feed(terminated, ready() + frame(3, "REAP", 100, 9) + frame(4, "DRAIN", -1, 0));
        require(!terminated.endOfStream(true, 255));
        LinuxTraceeEventWire partial = new LinuxTraceeEventWire(ID);
        feed(partial, ready() + frame(3, "REAP", 100, 0));
        byte[] bytes = frame(4, "DRAIN", 0, 0).getBytes(StandardCharsets.US_ASCII);
        require(partial.accept(bytes, 0, bytes.length - 1));
        require(!partial.endOfStream(true, 0));
        LinuxTraceeEventWire missingDrain = new LinuxTraceeEventWire(ID);
        feed(missingDrain, ready() + frame(3, "REAP", 100, 0));
        require(!missingDrain.endOfStream(true, 0));
    }

    private static void cancellationNeverPublishesSuccess() {
        LinuxTraceeEventWire beforeRoot = new LinuxTraceeEventWire(ID);
        beforeRoot.requestCancellation();
        feed(beforeRoot, ready() + frame(3, "REAP", 100, 0) + frame(4, "DRAIN", 0, 0));
        require(!beforeRoot.endOfStream(true, 0));
        LinuxTraceeEventWire afterRoot = new LinuxTraceeEventWire(ID);
        feed(afterRoot, ready() + frame(3, "REAP", 100, 0) + frame(4, "DRAIN", 0, 0));
        afterRoot.requestCancellation();
        require(!afterRoot.endOfStream(true, 0));
        LinuxTraceeEventWire afterEof = new LinuxTraceeEventWire(ID);
        feed(afterEof, ready() + frame(3, "REAP", 100, 0) + frame(4, "DRAIN", 0, 0));
        require(afterEof.endOfStream(true, 0));
        afterEof.requestCancellation();
        require(!afterEof.mayPublishSuccess());
    }

    private static String ready() {
        return frame(1, "ROOT", 100, 0) + frame(2, "ARM", 100,
            LinuxTraceeRetirementLedger.REQUIRED_OPTIONS);
    }

    private static String frame(long sequence, String event, long first, long second) {
        return "DSH_TRACE_V1\t" + ID + "\t" + sequence + "\t" + event +
            "\t" + first + "\t" + second + "\n";
    }

    private static void feed(LinuxTraceeEventWire parser, String stream) {
        byte[] bytes = stream.getBytes(StandardCharsets.UTF_8);
        require(parser.accept(bytes, 0, bytes.length));
    }

    private static void reject(LinuxTraceeEventWire parser, String stream) {
        byte[] bytes = stream.getBytes(StandardCharsets.UTF_8);
        require(!parser.accept(bytes, 0, bytes.length));
        require(parser.failure() != null);
        require(!parser.mayPublishSuccess());
    }

    private static void require(boolean value) {
        if (!value) throw new AssertionError("PRoot wire evidence was accepted or rejected incorrectly");
    }
}
