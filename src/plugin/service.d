/// qntx-datapunt-plugin: datapunt as a QNTX plugin (CDR-025).
module plugin.service;

// "I WANT THIS DATA TO LIVE IN QNTX OBVIOUSLY"

// The node serves the sigils this hands it at Initialize; this answers them.

import plugin.grpc;
import plugin.proto;
import plugin.log;
import plugin.ats : Store, readKind, write;
import plugin.punt;

enum PLUGIN_NAME = "datapunt";

// "datapunt needs to be rebuilt and rereleased on any schema change"

// The schema is compiled in, so it is part of the version: a changed schema is
// a version the release workflow has not published yet.
enum PLUGIN_VERSION = "0.1.0-" ~ schemaDigest(import(".ctfe/schema.json"));

/// FNV-1a, 64 bits, as 16 hex digits. Computed by the compiler.
string schemaDigest(string schema) {
    ulong h = 0xcbf29ce484222325;
    foreach (char c; schema) {
        h ^= c;
        h *= 0x100000001b3;
    }
    enum hex = "0123456789abcdef";
    char[16] out_;
    foreach (i; 0 .. 16) out_[15 - i] = hex[(h >> (i * 4)) & 0xf];
    return out_.idup;
}

// Who is asking, as the node admitted them (server/plugin_sigils.go).
enum HEADER_ASKER = "x-qntx-asker";
enum HEADER_ASKER_DID = "x-qntx-asker-did";

private __gshared Store store;

void registerHandlers(ref GrpcServer server) {
    server.registerHandler("/protocol.DomainPluginService/Metadata", (const ubyte[] _) {
        MetadataResponse m;
        m.name = PLUGIN_NAME;
        m.version_ = PLUGIN_VERSION;
        m.qntxVersion = ">= 0.1.0";
        m.description = "The competitor data. The schema is compiled in; the observations live in QNTX";
        m.author = "sbvh-nl";
        return encode(m);
    });

    server.registerHandler("/protocol.DomainPluginService/Initialize", (const ubyte[] data) {
        auto req = decode!InitializeRequest(data);
        store = Store(req.atsStoreEndpoint, req.authToken);
        logInfo("[datapunt] Initialize: ats=%s token=%dB", req.atsStoreEndpoint, req.authToken.length);
        InitializeResponse resp;
        resp.signa = [signum()];
        return encode(resp);
    });

    server.registerHandler("/protocol.DomainPluginService/Health", (const ubyte[] _) {
        HealthResponse h;
        h.healthy = store.endpoint.length > 0;
        h.message = h.healthy ? "datapunt " ~ PLUGIN_VERSION : "not initialized: no ATSStore endpoint";
        h.details["version"] = PLUGIN_VERSION;
        h.details["ats"] = store.endpoint.length > 0 ? store.endpoint : "unset";
        return encode(h);
    });

    server.registerHandler("/protocol.DomainPluginService/HandleHTTP", (const ubyte[] data) {
        auto req = decode!HTTPRequest(data);
        auto a = handleHTTP(req);
        HTTPResponse resp;
        resp.statusCode = a.status;
        resp.body_ = cast(ubyte[])a.body.dup;
        HTTPHeader ct;
        ct.name = "Content-Type";
        ct.values = ["application/json"];
        resp.headers = [ct];
        return encode(resp);
    });

    server.registerHandler("/protocol.DomainPluginService/Shutdown", (const ubyte[] _) => encode(Empty()));
    server.registerHandler("/protocol.DomainPluginService/ConfigSchema", (const ubyte[] _) => encode(Empty()));
    server.registerHandler("/protocol.DomainPluginService/RegisterElements", (const ubyte[] _) => encode(Empty()));
    server.registerHandler("/protocol.DomainPluginService/ExecuteJob", (const ubyte[] _) {
        ExecuteJobResponse r;
        r.error = "datapunt declares no handlers";
        return encode(r);
    });
}

/// What datapunt does, as the node serves it (ADR-039).
Signum signum() {
    auto kind = Param("kind", "The kind of subject.", true, kindNames());
    Signum s;
    s.name = PLUGIN_NAME;
    s.sigils = [
        Sigil("read",
            "What is observed. Name a subject for what is unobserved of it, and a field for its value; name no subject and say by subject or by field for coverage across the kind.",
            [
                kind,
                Param("by", "For a whole kind: coverage per subject, or per field, fullest first.", false, ["subject", "field"]),
                Param("name", "One subject, by its name."),
                Param("field", "One field of that subject, by its dotted path.", false, fieldPaths()),
                Param("prefix", "With by field: one subtree, as the schema nests it."),
            ],
            [
                Field("kind", "The kind that was read."),
                Field("rows", "One row per subject, per field, or the one value, as asked."),
                Field("observed", "How many of the cells asked about are observed."),
                Field("of", "How many cells were asked about."),
            ],
            Endpoint("GET", "/api/datapunt/read")),
        Sigil("observe",
            "Write down one value seen for one field of one subject. Only a value verified by looking is written; a field looked for and not found is false.",
            [
                kind,
                Param("name", "The subject, by its name.", true),
                Param("field", "The field, by its dotted path.", true, fieldPaths()),
                Param("value", "What was seen, as text.", true),
            ],
            [
                Field("kind", "The kind written."),
                Field("name", "The subject written."),
                Field("field", "The field written."),
                Field("value", "The value written."),
            ],
            Endpoint("POST", "/api/datapunt/observe")),
    ];
    return s;
}

// What a sigil hands this: the path below /api/datapunt, a query for a GET, a JSON object of text for a POST.
Answer handleHTTP(ref const HTTPRequest req) {
    string path = req.path;
    string query;
    foreach (i, c; path) if (c == '?') { query = path[i + 1 .. $]; path = path[0 .. i]; break; }

    if (req.method == "GET" && path == "/read") {
        auto sent = parseQuery(query);
        Record[] records;
        if (auto why = readKind(store, sent.get("kind", ""), records)) return failed(why);
        return read(sent.get("kind", ""), sent.get("by", ""), sent.get("name", ""),
            sent.get("field", ""), sent.get("prefix", ""), records);
    }

    if (req.method == "POST" && path == "/observe") {
        string[string] sent;
        if (auto why = parseBody(cast(string)req.body_, sent)) return refused("invalid", "", why);
        auto kind = sent.get("kind", ""), name = sent.get("name", "");
        auto field = sent.get("field", ""), value = sent.get("value", "");
        if (name.length == 0) return refused("missing", "name", "observe needs name");

        Record[] records;
        if (auto why = readKind(store, kind, records)) return failed(why);
        string[2][] merged;
        auto a = observe(kind, name, field, value, records, merged);
        if (a.status != 200) return a;
        if (auto why = write(store, name, kind, merged, actorsOf(req))) return failed(why);
        return a;
    }

    return Answer(404, `{"error":"not found: ` ~ req.method ~ ` ` ~ path ~ `"}`);
}

/// datapunt, and whoever the node admitted: the token's own DID when a token
/// asked, the identity that admitted them otherwise. Nobody named is datapunt.
string[] actorsOf(ref const HTTPRequest req) {
    string asker, did;
    foreach (ref h; req.headers) {
        import std.uni : toLower;
        auto name = h.name.toLower;
        if (h.values.length == 0) continue;
        if (name == HEADER_ASKER_DID) did = h.values[0];
        if (name == HEADER_ASKER) asker = h.values[0];
    }
    if (did.length > 0) return [PLUGIN_NAME, did];
    if (asker.length > 0) return [PLUGIN_NAME, asker];
    return [PLUGIN_NAME];
}

// The store would not answer: the node's fault, and the log says what.
private Answer failed(string why) {
    logError("[datapunt] %s", why);
    return refused("failed", "", why);
}

string[string] parseQuery(string query) {
    import std.uri : decodeComponent;
    string[string] out_;
    foreach (pair; splitOn(query, '&')) {
        if (pair.length == 0) continue;
        string k = pair, v;
        foreach (i, c; pair) if (c == '=') { k = pair[0 .. i]; v = pair[i + 1 .. $]; break; }
        out_[decodeComponent(plus(k))] = decodeComponent(plus(v));
    }
    return out_;
}

// A query encodes a space as '+' (Go's url.Values), which decodeComponent leaves.
private string plus(string s) {
    char[] out_;
    foreach (c; s) out_ ~= c == '+' ? ' ' : c;
    return out_.idup;
}

private string[] splitOn(string s, char sep) {
    string[] out_;
    size_t start;
    foreach (i, c; s) if (c == sep) { out_ ~= s[start .. i]; start = i + 1; }
    out_ ~= s[start .. $];
    return out_;
}

/// A JSON object of text, which is how the node sends what a POST sigil took.
/// Null is read; anything else is why not.
string parseBody(string body_, ref string[string] sent) {
    import std.json : parseJSON, JSONType, JSONException;
    try {
        auto j = parseJSON(body_);
        if (j.type != JSONType.object) return "the body is not a JSON object";
        foreach (k, v; j.object) {
            if (v.type != JSONType.string) return k ~ " is not text";
            sent[k] = v.str;
        }
    } catch (JSONException e) {
        return "the body is not JSON: " ~ e.msg;
    }
    return null;
}

unittest {
    auto q = parseQuery("kind=competitor&by=field&prefix=cta&name=a+b%2Fc");
    assert(q["kind"] == "competitor" && q["by"] == "field" && q["prefix"] == "cta" && q["name"] == "a b/c");

    string[string] sent;
    assert(parseBody(`{"kind":"competitor","value":""}`, sent) is null);
    assert(sent["kind"] == "competitor" && sent["value"] == "");
    assert(parseBody(`[1]`, sent) == "the body is not a JSON object");

    HTTPRequest req;
    req.headers = [HTTPHeader("X-Qntx-Asker", ["https://id"]), HTTPHeader("X-Qntx-Asker-Did", ["did:key:z6"])];
    assert(actorsOf(req) == ["datapunt", "did:key:z6"]);
    req.headers = [HTTPHeader("X-Qntx-Asker", ["https://id"])];
    assert(actorsOf(req) == ["datapunt", "https://id"]);
    req.headers = null;
    assert(actorsOf(req) == ["datapunt"]);

    // Any change to the schema is a different version.
    assert(schemaDigest(`{"fields":[]}`) != schemaDigest(`{"fields":[1]}`));
    assert(schemaDigest("").length == 16);

    // The signum names every kind and every field it takes.
    auto s = signum();
    assert(s.name == "datapunt" && s.sigils.length == 2);
    assert(s.sigils[0].takes[0].oneOf == ["competitor"]);
    assert(s.sigils[1].http.path == "/api/datapunt/observe");

    // An unknown path is a 404 that says which.
    HTTPRequest unknown;
    unknown.method = "GET";
    unknown.path = "/nothing";
    assert(handleHTTP(unknown).status == 404);
}
