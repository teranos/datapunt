module records;

// One attestation per subject: every observed field sits in attributes, and a
// later attestation supersedes the whole set.

struct Pair {
    string key;
    string value;
}

struct Record {
    string subject;
    string predicate;
    string timestamp;
    Pair[] attributes;
}

string scan(string s, ref size_t i) {
    string out_;
    i++;
    while (i < s.length && s[i] != '"') {
        if (s[i] == '\\' && i + 1 < s.length) {
            i++;
            switch (s[i]) {
                case 'n': out_ ~= '\n'; break;
                case 't': out_ ~= '\t'; break;
                case 'r': out_ ~= '\r'; break;
                case '"': out_ ~= '"'; break;
                case '\\': out_ ~= '\\'; break;
                case '/': out_ ~= '/'; break;
                default: out_ ~= s[i];
            }
            i++;
            continue;
        }
        out_ ~= s[i];
        i++;
    }
    i++;
    return out_;
}

bool isKey(string s, size_t after) {
    size_t j = after;
    while (j < s.length && (s[j] == ' ' || s[j] == '\n' || s[j] == '\t')) j++;
    return j < s.length && s[j] == ':';
}

// Depth tells the envelope from the attributes object nested inside it.
Record[] parse(string json) {
    Record[] out_;
    Record cur;
    string key;
    int depth;
    bool inRecord;
    int attrDepth = -1;
    size_t i;

    while (i < json.length) {
        immutable c = json[i];
        if (c == '{') {
            depth++;
            if (depth == 1) { cur = Record.init; inRecord = true; }
            else if (key == "attributes") attrDepth = depth;
            i++;
            key = null;
            continue;
        }
        if (c == '}') {
            if (depth == attrDepth) attrDepth = -1;
            depth--;
            if (depth == 0 && inRecord) { out_ ~= cur; inRecord = false; }
            i++;
            continue;
        }
        if (c == '"') {
            immutable s = scan(json, i);
            if (isKey(json, i)) { key = s; while (json[i] != ':') i++; i++; continue; }
            if (attrDepth > 0) cur.attributes ~= Pair(key, s);
            else if (key == "timestamp") cur.timestamp = s;
            else if (key == "predicates") cur.predicate = s;
            else if (key == "subjects") cur.subject = s;
            key = null;
            continue;
        }
        i++;
    }
    return out_;
}

// Older attestations were written in a shape this reader does not understand.
// ATS has no delete, so they are filtered out instead.
enum SINCE = "2026-09-12T16:00:00Z";

// The last claim in time is operative.
Record newest(Record[] all) {
    Record best;
    foreach (r; all) {
        if (r.timestamp < SINCE) continue;
        if (best.timestamp.length == 0 || r.timestamp > best.timestamp) best = r;
    }
    return best;
}

string attribute(Record r, string key) {
    foreach (p; r.attributes) if (p.key == key) return p.value;
    return null;
}

string[] subjectsIn(Record[] all) {
    bool[string] seen;
    foreach (r; all) {
        if (r.timestamp < SINCE) continue;
        if (r.subject.length > 0) seen[r.subject] = true;
    }
    string[] out_;
    foreach (k; seen.keys) out_ ~= k;
    import std.algorithm : sort;
    out_.sort();
    return out_;
}
