module transcript;

// Claude Code writes a row per turn, and the row that spawned this process
// carries the command that spawned it. The row is on disk before the command
// runs, so a process can read the row that started it.
//
// The command is not unique — the same one run twice names two rows. Nothing
// unique per invocation reaches the process: two consecutive calls differ only
// in PWD and OLDPWD. So the row taken is the latest by the timestamp the rows
// carry, which is this run's because every earlier row's command has already
// finished. Two identical commands running at once in one session read the same
// row, and that is the case this cannot tell apart.
//
// The values are copied out under the names the row uses. Nothing here decides
// what any of them means.

import std.file : exists, isDir, readText, dirEntries, SpanMode, getcwd;
import std.process : environment;
import std.string : indexOf, replace, splitLines, strip;
import records : Pair, scan, isKey;

private string projectDir() {
    immutable home = environment.get("HOME", "");
    if (home.length == 0) return null;
    return home ~ "/.claude/projects/" ~ getcwd().replace("/", "-");
}

// The main thread's row is in <session>.jsonl; a subagent's is under
// <session>/subagents/. Which one this process is in, the match decides.
private string[] candidates() {
    immutable dir = projectDir();
    if (dir is null) return null;
    immutable sid = environment.get("CLAUDE_CODE_SESSION_ID", "");
    if (sid.length == 0) return null;

    string[] out_;
    immutable main = dir ~ "/" ~ sid ~ ".jsonl";
    if (exists(main)) out_ ~= main;

    immutable subs = dir ~ "/" ~ sid ~ "/subagents";
    if (exists(subs) && isDir(subs)) {
        try {
            foreach (e; dirEntries(subs, "agent-*.jsonl", SpanMode.shallow))
                out_ ~= e.name;
        } catch (Exception) {
        }
    }
    return out_;
}

private string field(string row, string key) {
    foreach (p; scalars(row)) if (p.key == key) return p.value;
    return null;
}

// The latest row naming this command, by the timestamp the rows carry.
private bool locate(string cmd, out string file, out string row) {
    string latest;
    foreach (c; candidates()) {
        string text;
        try {
            text = readText(c);
        } catch (Exception) {
            continue;
        }
        foreach (line; text.splitLines()) {
            if (line.indexOf(cmd) < 0) continue;
            if (line.indexOf(`"type":"assistant"`) < 0) continue;
            immutable ts = field(line, "timestamp");
            if (ts.length == 0) continue;
            if (latest.length > 0 && ts <= latest) continue;
            latest = ts;
            file = c;
            row = line;
        }
    }
    return latest.length > 0;
}

private void emit(ref Pair[] out_, int depth, ref string[8] opened, string key, string v) {
    if (key is null) return;
    if (depth == 1) out_ ~= Pair(key, v);
    else if (depth == 2 && opened[2] == "message") out_ ~= Pair("message." ~ key, v);
}

// Every scalar the row carries at its top level, and every scalar in the API
// message nested inside it. Arrays and deeper objects are the response body,
// not provenance, and are left where they are.
private Pair[] scalars(string row) {
    Pair[] out_;
    string[8] opened;
    string key;
    int depth, arr;
    size_t i;

    while (i < row.length) {
        immutable c = row[i];
        if (c == '{') {
            depth++;
            if (depth < opened.length) opened[depth] = key;
            key = null;
            i++;
            continue;
        }
        if (c == '}') { depth--; key = null; i++; continue; }
        if (c == '[') { arr++; i++; continue; }
        if (c == ']') { arr--; key = null; i++; continue; }
        if (c == '"') {
            immutable s = scan(row, i);
            if (isKey(row, i)) {
                key = s;
                while (i < row.length && row[i] != ':') i++;
                i++;
                continue;
            }
            if (arr == 0) emit(out_, depth, opened, key, s);
            key = null;
            continue;
        }
        if (arr == 0 && key !is null &&
            (c == 't' || c == 'f' || c == 'n' || c == '-' || (c >= '0' && c <= '9'))) {
            size_t j = i;
            while (j < row.length && row[j] != ',' && row[j] != '}' && row[j] != ']') j++;
            emit(out_, depth, opened, key, row[i .. j].strip());
            key = null;
            i = j;
            continue;
        }
        i++;
    }
    return out_;
}

// The row does not name the file it is in, so that name is ours: transcript.file.
enum FILE_KEY = "transcript.file";

// Empty when no single row names this command line. There is nothing to record
// then, and nothing to guess.
Pair[] provenance(string[] argv) {
    string cmd;
    foreach (n, a; argv) {
        if (n) cmd ~= " ";
        cmd ~= a;
    }
    if (cmd.length == 0) return null;

    string file, row;
    if (!locate(cmd, file, row)) return null;

    auto out_ = scalars(row);
    out_ ~= Pair(FILE_KEY, file);
    return out_;
}
