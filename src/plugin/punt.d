/// What datapunt answers, over records already read.
/// Nothing here reaches the store: service.d reads, this decides, service.d writes.
module plugin.punt;

import schema : fields, kinds, Field;

/// What kind of statement an observation is.
enum OBSERVED = "datapunt:observed";

/// A value seen in the world that the schema could not hold. It is written
/// down like an observation, because it is one: of where the schema and the
/// subjects disagree.
enum REFUSED = "datapunt:refused";

/// A field a read asked of a subject that the schema does not hold: a question
/// looking for a field. Written down, like a refusal, where the caller acts.
enum WANTED = "datapunt:wanted";

/// 2026-09-12T16:00:00Z, in Unix milliseconds. Older
/// attestations were written in a shape this does not read.
enum long SINCE_MS = 1_789_228_800_000;

struct Record {
    string subject;
    long timestamp; // Unix milliseconds
    string[2][] attributes;
    string[] actors; // who the store says made it: datapunt, and whoever asked
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
Answer read(string kind, string by, string name, string field, string prefix, Record[] kindRecords,
        Record[] refusedRecords = null, Record[] wantedRecords = null) {
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

    // A field of no one subject: its value for every subject, as a column.
    if (field.length > 0) {
        if (by.length > 0 || prefix.length > 0)
            return refused("invalid", by.length > 0 ? "by" : "prefix", "by and prefix are for a whole kind, and a field was named");
        auto f = declared(kind, field);
        if (f is null) return refused("not one of", "field", "no such field for " ~ kind ~ ": " ~ field);
        import std.algorithm : sort;
        auto names = held.keys;
        names.sort();
        string[] rows;
        size_t observed;
        foreach (s; names) {
            auto v = attribute(held[s], field);
            if (v !is null) observed++;
            rows ~= `{"subject":` ~ q(s) ~ `,"observed":` ~ (v is null ? "false" : "true") ~
                `,"value":` ~ (v is null ? "null" : q(v)) ~ `}`;
        }
        return answered(kind, rows, observed, names.length);
    }

    if (by == "token") {
        if (prefix.length > 0) return refused("invalid", "prefix", "prefix is for by field, refused or wanted");
        return byToken(kind, kindRecords, refusedRecords, wantedRecords);
    }
    if (by == "refused") return refusals(kind, prefix, kindRecords);
    if (by == "wanted") return wants(kind, prefix, kindRecords);

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

    return refused("missing", "by", "read of a whole kind needs by: subject, field, token, refused or wanted");
}

// ---------------------------------------------------------------------------
// token: who observed, by the token they asked with
// ---------------------------------------------------------------------------

// "I WANT TO BE ABLE TO SAY AND SEE EASILY WHO ATTESTED WHAT USING DATAPUNT"
// "THIS IS WHAT I WANT, PER TOKEN"

/// Which token an observation was asked for with, and the OAuth client that
/// token was issued through.
struct Provenance {
    string token;
    string client;
}

/// Read off the actors as actorsOf writes them: datapunt, then the token's
/// name, its DID, its client's DID and the person. Before 0.3.5 the node wrote
/// the token's DID ahead of datapunt, and the name still follows datapunt. A
/// name stands only beside a DID: a person signed in has neither, and the
/// first actor after datapunt is then the person.
Provenance provenanceOf(const string[] actors) {
    import std.algorithm : startsWith, countUntil;
    auto at = actors.countUntil(PLUGIN);
    const(string)[] after = at < 0 ? actors : actors[at + 1 .. $];
    string did;
    foreach (a; actors) if (a.startsWith("did:")) { did = a; break; }
    if (did.length == 0) return Provenance(NO_TOKEN, "");
    if (after.length == 0 || after[0].startsWith("did:")) return Provenance(UNNAMED ~ did, "");
    string client;
    if (after.length >= 3 && after[1].startsWith("did:") && after[2].startsWith("did:")) client = after[2];
    return Provenance(after[0], client);
}

private enum PLUGIN = "datapunt";
/// What a person signed in observed, with no token between.
enum NO_TOKEN = "no token";
/// A token whose DID is known and whose name was not said.
enum UNNAMED = "unnamed ";
/// How long one count of a token's days is: a day in UTC.
enum long DAY_MS = 86_400_000;

// "IT CAN MISATTEST AS WELL AND THAT IS ALSO SIGNAL"

/// Every observation of a kind, per token, in the order each first observed:
/// how many, of how many subjects, when first and last, how many on each day
/// anything was observed on, and how often the schema refused it or it asked
/// for a field the schema does not hold. A token that only misattested is a
/// row of its own, with nothing observed.
private Answer byToken(string kind, Record[] records, Record[] refusals, Record[] questions) {
    import std.algorithm : sort, SwapStrategy;
    auto all = records.dup;
    all.sort!((a, b) => a.timestamp < b.timestamp, SwapStrategy.stable);

    struct Row {
        Provenance p;
        size_t n;
        bool[string] subjects;
        long first, last;
        long[] days;
        size_t[] counts;
        size_t refused, wanted;
    }
    Row[] rows;
    size_t total;
    Row* rowOf(Provenance p) {
        foreach (ref x; rows) if (x.p.token == p.token) return &x;
        rows ~= Row(p);
        return &rows[$ - 1];
    }
    foreach (ref r; all) {
        if (r.timestamp < SINCE_MS) continue;
        auto p = provenanceOf(r.actors);
        Row* row = rowOf(p);
        if (row.n == 0) row.first = r.timestamp;
        // A token's client is said once it is known.
        if (row.p.client.length == 0) row.p.client = p.client;
        row.n++;
        total++;
        row.subjects[r.subject] = true;
        row.last = r.timestamp;
        immutable day = r.timestamp - r.timestamp % DAY_MS;
        if (row.days.length == 0 || row.days[$ - 1] != day) { row.days ~= day; row.counts ~= 0; }
        row.counts[$ - 1]++;
    }
    foreach (ref r; refusals) {
        if (r.timestamp < SINCE_MS) continue;
        auto p = provenanceOf(r.actors);
        auto row = rowOf(p);
        if (row.p.client.length == 0) row.p.client = p.client;
        row.refused++;
    }
    foreach (ref r; questions) {
        if (r.timestamp < SINCE_MS) continue;
        auto p = provenanceOf(r.actors);
        auto row = rowOf(p);
        if (row.p.client.length == 0) row.p.client = p.client;
        row.wanted++;
    }

    size_t refusedTotal, wantedTotal;
    string body = `{"kind":` ~ q(kind) ~ `,"rows":[`;
    foreach (i, ref x; rows) {
        string days;
        foreach (j, d; x.days) days ~= (j ? "," : "") ~ "[" ~ num(d) ~ "," ~ num(x.counts[j]) ~ "]";
        body ~= (i ? "," : "") ~ `{"token":` ~ q(x.p.token) ~ `,"client":` ~ (x.p.client.length ? q(x.p.client) : "null") ~
            `,"observed":` ~ num(x.n) ~ `,"subjects":` ~ num(x.subjects.length) ~
            `,"first":` ~ (x.n ? num(x.first) : "null") ~ `,"last":` ~ (x.n ? num(x.last) : "null") ~ `,"days":[` ~ days ~ `]` ~
            `,"refused":` ~ num(x.refused) ~ `,"wanted":` ~ num(x.wanted) ~ `}`;
        refusedTotal += x.refused;
        wantedTotal += x.wanted;
    }
    return Answer(200, body ~ `],"observed":` ~ num(total) ~ `,"of":null,"refused":` ~ num(refusedTotal) ~
        `,"standing":null,"wanted":` ~ num(wantedTotal) ~ `}`);
}

// ---------------------------------------------------------------------------
// refused: where the subjects pushed against the schema
// ---------------------------------------------------------------------------

/// Every refusal of a kind, one row per field and value, most refused first.
/// A row stands while the schema as compiled would still refuse it; one that
/// no longer stands was answered by a change to the schema.
private Answer refusals(string kind, string prefix, Record[] refusedRecords) {
    size_t total;
    auto rows = tally(refusedRecords, prefix, true, total);
    string body = `{"kind":` ~ q(kind) ~ `,"rows":[`;
    size_t standing;
    foreach (i, ref x; rows) {
        Refusal why;
        immutable stands = refuses(kind, x.field, x.value, why);
        if (stands) standing++;
        body ~= (i ? "," : "") ~ `{"field":` ~ q(x.field) ~ `,"value":` ~ q(x.value) ~
            `,"says":` ~ q(x.says) ~ `,"times":` ~ num(x.times) ~
            `,"subjects":` ~ num(x.subjects.length) ~ `,"last":` ~ num(x.last) ~ `,"stands":` ~ (stands ? "true" : "false") ~
            `,"tokens":` ~ names(x.tokens) ~ `}`;
    }
    return Answer(200, body ~ `],"observed":null,"of":null,"refused":` ~ num(total) ~ `,"standing":` ~ num(standing) ~ `,"wanted":null}`);
}

/// Every field a read of a kind asked for and the schema did not hold, most
/// wanted first. A row stands while the kind still lacks the field.
private Answer wants(string kind, string prefix, Record[] wantedRecords) {
    size_t total;
    auto rows = tally(wantedRecords, prefix, false, total);
    string body = `{"kind":` ~ q(kind) ~ `,"rows":[`;
    size_t standing;
    foreach (i, ref x; rows) {
        immutable stands = declared(kind, x.field) is null;
        if (stands) standing++;
        body ~= (i ? "," : "") ~ `{"field":` ~ q(x.field) ~ `,"says":` ~ q(x.says) ~ `,"times":` ~ num(x.times) ~
            `,"subjects":` ~ num(x.subjects.length) ~ `,"last":` ~ num(x.last) ~ `,"stands":` ~ (stands ? "true" : "false") ~
            `,"tokens":` ~ names(x.tokens) ~ `}`;
    }
    return Answer(200, body ~ `],"observed":null,"of":null,"refused":null,"standing":` ~ num(standing) ~ `,"wanted":` ~ num(total) ~ `}`);
}

/// What a read of one subject wanted that the schema does not hold, to be
/// written down; nothing when it asked for what the schema holds. Judged by
/// the rule observe refuses by: only a field the kind lacks is wanted.
string[2][] wanted(string kind, string name, string field) {
    if (name.length == 0 || field.length == 0) return null;
    Refusal why;
    if (!refuses(kind, field, "", why) || why.param != "field") return null;
    return [["field", field], ["says", why.says]];
}

/// Refusals or wants of one field (and value, when byValue), gathered.
private struct Tally {
    string field;
    string value;
    string says;
    size_t times;
    string[] subjects;
    long last;
    // Who misattested it, by the token they asked with, first first.
    string[] tokens;
}

/// The token names, as JSON.
private string names(const string[] tokens) {
    string out_ = "[";
    foreach (i, t; tokens) out_ ~= (i ? "," : "") ~ q(t);
    return out_ ~ "]";
}

/// Gathers records under a prefix into one tally per field, or per field and
/// value, most first. The newest says what the row says.
private Tally[] tally(Record[] records, string prefix, bool byValue, out size_t total) {
    Tally[] rows;
    foreach (ref r; records) {
        if (r.timestamp < SINCE_MS) continue;
        auto field = attribute(r, "field"), value = byValue ? attribute(r, "value") : null;
        if (field is null || !under(field, prefix)) continue;
        total++;
        Tally* row;
        foreach (ref x; rows) if (x.field == field && x.value == value) { row = &x; break; }
        if (row is null) { rows ~= Tally(field, value); row = &rows[$ - 1]; }
        row.times++;
        bool seen;
        foreach (s; row.subjects) if (s == r.subject) { seen = true; break; }
        if (!seen) row.subjects ~= r.subject;
        immutable token = provenanceOf(r.actors).token;
        bool told;
        foreach (t; row.tokens) if (t == token) { told = true; break; }
        if (!told) row.tokens ~= token;
        if (r.timestamp >= row.last) { row.last = r.timestamp; row.says = attribute(r, "says"); }
    }
    import std.algorithm : sort, SwapStrategy;
    rows.sort!((a, b) => a.times > b.times, SwapStrategy.stable);
    return rows;
}

/// Why the schema would not hold a value, in the parts refused() answers with.
struct Refusal {
    string why;
    string param;
    string says;
}

/// Whether the schema as compiled refuses this value for this field, and why.
/// The one check observe makes, so that a refusal read back is judged by the
/// same rule that made it.
bool refuses(string kind, string field, string value, out Refusal why) {
    if (!knownKind(kind)) { why = Refusal("not one of", "kind", "no such kind in the schema: " ~ kind); return true; }
    auto f = declared(kind, field);
    if (f is null) { why = Refusal("not one of", "field", "no such field for " ~ kind ~ ": " ~ field); return true; }
    if (f.type != "enum") return false;
    foreach (ok; f.values) if (ok == value) return false;
    string list;
    foreach (i, ok; f.values) list ~= (i ? ", " : "") ~ ok;
    why = Refusal("not one of", "value", "not a legal " ~ field ~ " value: " ~ value ~ ". Legal: " ~ list);
    return true;
}

// ---------------------------------------------------------------------------
// observe: merge one value into what is known of a subject
// ---------------------------------------------------------------------------

/// What to write for one observation, or why not. Only declared fields carry
/// forward: anything else in the record came from a run that is not this one.
///
/// A field or value the schema refuses is still something seen, so a refusal
/// hands back what to write for it as well. A kind the schema does not know is
/// not: there is no kind to file it under, and it is a slip more often than a
/// sighting.
Answer observe(string kind, string name, string field, string value, Record[] kindRecords,
        out string[2][] merged, out string[2][] refusal) {
    Refusal why;
    if (refuses(kind, field, value, why)) {
        if (why.param != "kind") refusal = [["field", field], ["value", value], ["param", why.param], ["says", why.says]];
        return refused(why.why, why.param, why.says);
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

// The node holds an answer to exactly what read says it gives
// (server/sigil/sigil.go, Holds): every field, and none besides. A read of
// coverage has no refusals or questions in it, and a read of those has no
// coverage, so what a read was not asked is null: not zero, which would be a
// count.
private Answer answered(string kind, string[] rows, size_t observed, size_t of) {
    string body = `{"kind":` ~ q(kind) ~ `,"rows":[`;
    foreach (i, r; rows) body ~= (i ? "," : "") ~ r;
    return Answer(200, body ~ `],"observed":` ~ num(observed) ~ `,"of":` ~ num(of) ~ `,"refused":null,"standing":null,"wanted":null}`);
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
        Record("acme.nl", t0 + 1, [["url", "https://acme.nl"], ["cta.form", "false"], ["cta.fax", "020 999"]]),
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
    assert(one.body == `{"kind":"competitor","rows":[{"field":"cta.form","type":"bool","observed":true,"value":"false"}],"observed":1,"of":1,"refused":null,"standing":null,"wanted":null}`);
    auto none = read("competitor", "", "beta.nl", "cta.form", "", rs);
    assert(none.body == `{"kind":"competitor","rows":[{"field":"cta.form","type":"bool","observed":false,"value":null}],"observed":0,"of":1,"refused":null,"standing":null,"wanted":null}`);

    // A field the schema does not declare is refused by name.
    auto nosuch = read("competitor", "", "acme.nl", "cta.fax", "", rs);
    assert(nosuch.status == 400 && nosuch.body == `{"why":"not one of","param":"field","says":"no such field for competitor: cta.fax"}`);

    // A field of no one subject is its value for every subject, sorted by name.
    auto column = read("competitor", "", "", "cta.form", "", rs);
    assert(column.body == `{"kind":"competitor","rows":[` ~
        `{"subject":"acme.nl","observed":true,"value":"false"},` ~
        `{"subject":"beta.nl","observed":false,"value":null}` ~
        `],"observed":1,"of":2,"refused":null,"standing":null,"wanted":null}`);
    assert(read("competitor", "", "", "cta.fax", "", rs).body == `{"why":"not one of","param":"field","says":"no such field for competitor: cta.fax"}`);
    assert(read("competitor", "subject", "", "cta.form", "", rs).body == `{"why":"invalid","param":"by","says":"by and prefix are for a whole kind, and a field was named"}`);

    // A whole kind needs by.
    assert(read("competitor", "", "", "", "", rs).body == `{"why":"missing","param":"by","says":"read of a whole kind needs by: subject, field, token, refused or wanted"}`);

    // By subject counts per subject; by field counts per field, one subtree.
    auto bySubject = read("competitor", "subject", "", "", "", rs);
    assert(bySubject.status == 200);
    auto byField = read("competitor", "field", "", "", "cta", rs);
    assert(byField.body == `{"kind":"competitor","rows":[{"field":"cta.form","type":"bool","subjects":1},{"field":"cta.phone","type":"string","subjects":0},{"field":"cta.whatsapp","type":"absentOrString","subjects":0}],"observed":1,"of":6,"refused":null,"standing":null,"wanted":null}`);
    assert(read("competitor", "field", "", "", "ct", rs).body == `{"why":"not one of","param":"prefix","says":"no field under ct for competitor"}`);

    // Observe carries the declared fields forward and drops the rest.
    string[2][] merged, refusal;
    auto seen = observe("competitor", "acme.nl", "cta.phone", "020 123", rs, merged, refusal);
    assert(seen.status == 200);
    assert(merged == [["url", "https://acme.nl"], ["cta.form", "false"], ["cta.phone", "020 123"]]);
    assert(refusal.length == 0);

    // An enum takes only its values, and says which.
    auto bad = observe("competitor", "acme.nl", "login.audience", "everyone", rs, merged, refusal);
    assert(bad.status == 400 && bad.body == `{"why":"not one of","param":"value","says":"not a legal login.audience value: everyone. Legal: customer, staff, unclear"}`);

    // What was refused is handed back to be written, and nothing to observe.
    assert(merged.length == 0);
    assert(refusal == [["field", "login.audience"], ["value", "everyone"], ["param", "value"],
        ["says", "not a legal login.audience value: everyone. Legal: customer, staff, unclear"]]);
    observe("competitor", "acme.nl", "cta.fax", "020 999", rs, merged, refusal);
    assert(refusal[2] == ["param", "field"]);

    // A kind the schema does not know is refused, and not written down.
    assert(observe("vendor", "acme.nl", "url", "x", rs, merged, refusal).status == 400);
    assert(refusal.length == 0);

    // Refusals read back per field and value, most refused first. A row stands
    // while the schema would still refuse it: `cta.form` is declared and not an
    // enum, so a refusal of it no longer stands.
    Record[] refusals_ = [
        Record("acme.nl", t0, [["field", "login.audience"], ["value", "everyone"], ["says", "old"]]),
        Record("beta.nl", t0 + 2, [["field", "login.audience"], ["value", "everyone"], ["says", "new"]]),
        Record("acme.nl", t0 + 1, [["field", "cta.fax"], ["value", "020 999"], ["says", "no fax"]]),
        Record("acme.nl", t0 + 3, [["field", "cta.form"], ["value", "yes"], ["says", "once"]]),
        Record("old.nl", SINCE_MS - 1, [["field", "cta.fax"], ["value", "1"]]),
    ];
    // An empty value refused reads back as the empty text it was.
    auto empty = read("competitor", "refused", "", "", "login",
        [Record("acme.nl", t0, [["field", "login.audience"], ["value", null], ["says", "empty"]])]);
    assert(empty.body == `{"kind":"competitor","rows":[{"field":"login.audience","value":"","says":"empty","times":1,"subjects":1,"last":` ~
        num(t0) ~ `,"stands":true,"tokens":["no token"]}],"observed":null,"of":null,"refused":1,"standing":1,"wanted":null}`);
    auto byRefused = read("competitor", "refused", "", "", "", refusals_);
    assert(byRefused.status == 200);
    assert(byRefused.body == `{"kind":"competitor","rows":[` ~
        `{"field":"login.audience","value":"everyone","says":"new","times":2,"subjects":2,"last":` ~ num(t0 + 2) ~ `,"stands":true,"tokens":["no token"]},` ~
        `{"field":"cta.fax","value":"020 999","says":"no fax","times":1,"subjects":1,"last":` ~ num(t0 + 1) ~ `,"stands":true,"tokens":["no token"]},` ~
        `{"field":"cta.form","value":"yes","says":"once","times":1,"subjects":1,"last":` ~ num(t0 + 3) ~ `,"stands":false,"tokens":["no token"]}` ~
        `],"observed":null,"of":null,"refused":4,"standing":2,"wanted":null}`);
    auto ctaRefused = read("competitor", "refused", "", "", "cta", refusals_);
    assert(ctaRefused.body == `{"kind":"competitor","rows":[` ~
        `{"field":"cta.fax","value":"020 999","says":"no fax","times":1,"subjects":1,"last":` ~ num(t0 + 1) ~ `,"stands":true,"tokens":["no token"]},` ~
        `{"field":"cta.form","value":"yes","says":"once","times":1,"subjects":1,"last":` ~ num(t0 + 3) ~ `,"stands":false,"tokens":["no token"]}` ~
        `],"observed":null,"of":null,"refused":2,"standing":1,"wanted":null}`);
    assert(read("competitor", "refused", "", "", "", []).body == `{"kind":"competitor","rows":[],"observed":null,"of":null,"refused":0,"standing":0,"wanted":null}`);

    assert(q("a\"b\\c\nd\x01") == `"a\"b\\c\nd\u0001"`);
}

// Who observed: the token each observation was asked with, as the store holds
// the actors that wrote it.
unittest {
    // A connector's token: its name, its DID, its client, and the person.
    assert(provenanceOf(["datapunt", "ManusClean", "did:key:ztoken", "did:key:zclient", "apple:001"]) ==
        Provenance("ManusClean", "did:key:zclient"));
    // A token with no client.
    assert(provenanceOf(["datapunt", "a-script", "did:key:z6", "https://id"]) == Provenance("a-script", ""));
    // Before 0.3.5: the token's DID ahead of datapunt, its name after.
    assert(provenanceOf(["did:key:zcc", "datapunt", "claude-code_2-1-273_agent", "remote_mobile:e3"]) ==
        Provenance("claude-code_2-1-273_agent", ""));
    // A DID and no name.
    assert(provenanceOf(["datapunt", "did:key:zbare"]) == Provenance("unnamed did:key:zbare", ""));
    // A person signed in, with no token.
    assert(provenanceOf(["datapunt", "apple:001"]) == Provenance("no token", ""));
    assert(provenanceOf(["datapunt"]) == Provenance("no token", ""));

    // Counted per UTC day: the same day twice is one count of two, the next day another.
    enum t0 = SINCE_MS - SINCE_MS % DAY_MS + DAY_MS;
    Record[] rs = [
        Record("b.nl", t0 + DAY_MS, [["url", "b"]], ["datapunt", "ManusClean", "did:key:zt", "did:key:zc", "apple:1"]),
        Record("a.nl", t0, [["url", "a"]], ["datapunt", "apple:1"]),
        Record("a.nl", t0 + DAY_MS - 1, [["url", "a"]], ["datapunt", "apple:1"]),
        Record("c.nl", t0 + 2 * DAY_MS + 5, [["url", "c"]], ["datapunt", "ManusClean", "did:key:zt", "did:key:zc", "apple:1"]),
        Record("old.nl", SINCE_MS - 1, [["url", "o"]], ["datapunt", "apple:1"]),
    ];
    // What the schema refused and what was asked of it, by who misattested it.
    // A token that only misattested is a row with nothing observed.
    Record[] refusals = [
        Record("b.nl", t0 + DAY_MS + 1, [["field", "cta.fax"], ["value", "1"], ["says", "no fax"]], ["datapunt", "ManusClean", "did:key:zt", "did:key:zc", "apple:1"]),
        Record("x.nl", t0 + 7, [["field", "cta.fax"], ["value", "2"], ["says", "no fax"]], ["datapunt", "claude.ai-default", "did:key:zd", "did:key:ze", "apple:1"]),
    ];
    Record[] questions = [
        Record("b.nl", t0 + DAY_MS + 2, [["field", "cta.fax"]], ["datapunt", "ManusClean", "did:key:zt", "did:key:zc", "apple:1"]),
    ];
    assert(read("competitor", "token", "", "", "", rs, refusals, questions).body == `{"kind":"competitor","rows":[` ~
        `{"token":"no token","client":null,"observed":2,"subjects":1,"first":` ~ num(t0) ~ `,"last":` ~ num(t0 + DAY_MS - 1) ~
            `,"days":[[` ~ num(t0) ~ `,2]],"refused":0,"wanted":0},` ~
        `{"token":"ManusClean","client":"did:key:zc","observed":2,"subjects":2,"first":` ~ num(t0 + DAY_MS) ~
            `,"last":` ~ num(t0 + 2 * DAY_MS + 5) ~ `,"days":[[` ~ num(t0 + DAY_MS) ~ `,1],[` ~ num(t0 + 2 * DAY_MS) ~ `,1]]` ~
            `,"refused":1,"wanted":1},` ~
        `{"token":"claude.ai-default","client":"did:key:ze","observed":0,"subjects":0,"first":null,"last":null,"days":[]` ~
            `,"refused":1,"wanted":0}` ~
        `],"observed":4,"of":null,"refused":2,"standing":null,"wanted":1}`);
    assert(read("competitor", "token", "", "", "cta", rs).status == 400);

    // A refusal names every token that made it, first first.
    assert(read("competitor", "refused", "", "", "", refusals).body == `{"kind":"competitor","rows":[` ~
        `{"field":"cta.fax","value":"1","says":"no fax","times":1,"subjects":1,"last":` ~ num(t0 + DAY_MS + 1) ~
            `,"stands":true,"tokens":["ManusClean"]},` ~
        `{"field":"cta.fax","value":"2","says":"no fax","times":1,"subjects":1,"last":` ~ num(t0 + 7) ~
            `,"stands":true,"tokens":["claude.ai-default"]}` ~
        `],"observed":null,"of":null,"refused":2,"standing":2,"wanted":null}`);
}

// A read that asks for a field the schema does not hold is a question looking
// for a field, and is written down as one.
unittest {
    // One subject, a field not declared: what was wanted, and why not.
    assert(wanted("competitor", "acme.nl", "cta.fax") ==
        [["field", "cta.fax"], ["says", "no such field for competitor: cta.fax"]]);

    // Not a question looking for a field: a kind the schema does not know, a
    // read of no one subject, or of no field.
    assert(wanted("vendor", "acme.nl", "cta.fax").length == 0);
    assert(wanted("competitor", "", "cta.fax").length == 0);
    assert(wanted("competitor", "acme.nl", "").length == 0);

    // A field the schema holds is answered, observed or not: nothing wanted.
    assert(wanted("competitor", "beta.nl", "cta.form").length == 0);
    assert(wanted("competitor", "beta.nl", "login.audience").length == 0);

    // Read back per field, most wanted first. A row stands while the kind
    // still lacks the field; `cta.form` it has.
    enum t0 = SINCE_MS + 1000;
    Record[] asked = [
        Record("acme.nl", t0, [["field", "cta.fax"], ["says", "a"]]),
        Record("acme.nl", t0 + 3, [["field", "cta.form"], ["says", "d"]]),
        Record("beta.nl", t0 + 2, [["field", "cta.fax"], ["says", "b"]]),
        Record("acme.nl", t0 + 1, [["field", "cta.fax"], ["says", "c"]]),
        Record("old.nl", SINCE_MS - 1, [["field", "cta.fax"], ["says", "old"]]),
    ];
    assert(read("competitor", "wanted", "", "", "", asked).body == `{"kind":"competitor","rows":[` ~
        `{"field":"cta.fax","says":"b","times":3,"subjects":2,"last":` ~ num(t0 + 2) ~ `,"stands":true,"tokens":["no token"]},` ~
        `{"field":"cta.form","says":"d","times":1,"subjects":1,"last":` ~ num(t0 + 3) ~ `,"stands":false,"tokens":["no token"]}` ~
        `],"observed":null,"of":null,"refused":null,"standing":1,"wanted":4}`);
    assert(read("competitor", "wanted", "", "", "login", asked).body == `{"kind":"competitor","rows":[],"observed":null,"of":null,"refused":null,"standing":0,"wanted":0}`);
}
