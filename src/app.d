module app;

import std.stdio : writeln, writefln, stderr;
import std.datetime : Clock;
import std.conv : to;
import schema : fields, Field;
import node : fetchSubject, write;
import records : parse, Seen;

private const(Field)* declared(string path) {
    foreach (ref f; fields) {
        if (f.path == path) return &f;
    }
    return null;
}

private bool legalValue(const(Field)* f, string v) {
    if (f.type != "enum") return true;
    foreach (ok; f.values) if (ok == v) return true;
    return false;
}

private string pad2(int n) {
    immutable s = to!string(n);
    return s.length == 1 ? "0" ~ s : s;
}

private string today() {
    immutable t = Clock.currTime();
    return to!string(t.year) ~ "-" ~ pad2(cast(int) t.month) ~ "-" ~ pad2(t.day);
}

private Seen latest(Seen[] all, string field) {
    Seen best;
    foreach (r; all) {
        if (r.predicate != "datapunt:" ~ field) continue;
        if (best.timestamp.length == 0 || r.timestamp > best.timestamp) best = r;
    }
    return best;
}

private int usage() {
    stderr.writeln("datapunt schema                             the compiled-in schema");
    stderr.writeln("datapunt <subject> <field>                  read");
    stderr.writeln("datapunt <subject> <field> <value> <source> write");
    return 2;
}

int main(string[] argv) {
    if (argv.length == 2 && argv[1] == "schema") {
        foreach (f; fields) {
            writefln("%-38s %-15s %s", f.path, f.type, f.question is null ? "" : f.question);
        }
        writefln("%s fields", fields.length);
        return 0;
    }

    if (argv.length != 3 && argv.length != 5) return usage();

    immutable subject = argv[1];
    immutable path = argv[2];

    auto f = declared(path);
    if (f is null) {
        stderr.writefln("no such field in the schema: %s", path);
        return 2;
    }

    if (argv.length == 5) {
        if (!legalValue(f, argv[3])) {
            stderr.writefln("not a legal %s value: %s", path, argv[3]);
            stderr.writefln("legal: %-(%s, %)", f.values);
            return 2;
        }
        try {
            cast(void) write(subject, path, argv[3], argv[4], today());
            writeln("true");
            return 0;
        } catch (Exception e) {
            stderr.writefln("write failed: %s", e.msg);
            return 3;
        }
    }

    try {
        immutable r = latest(parse(fetchSubject(subject)), path);
        if (r.value.length == 0) { writeln("false"); return 1; }
        writeln("true");
        return 0;
    } catch (Exception e) {
        stderr.writefln("read failed: %s", e.msg);
        return 3;
    }
}
