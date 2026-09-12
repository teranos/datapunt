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

// A subject is whatever the caller names. A bare name with no kind in front of
// it is a competitor, because that is what the schema currently describes.
string subjectOf(string name) {
    foreach (c; name) if (c == ':') return name;
    return "competitor:" ~ name;
}

string predicateOf(string field) { return "datapunt:" ~ field; }

string fetchSubject(string slug) {
    auto http = authed();
    return cast(string) get(nodeUrl() ~ "/api/attestations?subject=" ~ subjectOf(slug), http);
}

string write(string slug, string field, string value, string source, string seen) {
    auto http = authed();
    http.addRequestHeader("content-type", "application/json");
    immutable body_ =
        `{"subjects":["` ~ escape(subjectOf(slug)) ~ `"],` ~
        `"predicates":["` ~ escape(predicateOf(field)) ~ `"],` ~
        `"contexts":["datapunt","competitors"],` ~
        `"attributes":{` ~
            `"value":"` ~ escape(value) ~ `",` ~
            `"source":"` ~ escape(source) ~ `",` ~
            `"seen":"` ~ escape(seen) ~ `"}}`;
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
