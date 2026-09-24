/// The node's ATSStore, asked over the endpoint and token Initialize handed.
module plugin.ats;

import plugin.proto;
import plugin.grpc : grpcCall;
import plugin.punt : Record, SINCE_MS;

struct Store {
    string endpoint;
    string token;
}

/// Every statement of one predicate about a kind since SINCE_MS, one call: the
/// node applies no limit when the filter names none (atsstore.proto). Null is
/// the records; anything else is why the store did not give them.
string readKind(Store store, string kind, string predicate, out Record[] records) {
    GetAttestationsRequest req;
    req.authToken = store.token;
    req.filter.predicates = [predicate];
    req.filter.contexts = [kind];
    req.filter.timeStart = SINCE_MS;

    auto called = grpcCall(store.endpoint, "/protocol.ATSStoreService/GetAttestations", encode(req));
    if (called.error !is null) return called.error;
    auto resp = decode!GetAttestationsResponse(called.message);
    if (!resp.success) return "the store refused the read: " ~ resp.error;

    foreach (ref as; resp.attestations) records ~= toRecord(as);
    return null;
}

/// One attestation of a predicate about a subject: for an observation, every
/// field known so far (the newest supersedes); for a refusal, what was refused
/// and why. Null is written; anything else is why it was not.
string write(Store store, string subject, string kind, string predicate, string[2][] attributes, string[] actors) {
    GenerateAttestationRequest req;
    req.authToken = store.token;
    req.command.subjects = [subject];
    req.command.predicates = [predicate];
    req.command.contexts = [kind];
    req.command.actors = actors;
    req.command.attributes = encodeStruct(attributes);
    req.command.source = "datapunt";

    auto called = grpcCall(store.endpoint, "/protocol.ATSStoreService/GenerateAndCreateAttestation", encode(req));
    if (called.error !is null) return called.error;
    auto resp = decode!GenerateAttestationResponse(called.message);
    if (!resp.success) return "the store refused the write: " ~ resp.error;
    return null;
}

Record toRecord(ref const Attestation as) {
    Record r;
    if (as.subjects.length > 0) r.subject = as.subjects[0];
    r.timestamp = as.timestamp;
    foreach (ref entry; as.attributes.fields) r.attributes ~= [entry.key, text(entry.value)];
    return r;
}

// datapunt writes every value as text. A bool or a number was written by
// something else, and is read as the text it would have been.
private string text(ref const Value v) {
    import std.conv : to;
    if (v.stringValue.length > 0) return v.stringValue;
    if (v.boolValue) return "true";
    if (v.numberValue != 0) return v.numberValue.to!string;
    return v.stringValue;
}

/// google.protobuf.Struct of text values. string_value is written even when it
/// is empty, so an empty observation is not read back as nothing.
ubyte[] encodeStruct(string[2][] pairs) {
    ubyte[] out_;
    foreach (kv; pairs) {
        ubyte[] value = encodeTag(3, WireType.LengthDelimited) ~ encodeVarint(kv[1].length) ~ cast(const(ubyte)[])kv[1];
        ubyte[] entry = encodeTag(1, WireType.LengthDelimited) ~ encodeVarint(kv[0].length) ~ cast(const(ubyte)[])kv[0];
        entry ~= encodeTag(2, WireType.LengthDelimited) ~ encodeVarint(value.length) ~ value;
        out_ ~= encodeTag(1, WireType.LengthDelimited) ~ encodeVarint(entry.length) ~ entry;
    }
    return out_;
}

unittest {
    // What is written reads back as it was, an empty value included.
    string[2][] pairs = [["cta.form", "true"], ["terms.trial", ""]];
    auto s = decode!Struct(encodeStruct(pairs));
    assert(s.fields.length == 2);
    assert(s.fields[0].key == "cta.form" && s.fields[0].value.stringValue == "true");
    assert(s.fields[1].key == "terms.trial" && s.fields[1].value.stringValue == "");
}
