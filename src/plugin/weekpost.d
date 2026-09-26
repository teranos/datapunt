/// The weekly strip: mail/weekpost.html's drawing, carried over to D call for
/// call. The same squares, pencil and ink, and the same wobble from the same
/// seeds, drawn in the same order. mail/weekpost.html is the reference this
/// has to match; where the two differ, the page is right.
module plugin.weekpost;

import plugin.canvas;
import plugin.font : sugarpie;
import plugin.png : encodePNG;

/// The week to draw: what the page reads from window.WEEKPOST.
struct Week {
    string label;
    string[] days;
    long[] coverage;
    long[] terminal, web, sigil; // WRITES
    long[] green, red;
    SchemaStep[] schema;
    Top[] top;
}

struct SchemaStep { long day, fields, add, del; }
struct Top { string title; string[3][] rows; } // amount, name, thing

/// The strip as a PNG, at dpr device pixels to the page's pixel.
ubyte[] drawWeek(ref const Week week, double dpr) {
    auto s = strip(dpr);
    draw(s, week);
    return encodePNG(s.ctx.unpremultiplied(), s.ctx.width, s.ctx.height);
}

private:

enum W = 400, H = 2340, CELL = 8;
immutable PAPER = Colour(0xe2, 0xd2, 0xae);
immutable int[3] LEAD = [44, 40, 34], INK = [34, 30, 26], PEN = [30, 55, 125], GRN = [72, 128, 72], RD = [178, 62, 50];

Colour rgba(const int[3] c, double a) { return Colour(c[0], c[1], c[2], a); }

/// rng(seed) of the page: Park and Miller's minimal standard generator.
struct Rng {
    long seed;
    this(long seed) { this.seed = seed; }
    double opCall() {
        seed = seed * 16807 % 2147483647;
        return (seed - 1) / 2147483646.0;
    }
}

/// What a Uint8ClampedArray keeps of a number: clamped, and rounded to the
/// nearest, halves to even.
ubyte clamped(double v) {
    import std.math : floor;
    if (!(v > 0)) return 0;
    if (v >= 255) return 255;
    immutable f = floor(v);
    if (f + 0.5 < v) return cast(ubyte)(f + 1);
    if (v < f + 0.5) return cast(ubyte) f;
    return cast(ubyte)(cast(int) f % 2 ? f + 1 : f);
}

/// The paper's grain: 256 by 256, from its own seed.
ubyte[] grain() {
    auto r = Rng(7);
    auto d = new ubyte[](256 * 256 * 4);
    for (size_t i = 0; i < d.length; i += 4) {
        immutable v = 120 + (r() - .5) * 70;
        d[i] = clamped(v); d[i + 1] = clamped(v * .95); d[i + 2] = clamped(v * .85); d[i + 3] = 26;
    }
    return d;
}

alias Pt = double[2];

struct Strip {
    Canvas ctx;
    Rng r;

    void mul(scope void delegate() fn) {
        ctx.save();
        ctx.globalCompositeOperation = Composite.multiply;
        fn();
        ctx.restore();
    }

    // Pencil hatching in three weights: 1 light, 2 medium, 3 crosshatched dark.
    void hatch(scope void delegate() path, int level) {
        mul({
            path(); ctx.clip();
            void lines(int angle, double step, double a) {
                ctx.lineWidth = .75;
                enum len = W + H;
                for (double i = -len; i < len; i += step) {
                    ctx.strokeStyle = rgba(LEAD, a * (.6 + r() * .4));
                    ctx.beginPath();
                    if (angle > 0) {
                        immutable x0 = i + (r() - .5);
                        ctx.moveTo(x0, H);
                        immutable x1 = i + H + (r() - .5);
                        ctx.lineTo(x1, 0);
                    } else {
                        immutable x0 = i + (r() - .5);
                        ctx.moveTo(x0, 0);
                        immutable x1 = i + H + (r() - .5);
                        ctx.lineTo(x1, H);
                    }
                    ctx.stroke();
                }
            }
            if (level == 1) lines(1, 3.6, .55);
            if (level == 2) { lines(1, 2.2, .7); ctx.fillStyle = rgba(LEAD, .06); ctx.fillRect(0, 0, W, H); }
            if (level == 3) { lines(1, 2, .75); lines(-1, 2.4, .6); ctx.fillStyle = rgba(LEAD, .1); ctx.fillRect(0, 0, W, H); }
        });
    }

    void rect(double x, double y, double w, double h, int level) {
        if (w > 0 && h > 0) hatch({ ctx.beginPath(); ctx.rect(x, y, w, h); }, level);
    }

    // A block in coloured pencil, pressed hard.
    void block(double x, double y, double w, double h, const int[3] color) {
        mul({
            ctx.beginPath(); ctx.rect(x + .5, y + .5, w - 1, h - 1); ctx.clip();
            ctx.fillStyle = rgba(color, .55); ctx.fillRect(x, y, w, h);
            ctx.lineWidth = .8;
            for (double i = -h; i < w; i += 1.6) {
                ctx.strokeStyle = rgba(color, .35 + r() * .3);
                ctx.beginPath(); ctx.moveTo(x + i, y + h + 1); ctx.lineTo(x + i + h, y - 1); ctx.stroke();
            }
        });
    }

    void line(const Pt[] pts, const int[3] color = LEAD, double a = .8, double w = 1.1) {
        mul({
            ctx.strokeStyle = rgba(color, a); ctx.lineWidth = w; ctx.lineCap = Cap.round; ctx.lineJoin = Join.round;
            ctx.beginPath();
            foreach (i, p; pts) {
                immutable x = p[0], y = p[1];
                immutable jx = x + (r() - .5) * .7;
                immutable jy = y + (r() - .5) * .7;
                if (!i) ctx.moveTo(jx, jy);
                else {
                    immutable px = pts[i - 1][0], py = pts[i - 1][1];
                    immutable cx = (px + x) / 2 + (r() - .5) * 1.2;
                    immutable cy = (py + y) / 2 + (r() - .5) * 1.2;
                    ctx.quadraticCurveTo(cx, cy, jx, jy);
                }
            }
            ctx.stroke();
        });
    }

    // Ballpoint: blue, thin, a second faint pass beside the first.
    void pen(const Pt[] pts, double w = 1.1) {
        line(pts, PEN, .85, w);
        Pt[] beside;
        foreach (p; pts) beside ~= [p[0] + .4, p[1] + .3];
        line(beside, PEN, .25, .6);
    }

    void text(string t, double x, double y, double size = 12, Align align_ = Align.left, const int[3] color = INK, double a = .9) {
        import std.math : floor;
        mul({
            ctx.fontSize = floor(size * 1.25 + .5); // Math.round
            ctx.fillStyle = rgba(color, a); ctx.textAlign = align_;
            ctx.fillText(t, x, y);
        });
    }
}

Strip strip(double dpr) {
    import std.algorithm : max, min;

    Strip s;
    s.ctx = new Canvas(W, H, dpr, sugarpie);
    s.r = Rng(91);
    auto ctx = s.ctx;

    // Torn out along the left, the way a page leaves a schrift: a ragged edge
    // that wanders, with now and then a deeper bite. Top, right and bottom are cut.
    Pt[] edge;
    {
        double x = 2;
        for (int y = 0; y <= H; y += 3) {
            x += (s.r() - .5) * .9 + (2 - x) * .15;
            edge ~= [max(.5, min(4.0, x)), y];
        }
    }
    ctx.beginPath();
    ctx.moveTo(edge[0][0], 0);
    ctx.lineTo(W, 0); ctx.lineTo(W, H); ctx.lineTo(edge[$ - 1][0], H);
    foreach_reverse (p; edge) ctx.lineTo(p[0], p[1]);
    ctx.closePath();
    ctx.clip();

    ctx.fillStyle = PAPER; ctx.fillRect(0, 0, W, H);
    auto tone = ctx.createLinearGradient(0, 0, W, 0);
    tone.addColorStop(0, Colour(140, 105, 55, .22)); tone.addColorStop(.1, Colour(245, 235, 210, .12));
    tone.addColorStop(.9, Colour(245, 235, 210, .12)); tone.addColorStop(1, Colour(140, 105, 55, .22));
    ctx.fillStyle = tone; ctx.fillRect(0, 0, W, H);
    ctx.fillStyle = ctx.createPattern(grain(), 256, 256); ctx.fillRect(0, 0, W, H);
    foreach (i; 0 .. 9) {
        immutable x = s.r() * W;
        immutable y = s.r() * H;
        immutable sz = 2 + s.r() * 6;
        auto f = ctx.createRadialGradient(x, y, 0, x, y, sz * 3);
        f.addColorStop(0, Colour(140, 95, 45, .14)); f.addColorStop(1, Colour(140, 95, 45, 0));
        ctx.fillStyle = f; ctx.fillRect(x - sz * 3, y - sz * 3, sz * 6, sz * 6);
    }
    // Minor squares, and every fifth line heavier: the lines text stands on.
    for (int x = CELL, i = 1; x < W; x += CELL, i++) {
        immutable major = i % 5 == 0;
        ctx.lineWidth = major ? 1 : .55;
        ctx.strokeStyle = Colour(95, 102, 112, major ? .34 : .15);
        ctx.beginPath(); ctx.moveTo(x + .5, 0); ctx.lineTo(x + .5, H); ctx.stroke();
    }
    for (int y = CELL, i = 1; y < H; y += CELL, i++) {
        immutable major = i % 5 == 0;
        ctx.lineWidth = major ? 1 : .55;
        ctx.strokeStyle = Colour(95, 102, 112, major ? .34 : .15);
        ctx.beginPath(); ctx.moveTo(0, y + .5); ctx.lineTo(W, y + .5); ctx.stroke();
    }

    // The margin line: printed magenta, top to bottom, on the heavy line at 40.
    for (int y = 0; y < H; y += 20) {
        ctx.strokeStyle = Colour(196, 58, 122, .55 + s.r() * .12);
        ctx.lineWidth = 1.2;
        ctx.beginPath(); ctx.moveTo(40.5, y); ctx.lineTo(40.5, y + 20); ctx.stroke();
    }

    // The torn edge shows the paper's lighter core in a thin, frayed rim.
    ctx.save();
    ctx.lineCap = Cap.round;
    foreach (i, p; edge) {
        if (!i) continue;
        immutable x = p[0], y = p[1];
        immutable px = edge[i - 1][0], py = edge[i - 1][1];
        ctx.strokeStyle = Colour(248, 240, 220, .2 + s.r() * .2);
        ctx.lineWidth = .6 + s.r() * .6;
        ctx.beginPath(); ctx.moveTo(px + 1, py); ctx.lineTo(x + 1, y); ctx.stroke();
        if (s.r() < .05) {
            ctx.strokeStyle = Colour(248, 240, 220, .5); ctx.lineWidth = .6;
            ctx.beginPath(); ctx.moveTo(x + 1, y);
            immutable tx = x - 1.5 - s.r() * 2;
            immutable ty = y + (s.r() - .5) * 3;
            ctx.lineTo(tx, ty); ctx.stroke();
        }
    }
    ctx.restore();
    return s;
}

// Everything sits on the squares. A square is 8 across; every fifth line is heavy,
// 40 apart. c(n) is the nth vertical line, l(n) the nth horizontal one.
// Text starts, ends or centres on a heavy vertical line and stands on a heavy
// horizontal one wherever the data lets it.
double c(double n) { return n * CELL; }
double l(double n) { return n * CELL; }
enum LEFT = 5, AXIS = 10, RIGHT = 45; // heavy lines at 40, 80 and 360

struct Tick { double at; string label; int[3] color = INK; }

void draw(ref Strip s, ref const Week week) {
    import std.conv : to;
    import std.math : ceil;

    void T(string t, double col, double row, double size = 11, Align align_ = Align.left, const int[3] color = INK, double a = .9) {
        s.text(t, c(col) + (col == LEFT && align_ == Align.left ? 4 : 0), l(row), size, align_, color, a);
    }
    void along(double c0, double c1, double row, double w = 1) {
        s.pen([[c(c0), l(row) + 1], [c((c0 + c1) / 2), l(row) + 1.4], [c(c1), l(row) + 1]], w);
    }
    void heading(string t, double row) { T(t, LEFT, row - .25, 16, Align.left, INK, .95); along(LEFT, RIGHT, row, .9); }
    void bracket(double c0, double c1, double row) {
        s.pen([[c(c0), l(row + 1)], [c(c0), l(row)], [c(c1), l(row)], [c(c1), l(row + 1)]], .9);
    }
    // Tick values start on the heavy line at 40; the axis is the heavy line at 80.
    void axisY(double top, double base, const Tick[] ticks, string title, double titleRow) {
        s.line([[c(AXIS), l(top)], [c(AXIS), l(base)]], LEAD, .85, .9);
        foreach (t; ticks) {
            s.line([[c(AXIS) - 4, l(t.at)], [c(AXIS), l(t.at)]], LEAD, .85, .9);
            T(t.label, LEFT, t.at, 10, Align.left, t.color, .9);
        }
        T(title, LEFT, titleRow, 11, Align.left, INK, .9);
    }
    void xAxis(double row, const Tick[] ticks) {
        s.line([[c(AXIS), l(row)], [c(RIGHT), l(row)]], LEAD, .85, .9);
        foreach (t; ticks) s.line([[c(t.at), l(row)], [c(t.at), l(row) + 4]], LEAD, .85, .9);
    }
    void labels(const Tick[] ticks, double row) { foreach (t; ticks) T(t.label, t.at, row, 10, Align.center, INK, .9); }

    T("datapunt", LEFT, 5, 22, Align.left, INK, .95);
    T(week.label, RIGHT, 5, 12, Align.right, INK, .85);

    // Days 15 … 25 three squares apart, from the heavy line at 120: 15, 20 and 25 fall on heavy lines.
    double D(size_t i) { return 15 + 3 * cast(double) i; }
    immutable n = week.days.length;
    Tick[] dayTicks;
    foreach (i, d; week.days) dayTicks ~= Tick(D(i), d);

    heading("velden gezien", 10);
    {
        enum base = 30;
        double Y(double v) { return l(base) - v / 200 * CELL; } // 1000 fields to five squares
        axisY(17, base, [Tick(30, "0"), Tick(25, "1000"), Tick(20, "2000")], "velden", 15);
        Pt[] pts;
        foreach (i, v; week.coverage) pts ~= [c(D(i)), Y(v)];
        s.hatch({
            auto x = s.ctx;
            x.beginPath(); x.moveTo(pts[0][0], l(base));
            foreach (p; pts) x.lineTo(p[0], p[1]);
            x.lineTo(pts[n - 1][0], l(base)); x.closePath();
        }, 1);
        s.line(pts, LEAD, .9, 1.4);
        foreach (p; pts) s.line([[p[0] - 1.5, p[1]], [p[0] + 1.5, p[1]]], LEAD, .9, 2.4);
        T(week.coverage[$ - 1].to!string, RIGHT, 15, 11, Align.right, INK, .95);
        bracket(D(3), D(9), 15);
        xAxis(base, dayTicks);
        labels(dayTicks, 35); T("sep", LEFT, 35, 10, Align.left, INK, .9);
    }

    heading("schrijfacties", 45);
    {
        enum base = 65;
        double Y(double v) { return l(base) - v / 100 * CELL; } // 500 writes to five squares
        axisY(54, base, [Tick(65, "0"), Tick(60, "500"), Tick(55, "1000")], "per dag", 50);
        auto acc = new double[](n);
        acc[] = 0;
        static struct Writer { string name; int level; }
        immutable writers = [Writer("terminal", 1), Writer("web", 2), Writer("sigil", 3)];
        foreach (wr; writers) {
            const(long)[] writes = wr.name == "terminal" ? week.terminal : wr.name == "web" ? week.web : week.sigil;
            auto lo = acc.dup;
            auto hi = new double[](n);
            foreach (i, v; acc) hi[i] = v + writes[i];
            s.hatch({
                auto x = s.ctx;
                x.beginPath();
                foreach (i, v; hi) if (i) x.lineTo(c(D(i)), Y(v)); else x.moveTo(c(D(i)), Y(v));
                foreach_reverse (i; 0 .. n) x.lineTo(c(D(i)), Y(lo[i]));
                x.closePath();
            }, wr.level);
            Pt[] top;
            foreach (i, v; hi) top ~= [c(D(i)), Y(v)];
            s.line(top, LEAD, .75, .9);
            acc[] = hi[];
        }
        T("875", 20, 55, 11, Align.left, INK, .95);
        T("132", D(8), 60, 11, Align.center, INK, .95);
        bracket(D(3), D(9), 50);
        xAxis(base, dayTicks);
        labels(dayTicks, 70); T("sep", LEFT, 70, 10, Align.left, INK, .9);
        foreach (i, wr; writers) {
            immutable col = LEFT + i * 15;
            s.rect(c(col), l(74), 2 * CELL, CELL, wr.level);
            T(wr.name, col + 5, 75, 11);
        }
    }

    heading("nieuw en overschreven", 85);
    {
        enum zero = 110; // a green square per 100 new fields, a red one per 2 values overwritten
        axisY(94, zero + 10, [Tick(110, "0"), Tick(105, "500"), Tick(100, "1000"), Tick(95, "1500"), Tick(115, "10", RD), Tick(120, "20", RD)], "velden nieuw", 90);
        foreach (i, v; week.green) {
            if (v) {
                immutable h = ceil(v / 100.0);
                s.block(c(D(i) - 1), l(zero - h), 2 * CELL, h * CELL, GRN);
                T(v.to!string, D(i), zero - h - 1, 10, Align.center, INK, .95);
            }
            if (week.red[i]) {
                immutable h = ceil(week.red[i] / 2.0);
                s.block(c(D(i) - 1), l(zero), 2 * CELL, h * CELL, RD);
                T(week.red[i].to!string, D(i), zero + h + 2, 10, Align.center, RD, .95);
            }
        }
        bracket(D(3), D(9), 90);
        xAxis(zero, []);
        labels(dayTicks, 125); T("sep", LEFT, 125, 10, Align.left, INK, .9);
        T("overschreven", LEFT, 130, 11, Align.left, RD, .95);
    }

    heading("schema", 140);
    {
        enum base = 160;
        double S(double d) { return 15 + 2 * (d - 11); } // a square per field; the 11th on a heavy line
        double R(double v) { return base - (v - 75); }
        axisY(149, base, [Tick(160, "75"), Tick(155, "80"), Tick(150, "85")], "velden", 145);
        Pt[] pts;
        foreach (i, v; week.schema) {
            if (i) pts ~= [c(S(v.day)), l(R(week.schema[i - 1].fields))];
            pts ~= [c(S(v.day)), l(R(v.fields))];
        }
        pts ~= [c(S(25)), l(R(82))];
        s.pen(pts, 1.3);
        foreach (v; week.schema) {
            immutable g = v.day == 11 ? 0 : v.add;
            foreach (k; 0 .. g) s.block(c(S(v.day)), l(base - 1 - k), CELL, CELL, GRN);
            foreach (k; 0 .. v.del) s.block(c(S(v.day) + 1), l(base - 1 - k), CELL, CELL, RD);
        }
        T("78", S(11), R(78) - 1, 11, Align.left, PEN, .95);
        T("3 types", S(13), R(78) - 4, 11, Align.left, PEN, .95);
        T("+ llms_txt", S(17), R(79) - 6, 11, Align.right, PEN, .95);
        T("+ login.*", S(18) + 1, R(82) - 2, 11, Align.left, PEN, .95);
        T("nix -> cue", S(23), R(82) - 5, 11, Align.center, PEN, .95);
        bracket(S(18), S(24), 145);
        Tick[] ticks;
        foreach (d; [11, 13, 15, 17, 19, 21, 23, 25]) ticks ~= Tick(S(d), d.to!string);
        xAxis(base, ticks);
        labels(ticks, 165); T("sep", LEFT, 165, 10, Align.left, INK, .9);
    }

    // top 3s, one under the other: amount on 80, name on 120, what on 320 — all heavy lines.
    foreach (j, top; week.top) {
        immutable r0 = 175 + j * 30.0, r1 = r0 + 25;
        T(top.title, AXIS, r0 + 5 - .25, 12, Align.left, INK, .95);
        along(AXIS, 40, r0 + 5, .8);
        foreach (i, row; top.rows) {
            immutable r = r0 + 10 + i * 5;
            T(row[0], AXIS, r, 16, Align.left, INK, .95);
            T(row[1], 15, r, 11, Align.left, INK, .9);
            T(row[2], 40, r, 10, Align.right, INK, .6);
        }
        s.pen([[c(LEFT), l(r0)], [c(RIGHT), l(r0)], [c(RIGHT), l(r1)], [c(LEFT), l(r1)], [c(LEFT), l(r0)]], 1);
    }
}

public:

/// A week in the shape the page reads window.WEEKPOST.
Week weekFromJSON(string json) {
    import std.json : parseJSON, JSONValue;

    auto j = parseJSON(json);
    long[] numbers(JSONValue v) { long[] out_; foreach (x; v.array) out_ ~= x.integer; return out_; }
    Week w;
    w.label = j["LABEL"].str;
    foreach (d; j["DAYS"].array) w.days ~= d.str;
    w.coverage = numbers(j["COVERAGE"]);
    w.terminal = numbers(j["WRITES"]["terminal"]);
    w.web = numbers(j["WRITES"]["web"]);
    w.sigil = numbers(j["WRITES"]["sigil"]);
    w.green = numbers(j["GREEN"]);
    w.red = numbers(j["RED"]);
    foreach (v; j["SCHEMA"].array)
        w.schema ~= SchemaStep(v["day"].integer, v["fields"].integer, v["add"].integer, v["del"].integer);
    foreach (t; j["TOP"].array) {
        Top top;
        top.title = t.array[0].str;
        foreach (row; t.array[1].array) top.rows ~= [row.array[0].str, row.array[1].str, row.array[2].str];
        w.top ~= top;
    }
    return w;
}

unittest {
    // The page's generator, from its seeds: the first draws as JavaScript
    // computes them for rng(91) and rng(7).
    auto r = Rng(91);
    assert(r() == (91L * 16807 % 2147483647 - 1) / 2147483646.0);
    auto g = Rng(7);
    assert(g.seed == 7 && g() == (7L * 16807 - 1) / 2147483646.0);

    // Uint8ClampedArray rounds halves to even.
    assert(clamped(1.5) == 2 && clamped(2.5) == 2 && clamped(2.51) == 3 && clamped(-3) == 0 && clamped(300) == 255);
}
