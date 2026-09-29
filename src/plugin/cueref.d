/// The CUE reference datapunt carries: the spec from the source of the very cue
/// wind checked the schema with, compiled in, so it is never another version's.
module plugin.cueref;

// "datapunt needs to expose the CUE sigil for its own CUE reference, it carries
// its documentation and is always up to date"

import plugin.punt : Answer, q, refused;

/// What `cue version` said when wind ran, and the spec from that cue's source.
enum CUE_VERSION = import(".ctfe/cue-version");
enum CUE_SPEC = import(".ctfe/cue-spec.md");

/// One heading of the spec and everything under it, up to the next heading of
/// the same or a higher level.
struct Section {
    size_t level;
    string title;
    string text;
}

/// The spec's sections in order. A fence or an HTML comment is not a heading:
/// CUE definitions start with `#`, and the spec keeps an unclosed fence inside
/// a comment.
Section[] sections(string spec) {
    auto lines = splitLines(spec);
    struct Head { size_t level; string title; size_t line; }
    Head[] heads;
    bool fence, comment;
    foreach (i, l; lines) {
        if (comment) {
            if (contains(l, "-->")) comment = false;
            continue;
        }
        if (!fence) {
            auto open = indexOf(l, "<!--");
            if (open >= 0 && !contains(l[open .. $], "-->")) { comment = true; continue; }
        }
        if (startsWith(l, "```")) { fence = !fence; continue; }
        if (fence) continue;
        size_t level;
        while (level < l.length && l[level] == '#') level++;
        if (level == 0 || level == l.length || l[level] != ' ') continue;
        heads ~= Head(level, strip(l[level .. $]), i);
    }

    Section[] out_;
    foreach (n, h; heads) {
        size_t end = lines.length;
        foreach (next; heads[n + 1 .. $]) if (next.level <= h.level) { end = next.line; break; }
        out_ ~= Section(h.level, h.title, strip(join(lines[h.line .. end])));
    }
    return out_;
}

/// No section: the version and every heading. A section: the version and every
/// section by that title, since the spec repeats some.
Answer cue(string section) {
    auto all = sections(CUE_SPEC);
    string[] rows;
    foreach (s; all) {
        if (section.length == 0) {
            rows ~= `{"level":` ~ num(s.level) ~ `,"title":` ~ q(s.title) ~ `}`;
        } else if (s.title == section) {
            rows ~= `{"level":` ~ num(s.level) ~ `,"title":` ~ q(s.title) ~ `,"text":` ~ q(s.text) ~ `}`;
        }
    }
    if (section.length > 0 && rows.length == 0)
        return refused("not one of", "section", "no section of the CUE spec at " ~ CUE_VERSION ~ " is titled " ~ section);
    string body = `{"version":` ~ q(CUE_VERSION) ~ `,"rows":[`;
    foreach (i, r; rows) body ~= (i ? "," : "") ~ r;
    return Answer(200, body ~ `]}`);
}

private string num(size_t n) {
    import std.conv : to;
    return n.to!string;
}

private string[] splitLines(string s) {
    string[] out_;
    size_t start;
    foreach (i, c; s) if (c == '\n') { out_ ~= s[start .. i]; start = i + 1; }
    out_ ~= s[start .. $];
    return out_;
}

private string join(string[] lines) {
    string out_;
    foreach (i, l; lines) out_ ~= (i ? "\n" : "") ~ l;
    return out_;
}

private bool startsWith(string s, string prefix) {
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

private long indexOf(string s, string sub) {
    if (sub.length > s.length) return -1;
    foreach (i; 0 .. s.length - sub.length + 1) if (s[i .. i + sub.length] == sub) return i;
    return -1;
}

private bool contains(string s, string sub) {
    return indexOf(s, sub) >= 0;
}

private string strip(string s) {
    size_t a, b = s.length;
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\n' || s[a] == '\r')) a++;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\n' || s[b - 1] == '\r')) b--;
    return s[a .. b];
}

unittest {
    // A fence and a comment hide what would be a heading; a subsection belongs
    // to its section; a title can repeat.
    auto spec = "# Spec\n\nintro\n\n## A\n\ntext a\n\n```\n#Def: 1\n```\n\n### A.1\n\nsub\n\n" ~
        "<!--\n```\n## Hidden\n-->\n\n## B\n\ntext b\n\n## A\n\nagain\n";
    auto s = sections(spec);
    assert(s.length == 5);
    assert(s[0].level == 1 && s[0].title == "Spec");
    assert(s[1].title == "A" && s[1].level == 2);
    assert(s[1].text == "## A\n\ntext a\n\n```\n#Def: 1\n```\n\n### A.1\n\nsub\n\n<!--\n```\n## Hidden\n-->");
    assert(s[2].title == "A.1" && s[2].level == 3);
    assert(s[3].title == "B" && s[3].text == "## B\n\ntext b");
    assert(s[4].title == "A" && s[4].text == "## A\n\nagain");
}

unittest {
    // The spec compiled in: one top heading, every heading resolves, and the
    // version is the one cue printed.
    auto all = sections(CUE_SPEC);
    assert(all.length > 0 && all[0].level == 1);
    size_t tops;
    foreach (s; all) if (s.level == 1) tops++;
    assert(tops == 1);
    assert(CUE_VERSION.length > 0 && CUE_VERSION[0] == 'v');

    import std.json : parseJSON;
    auto index = cue("");
    assert(index.status == 200);
    auto j = parseJSON(index.body);
    assert(j["version"].str == CUE_VERSION);
    assert(j["rows"].array.length == all.length);
    foreach (s; all) {
        auto one = cue(s.title);
        assert(one.status == 200, s.title);
        assert(parseJSON(one.body)["rows"].array.length > 0);
    }
    assert(cue("No such heading").status == 400);
}
