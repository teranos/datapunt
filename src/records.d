module records;

// Pulls the attributes datapunt cares about out of the node's JSON. The full
// record carries a signature and an actor; a query needs value, source, seen.

struct Seen {
    string predicate;
    string value;
    string source;
    string seen;
    string timestamp;
}

private string scan(string s, ref size_t i) {
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

// One pass, tracking the keys that matter. Records are flat enough that a
// depth counter separates the attributes object from the envelope.
Seen[] parse(string json) {
    Seen[] out_;
    Seen cur;
    string key;
    int depth;
    bool inRecord;
    size_t i;

    while (i < json.length) {
        immutable c = json[i];
        if (c == '{') {
            depth++;
            if (depth == 1) { cur = Seen.init; inRecord = true; }
            i++;
            continue;
        }
        if (c == '}') {
            depth--;
            if (depth == 0 && inRecord) { out_ ~= cur; inRecord = false; }
            i++;
            continue;
        }
        if (c == '"') {
            immutable start = i;
            immutable s = scan(json, i);
            // a key is a string followed by a colon
            size_t j = i;
            while (j < json.length && (json[j] == ' ' || json[j] == '\n')) j++;
            if (j < json.length && json[j] == ':') { key = s; i = j + 1; continue; }
            if (key == "value") cur.value = s;
            else if (key == "source" && cur.source.length == 0) cur.source = s;
            else if (key == "seen") cur.seen = s;
            else if (key == "timestamp") cur.timestamp = s;
            else if (key == "predicates") cur.predicate = s;
            key = null;
            cast(void) start;
            continue;
        }
        i++;
    }
    return out_;
}
