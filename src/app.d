module app;

import std.stdio : writeln, writefln, stderr;
import schema : fields, kinds, Field;
import node : fetchSubject, fetchKind, write, OBSERVED;
import records : parse, newest, attribute, Record, subjectsIn;

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
    stderr.writeln("datapunt <kind>                              coverage across a kind");
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
private int observe(string kind, string name, string path, string value) {
    auto r = current(name);
    string[2][] merged;
    bool replaced;
    foreach (p; r.attributes) {
        if (p.key == path) { merged ~= [path, value]; replaced = true; }
        else merged ~= [p.key, p.value];
    }
    if (!replaced) merged ~= [path, value];
    cast(void) write(name, kind, OBSERVED, merged);
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
        if (argv.length == 3) return unobserved(kind, name);

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
            return observe(kind, name, path, argv[4]);
        }

        immutable v = attribute(current(name), path);
        writeln(v is null ? "false" : "true");
        return v is null ? 1 : 0;
    } catch (Exception e) {
        stderr.writefln("failed: %s", e.msg);
        return 3;
    }
}
