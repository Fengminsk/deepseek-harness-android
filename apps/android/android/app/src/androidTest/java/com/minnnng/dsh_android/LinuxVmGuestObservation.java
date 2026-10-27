package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Acceptance-only parsing of top-level service identities; no process or retirement inference. */
public final class LinuxVmGuestObservation {
    private static final Pattern HEADER = Pattern.compile("^( {0,2})\\* (ServiceRecord\\{[^\\r\\n]+\\})[ \\t]*$");

    private LinuxVmGuestObservation() {}

    public static final class ObservationFailure extends IllegalStateException {
        public final String diagnostic;
        private ObservationFailure(String reason, String diagnostic) {
            super(reason);
            this.diagnostic = diagnostic;
        }
    }

    private record Candidate(String header, List<String> names, List<String> apps) {}

    public static final class WorkerCpu {
        public final int tid;
        public final String command;
        public final String time;
        public final long seconds;
        private WorkerCpu(int tid, String command, String time, long seconds) {
            this.tid = tid; this.command = command; this.time = time; this.seconds = seconds;
        }
    }

    /** ps CMD is the thread comm on the tested device; NAME is process argv and is not accepted. */
    public static WorkerCpu workerCpu(String output) {
        if (output.length() > 64 * 1024) throw new IllegalArgumentException("Linux thread observation exceeds limit");
        String[] lines = output.split("\\r?\\n", -1);
        int header = 0;
        while (header < lines.length && lines[header].isBlank()) header++;
        if (header == lines.length || !lines[header].trim().replaceAll("\\s+", " ").equals("TID CMD TIME"))
            throw new IllegalArgumentException("Expected exact Linux thread columns TID CMD TIME");
        WorkerCpu worker = null;
        for (int i = header + 1; i < lines.length; i++) {
            String[] fields = lines[i].trim().split("\\s+");
            if (fields.length < 2 || (!fields[1].equals("isolated-linux-vm") && !fields[1].equals("isolated-linux-"))) continue;
            if (worker != null) throw new IllegalStateException("Ambiguous Linux worker thread identity");
            if (fields.length != 3) throw new IllegalArgumentException("Malformed Linux worker thread row");
            int tid;
            try { tid = Integer.parseInt(fields[0]); }
            catch (NumberFormatException invalid) { throw new IllegalArgumentException("Invalid Linux worker TID", invalid); }
            if (tid < 1 || !Integer.toString(tid).equals(fields[0])) throw new IllegalArgumentException("Invalid Linux worker TID");
            String[] time = fields[2].split(":", -1);
            if (time.length != 3 || time[0].isEmpty() || time[1].length() != 2 || time[2].length() != 2)
                throw new IllegalArgumentException("Invalid Linux worker CPU time");
            for (String part : time) for (int n = 0; n < part.length(); n++)
                if (part.charAt(n) < '0' || part.charAt(n) > '9') throw new IllegalArgumentException("Invalid Linux worker CPU time");
            long seconds;
            try {
                int minutes = Integer.parseInt(time[1]), remainder = Integer.parseInt(time[2]);
                if (minutes > 59 || remainder > 59) throw new IllegalArgumentException("Invalid Linux worker CPU time");
                seconds = Math.addExact(Math.multiplyExact(Long.parseLong(time[0]), 3600L), minutes * 60L + remainder);
            } catch (ArithmeticException | NumberFormatException invalid) {
                throw new IllegalArgumentException("Invalid Linux worker CPU time", invalid);
            }
            worker = new WorkerCpu(tid, fields[1], fields[2], seconds);
        }
        return worker != null && worker.seconds > 0 ? worker : null;
    }

    /** Only duplicate renderings of the same ServiceRecord and exact ProcessRecord may collapse. */
    public static Integer pid(String output, String expected) {
        if (output.length() > 2 * 1024 * 1024 || expected.isBlank() || expected.length() > 512)
            throw new IllegalArgumentException("Linux process observation exceeds limit");
        String[] lines = output.split("\\r?\\n", -1);
        List<Candidate> candidates = new ArrayList<>();
        for (int i = 0; i < lines.length; i++) {
            Matcher header = HEADER.matcher(lines[i]);
            if (!header.matches()) continue;
            String direct = header.group(1) + "  ";
            List<String> names = new ArrayList<>(), apps = new ArrayList<>();
            for (int j = i + 1; j < lines.length; j++) {
                String line = lines[j];
                if (line.isBlank()) continue;
                // Stop at peer records and section headings. Nested connection references
                // and their fields cannot supply this service's direct process identity.
                if (indent(line) <= header.group(1).length()) break;
                if (line.startsWith(direct + "processName=")) names.add(line.substring(direct.length()).trim());
                if (line.startsWith(direct + "app=")) apps.add(line.substring(direct.length()).trim());
            }
            if (names.contains("processName=" + expected))
                candidates.add(new Candidate(header.group(2), names, apps));
        }
        if (candidates.isEmpty()) return null;
        Candidate first = candidates.get(0);
        Pattern app = Pattern.compile("app=ProcessRecord\\{[0-9a-fA-F]+ ([1-9][0-9]*):"
                + Pattern.quote(expected) + "/[^}\\r\\n]+\\}");
        for (Candidate candidate : candidates) {
            if (candidate.names.size() != 1 || candidate.apps.size() != 1)
                throw failure("Linux guest process fields are missing or ambiguous", candidates);
            if (!candidate.equals(first))
                throw failure("Ambiguous Linux guest identity", candidates);
        }
        String process = first.apps.get(0);
        if (process.equals("app=null")) return null;
        Matcher processMatch = app.matcher(process);
        if (!processMatch.matches())
            throw failure("Linux guest app does not match its exact process", candidates);
        try { return Integer.valueOf(processMatch.group(1)); }
        catch (NumberFormatException invalid) {
            throw failure("Linux guest PID is invalid", candidates);
        }
    }

    private static int indent(String line) {
        int count = 0;
        while (count < line.length() && (line.charAt(count) == ' ' || line.charAt(count) == '\t')) count++;
        return count;
    }

    private static ObservationFailure failure(String reason, List<Candidate> candidates) {
        StringBuilder summary = new StringBuilder("matchingRecords=").append(candidates.size());
        for (int i = 0; i < Math.min(4, candidates.size()); i++) {
            Candidate candidate = candidates.get(i);
            summary.append("\nrecord=").append(bounded(candidate.header, 384));
            summary.append("; processFields=").append(candidate.names.size());
            summary.append("; appFields=").append(candidate.apps.size());
            for (int j = 0; j < Math.min(2, candidate.apps.size()); j++)
                summary.append("; ").append(bounded(candidate.apps.get(j), 384));
        }
        return new ObservationFailure(reason, summary.toString());
    }

    private static String bounded(String value, int limit) {
        return value.length() <= limit ? value : value.substring(0, limit) + "…";
    }
}
