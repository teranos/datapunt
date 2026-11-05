module schema;

// The schema, parsed at compile time into static data. cue wrote the JSON
// (wind); nothing here reads a file at runtime.

// No namespace here. The node hands each call a store token that reaches the
// caller's namespace and names it to nobody (QNTX ADR-038), so one schema
// serves every company and the data parts by token.
struct Field {
    string kind;
    string path;
    string type;
    string[] values;
}

struct Kind {
    string name;
    string identity;
}

/// A pixel: one web analytics datapunt, and the events its snippet may name,
/// page_view first. Its fields are its kind's.
struct Pixel {
    string name;
    string[] events;
}

private struct Cursor {
    string s;
    size_t i;
}

private void ws(ref Cursor c) {
    while (c.i < c.s.length) {
        immutable ch = c.s[c.i];
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') c.i++;
        else break;
    }
}

private string str(ref Cursor c) {
    ws(c);
    if (c.i >= c.s.length || c.s[c.i] != '"') return null;
    c.i++;
    string out_;
    while (c.i < c.s.length && c.s[c.i] != '"') {
        if (c.s[c.i] == '\\' && c.i + 1 < c.s.length) {
            c.i++;
            switch (c.s[c.i]) {
                case 'n': out_ ~= '\n'; break;
                case 't': out_ ~= '\t'; break;
                case 'r': out_ ~= '\r'; break;
                case '"': out_ ~= '"'; break;
                case '\\': out_ ~= '\\'; break;
                case '/': out_ ~= '/'; break;
                default: out_ ~= c.s[c.i]; break;
            }
            c.i++;
            continue;
        }
        out_ ~= c.s[c.i];
        c.i++;
    }
    c.i++;
    return out_;
}

// Skips whatever value sits at the cursor, including nested ones.
private void skip(ref Cursor c) {
    ws(c);
    if (c.i >= c.s.length) return;
    immutable ch = c.s[c.i];
    if (ch == '"') { cast(void) str(c); return; }
    if (ch == '{' || ch == '[') {
        immutable close = ch == '{' ? '}' : ']';
        c.i++;
        while (c.i < c.s.length) {
            ws(c);
            if (c.i < c.s.length && c.s[c.i] == close) { c.i++; return; }
            if (c.i < c.s.length && (c.s[c.i] == ',' || c.s[c.i] == ':')) { c.i++; continue; }
            skip(c);
        }
        return;
    }
    while (c.i < c.s.length) {
        immutable d = c.s[c.i];
        if (d == ',' || d == '}' || d == ']') break;
        c.i++;
    }
}

private string[] strList(ref Cursor c) {
    string[] out_;
    ws(c);
    if (c.i >= c.s.length || c.s[c.i] != '[') { skip(c); return out_; }
    c.i++;
    while (c.i < c.s.length) {
        ws(c);
        if (c.i < c.s.length && c.s[c.i] == ']') { c.i++; break; }
        if (c.i < c.s.length && c.s[c.i] == ',') { c.i++; continue; }
        out_ ~= str(c);
    }
    return out_;
}

private Field field(ref Cursor c) {
    Field f;
    ws(c);
    if (c.i >= c.s.length || c.s[c.i] != '{') return f;
    c.i++;
    while (c.i < c.s.length) {
        ws(c);
        if (c.i < c.s.length && c.s[c.i] == '}') { c.i++; break; }
        if (c.i < c.s.length && c.s[c.i] == ',') { c.i++; continue; }
        immutable key = str(c);
        ws(c);
        if (c.i < c.s.length && c.s[c.i] == ':') c.i++;
        if (key == "path") f.path = str(c);
        else if (key == "kind") f.kind = str(c);
        else if (key == "type") f.type = str(c);
        else if (key == "values") f.values = strList(c);
        else skip(c);
    }
    return f;
}

Field[] parseSchema(string json) {
    Field[] out_;
    auto c = Cursor(json, 0);
    immutable at = indexOfKey(json, "\"fields\"");
    if (at < 0) return out_;
    c.i = at + 8;
    ws(c);
    if (c.i < c.s.length && c.s[c.i] == ':') c.i++;
    ws(c);
    if (c.i >= c.s.length || c.s[c.i] != '[') return out_;
    c.i++;
    while (c.i < c.s.length) {
        ws(c);
        if (c.i < c.s.length && c.s[c.i] == ']') break;
        if (c.i < c.s.length && c.s[c.i] == ',') { c.i++; continue; }
        out_ ~= field(c);
    }
    return out_;
}

private ptrdiff_t indexOfKey(string hay, string needle) {
    if (needle.length > hay.length) return -1;
    foreach (i; 0 .. hay.length - needle.length + 1) {
        bool hit = true;
        foreach (j; 0 .. needle.length) {
            if (hay[i + j] != needle[j]) { hit = false; break; }
        }
        if (hit) return cast(ptrdiff_t) i;
    }
    return -1;
}

private Kind kindEntry(ref Cursor c) {
    Kind k;
    ws(c);
    if (c.i >= c.s.length || c.s[c.i] != '{') return k;
    c.i++;
    while (c.i < c.s.length) {
        ws(c);
        if (c.i < c.s.length && c.s[c.i] == '}') { c.i++; break; }
        if (c.i < c.s.length && c.s[c.i] == ',') { c.i++; continue; }
        immutable key = str(c);
        ws(c);
        if (c.i < c.s.length && c.s[c.i] == ':') c.i++;
        if (key == "name") k.name = str(c);
        else if (key == "identity") k.identity = str(c);
        else skip(c);
    }
    return k;
}

Kind[] parseKinds(string json) {
    Kind[] out_;
    auto c = Cursor(json, 0);
    immutable at = indexOfKey(json, "\"kinds\"");
    if (at < 0) return out_;
    c.i = at + 7;
    ws(c);
    if (c.i < c.s.length && c.s[c.i] == ':') c.i++;
    ws(c);
    if (c.i >= c.s.length || c.s[c.i] != '[') return out_;
    c.i++;
    while (c.i < c.s.length) {
        ws(c);
        if (c.i < c.s.length && c.s[c.i] == ']') break;
        if (c.i < c.s.length && c.s[c.i] == ',') { c.i++; continue; }
        out_ ~= kindEntry(c);
    }
    return out_;
}

private Pixel pixelEntry(ref Cursor c) {
    Pixel p;
    ws(c);
    if (c.i >= c.s.length || c.s[c.i] != '{') return p;
    c.i++;
    while (c.i < c.s.length) {
        ws(c);
        if (c.i < c.s.length && c.s[c.i] == '}') { c.i++; break; }
        if (c.i < c.s.length && c.s[c.i] == ',') { c.i++; continue; }
        immutable key = str(c);
        ws(c);
        if (c.i < c.s.length && c.s[c.i] == ':') c.i++;
        if (key == "name") p.name = str(c);
        else if (key == "events") p.events = strList(c);
        else skip(c);
    }
    return p;
}

Pixel[] parsePixels(string json) {
    Pixel[] out_;
    auto c = Cursor(json, 0);
    // The key and its colon: a kind or a field named pixels is a value, and
    // a value is followed by a comma or a close, never a colon.
    immutable at = indexOfKey(json, "\"pixels\":");
    if (at < 0) return out_;
    c.i = at + 9;
    ws(c);
    if (c.i >= c.s.length || c.s[c.i] != '[') return out_;
    c.i++;
    while (c.i < c.s.length) {
        ws(c);
        if (c.i < c.s.length && c.s[c.i] == ']') break;
        if (c.i < c.s.length && c.s[c.i] == ',') { c.i++; continue; }
        out_ ~= pixelEntry(c);
    }
    return out_;
}

unittest {
    auto ps = parsePixels(`{"fields":[{"kind":"pixels","path":"a","type":"string"}],"kinds":[],"pixels": [{"name":"site","events":["page_view","signup"]}]}`);
    assert(ps.length == 1 && ps[0].name == "site" && ps[0].events == ["page_view", "signup"]);
    assert(parsePixels(`{"fields":[],"kinds":[]}`).length == 0);
}

// The whole point: parsed by the compiler, baked in as static data.
enum fields = parseSchema(import(".ctfe/schema.json"));
enum kinds = parseKinds(import(".ctfe/schema.json"));
enum pixels = parsePixels(import(".ctfe/schema.json"));
