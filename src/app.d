module app;

import std.stdio : writeln, writefln, stderr;
import schema : fields, kinds, Field;
import node : fetchSubject, fetchKind, write, OBSERVED;
import records : parse, newest, attribute, Record, subjectsIn;
import transcript : provenance;

private const(Field)* declared(string kind, string path) {
    foreach (ref f; fields) {
        if (f.kind == kind && f.path == path) return &f;
    }
    return null;
}

private bool knownKind(string kind) {
    foreach (ref f; fields) if (f.kind == kind) return true;
    return false;
}

private bool legalValue(const(Field)* f, string v) {
    if (f.type != "enum") return true;
    foreach (ok; f.values) if (ok == v) return true;
    return false;
}

private Record current(string subject) {
    return newest(parse(fetchSubject(subject)));
}

private size_t declaredFor(string kind) {
    size_t n;
    foreach (f; fields) if (f.kind == kind) n++;
    return n;
}

private size_t observedIn(Record r, string kind) {
    size_t n;
    foreach (f; fields) {
        if (f.kind != kind) continue;
        if (attribute(r, f.path) !is null) n++;
    }
    return n;
}

private int usage() {
    stderr.writeln("datapunt schema                              what it was built to know");
    stderr.writeln("datapunt <kind>                              coverage per subject");
    stderr.writeln("datapunt <kind> fields                       coverage per field");
    stderr.writeln("datapunt <kind> fields <prefix>              coverage per field, one subtree");
    stderr.writeln("datapunt <kind> <name>                       what is unobserved");
    stderr.writeln("datapunt <kind> <name> <field>               observed or not");
    stderr.writeln("datapunt <kind> <name> <field> <value>       observe");
    return 2;
}

private int unobserved(string kind, string name) {
    auto r = current(name);
    foreach (f; fields) {
        if (f.kind != kind) continue;
        if (attribute(r, f.path) !is null) continue;
        writefln("%-38s %s", f.path, f.type);
    }
    immutable n = observedIn(r, kind);
    immutable total = declaredFor(kind);
    writefln("%s of %s observed", n, total);
    return n == total ? 0 : 1;
}

// A prefix names a subtree the way the schema nests it, so `pricing` takes the
// whole group and `pricing.hourly` takes the one field. A prefix that is only
// the start of a segment matches nothing.
private bool under(string path, string prefix) {
    if (prefix.length == 0) return true;
    if (path.length < prefix.length) return false;
    if (path[0 .. prefix.length] != prefix) return false;
    return path.length == prefix.length || path[prefix.length] == '.';
}

// The other axis: how many subjects carry each field. A field nearly every
// subject has is a gap worth closing; one almost nobody has may be a field
// worth removing instead.
private int byField(string kind, string prefix) {
    struct Row { string path; string type; size_t n; }
    Row[] rows;
    foreach (f; fields) {
        if (f.kind != kind) continue;
        if (!under(f.path, prefix)) continue;
        rows ~= Row(f.path, f.type, 0);
    }
    if (rows.length == 0) {
        stderr.writefln("no field under %s for %s", prefix, kind);
        return 2;
    }

    auto names = subjectsIn(parse(fetchKind(kind)));
    Record[] held;
    foreach (s; names) held ~= current(s);
    foreach (ref row; rows) {
        foreach (r; held) if (attribute(r, row.path) !is null) row.n++;
    }

    import std.algorithm : sort;
    rows.sort!((a, b) => a.n > b.n);
    foreach (r; rows) writefln("%3s/%s  %-38s %s", r.n, names.length, r.path, r.type);
    return 0;
}

private int coverage(string kind) {
    immutable total = declaredFor(kind);
    auto all = parse(fetchKind(kind));
    auto names = subjectsIn(all);
    size_t sum;
    foreach (s; names) {
        immutable n = observedIn(current(s), kind);
        sum += n;
        writefln("%3s/%s  %s", n, total, s);
    }
    writefln("%s of %s observed across %s subjects", sum, names.length * total, names.length);
    return 0;
}

// Read what is there, merge the one new value in, write the whole set back.
//
// Only declared fields carry forward. Everything else in the record came from
// the transcript of the run that wrote it, and that run is not this one — a
// write that inherited it would name a row it never read.
private int observe(string kind, string name, string path, string value, string[] argv) {
    auto r = current(name);
    string[2][] merged;
    bool replaced;
    foreach (p; r.attributes) {
        if (p.key == path) { merged ~= [path, value]; replaced = true; }
        else if (declared(kind, p.key) !is null) merged ~= [p.key, p.value];
    }
    if (!replaced) merged ~= [path, value];
    cast(void) write(name, kind, OBSERVED, merged, provenance(argv));
    writeln("true");
    return 0;
}

int main(string[] argv) {
    if (argv.length == 2 && argv[1] == "schema") {
        foreach (f; fields) {
            writefln("%-12s %-38s %-15s %s", f.kind, f.path, f.type,
                f.question is null ? "" : f.question);
        }
        writefln("%s fields across %s kinds", fields.length, kinds.length);
        return 0;
    }

    if (argv.length == 2 && (argv[1] == "help" || argv[1] == "--help" || argv[1] == "-h")) {
        usage();
        return 0;
    }

    if (argv.length < 2 || argv.length > 5) return usage();

    immutable kind = argv[1];
    if (!knownKind(kind)) {
        stderr.writefln("no such kind in the schema: %s", kind);
        return 2;
    }

    try {
        if (argv.length == 2) return coverage(kind);
        immutable name = argv[2];
        if (argv.length == 3) return name == "fields" ? byField(kind, null) : unobserved(kind, name);
        if (argv.length == 4 && name == "fields") return byField(kind, argv[3]);

        immutable path = argv[3];
        auto f = declared(kind, path);
        if (f is null) {
            stderr.writefln("no such field for %s: %s", kind, path);
            return 2;
        }

        if (argv.length == 5) {
            if (!legalValue(f, argv[4])) {
                stderr.writefln("not a legal %s value: %s", path, argv[4]);
                stderr.writefln("legal: %-(%s, %)", f.values);
                return 2;
            }
            return observe(kind, name, path, argv[4], argv);
        }

        immutable v = attribute(current(name), path);
        writeln(v is null ? "false" : "true");
        return v is null ? 1 : 0;
    } catch (Exception e) {
        stderr.writefln("failed: %s", e.msg);
        return 3;
    }
}
