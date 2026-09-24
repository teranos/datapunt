module node;

import std.net.curl : HTTP, get, post, CurlException;
import std.file : readText, exists;
import std.process : environment;
import std.string : strip;
import std.conv : to;

struct Record {
    string predicate;
    string value;
    string source;
    string seen;
    string timestamp;
}

// clean-datapunt, beside the binary. Never ~/.qntx/token: that is root.
// Empty where an egress proxy holds the credential, so the node answers.
private string token() {
    import std.file : thisExePath;
    import std.path : dirName;
    immutable path = thisExePath().dirName ~ "/.token";
    if (exists(path)) return readText(path).strip();
    return environment.get("QNTX_TOKEN", "");
}

private string nodeUrl() {
    return environment.get("QNTX_NODE", "https://api.q.sbvh.nl");
}

// The 401 is the node's to give. A local check cannot see the whole path the
// request takes, so it cannot be the one that decides the request is hopeless.
private HTTP authed() {
    auto http = HTTP();
    immutable t = token();
    if (t.length > 0) http.addRequestHeader("authorization", "Bearer " ~ t);
    return http;
}

// What kind of statement this is. The fields it carries are in attributes; the
// kind of thing it is about is the context.
// Namespaced, so `source` is free to say where the value was seen rather than
// which tool wrote it.
enum OBSERVED = "datapunt:observed";

// The lane for trying datapunt against a real node without saying anything
// about a real subject: DATAPUNT_TEST=1 reads and writes this instead of
// OBSERVED, and nothing in either lane sees the other.
enum TEST = "datapunt:test";

string predicateFor(string test) {
    return test.length > 0 ? TEST : OBSERVED;
}

// The predicate this run reads and writes.
string lane() {
    return predicateFor(environment.get("DATAPUNT_TEST", ""));
}

// This module has a Record of its own — what a write carries — so the parsed
// row comes in under the name of what it is.
import records : SINCE, Pair, parse, Row = Record;

// ubyte, not char: the char instantiation transcodes the body out of whatever
// charset Content-Type names, and the node names none.
private string body_(string url) {
    auto http = authed();
    return cast(string) get!(HTTP, ubyte)(url, http);
}

// A page and what the node said about it. `more` is the node's own answer to
// whether anything exists past this page; a full page is not that answer.
private struct Page {
    string body;
    bool more;
}

// get() installs its own header handler, so onReceiveHeader never fires here.
// What it leaves on the client is the answer's headers, keyed in lower case.
private Page page_(string url) {
    auto http = authed();
    immutable body = cast(string) get!(HTTP, ubyte)(url, http);
    auto said = "x-qntx-more" in http.responseHeaders;
    if (said is null)
        throw new Exception(
            "the node did not say whether more exists past this page (x-qntx-more): " ~ url);
    return Page(body, *said == "true");
}

// What one page holds. The node caps it here whatever a caller asks for.
enum PAGE = 1000;

private string oldest(Row[] rows) {
    string out_;
    foreach (r; rows)
        if (out_.length == 0 || r.timestamp < out_) out_ = r.timestamp;
    return out_;
}

// A read names its predicate and kind: the node holds refusals, questions and
// the test lane under the same subjects, and the newest of those is not the
// newest observation.
string kindUrl(string node, string kind, string predicate, string until) {
    return node ~ "/api/attestations?context=" ~ kind
        ~ "&predicate=" ~ predicate
        ~ "&since=" ~ SINCE
        ~ (until.length ? "&until=" ~ until : "")
        ~ "&limit=" ~ PAGE.to!string;
}

string subjectUrl(string node, string subject, string kind, string predicate) {
    return node ~ "/api/attestations?subject=" ~ subject ~ "&context=" ~ kind
        ~ "&predicate=" ~ predicate ~ "&since=" ~ SINCE;
}

// A kind is a walk backwards in time: rows come newest-first, each page ends
// at its oldest row, and the next page asks `until` that row. The bound is
// inclusive, so it arrives twice — the same claim read twice is the same claim.
string[] fetchKind(string kind) {
    string[] pages;
    string until;
    while (true) {
        immutable url = kindUrl(nodeUrl(), kind, lane(), until);
        immutable page = page_(url);
        pages ~= page.body;

        // The node says whether anything is past this page. Counting rows was
        // a guess at the same question, and a full page that was the whole of
        // the kind cost one request every time.
        if (!page.more) return pages;

        auto rows = parse(page.body);
        immutable edge = oldest(rows);
        // A full page whose oldest row is the one already asked until cannot
        // move: more rows share that instant than fit in a page, and time is
        // the only handle the node gives.
        if (edge == until)
            throw new Exception(
                "a full page of " ~ PAGE.to!string ~ " rows sits on one timestamp (" ~ edge ~
                "), so paging by time cannot reach past it");
        until = edge;
    }
}

string fetchSubject(string subject, string kind) {
    return body_(subjectUrl(nodeUrl(), subject, kind, lane()));
}

// Who ran this, read rather than claimed: a human at a shell has neither
// variable set, so the absence is the observation.
private string actors() {
    string[] who = ["datapunt"];

    immutable agent = environment.get("AI_AGENT", "");
    if (agent.length > 0) who ~= agent;

    // The surface prefixes the session, because a transcript id only means
    // something alongside where it was typed.
    immutable session = environment.get("CLAUDE_CODE_SESSION_ID", "");
    if (session.length > 0) {
        immutable where = environment.get("CLAUDE_CODE_ENTRYPOINT", "");
        who ~= where.length > 0 ? where ~ ":" ~ session : session;
    }

    string out_;
    foreach (i, a; who) {
        if (i) out_ ~= ",";
        out_ ~= `"` ~ escape(a) ~ `"`;
    }
    return out_;
}

// One attestation per subject. A write carries every field known so far, so
// the newest record is the whole picture and supersedes the one before it.
//
// `prov` is what the row says about this run, written last so the run that
// wrote the record is the run the record names.
string write(string subject, string kind, string predicate, string[2][] fields,
             Pair[] prov, string[] seen) {
    auto http = authed();
    http.addRequestHeader("content-type", "application/json");

    string attrs;
    size_t n;
    void put(string k, string v) {
        if (n++) attrs ~= ",";
        attrs ~= `"` ~ escape(k) ~ `":"` ~ escape(v) ~ `"`;
    }

    foreach (kv; fields) {
        bool superseded;
        foreach (p; prov) if (p.key == kv[0]) { superseded = true; break; }
        if (!superseded) put(kv[0], kv[1]);
    }
    foreach (p; prov) put(p.key, p.value);

    // Every page fetched for this write, not a pick among them.
    string src;
    foreach (i, u; seen) {
        if (i) src ~= " | ";
        src ~= u;
    }

    immutable body_ =
        `{"subjects":["` ~ escape(subject) ~ `"],` ~
        `"contexts":["` ~ escape(kind) ~ `"],` ~
        `"predicates":["` ~ escape(predicate) ~ `"],` ~
        `"actors":[` ~ actors() ~ `],` ~
        `"source":"` ~ escape(src) ~ `",` ~
        `"attributes":{` ~ attrs ~ `}}`;
    return cast(string) post(nodeUrl() ~ "/api/attestations", body_, http);
}

string escape(string s) {
    string out_;
    foreach (c; s) {
        switch (c) {
            case '"': out_ ~= `\"`; break;
            case '\\': out_ ~= `\\`; break;
            case '\n': out_ ~= `\n`; break;
            case '\r': out_ ~= `\r`; break;
            case '\t': out_ ~= `\t`; break;
            default: out_ ~= c;
        }
    }
    return out_;
}

unittest {
    // The lane: datapunt:test when DATAPUNT_TEST says so, the real one otherwise.
    assert(predicateFor("") == OBSERVED);
    assert(predicateFor("1") == TEST);
    assert(TEST == "datapunt:test");

    // A read asks the node for one predicate and one kind, never everything
    // the subject or the kind was ever said with.
    assert(kindUrl("https://n", "competitor", OBSERVED, "") ==
        "https://n/api/attestations?context=competitor&predicate=datapunt:observed&since=" ~ SINCE ~ "&limit=1000");
    assert(kindUrl("https://n", "competitor", TEST, "2026-09-20T00:00:00Z") ==
        "https://n/api/attestations?context=competitor&predicate=datapunt:test&since=" ~ SINCE ~
        "&until=2026-09-20T00:00:00Z&limit=1000");
    assert(subjectUrl("https://n", "acme.nl", "competitor", TEST) ==
        "https://n/api/attestations?subject=acme.nl&context=competitor&predicate=datapunt:test&since=" ~ SINCE);
}
