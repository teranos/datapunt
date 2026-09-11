module app;

import std.stdio : writeln, writefln, stderr;
import std.file : exists, readText, dirEntries, SpanMode;
import std.path : buildPath, baseName;
import std.algorithm : sort, map, filter;
import std.array : array;
import schema : fields, Field;
import teardown : frontmatter, lookup;

enum DIR = "competitors";

private const(Field)* declared(string path) {
    foreach (ref f; fields) {
        if (f.path == path) return &f;
    }
    return null;
}

private string[] teardowns() {
    string[] out_;
    foreach (entry; dirEntries(DIR, "*.md", SpanMode.shallow)) {
        if (baseName(entry.name) == "README.md") continue;
        out_ ~= entry.name;
    }
    out_.sort();
    return out_;
}

private ptrdiff_t indexOf(string hay, string needle) {
    if (needle.length == 0 || needle.length > hay.length) return -1;
    foreach (i; 0 .. hay.length - needle.length + 1) {
        bool hit = true;
        foreach (j; 0 .. needle.length) {
            if (hay[i + j] != needle[j]) { hit = false; break; }
        }
        if (hit) return cast(ptrdiff_t) i;
    }
    return -1;
}

// A subject is named by filename, by slug, or by the url it records.
private string resolve(string want) {
    foreach (cand; [buildPath(DIR, want), buildPath(DIR, want ~ ".md")]) {
        if (exists(cand)) return cand;
    }
    foreach (file; teardowns()) {
        immutable url = lookup(frontmatter(readText(file)), "url");
        if (url.found && indexOf(url.raw, want) >= 0) return file;
    }
    return null;
}

private size_t answeredIn(string fm) {
    size_t n;
    foreach (f; fields) {
        if (lookup(fm, f.path).answered) n++;
    }
    return n;
}

private int coverage() {
    struct Row { string name; size_t n; }
    Row[] rows;
    size_t total;
    foreach (file; teardowns()) {
        immutable n = answeredIn(frontmatter(readText(file)));
        rows ~= Row(baseName(file)[0 .. $ - 3], n);
        total += n;
    }
    rows.sort!((a, b) => a.n < b.n);
    foreach (r; rows) {
        writefln("%3s/%s  %s", r.n, fields.length, r.name);
    }
    writefln("%s of %s answered across %s teardowns",
        total, rows.length * fields.length, rows.length);
    return 0;
}

private int byField() {
    struct Row { string path; size_t n; }
    Row[] rows;
    auto files = teardowns();
    string[] fms;
    foreach (file; files) fms ~= frontmatter(readText(file));
    foreach (f; fields) {
        size_t n;
        foreach (fm; fms) if (lookup(fm, f.path).answered) n++;
        rows ~= Row(f.path, n);
    }
    rows.sort!((a, b) => a.n < b.n);
    foreach (r; rows) writefln("%3s/%s  %s", r.n, files.length, r.path);
    return 0;
}

private int missing(string file) {
    immutable fm = frontmatter(readText(file));
    size_t n;
    foreach (f; fields) {
        if (lookup(fm, f.path).answered) { n++; continue; }
        writefln("%-38s %s", f.path, f.type);
    }
    writefln("%s of %s answered", n, fields.length);
    return n == fields.length ? 0 : 1;
}

int main(string[] argv) {
    if (argv.length == 1) return coverage();

    if (argv.length == 2 && argv[1] == "schema") {
        foreach (f; fields) {
            writefln("%-38s %-15s %s", f.path, f.type, f.question is null ? "" : f.question);
        }
        writefln("%s fields", fields.length);
        return 0;
    }

    if (argv.length == 2 && argv[1] == "fields") return byField();

    if (argv.length == 2) {
        immutable file = resolve(argv[1]);
        if (file is null) { stderr.writefln("no teardown for: %s", argv[1]); return 2; }
        return missing(file);
    }

    if (argv.length != 3) {
        stderr.writeln("datapunt                      coverage per teardown");
        stderr.writeln("datapunt fields               coverage per field");
        stderr.writeln("datapunt schema               the compiled-in schema");
        stderr.writeln("datapunt <competitor>         what is missing for one");
        stderr.writeln("datapunt <competitor> <field> true or false");
        return 2;
    }

    immutable path = argv[2];
    if (declared(path) is null) {
        stderr.writefln("no such field in the schema: %s", path);
        return 2;
    }

    immutable file = resolve(argv[1]);
    if (file is null) { stderr.writefln("no teardown for: %s", argv[1]); return 2; }

    immutable a = lookup(frontmatter(readText(file)), path);
    writeln(a.answered ? "true" : "false");
    return a.answered ? 0 : 1;
}
