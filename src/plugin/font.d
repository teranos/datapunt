/// A TrueType font, read by the compiler into static data the way schema.d
/// reads the schema: for each character its advance and its outline. Nothing
/// here reads a file at runtime.
///
/// Sugarpie carries no kern, GPOS or GSUB table, so a line of text is its
/// glyphs one after the other, each moved on by its advance.
module plugin.font;

/// One step of a glyph's outline, in font units, y up.
struct Step {
    enum Kind { move, line, quad }
    Kind kind;
    double cx = 0, cy = 0; // a quad's off-curve point
    double x = 0, y = 0;
}

struct Glyph {
    dchar ch;
    uint advance; // font units
    Step[] outline;
}

struct Font {
    uint unitsPerEm;
    /// Glyph 0, what a character the font lacks is drawn with.
    Glyph missing;
    /// Every character the font maps, in order.
    Glyph[] glyphs;

    const(Glyph)* glyph(dchar ch) const {
        size_t lo = 0, hi = glyphs.length;
        while (lo < hi) {
            immutable mid = (lo + hi) / 2;
            if (glyphs[mid].ch < ch) lo = mid + 1;
            else hi = mid;
        }
        return lo < glyphs.length && glyphs[lo].ch == ch ? &glyphs[lo] : &missing;
    }
}

/// The weekly strip's handwriting: FontPanda's Sugarpie (dafont.com, sugarpie_2).
static immutable Font sugarpie = readFont(import("mail/Sugarpie.ttf"));

/// A font's Unicode characters (cmap format 4), advances (hmtx) and outlines
/// (glyf). Runs at compile time.
Font readFont(string data) {
    auto t = Tables(data);
    Font f;
    f.unitsPerEm = t.u16(t.head + 18);
    f.missing = Glyph(0, t.advance(0), t.outline(0));

    immutable sub = t.cmap4;
    immutable segX2 = t.u16(sub + 6);
    foreach (s; 0 .. segX2 / 2) {
        immutable end = t.u16(sub + 14 + s * 2);
        immutable start = t.u16(sub + 16 + segX2 + s * 2);
        immutable delta = cast(short) t.u16(sub + 16 + segX2 * 2 + s * 2);
        immutable rangeAt = sub + 16 + segX2 * 3 + s * 2;
        immutable range = t.u16(rangeAt);
        if (start == 0xFFFF) continue;
        foreach (uint ch; start .. end + 1) {
            ushort g;
            if (range == 0) g = cast(ushort)(ch + delta);
            else {
                immutable at = t.u16(rangeAt + range + (ch - start) * 2);
                g = at ? cast(ushort)(at + delta) : 0;
            }
            if (g == 0) continue;
            f.glyphs ~= Glyph(cast(dchar) ch, t.advance(g), t.outline(g));
        }
    }
    return f;
}

private struct Tables {
    string data;
    size_t head, cmap4, glyf, loca, hmtx;
    uint metrics;
    bool longLoca;

    this(string data) {
        this.data = data;
        size_t hhea;
        foreach (i; 0 .. u16(4)) {
            immutable rec = 12 + i * 16;
            immutable tag = data[rec .. rec + 4];
            immutable at = u32(rec + 8);
            if (tag == "head") head = at;
            else if (tag == "hhea") hhea = at;
            else if (tag == "hmtx") hmtx = at;
            else if (tag == "loca") loca = at;
            else if (tag == "glyf") glyf = at;
            else if (tag == "cmap") {
                foreach (k; 0 .. u16(at + 2)) {
                    immutable r = at + 4 + k * 8;
                    immutable sub = at + u32(r + 4);
                    // Unicode BMP, as Windows or as Unicode names it.
                    immutable platform = u16(r), encoding = u16(r + 2);
                    if (u16(sub) == 4 && (platform == 3 && encoding == 1 || platform == 0)) { cmap4 = sub; break; }
                }
            }
        }
        if (!head || !hhea || !hmtx || !loca || !glyf) assert(0, "the font lacks one of head, hhea, hmtx, loca, glyf");
        if (!cmap4) assert(0, "the font has no Unicode cmap of format 4");
        longLoca = u16(head + 50) == 1;
        metrics = u16(hhea + 34);
    }

    uint advance(ushort glyph) const {
        return u16(hmtx + (glyph < metrics ? glyph : metrics - 1) * 4);
    }

    Step[] outline(ushort glyph) const {
        Step[] steps;
        outlineInto(glyph, 1, 0, 0, 1, 0, 0, steps, 0);
        return steps;
    }

    private void outlineInto(ushort glyph, double a, double b, double c, double d, double dx, double dy, ref Step[] steps, int depth) const {
        if (depth > 8) assert(0, "a composite glyph nests deeper than 8");
        immutable from = longLoca ? u32(loca + glyph * 4) : u16(loca + glyph * 2) * 2;
        immutable to = longLoca ? u32(loca + glyph * 4 + 4) : u16(loca + glyph * 2 + 2) * 2;
        if (to <= from) return; // no outline, like the space
        size_t p = glyf + from;
        immutable contours = cast(short) u16(p);
        p += 10;

        if (contours < 0) {
            // A composite: other glyphs, each moved and possibly scaled.
            enum WORDS = 0x1, XY = 0x2, SCALE = 0x8, MORE = 0x20, XY_SCALE = 0x40, TWO_BY_TWO = 0x80;
            ushort flags;
            do {
                flags = u16(p);
                immutable part = u16(p + 2);
                p += 4;
                double ox, oy;
                if (flags & WORDS) { ox = cast(short) u16(p); oy = cast(short) u16(p + 2); p += 4; }
                else { ox = cast(byte) data[p]; oy = cast(byte) data[p + 1]; p += 2; }
                if (!(flags & XY)) assert(0, "a composite glyph places a part by point numbers");
                double pa = 1, pb = 0, pc = 0, pd = 1;
                if (flags & SCALE) { pa = pd = f2dot14(p); p += 2; }
                else if (flags & XY_SCALE) { pa = f2dot14(p); pd = f2dot14(p + 2); p += 4; }
                else if (flags & TWO_BY_TWO) { pa = f2dot14(p); pb = f2dot14(p + 2); pc = f2dot14(p + 4); pd = f2dot14(p + 6); p += 8; }
                // The part's transform, then this glyph's.
                outlineInto(part,
                    a * pa + c * pb, b * pa + d * pb,
                    a * pc + c * pd, b * pc + d * pd,
                    a * ox + c * oy + dx, b * ox + d * oy + dy,
                    steps, depth + 1);
            } while (flags & MORE);
            return;
        }

        auto ends = new ushort[](contours);
        foreach (i; 0 .. contours) { ends[i] = u16(p); p += 2; }
        immutable size_t count = contours ? ends[$ - 1] + 1 : 0;
        p += 2 + u16(p); // the instructions, which an unhinted outline does not run

        enum ON = 0x1, X_SHORT = 0x2, Y_SHORT = 0x4, REPEAT = 0x8, X_SAME = 0x10, Y_SAME = 0x20;
        auto flags = new ubyte[](count);
        for (size_t i = 0; i < count;) {
            immutable f = byte_(p++);
            flags[i++] = f;
            if (f & REPEAT) {
                immutable times = byte_(p++);
                foreach (_; 0 .. times) flags[i++] = f;
            }
        }
        auto xs = new double[](count), ys = new double[](count);
        int v;
        foreach (i; 0 .. count) {
            immutable f = flags[i];
            if (f & X_SHORT) { v += (f & X_SAME) ? byte_(p) : -cast(int) byte_(p); p += 1; }
            else if (!(f & X_SAME)) { v += cast(short) u16(p); p += 2; }
            xs[i] = v;
        }
        v = 0;
        foreach (i; 0 .. count) {
            immutable f = flags[i];
            if (f & Y_SHORT) { v += (f & Y_SAME) ? byte_(p) : -cast(int) byte_(p); p += 1; }
            else if (!(f & Y_SAME)) { v += cast(short) u16(p); p += 2; }
            ys[i] = v;
        }

        // Points on the curve are passed through; between two off it lies
        // one on it, halfway.
        size_t start;
        foreach (end; ends) {
            immutable size_t n = end + 1 - start;
            if (n == 0) continue;
            double px(size_t i) { immutable k = start + i % n; return a * xs[k] + c * ys[k] + dx; }
            double py(size_t i) { immutable k = start + i % n; return b * xs[k] + d * ys[k] + dy; }
            bool on(size_t i) { return (flags[start + i % n] & ON) != 0; }

            // Begin on a point on the curve, or halfway between the first two off it.
            size_t first;
            while (first < n && !on(first)) first++;
            double sx, sy;
            if (first == n) { sx = (px(0) + px(1)) / 2; sy = (py(0) + py(1)) / 2; first = 0; }
            else { sx = px(first); sy = py(first); }
            steps ~= Step(Step.Kind.move, 0, 0, sx, sy);

            bool pending;
            double qx = 0, qy = 0;
            foreach (k; 1 .. n + 1) {
                immutable i = first + k;
                immutable x = px(i), y = py(i);
                if (on(i)) {
                    if (pending) steps ~= Step(Step.Kind.quad, qx, qy, x, y);
                    else steps ~= Step(Step.Kind.line, 0, 0, x, y);
                    pending = false;
                } else {
                    if (pending) steps ~= Step(Step.Kind.quad, qx, qy, (qx + x) / 2, (qy + y) / 2);
                    qx = x; qy = y;
                    pending = true;
                }
            }
            if (pending) steps ~= Step(Step.Kind.quad, qx, qy, sx, sy);
            start = end + 1;
        }
    }

    ubyte byte_(size_t o) const { return cast(ubyte) data[o]; }
    ushort u16(size_t o) const { return cast(ushort)((byte_(o) << 8) | byte_(o + 1)); }
    uint u32(size_t o) const { return (byte_(o) << 24) | (byte_(o + 1) << 16) | (byte_(o + 2) << 8) | byte_(o + 3); }
    double f2dot14(size_t o) const { return cast(short) u16(o) / 16384.0; }
}

unittest {
    assert(sugarpie.unitsPerEm == 2048);

    // Every character the strip writes has a glyph of its own.
    foreach (dchar ch; "abcdefghijklmnopqrstuvwxyzC0123456789 -+.*_:>")
        assert(sugarpie.glyph(ch) !is &sugarpie.missing, "Sugarpie has no glyph for a character the strip writes");

    // A letter has an outline that begins each contour with a move; the space
    // has none, and still advances.
    auto a = sugarpie.glyph('a');
    assert(a.outline.length > 0 && a.outline[0].kind == Step.Kind.move);
    assert(sugarpie.glyph(' ').outline.length == 0);
    assert(sugarpie.glyph(' ').advance > 0);

    // A character it lacks is drawn as its missing glyph.
    assert(sugarpie.glyph('一') is &sugarpie.missing);
}
