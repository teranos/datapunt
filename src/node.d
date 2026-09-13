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

// Empty when this environment carries the credential somewhere the process
// cannot read — an egress proxy that authenticates on the way out. Guessing a
// token would be worse than sending none, so send none and let the node answer.
private string token() {
    immutable env = environment.get("QNTX_TOKEN", "");
    if (env.length > 0) return env;
    immutable path = environment.get("HOME", "") ~ "/.qntx/token";
    if (!exists(path)) return "";
    return readText(path).strip();
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
enum OBSERVED = "observed";

import records : SINCE, Pair;

// ubyte, not char: the char instantiation transcodes the body out of whatever
// charset Content-Type names, and the node names none.
private string body_(string url) {
    auto http = authed();
    return cast(string) get!(HTTP, ubyte)(url, http);
}

// The kind is the context, so one query returns the whole kind.
string fetchKind(string kind) {
    return body_(
        nodeUrl() ~ "/api/attestations?context=" ~ kind ~ "&since=" ~ SINCE ~ "&limit=5000");
}

string fetchSubject(string subject) {
    return body_(nodeUrl() ~ "/api/attestations?subject=" ~ subject ~ "&since=" ~ SINCE);
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
// `prov` is what the transcript row says about this run. It is written last so
// the run that wrote the record is the run the record names, rather than one
// carried forward from the record this one supersedes.
string write(string subject, string kind, string predicate, string[2][] fields, Pair[] prov) {
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
    immutable body_ =
        `{"subjects":["` ~ escape(subject) ~ `"],` ~
        `"contexts":["` ~ escape(kind) ~ `"],` ~
        `"predicates":["` ~ escape(predicate) ~ `"],` ~
        `"actors":[` ~ actors() ~ `],` ~
        `"source":"datapunt",` ~
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
