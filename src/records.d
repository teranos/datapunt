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

// Four hex digits as one UTF-16 code unit, or -1 when they are not four hex digits.
private int hex4(string s, size_t at) {
    if (at + 4 > s.length) return -1;
    int v;
    foreach (k; 0 .. 4) {
        immutable h = s[at + k];
        v <<= 4;
        if (h >= '0' && h <= '9') v |= h - '0';
        else if (h >= 'a' && h <= 'f') v |= h - 'a' + 10;
        else if (h >= 'A' && h <= 'F') v |= h - 'A' + 10;
        else return -1;
    }
    return v;
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
                case 'b': out_ ~= '\b'; break;
                case 'f': out_ ~= '\f'; break;
                case '"': out_ ~= '"'; break;
                case '\\': out_ ~= '\\'; break;
                case '/': out_ ~= '/'; break;
                // The node writes & < > as & < >. Dropping the
                // backslash kept u0026, and every write carries a read forward.
                case 'u': {
                    immutable unit = hex4(s, i + 1);
                    if (unit < 0) { out_ ~= "\\u"; break; }
                    i += 4;
                    dchar c = cast(dchar) unit;
                    if (unit >= 0xD800 && unit < 0xDC00 && i + 6 < s.length && s[i + 1] == '\\' && s[i + 2] == 'u') {
                        immutable low = hex4(s, i + 3);
                        if (low >= 0xDC00 && low < 0xE000) {
                            c = cast(dchar) (0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
                            i += 6;
                        }
                    }
                    out_ ~= (c >= 0xD800 && c < 0xE000) ? cast(dchar) 0xFFFD : c;
                    break;
                }
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

// One query for the kind already carries every subject's records, so the newest
// per subject is in hand and asking the node again for each one asks it what it
// has already said.
Record[string] newestBySubject(Record[] all) {
    Record[string] best;
    foreach (r; all) {
        if (r.timestamp < SINCE) continue;
        if (r.subject.length == 0) continue;
        auto seen = r.subject in best;
        if (seen is null || r.timestamp > seen.timestamp) best[r.subject] = r;
    }
    return best;
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
