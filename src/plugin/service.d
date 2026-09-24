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
enum PLUGIN_VERSION = "0.2.0-" ~ schemaDigest(import(".ctfe/schema.json"));

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
// What this one call presents to the ATS store: it reaches the namespace the
// caller acts in, and nothing else does.
enum HEADER_STORE_TOKEN = "x-qntx-store-token";

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
            "What is observed. Name a subject for what is unobserved of it, and a field for its value; name no subject and say by subject or by field for coverage across the kind, by refused for what the schema would not hold, or by wanted for what was asked of it that it does not hold. Asking one subject for a field the schema does not hold is refused, and the question is written down.",
            [
                kind,
                Param("by", "For a whole kind: coverage per subject, or per field, fullest first; the refusals, per field and value, most refused first; or the fields asked for that the schema does not hold, most wanted first.", false, ["subject", "field", "refused", "wanted"]),
                Param("name", "One subject, by its name."),
                Param("field", "One field of that subject, by its dotted path.", false, fieldPaths()),
                Param("prefix", "With by field, refused or wanted: one subtree, as the schema nests it."),
            ],
            [
                Field("kind", "The kind that was read."),
                Field("rows", "One row per subject, per field, or the one value, as asked."),
                Field("observed", "How many of the cells asked about are observed."),
                Field("of", "How many cells were asked about."),
                Field("refused", "By refused: how many refusals were read."),
                Field("standing", "By refused or wanted: how many rows the schema as compiled would still refuse."),
                Field("wanted", "By wanted: how many questions were read."),
            ],
            Endpoint("GET", "/api/datapunt/read")),
        Sigil("observe",
            "Write down one value seen for one field of one subject. Only a value verified by looking is written; a field looked for and not found is false. A field or value the schema does not hold is refused, and the refusal is written down: read by refused.",
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

    Store call;
    if (auto why = callStore(req, call)) return failed(why);

    if (req.method == "GET" && path == "/read") {
        auto sent = parseQuery(query);
        auto kind = sent.get("kind", ""), name = sent.get("name", ""), field = sent.get("field", "");
        Record[] records;
        if (auto why = readKind(call, kind, predicateFor(sent.get("by", "")), records)) return failed(why);
        auto a = read(kind, sent.get("by", ""), name, field, sent.get("prefix", ""), records);
        // The caller is answered either way. A question the store would not
        // keep is the node's fault, and the log says what.
        if (auto w = wantedRecord(kind, name, field))
            if (auto why = write(call, name, kind, WANTED, w, actorsOf(req)))
                logError("[datapunt] the question was not written: %s", why);
        return a;
    }

    if (req.method == "POST" && path == "/observe") {
        string[string] sent;
        if (auto why = parseBody(cast(string)req.body_, sent)) return refused("invalid", "", why);
        auto kind = sent.get("kind", ""), name = sent.get("name", "");
        auto field = sent.get("field", ""), value = sent.get("value", "");
        if (name.length == 0) return refused("missing", "name", "observe needs name");

        Record[] records;
        if (auto why = readKind(call, kind, OBSERVED, records)) return failed(why);
        string[2][] merged, refusal;
        auto a = observe(kind, name, field, value, records, merged, refusal);
        if (a.status != 200) {
            // The caller is answered with the refusal either way. One the store
            // would not keep is the node's fault, and the log says what.
            if (refusal.length > 0) {
                refusal ~= ["schema", PLUGIN_VERSION];
                if (auto why = write(call, name, kind, REFUSED, refusal, actorsOf(req)))
                    logError("[datapunt] the refusal was not written: %s", why);
            }
            return a;
        }
        if (auto why = write(call, name, kind, OBSERVED, merged, actorsOf(req))) return failed(why);
        return a;
    }

    return Answer(404, `{"error":"not found: ` ~ req.method ~ ` ` ~ path ~ `"}`);
}

/// The statements a read of this by is over.
string predicateFor(string by) {
    if (by == "refused") return REFUSED;
    if (by == "wanted") return WANTED;
    return OBSERVED;
}

/// What to write for a read that asked for a field the schema does not hold:
/// what was wanted, and the schema that did not hold it. Nothing otherwise.
string[2][] wantedRecord(string kind, string name, string field) {
    auto w = wanted(kind, name, field);
    if (w.length > 0) w ~= ["schema", PLUGIN_VERSION];
    return w;
}

/// The store this call reaches: the node's, under the token it handed for this
/// call. Null is that store; anything else is why there is none.
string callStore(ref const HTTPRequest req, out Store call) {
    foreach (ref h; req.headers) {
        import std.uni : toLower;
        if (h.name.toLower != HEADER_STORE_TOKEN || h.values.length == 0) continue;
        if (h.values[0].length == 0) break;
        call = Store(store.endpoint, h.values[0]);
        return null;
    }
    return "the node handed no store token for this call, so which namespace the caller acts in is unknown";
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
    assert(s.sigils[0].takes[1].oneOf == ["subject", "field", "refused", "wanted"]);

    // A read goes to the statements its by names.
    assert(predicateFor("") == OBSERVED && predicateFor("subject") == OBSERVED && predicateFor("field") == OBSERVED);
    assert(predicateFor("refused") == REFUSED);
    assert(predicateFor("wanted") == WANTED);

    // A question the schema cannot hold is written with the schema that could not.
    assert(wantedRecord("competitor", "acme.nl", "cta.fax") ==
        [["field", "cta.fax"], ["says", "no such field for competitor: cta.fax"], ["schema", PLUGIN_VERSION]]);
    assert(wantedRecord("competitor", "acme.nl", "cta.form").length == 0);

    // An unknown path is a 404 that says which.
    HTTPRequest unknown;
    unknown.method = "GET";
    unknown.path = "/nothing";
    unknown.headers = [HTTPHeader("X-Qntx-Store-Token", ["call"])];
    assert(handleHTTP(unknown).status == 404);

    // A call reads and writes under the token the node handed for it, at the
    // store Initialize named.
    store = Store("127.0.0.1:9", "shared");
    Store call;
    HTTPRequest handed;
    handed.headers = [HTTPHeader("X-Qntx-Store-Token", ["call"])];
    assert(callStore(handed, call) is null);
    assert(call.endpoint == "127.0.0.1:9" && call.token == "call");

    // A call the node handed no token for is not answered at the shared one.
    handed.headers = null;
    assert(callStore(handed, call) !is null);
    handed.headers = [HTTPHeader("X-Qntx-Store-Token", [""])];
    assert(callStore(handed, call) !is null);
    HTTPRequest bare;
    bare.method = "GET";
    bare.path = "/read?kind=competitor&by=subject";
    assert(handleHTTP(bare).status == 500);
}

// What a call writes, against a store that keeps what it is asked and has
// nothing to give: this plugin's own server, answering as the node's ATSStore.
unittest {
    import core.thread : Thread;
    import std.conv : to;

    struct Wrote {
        string subject;
        string predicate;
        string kind;
        string[2][] attributes;
    }
    Wrote[] wrote;
    string[] readOf;
    bool keeps = true;

    GrpcServer fake;
    fake.registerHandler("/protocol.ATSStoreService/GetAttestations", (const ubyte[] data) {
        readOf ~= decode!GetAttestationsRequest(data).filter.predicates;
        GetAttestationsResponse resp;
        resp.success = true;
        return encode(resp);
    });
    fake.registerHandler("/protocol.ATSStoreService/GenerateAndCreateAttestation", (const ubyte[] data) {
        auto cmd = decode!GenerateAttestationRequest(data).command;
        GenerateAttestationResponse resp;
        resp.success = keeps;
        if (!keeps) {
            resp.error = "full";
            return encode(resp);
        }
        Wrote w = Wrote(cmd.subjects[0], cmd.predicates[0], cmd.contexts[0]);
        foreach (ref e; decode!Struct(cmd.attributes).fields) w.attributes ~= [e.key, e.value.stringValue];
        wrote ~= w;
        return encode(resp);
    });
    immutable port = fake.bind(39217);
    assert(port != 0);
    auto serving = new Thread(() { fake.serve(); });
    serving.isDaemon = true;
    serving.start();
    store = Store("127.0.0.1:" ~ port.to!string, "shared");

    Answer get(string query) {
        HTTPRequest r;
        r.method = "GET";
        r.path = "/read?" ~ query;
        r.headers = [HTTPHeader("X-Qntx-Store-Token", ["call"])];
        return handleHTTP(r);
    }
    Answer post(string body_) {
        HTTPRequest r;
        r.method = "POST";
        r.path = "/observe";
        r.body_ = cast(ubyte[]) body_.dup;
        r.headers = [HTTPHeader("X-Qntx-Store-Token", ["call"])];
        return handleHTTP(r);
    }

    // An observation is written as one.
    assert(post(`{"kind":"competitor","name":"acme.nl","field":"cta.phone","value":"020"}`).status == 200);
    assert(wrote.length == 1 && wrote[0].predicate == OBSERVED);

    // A value the schema will not hold is refused, and the refusal written,
    // with the schema that refused it.
    auto everyone = post(`{"kind":"competitor","name":"acme.nl","field":"login.audience","value":"everyone"}`);
    assert(everyone.status == 400);
    assert(wrote.length == 2);
    assert(wrote[1].predicate == REFUSED && wrote[1].subject == "acme.nl" && wrote[1].kind == "competitor");
    assert(wrote[1].attributes == [["field", "login.audience"], ["value", "everyone"], ["param", "value"],
        ["says", "not a legal login.audience value: everyone. Legal: customer, staff, unclear"], ["schema", PLUGIN_VERSION]]);

    // So is a field the kind does not have.
    assert(post(`{"kind":"competitor","name":"acme.nl","field":"cta.fax","value":"020"}`).status == 400);
    assert(wrote.length == 3 && wrote[2].predicate == REFUSED && wrote[2].attributes[2] == ["param", "field"]);

    // A kind the schema does not know is refused and not written.
    assert(post(`{"kind":"vendor","name":"acme.nl","field":"url","value":"x"}`).status == 400);
    assert(wrote.length == 3);

    // A question the schema cannot hold is refused, and the question written.
    assert(get("kind=competitor&name=acme.nl&field=cta.fax").status == 400);
    assert(wrote.length == 4);
    assert(wrote[3].predicate == WANTED && wrote[3].subject == "acme.nl" && wrote[3].kind == "competitor");
    assert(wrote[3].attributes == [["field", "cta.fax"], ["says", "no such field for competitor: cta.fax"], ["schema", PLUGIN_VERSION]]);

    // One it can hold is answered, and nothing written.
    assert(get("kind=competitor&name=acme.nl&field=cta.form").status == 200);
    assert(wrote.length == 4);

    // Each by reads its own statements.
    readOf = null;
    get("kind=competitor&by=field");
    get("kind=competitor&by=refused");
    get("kind=competitor&by=wanted");
    assert(readOf == [OBSERVED, REFUSED, WANTED]);

    // A store that will not keep a refusal or a question does not change the
    // caller's answer.
    keeps = false;
    assert(post(`{"kind":"competitor","name":"acme.nl","field":"login.audience","value":"everyone"}`) == everyone);
    assert(get("kind=competitor&name=acme.nl&field=cta.fax").status == 400);
    assert(wrote.length == 4);
}
