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

private string token() {
    immutable env = environment.get("QNTX_TOKEN", "");
    if (env.length > 0) return env;
    immutable path = environment.get("HOME", "") ~ "/.qntx/token";
    if (!exists(path)) throw new Exception("no token: set QNTX_TOKEN or write ~/.qntx/token");
    return readText(path).strip();
}

private string nodeUrl() {
    return environment.get("QNTX_NODE", "https://api.q.sbvh.nl");
}

private HTTP authed() {
    auto http = HTTP();
    http.addRequestHeader("authorization", "Bearer " ~ token());
    return http;
}

// What kind of statement this is. The fields it carries are in attributes; the
// kind of thing it is about is the context.
enum OBSERVED = "observed";

import records : SINCE;

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

// One attestation per subject. A write carries every field known so far, so
// the newest record is the whole picture and supersedes the one before it.
string write(string subject, string kind, string predicate, string[2][] fields) {
    auto http = authed();
    http.addRequestHeader("content-type", "application/json");
    string attrs;
    foreach (i, kv; fields) {
        if (i) attrs ~= ",";
        attrs ~= `"` ~ escape(kv[0]) ~ `":"` ~ escape(kv[1]) ~ `"`;
    }
    immutable body_ =
        `{"subjects":["` ~ escape(subject) ~ `"],` ~
        `"contexts":["` ~ escape(kind) ~ `"],` ~
        `"predicates":["` ~ escape(predicate) ~ `"],` ~
        `"actors":["datapunt"],` ~
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
