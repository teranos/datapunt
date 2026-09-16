module jsonl;

// Claude Code writes a row per turn to a JSONL file, and the row that spawned
// this process carries the command that spawned it. The row is on disk before
// the command runs, so a process can read the row that started it.
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

import std.stdio : stderr;
import std.file : exists, isDir, readText, dirEntries, SpanMode;
import std.process : environment;
import std.string : indexOf, splitLines, strip;
import records : Pair, scan, isKey;

// The session id is unique, so the directory is whichever one holds that file.
// Deriving the name means owning the harness's rule for which characters get
// flattened, and `/Users/s.b.vanhouten` flattens to `-Users-s-b-vanhouten`.
private string projectDir(string sid) {
    immutable home = environment.get("HOME", "");
    if (home.length == 0) return null;
    immutable root = home ~ "/.claude/projects";
    if (!exists(root) || !isDir(root)) return null;

    try {
        foreach (e; dirEntries(root, SpanMode.shallow)) {
            if (!e.isDir) continue;
            if (exists(e.name ~ "/" ~ sid ~ ".jsonl")) return e.name;
        }
    } catch (Exception) {
    }
    return null;
}

// The main thread's row is in <session>.jsonl; a subagent's is under
// <session>/subagents/. Which one this process is in, the match decides.
private string[] candidates() {
    immutable sid = environment.get("CLAUDE_CODE_SESSION_ID", "");
    if (sid.length == 0) return null;
    immutable dir = projectDir(sid);
    if (dir is null) return null;

    string[] out_ = [dir ~ "/" ~ sid ~ ".jsonl"];

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

// Each argument on its own, inside what one Bash call was handed.
//
// The line as typed is not the line as argv: the binary can be reached through
// a variable or an alias, and any value holding a space is quoted, so the joined
// argv is not a substring of the command. Every argument is a substring of the
// quoted text that carries it, so each is looked for separately.
//
// Inside a Bash input, not anywhere in the row: a turn that writes about a
// command names the same words as the turn that ran it, and prose is not a run.
//
// A Bash input that writes the command into a file names it too, and that is
// not a run either. Run through a script, the running row holds only the
// script's path and the arguments appear solely in the row that wrote it, so
// the row found is that one. Nothing on disk links the two.
private bool names(string line, string[] args) {
    foreach (span; inputs(line, "Bash")) {
        bool all = true;
        foreach (a; args) {
            if (a.length == 0) continue;
            if (span.indexOf(a) < 0) { all = false; break; }
        }
        if (all) return true;
    }
    return false;
}

// The latest row naming these arguments, by the timestamp the rows carry.
private bool locate(string[] cands, string[] args, out string file, out string row) {
    string latest;
    foreach (c; cands) {
        string text;
        try {
            text = readText(c);
        } catch (Exception) {
            continue;
        }
        foreach (line; text.splitLines()) {
            if (line.indexOf(`"type":"assistant"`) < 0) continue;
            if (!names(line, args)) continue;
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

private bool terminator(char c) {
    return c == ' ' || c == '"' || c == '\\' || c == '\'' || c == '<' || c == '>'
        || c == '`' || c == ')' || c == '\t';
}

private void collect(ref string[] out_, string span) {
    size_t i;
    while (i < span.length) {
        immutable at = span[i .. $].indexOf("http");
        if (at < 0) return;
        immutable s = i + at;
        if (span[s .. $].indexOf("http://") != 0 && span[s .. $].indexOf("https://") != 0) {
            i = s + 4;
            continue;
        }
        size_t e = s;
        while (e < span.length && !terminator(span[e])) e++;
        immutable u = span[s .. e];
        bool seen;
        foreach (h; out_) if (h == u) { seen = true; break; }
        if (!seen) out_ ~= u;
        i = e;
    }
}

// What one tool was handed, per call, so a URL a tool fetched is never confused
// with one that merely appears in prose on the same row.
private string[] inputs(string line, string tool) {
    string[] out_;
    immutable needle = `"name":"` ~ tool ~ `"`;
    size_t i;
    while (i < line.length) {
        immutable at = line[i .. $].indexOf(needle);
        if (at < 0) break;
        immutable s = i + at + needle.length;
        immutable e = line[s .. $].indexOf(`"type":"tool_use"`);
        immutable stop = e < 0 ? line.length : s + e;
        out_ ~= line[s .. stop];
        i = stop;
    }
    return out_;
}

// Only the inputs of tools that fetch. A URL in a skill's arguments was typed
// by someone, and recording it would claim a page was read that never was.
private void fromFetchers(ref string[] out_, string line) {
    static immutable tools = ["Bash", "WebFetch"];
    foreach (tool; tools)
        foreach (span; inputs(line, tool)) collect(out_, span);
}

// A previous run of the tool, not a mention of it. Every message in a session
// about datapunt names datapunt, and a name is not a run.
private bool ranDatapunt(string line) {
    foreach (span; inputs(line, "Bash"))
        if (span.indexOf("datapunt ") >= 0) return true;
    return false;
}

// Every page fetched since the previous datapunt run in this file. Which of
// them a value came from is not on disk. All of them are.
private string[] sources(string file, string row) {
    string[] out_;
    string text;
    try {
        text = readText(file);
    } catch (Exception) {
        return null;
    }
    foreach (line; text.splitLines()) {
        if (line == row) break;
        if (line.indexOf(`"type":"assistant"`) < 0) continue;
        if (ranDatapunt(line)) out_ = null;
        fromFetchers(out_, line);
    }
    return out_;
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
            // A JSON null is the row declining to say, which is not an
            // observation. The string "null" is left alone, being a value.
            immutable lit = row[i .. j].strip();
            if (lit != "null") emit(out_, depth, opened, key, lit);
            key = null;
            i = j;
            continue;
        }
        i++;
    }
    return out_;
}

// The row does not name the file it is in, so that name is ours: jsonl.file.
enum FILE_KEY = "jsonl.file";

struct Provenance {
    Pair[] pairs;
    string[] fetched;
}

// Empty when no row names these arguments. There is nothing to record then, and
// nothing to guess — but where this session has a transcript and no row matches,
// that is the tool failing to find itself rather than there being nothing to
// find, and it says so instead of writing a record that quietly claims nobody.
Provenance provenance(string[] argv) {
    if (argv.length < 2) return Provenance.init;
    auto args = argv[1 .. $];

    auto cands = candidates();
    if (cands.length == 0) return Provenance.init;

    string file, row;
    if (!locate(cands, args, file, row)) {
        stderr.writeln("datapunt: no row in this session names this command; provenance not recorded");
        return Provenance.init;
    }

    auto pairs = scalars(row);
    pairs ~= Pair(FILE_KEY, file);
    return Provenance(pairs, sources(file, row));
}
