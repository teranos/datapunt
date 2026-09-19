/// What datapunt answers, as the command line did, over records already read.
/// Nothing here reaches the store: main.d reads, this decides, main.d writes.
module plugin.punt;

import schema : fields, kinds, Field;

/// What kind of statement an observation is (as node.d writes it).
enum OBSERVED = "datapunt:observed";

/// records.d's SINCE, 2026-09-12T16:00:00Z, in Unix milliseconds. Older
/// attestations were written in a shape this does not read.
enum long SINCE_MS = 1_789_228_800_000;

struct Record {
    string subject;
    long timestamp; // Unix milliseconds
    string[2][] attributes;
}

/// An HTTP status and a JSON body, which is all HandleHTTP hands back.
struct Answer {
    int status;
    string body;
}

// ---------------------------------------------------------------------------
// The records
// ---------------------------------------------------------------------------

/// The last claim in time is operative, per subject.
Record[string] newestBySubject(Record[] all) {
    Record[string] best;
    foreach (r; all) {
        if (r.timestamp < SINCE_MS || r.subject.length == 0) continue;
        auto seen = r.subject in best;
        if (seen is null || r.timestamp > seen.timestamp) best[r.subject] = r;
    }
    return best;
}

/// The value of one field, or null when it is unobserved.
string attribute(ref const Record r, string key) {
    foreach (kv; r.attributes) if (kv[0] == key) return kv[1];
    return null;
}

const(Field)* declared(string kind, string path) {
    foreach (ref f; fields) if (f.kind == kind && f.path == path) return &f;
    return null;
}

bool knownKind(string kind) {
    foreach (k; kinds) if (k.name == kind) return true;
    return false;
}

string[] kindNames() {
    string[] names;
    foreach (k; kinds) names ~= k.name;
    return names;
}

/// Every declared path, across kinds, once each: what a field may be named.
string[] fieldPaths() {
    string[] paths;
    foreach (f; fields) {
        bool seen;
        foreach (p; paths) if (p == f.path) { seen = true; break; }
        if (!seen) paths ~= f.path;
    }
    return paths;
}

private const(Field)[] declaredFor(string kind) {
    const(Field)[] out_;
    foreach (ref f; fields) if (f.kind == kind) out_ ~= f;
    return out_;
}

// A prefix names a subtree the way the schema nests it: `pricing` takes the
// group and `pricing.hourly` the field. The start of a segment matches nothing.
private bool under(string path, string prefix) {
    if (prefix.length == 0) return true;
    if (path.length < prefix.length || path[0 .. prefix.length] != prefix) return false;
    return path.length == prefix.length || path[prefix.length] == '.';
}

// ---------------------------------------------------------------------------
// read: what is observed, as cells of (subject, field)
// ---------------------------------------------------------------------------

/// Every read answers kind, rows, and how many of the cells it is about are
/// observed, out of how many.
Answer read(string kind, string by, string name, string field, string prefix, Record[] kindRecords) {
    if (!knownKind(kind)) return refused("not one of", "kind", "no such kind in the schema: " ~ kind);
    auto held = newestBySubject(kindRecords);
    auto declaredHere = declaredFor(kind);

    if (name.length > 0) {
        if (by.length > 0 || prefix.length > 0)
            return refused("invalid", by.length > 0 ? "by" : "prefix", "by and prefix are for a whole kind, and a name was named");
        Record r;
        if (auto got = name in held) r = *got;

        if (field.length > 0) {
            auto f = declared(kind, field);
            if (f is null) return refused("not one of", "field", "no such field for " ~ kind ~ ": " ~ field);
            auto v = attribute(r, field);
            auto row = `{"field":` ~ q(field) ~ `,"type":` ~ q(f.type) ~ `,"observed":` ~ (v is null ? "false" : "true") ~
                `,"value":` ~ (v is null ? "null" : q(v)) ~ `}`;
            return answered(kind, [row], v is null ? 0 : 1, 1);
        }

        string[] rows;
        size_t observed;
        foreach (ref f; declaredHere) {
            if (attribute(r, f.path) !is null) { observed++; continue; }
            rows ~= `{"field":` ~ q(f.path) ~ `,"type":` ~ q(f.type) ~ `}`;
        }
        return answered(kind, rows, observed, declaredHere.length);
    }

    if (field.length > 0) return refused("invalid", "field", "a field is read of one subject: name one");

    if (by == "subject") {
        if (prefix.length > 0) return refused("invalid", "prefix", "prefix is for by field");
        import std.algorithm : sort;
        auto names = held.keys;
        names.sort();
        string[] rows;
        size_t observed;
        foreach (s; names) {
            size_t n;
            foreach (ref f; declaredHere) if (attribute(held[s], f.path) !is null) n++;
            observed += n;
            rows ~= `{"subject":` ~ q(s) ~ `,"observed":` ~ num(n) ~ `,"of":` ~ num(declaredHere.length) ~ `}`;
        }
        return answered(kind, rows, observed, names.length * declaredHere.length);
    }

    if (by == "field") {
        struct Row { string path; string type; size_t n; }
        Row[] counted;
        foreach (ref f; declaredHere) {
            if (!under(f.path, prefix)) continue;
            size_t n;
            foreach (ref r; held) if (attribute(r, f.path) !is null) n++;
            counted ~= Row(f.path, f.type, n);
        }
        if (counted.length == 0) return refused("not one of", "prefix", "no field under " ~ prefix ~ " for " ~ kind);

        // Fullest first. A field nearly every subject has is a gap worth
        // closing; one almost nobody has may be a field worth deleting.
        import std.algorithm : sort, SwapStrategy;
        counted.sort!((a, b) => a.n > b.n, SwapStrategy.stable);
        string[] rows;
        size_t observed;
        foreach (c; counted) {
            observed += c.n;
            rows ~= `{"field":` ~ q(c.path) ~ `,"type":` ~ q(c.type) ~ `,"subjects":` ~ num(c.n) ~ `}`;
        }
        return answered(kind, rows, observed, counted.length * held.length);
    }

    return refused("missing", "by", "read of a whole kind needs by: subject or field");
}

// ---------------------------------------------------------------------------
// observe: merge one value into what is known of a subject
// ---------------------------------------------------------------------------

/// What to write for one observation, or why not. Only declared fields carry
/// forward: anything else in the record came from a run that is not this one.
Answer observe(string kind, string name, string field, string value, Record[] kindRecords, out string[2][] merged) {
    if (!knownKind(kind)) return refused("not one of", "kind", "no such kind in the schema: " ~ kind);
    auto f = declared(kind, field);
    if (f is null) return refused("not one of", "field", "no such field for " ~ kind ~ ": " ~ field);
    if (f.type == "enum") {
        bool legal;
        foreach (ok; f.values) if (ok == value) { legal = true; break; }
        if (!legal) {
            string list;
            foreach (i, ok; f.values) list ~= (i ? ", " : "") ~ ok;
            return refused("not one of", "value", "not a legal " ~ field ~ " value: " ~ value ~ ". Legal: " ~ list);
        }
    }

    auto held = newestBySubject(kindRecords);
    bool replaced;
    if (auto r = name in held) {
        foreach (kv; r.attributes) {
            if (kv[0] == field) { merged ~= [field, value]; replaced = true; }
            else if (declared(kind, kv[0]) !is null) merged ~= kv;
        }
    }
    if (!replaced) merged ~= [field, value];
    return Answer(200, `{"kind":` ~ q(kind) ~ `,"name":` ~ q(name) ~ `,"field":` ~ q(field) ~ `,"value":` ~ q(value) ~ `}`);
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

/// A sigil's refusal in the shape the node reads (server/plugin_sigils.go).
Answer refused(string why, string param, string says) {
    int status = why == "missing" || why == "invalid" || why == "not one of" ? 400 : 500;
    return Answer(status, `{"why":` ~ q(why) ~ `,"param":` ~ q(param) ~ `,"says":` ~ q(says) ~ `}`);
}

private Answer answered(string kind, string[] rows, size_t observed, size_t of) {
    string body = `{"kind":` ~ q(kind) ~ `,"rows":[`;
    foreach (i, r; rows) body ~= (i ? "," : "") ~ r;
    return Answer(200, body ~ `],"observed":` ~ num(observed) ~ `,"of":` ~ num(of) ~ `}`);
}

private string num(size_t n) {
    import std.conv : to;
    return n.to!string;
}

/// A JSON string, quoted. Control characters below 0x20 are escaped, not dropped.
string q(string s) {
    import std.format : format;
    string out_ = `"`;
    foreach (char c; s) {
        switch (c) {
            case '"': out_ ~= `\"`; break;
            case '\\': out_ ~= `\\`; break;
            case '\n': out_ ~= `\n`; break;
            case '\r': out_ ~= `\r`; break;
            case '\t': out_ ~= `\t`; break;
            default:
                if (c < 0x20) out_ ~= format(`\u%04x`, cast(int)c);
                else out_ ~= c;
        }
    }
    return out_ ~ `"`;
}

// ---------------------------------------------------------------------------
// Tests, against the schema as compiled in
// ---------------------------------------------------------------------------

unittest {
    enum t0 = SINCE_MS + 1000;
    Record[] rs = [
        Record("acme.nl", t0, [["url", "https://acme.nl"], ["cta.form", "true"]]),
        Record("acme.nl", t0 + 1, [["url", "https://acme.nl"], ["cta.form", "false"], ["jsonl.file", "/x"]]),
        Record("beta.nl", t0, [["url", "https://beta.nl"]]),
        Record("old.nl", SINCE_MS - 1, [["url", "https://old.nl"]]),
    ];

    // The newest per subject is the whole picture; older than SINCE is not read.
    auto held = newestBySubject(rs);
    assert(held.length == 2);
    assert(attribute(held["acme.nl"], "cta.form") == "false");

    // One value, and one unobserved.
    auto one = read("competitor", "", "acme.nl", "cta.form", "", rs);
    assert(one.status == 200);
    assert(one.body == `{"kind":"competitor","rows":[{"field":"cta.form","type":"bool","observed":true,"value":"false"}],"observed":1,"of":1}`);
    auto none = read("competitor", "", "beta.nl", "cta.form", "", rs);
    assert(none.body == `{"kind":"competitor","rows":[{"field":"cta.form","type":"bool","observed":false,"value":null}],"observed":0,"of":1}`);

    // A field the schema does not declare is refused by name.
    auto nosuch = read("competitor", "", "acme.nl", "cta.fax", "", rs);
    assert(nosuch.status == 400 && nosuch.body == `{"why":"not one of","param":"field","says":"no such field for competitor: cta.fax"}`);

    // A whole kind needs by.
    assert(read("competitor", "", "", "", "", rs).body == `{"why":"missing","param":"by","says":"read of a whole kind needs by: subject or field"}`);

    // By subject counts per subject; by field counts per field, one subtree.
    auto bySubject = read("competitor", "subject", "", "", "", rs);
    assert(bySubject.status == 200);
    auto byField = read("competitor", "field", "", "", "cta", rs);
    assert(byField.body == `{"kind":"competitor","rows":[{"field":"cta.form","type":"bool","subjects":1},{"field":"cta.phone","type":"string","subjects":0},{"field":"cta.whatsapp","type":"absentOrString","subjects":0}],"observed":1,"of":6}`);
    assert(read("competitor", "field", "", "", "ct", rs).body == `{"why":"not one of","param":"prefix","says":"no field under ct for competitor"}`);

    // Observe carries the declared fields forward and drops the rest.
    string[2][] merged;
    auto seen = observe("competitor", "acme.nl", "cta.phone", "020 123", rs, merged);
    assert(seen.status == 200);
    assert(merged == [["url", "https://acme.nl"], ["cta.form", "false"], ["cta.phone", "020 123"]]);

    // An enum takes only its values, and says which.
    auto bad = observe("competitor", "acme.nl", "login.audience", "everyone", rs, merged);
    assert(bad.status == 400 && bad.body == `{"why":"not one of","param":"value","says":"not a legal login.audience value: everyone. Legal: customer, staff, unclear"}`);

    assert(q("a\"b\\c\nd\x01") == `"a\"b\\c\nd\u0001"`);
}
