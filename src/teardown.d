module teardown;

// Reads one teardown's frontmatter at runtime. The subject is not compiled in;
// only the schema is.

struct Answer {
    bool found;     // the key exists in this file
    bool answered;  // it carries something other than null or an empty list
    string raw;
}

private size_t indentOf(string line) {
    size_t n;
    while (n < line.length && line[n] == ' ') n++;
    return n;
}

private string strip(string s) {
    size_t a;
    size_t b = s.length;
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r')) a++;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r')) b--;
    return s[a .. b];
}

private string[] lines(string text) {
    string[] out_;
    size_t start;
    foreach (i; 0 .. text.length) {
        if (text[i] == '\n') { out_ ~= text[start .. i]; start = i + 1; }
    }
    if (start < text.length) out_ ~= text[start .. $];
    return out_;
}

string frontmatter(string text) {
    auto ls = lines(text);
    if (ls.length == 0 || strip(ls[0]) != "---") return null;
    size_t end;
    foreach (i; 1 .. ls.length) {
        if (strip(ls[i]) == "---") { end = i; break; }
    }
    if (end == 0) return null;
    string out_;
    foreach (i; 1 .. end) { out_ ~= ls[i]; out_ ~= "\n"; }
    return out_;
}

private bool emptyValue(string v) {
    immutable s = strip(v);
    return s.length == 0 || s == "null" || s == "~" || s == "[]" || s == "\"\"";
}

// Walks the block, tracking the key stack by indent, and answers for one path.
Answer lookup(string fm, string path) {
    Answer a;
    auto ls = lines(fm);
    string[] stack;
    size_t[] indents;

    foreach (idx, line; ls) {
        if (strip(line).length == 0) continue;
        immutable ind = indentOf(line);
        immutable t = strip(line);
        if (t[0] == '-') continue;
        if (t[0] == '#') continue;

        ptrdiff_t colon = -1;
        foreach (i; 0 .. t.length) {
            if (t[i] == ':') { colon = cast(ptrdiff_t) i; break; }
        }
        if (colon < 0) continue;

        immutable key = strip(t[0 .. colon]);
        immutable rest = colon + 1 <= cast(ptrdiff_t) t.length ? t[colon + 1 .. $] : "";

        while (indents.length > 0 && indents[$ - 1] >= ind) {
            stack = stack[0 .. $ - 1];
            indents = indents[0 .. $ - 1];
        }
        stack ~= key;
        indents ~= ind;

        string full;
        foreach (i, k; stack) { if (i) full ~= "."; full ~= k; }

        if (full != path) continue;

        a.found = true;
        a.raw = strip(rest);

        if (!emptyValue(rest)) { a.answered = true; return a; }

        // A key with nothing after the colon may open a block list beneath it.
        foreach (j; idx + 1 .. ls.length) {
            if (strip(ls[j]).length == 0) continue;
            if (indentOf(ls[j]) <= ind) break;
            if (strip(ls[j])[0] == '-') { a.answered = true; a.raw = "[...]"; }
            break;
        }
        return a;
    }
    return a;
}
