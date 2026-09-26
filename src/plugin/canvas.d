/// The part of a 2D canvas mail/weekpost.html draws with, so the page's own
/// drawing code can be carried over call for call.
///
/// Like a browser's canvas it keeps its pixels premultiplied, 8 bits a
/// channel, and scales everything it is given by one factor (the page's
/// ctx.scale(dpr)). Edges are antialiased: a pixel is covered by the share of
/// it a shape takes, found over SUB rows within it and exactly across it.
module plugin.canvas;

import plugin.font : Font, Glyph, Step;

import std.math : abs, acos, ceil, floor, sqrt, PI, cos, sin;

/// A colour as rgba() writes one: channels 0 to 255, alpha 0 to 1.
struct Colour {
    int r, g, b;
    double a = 1;
}

enum Composite { sourceOver, multiply }
enum Cap { butt, round }
enum Join { miter, round }
enum Align { left, center, right }

/// A linear or radial gradient, its stops interpolated unpremultiplied.
final class Gradient {
    private bool radial;
    private double x0, y0, r0, x1, y1, r1;
    private Stop[] stops;
    private struct Stop { double offset; Colour colour; }

    void addColorStop(double offset, Colour colour) { stops ~= Stop(offset, colour); }
}

/// An image repeated in both directions, as createPattern(image, "repeat").
final class Pattern {
    private const(ubyte)[] premultiplied;
    private uint width, height;
}

private struct Paint {
    Colour colour;
    Gradient gradient;
    Pattern pattern;
}

/// Coverage kept by clip(): 0 to 255 inside the box, nothing outside it.
private final class Mask {
    int x0, y0, x1, y1;
    ubyte[] alpha;
    ubyte at(int x, int y) const {
        if (x < x0 || x >= x1 || y < y0 || y >= y1) return 0;
        return alpha[(y - y0) * (x1 - x0) + (x - x0)];
    }
}

private struct State {
    Paint fill, stroke;
    double lineWidth = 1;
    Cap lineCap = Cap.butt;
    Join lineJoin = Join.miter;
    Composite composite = Composite.sourceOver;
    Mask clip; // null is the whole canvas
    double fontSize = 10;
    Align textAlign = Align.left;
}

private struct Point { double x, y; }
private struct Subpath { Point[] points; bool closed; }
/// An edge of one of two shapes a fill takes the union of.
private struct Edge { double x0, y0, x1, y1; int dir; int shape; }

/// Rows a pixel is sampled at, top to bottom. Across a row coverage is exact.
enum SUB = 16;

/// How far a flattened curve may stray from the curve, in device pixels.
private enum TOLERANCE = 0.02;

final class Canvas {
    immutable uint width, height; // device pixels
    immutable double scale;
    /// Premultiplied RGBA, row after row.
    ubyte[] pixels;

    private State state;
    private State[] saved;
    private Subpath[] path;
    private const(Font)* font;

    /// A canvas of width × height user units, drawn at scale device pixels to
    /// the unit, transparent throughout.
    this(uint width, uint height, double scale, ref const Font font) {
        this.width = cast(uint)(width * scale);
        this.height = cast(uint)(height * scale);
        this.scale = scale;
        this.font = &font;
        pixels = new ubyte[](cast(size_t) this.width * this.height * 4);
    }

    // -- state ---------------------------------------------------------------

    void save() { saved ~= state; }
    void restore() {
        if (saved.length == 0) return;
        state = saved[$ - 1];
        saved = saved[0 .. $ - 1];
    }

    @property void fillStyle(Colour c) { state.fill = Paint(c); }
    @property void fillStyle(Gradient g) { state.fill = Paint(Colour.init, g); }
    @property void fillStyle(Pattern p) { state.fill = Paint(Colour.init, null, p); }
    @property void strokeStyle(Colour c) { state.stroke = Paint(c); }
    @property void lineWidth(double w) { state.lineWidth = w; }
    @property void lineCap(Cap c) { state.lineCap = c; }
    @property void lineJoin(Join j) { state.lineJoin = j; }
    @property void globalCompositeOperation(Composite c) { state.composite = c; }
    @property void textAlign(Align a) { state.textAlign = a; }
    /// The font's size in px: `${px}px "Sugarpie"`.
    @property void fontSize(double px) { state.fontSize = px; }

    Gradient createLinearGradient(double x0, double y0, double x1, double y1) {
        auto g = new Gradient;
        g.x0 = x0; g.y0 = y0; g.x1 = x1; g.y1 = y1;
        return g;
    }

    Gradient createRadialGradient(double x0, double y0, double r0, double x1, double y1, double r1) {
        // The page only draws circles about one centre, from radius 0.
        assert(x0 == x1 && y0 == y1 && r0 == 0, "a radial gradient other than one circle from its centre");
        auto g = new Gradient;
        g.radial = true;
        g.x0 = x0; g.y0 = y0; g.r0 = r0; g.x1 = x1; g.y1 = y1; g.r1 = r1;
        return g;
    }

    /// RGBA not premultiplied, as putImageData takes it. The canvas keeps it
    /// premultiplied, rounded to 8 bits, the way a browser's canvas does.
    Pattern createPattern(const(ubyte)[] rgba, uint width, uint height) {
        auto p = new Pattern;
        auto premultiplied = new ubyte[](rgba.length);
        for (size_t i = 0; i < rgba.length; i += 4) {
            immutable a = rgba[i + 3];
            foreach (k; 0 .. 3) premultiplied[i + k] = cast(ubyte)((rgba[i + k] * a + 127) / 255);
            premultiplied[i + 3] = a;
        }
        p.premultiplied = premultiplied;
        p.width = width;
        p.height = height;
        return p;
    }

    // -- the path ------------------------------------------------------------

    void beginPath() { path = null; }

    void moveTo(double x, double y) { path ~= Subpath([Point(x * scale, y * scale)]); }

    void lineTo(double x, double y) {
        if (path.length == 0) { moveTo(x, y); return; }
        path[$ - 1].points ~= Point(x * scale, y * scale);
    }

    /// The page only ever strokes its curves, so a curve is taken here the way
    /// Chrome's stroker (Skia's SkPathStroker::quadTo) takes one: a curve whose
    /// control point lies within √(5e-6) of its longest extent from the line
    /// through its outer points is drawn straight, or as two straight lines
    /// meeting where it bends most. Only a curve that bends more is a curve.
    void quadraticCurveTo(double cx, double cy, double x, double y) {
        if (path.length == 0) moveTo(cx, cy);
        auto pts = &path[$ - 1].points;
        immutable a = (*pts)[$ - 1], b = Point(cx * scale, cy * scale), c = Point(x * scale, y * scale);
        immutable flatAB = a.x == b.x && a.y == b.y, flatBC = b.x == c.x && b.y == c.y;
        if (flatAB || flatBC) { *pts ~= c; return; }
        if (!quadInLine(a, b, c)) { quadInto(*pts, a, b, c); return; }
        immutable t = quadMaxCurvature(a, b, c);
        if (t > 0 && t < 1) {
            immutable u = 1 - t;
            *pts ~= Point(u * u * a.x + 2 * u * t * b.x + t * t * c.x, u * u * a.y + 2 * u * t * b.y + t * t * c.y);
        }
        *pts ~= c;
    }

    void rect(double x, double y, double w, double h) {
        path ~= Subpath([
            Point(x * scale, y * scale), Point((x + w) * scale, y * scale),
            Point((x + w) * scale, (y + h) * scale), Point(x * scale, (y + h) * scale),
        ], true);
    }

    void closePath() { if (path.length) path[$ - 1].closed = true; }

    // -- drawing -------------------------------------------------------------

    /// Everything drawn from here on is drawn only where the path is, too.
    void clip() {
        auto edges = fillEdges(path);
        int bx0, by0, bx1, by1;
        bounds(edges, bx0, by0, bx1, by1);
        auto m = new Mask;
        m.x0 = bx0; m.y0 = by0; m.x1 = bx1; m.y1 = by1;
        m.alpha = new ubyte[](cast(size_t)(bx1 - bx0) * (by1 - by0));
        auto parent = state.clip;
        scan(edges, bx0, by0, bx1, by1, (int y, int from, const(float)[] cover) {
            foreach (i, c; cover) {
                immutable x = from + cast(int) i;
                uint a = toByte(c);
                if (parent !is null) a = mulDiv255(a, parent.at(x, y));
                m.alpha[(y - by0) * (bx1 - bx0) + (x - bx0)] = cast(ubyte) a;
            }
        });
        state.clip = m;
    }

    void stroke() {
        auto edges = strokeEdges(path, state.lineWidth * scale, state.lineCap, state.lineJoin);
        paintEdges(edges, state.stroke);
    }

    void fillRect(double x, double y, double w, double h) {
        immutable x0 = x * scale, y0 = y * scale, x1 = (x + w) * scale, y1 = (y + h) * scale;
        int bx0 = cast(int) floor(x0), by0 = cast(int) floor(y0);
        int bx1 = cast(int) ceil(x1), by1 = cast(int) ceil(y1);
        clampToClip(bx0, by0, bx1, by1);
        auto cover = new float[](bx1 > bx0 ? bx1 - bx0 : 0);
        foreach (py; by0 .. by1) {
            immutable cy = overlap(py, y0, y1);
            foreach (px; bx0 .. bx1) cover[px - bx0] = cast(float)(cy * overlap(px, x0, x1));
            blendRow(py, bx0, cover, state.fill);
        }
    }

    /// Text on its alphabetic baseline at x, y, placed by textAlign.
    void fillText(string text, double x, double y) {
        immutable k = state.fontSize / font.unitsPerEm;
        const(Glyph)*[] glyphs;
        double width = 0;
        foreach (dchar ch; text) {
            auto g = font.glyph(ch);
            glyphs ~= g;
            width += g.advance * k;
        }
        double pen = x;
        if (state.textAlign == Align.center) pen -= width / 2;
        else if (state.textAlign == Align.right) pen -= width;

        Subpath[] outlines;
        foreach (g; glyphs) {
            immutable ox = pen * scale, oy = y * scale, s = k * scale;
            Point at(double fx, double fy) { return Point(ox + fx * s, oy - fy * s); }
            foreach (step; g.outline) final switch (step.kind) {
                case Step.Kind.move:
                    outlines ~= Subpath([at(step.x, step.y)], true);
                    break;
                case Step.Kind.line:
                    outlines[$ - 1].points ~= at(step.x, step.y);
                    break;
                case Step.Kind.quad:
                    quadInto(outlines[$ - 1].points, outlines[$ - 1].points[$ - 1], at(step.cx, step.cy), at(step.x, step.y));
                    break;
            }
            pen += g.advance * k;
        }
        // The page was drawn by Chrome on macOS, where glyphs go through
        // CoreText, and CoreText grows every outline: at the strip's sizes
        // (39 to 84 device pixels) by min(size / 150, 0.35) device pixels all
        // round, measured against Chrome's own text. The outline is grown by
        // taking it together with a round-joined stroke of twice that width.
        immutable grow = state.fontSize * scale / 150 < 0.35 ? state.fontSize * scale / 150 : 0.35;
        auto edges = fillEdges(outlines, false);
        auto around = strokeEdges(outlines, 2 * grow, Cap.round, Join.round, false);
        foreach (ref e; around) e.shape = 1;
        paintEdges(edges ~ around, state.fill);
    }

    /// The pixels as a PNG takes them: RGBA, not premultiplied.
    ubyte[] unpremultiplied() const {
        auto out_ = new ubyte[](pixels.length);
        for (size_t i = 0; i < pixels.length; i += 4) {
            immutable a = pixels[i + 3];
            if (a == 0) continue;
            foreach (k; 0 .. 3) {
                immutable v = (pixels[i + k] * 255 + a / 2) / a;
                out_[i + k] = cast(ubyte)(v > 255 ? 255 : v);
            }
            out_[i + 3] = a;
        }
        return out_;
    }

    // -- inside --------------------------------------------------------------

    private void paintEdges(Edge[] edges, ref const Paint paint) {
        int bx0, by0, bx1, by1;
        bounds(edges, bx0, by0, bx1, by1);
        clampToClip(bx0, by0, bx1, by1);
        scan(edges, bx0, by0, bx1, by1, (int y, int from, const(float)[] cover) {
            blendRow(y, from, cover, paint);
        });
    }

    private void bounds(const Edge[] edges, out int x0, out int y0, out int x1, out int y1) {
        double minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
        foreach (e; edges) {
            if (e.x0 < minX) minX = e.x0; if (e.x1 < minX) minX = e.x1;
            if (e.x0 > maxX) maxX = e.x0; if (e.x1 > maxX) maxX = e.x1;
            if (e.y0 < minY) minY = e.y0;
            if (e.y1 > maxY) maxY = e.y1;
        }
        if (edges.length == 0) return;
        x0 = cast(int) floor(minX < 0 ? 0 : minX);
        y0 = cast(int) floor(minY < 0 ? 0 : minY);
        x1 = cast(int) ceil(maxX > width ? width : maxX);
        y1 = cast(int) ceil(maxY > height ? height : maxY);
        if (x1 < x0) x1 = x0;
        if (y1 < y0) y1 = y0;
    }

    private void clampToClip(ref int x0, ref int y0, ref int x1, ref int y1) {
        int cx0 = 0, cy0 = 0, cx1 = width, cy1 = height;
        if (state.clip !is null) { cx0 = state.clip.x0; cy0 = state.clip.y0; cx1 = state.clip.x1; cy1 = state.clip.y1; }
        if (x0 < cx0) x0 = cx0; if (y0 < cy0) y0 = cy0;
        if (x1 > cx1) x1 = cx1; if (y1 > cy1) y1 = cy1;
        if (x1 < x0) x1 = x0;
        if (y1 < y0) y1 = y0;
    }

    /// One row of coverage, drawn with a paint under the clip and the
    /// composite operation.
    ///
    /// A colour is drawn in 8 bits, as Chrome draws it, measured against
    /// Chrome square by square: its alpha rounded to 8 bits and the colour
    /// premultiplied by that, rounded. Over the canvas it goes the way Skia's
    /// 8-bit blitter takes it (SkARGB32_Blitter): scaled by coverage + 1 and
    /// shifted down 8, then added to what is there times 256 minus its alpha,
    /// shifted down 8. Multiplied, it goes through Skia's 8-bit pipeline:
    /// s(1 - da) + d(1 - sa) + sd over 255, rounded, then mixed into what is
    /// there by coverage over 255, rounded.
    ///
    /// Gradients and patterns are worked out in floating point, dithered, and
    /// rounded once.
    private void blendRow(int y, int from, const(float)[] cover, ref const Paint paint) {
        auto clip = state.clip;
        immutable op = state.composite;
        double sr, sg, sb, sa;
        immutable solid = paint.gradient is null && paint.pattern is null;
        uint[4] s8;
        if (solid) {
            immutable c = paint.colour;
            immutable a8 = cast(uint) floor(c.a * 255 + .5);
            s8 = [div255(c.r * a8), div255(c.g * a8), div255(c.b * a8), a8];
        }
        foreach (i, c; cover) {
            if (c <= 0) continue;
            immutable x = from + cast(int) i;
            uint a = toByte(c);
            if (clip !is null) a = mulDiv255(a, clip.at(x, y));
            if (a == 0) continue;
            auto d = pixels[(cast(size_t) y * width + x) * 4 .. (cast(size_t) y * width + x) * 4 + 4];
            if (solid && op == Composite.sourceOver) {
                uint[4] sc = s8;
                if (a < 255) foreach (k; 0 .. 4) sc[k] = (s8[k] * (a + 1)) >> 8;
                foreach (k; 0 .. 4) d[k] = cast(ubyte)(sc[k] + ((d[k] * (256 - sc[3])) >> 8));
                continue;
            }
            if (solid && op == Composite.multiply) {
                immutable da = d[3];
                foreach (k; 0 .. 3) {
                    immutable m = div255(s8[k] * (255 - da) + d[k] * (255 - s8[3]) + s8[k] * d[k]);
                    d[k] = cast(ubyte) div255(d[k] * (255 - a) + m * a);
                }
                immutable ma = s8[3] + div255(da * (255 - s8[3]));
                d[3] = cast(ubyte) div255(da * (255 - a) + ma * a);
                continue;
            }
            source(paint, x, y, sr, sg, sb, sa);
            dither(x, y, sr, sg, sb, sa);
            immutable cov = a / 255.0;
            immutable dr = d[0] / 255.0, dg = d[1] / 255.0, db = d[2] / 255.0, da = d[3] / 255.0;
            double r, g, b, al;
            final switch (op) {
                case Composite.sourceOver:
                    r = sr * cov + dr * (1 - sa * cov);
                    g = sg * cov + dg * (1 - sa * cov);
                    b = sb * cov + db * (1 - sa * cov);
                    al = sa * cov + da * (1 - sa * cov);
                    break;
                case Composite.multiply:
                    immutable mr = sr * (1 - da) + dr * (1 - sa) + sr * dr;
                    immutable mg = sg * (1 - da) + dg * (1 - sa) + sg * dg;
                    immutable mb = sb * (1 - da) + db * (1 - sa) + sb * db;
                    immutable ma = sa + da - sa * da;
                    r = dr + (mr - dr) * cov;
                    g = dg + (mg - dg) * cov;
                    b = db + (mb - db) * cov;
                    al = da + (ma - da) * cov;
                    break;
            }
            d[0] = unit(r); d[1] = unit(g); d[2] = unit(b); d[3] = unit(al);
        }
    }

    /// What a gradient or pattern paints at the centre of device pixel x, y,
    /// premultiplied, 0 to 1.
    private void source(ref const Paint paint, int x, int y, out double r, out double g, out double b, out double a) {
        immutable ux = (x + 0.5) / scale, uy = (y + 0.5) / scale;
        if (paint.pattern !is null) {
            auto p = paint.pattern;
            immutable fx = ux - 0.5, fy = uy - 0.5;
            immutable ix = cast(int) floor(fx), iy = cast(int) floor(fy);
            immutable tx = fx - ix, ty = fy - iy;
            double[4] sum = 0;
            foreach (j; 0 .. 2) foreach (i; 0 .. 2) {
                immutable w = (i ? tx : 1 - tx) * (j ? ty : 1 - ty);
                immutable px = ((ix + i) % cast(int) p.width + p.width) % p.width;
                immutable py = ((iy + j) % cast(int) p.height + p.height) % p.height;
                immutable at = (py * p.width + px) * 4;
                foreach (k; 0 .. 4) sum[k] += w * p.premultiplied[at + k];
            }
            r = sum[0] / 255; g = sum[1] / 255; b = sum[2] / 255; a = sum[3] / 255;
            return;
        }
        auto gr = paint.gradient;
        double t;
        if (gr.radial) {
            immutable dx = ux - gr.x0, dy = uy - gr.y0;
            t = sqrt(dx * dx + dy * dy) / gr.r1;
        } else {
            immutable vx = gr.x1 - gr.x0, vy = gr.y1 - gr.y0;
            t = ((ux - gr.x0) * vx + (uy - gr.y0) * vy) / (vx * vx + vy * vy);
        }
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        auto stops = gr.stops;
        Colour c = stops[$ - 1].colour;
        double cr = c.r, cg = c.g, cb = c.b, ca = c.a;
        if (t <= stops[0].offset) { c = stops[0].colour; cr = c.r; cg = c.g; cb = c.b; ca = c.a; }
        else foreach (k; 1 .. stops.length) {
            if (t > stops[k].offset) continue;
            immutable lo = stops[k - 1], hi = stops[k];
            immutable f = hi.offset > lo.offset ? (t - lo.offset) / (hi.offset - lo.offset) : 1;
            cr = lo.colour.r + (hi.colour.r - lo.colour.r) * f;
            cg = lo.colour.g + (hi.colour.g - lo.colour.g) * f;
            cb = lo.colour.b + (hi.colour.b - lo.colour.b) * f;
            ca = lo.colour.a + (hi.colour.a - lo.colour.a) * f;
            break;
        }
        a = ca;
        r = cr / 255 * ca; g = cg / 255 * ca; b = cb / 255 * ca;
    }
}

/// A gradient or pattern is dithered before it is drawn, as a browser's
/// canvas dithers it: an 8 by 8 ordered dither of just under half a step of 8
/// bits, up or down, never past the alpha.
private void dither(int x, int y, ref double r, ref double g, ref double b, double a) {
    immutable uint X = x, Y = y ^ x;
    immutable M = (Y & 1) << 5 | (X & 1) << 4 | (Y & 2) << 2 | (X & 2) << 1 | (Y & 4) >> 1 | (X & 4) >> 2;
    immutable d = (M * (2 / 128.0) - 63 / 128.0) / 255;
    double clamp(double v) { return v < 0 ? 0 : v > a ? a : v; }
    r = clamp(r + d); g = clamp(g + d); b = clamp(b + d);
}

private ubyte unit(double v) {
    if (v <= 0) return 0;
    if (v >= 1) return 255;
    return cast(ubyte)(v * 255 + 0.5);
}

private uint toByte(float c) {
    if (c >= 1) return 255;
    return cast(uint)(c * 255 + 0.5f);
}

private uint mulDiv255(uint a, uint b) { return (a * b + 127) / 255; }

/// v / 255, rounded.
private uint div255(uint v) { return (v + 127) / 255; }

/// How much of the unit from p to p + 1 lies between lo and hi.
private double overlap(int p, double lo, double hi) {
    immutable a = lo > p ? lo : p, b = hi < p + 1 ? hi : p + 1;
    return b > a ? b - a : 0;
}

/// A quadratic Bézier from `from`, as short lines no further than TOLERANCE
/// from the curve.
private void quadInto(ref Point[] points, Point from, Point control, Point to) {
    immutable ddx = from.x - 2 * control.x + to.x, ddy = from.y - 2 * control.y + to.y;
    immutable dd = sqrt(ddx * ddx + ddy * ddy);
    immutable n = dd > 0 ? cast(int) ceil(sqrt(dd / (8 * TOLERANCE))) : 1;
    foreach (i; 1 .. n + 1) {
        immutable t = cast(double) i / n, u = 1 - t;
        points ~= Point(u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                        u * u * from.y + 2 * u * t * control.y + t * t * to.y);
    }
}

/// Skia's quad_in_line: the middle point of the three (by their longest
/// extent) lies within √(5e-6) of that extent of the line through the other two.
private bool quadInLine(Point p0, Point p1, Point p2) {
    immutable Point[3] q = [p0, p1, p2];
    double most = -1;
    int outer1, outer2;
    foreach (i; 0 .. 2) foreach (j; i + 1 .. 3) {
        immutable dx = abs(q[j].x - q[i].x), dy = abs(q[j].y - q[i].y);
        immutable m = dx > dy ? dx : dy;
        if (most < m) { outer1 = i; outer2 = j; most = m; }
    }
    immutable mid = outer1 ^ outer2 ^ 3;
    immutable slop = most * most * 0.000005;
    // The squared distance from the middle point to the segment between the outer two.
    immutable s = q[outer1], e = q[outer2], p = q[mid];
    immutable dx = e.x - s.x, dy = e.y - s.y;
    immutable t = (dx * (p.x - s.x) + dy * (p.y - s.y)) / (dx * dx + dy * dy);
    double hx = s.x, hy = s.y;
    if (t >= 0 && t <= 1) { hx = s.x * (1 - t) + e.x * t; hy = s.y * (1 - t) + e.y * t; }
    return (p.x - hx) * (p.x - hx) + (p.y - hy) * (p.y - hy) <= slop;
}

/// Skia's SkFindQuadMaxCurvature: where along the curve it bends most, 0 to 1.
private double quadMaxCurvature(Point p0, Point p1, Point p2) {
    immutable ax = p1.x - p0.x, ay = p1.y - p0.y;
    immutable bx = p0.x - p1.x - p1.x + p2.x, by = p0.y - p1.y - p1.y + p2.y;
    immutable numer = -(ax * bx + ay * by), denom = bx * bx + by * by;
    if (numer <= 0) return 0;
    if (numer >= denom) return 1;
    return numer / denom;
}

/// Every subpath closed, as a fill takes it.
private Edge[] fillEdges(const Subpath[] paths, bool snap = true) {
    Edge[] edges;
    foreach (sp; paths) {
        immutable n = sp.points.length;
        foreach (i; 0 .. n) edges.addEdge(sp.points[i], sp.points[(i + 1) % n], snap);
    }
    return edges;
}

/// A path's edge. Snapped, its ends move up or down to the nearest quarter
/// pixel, as Skia's scan converter moves them (SkAnalyticEdge's SnapY); across,
/// an edge stays where it is. Glyphs are not snapped: Chrome's come from
/// CoreText, not from Skia's scan converter.
private void addEdge(ref Edge[] edges, Point a, Point b, bool snap = true) {
    if (snap) {
        a.y = floor(a.y * 4 + .5) / 4;
        b.y = floor(b.y * 4 + .5) / 4;
    }
    if (a.y == b.y) return;
    if (a.y < b.y) edges ~= Edge(a.x, a.y, b.x, b.y, 1);
    else edges ~= Edge(b.x, b.y, a.x, a.y, -1);
}

/// The outline of a stroke, as shapes that all wind one way, so a nonzero
/// fill of them is their union: a band along each line, and a disc wherever
/// a round cap or join rounds it off.
private Edge[] strokeEdges(const Subpath[] paths, double width, Cap cap, Join join, bool snap = true) {
    Edge[] edges;
    immutable half = width / 2;
    foreach (sp; paths) {
        Point[] pts;
        foreach (p; sp.points) if (pts.length == 0 || p.x != pts[$ - 1].x || p.y != pts[$ - 1].y) pts ~= p;
        // A closed subpath ends where it began, once.
        if (sp.closed && pts.length > 1 && (pts[$ - 1].x != pts[0].x || pts[$ - 1].y != pts[0].y)) pts ~= pts[0];
        if (pts.length < 2) {
            if (pts.length == 1 && cap == Cap.round) edges.addDisc(pts[0], half, snap);
            continue;
        }
        foreach (i; 1 .. pts.length) {
            immutable a = pts[i - 1], b = pts[i];
            immutable dx = b.x - a.x, dy = b.y - a.y, len = sqrt(dx * dx + dy * dy);
            immutable nx = -dy / len * half, ny = dx / len * half;
            immutable p0 = Point(a.x + nx, a.y + ny), p1 = Point(b.x + nx, b.y + ny);
            immutable p2 = Point(b.x - nx, b.y - ny), p3 = Point(a.x - nx, a.y - ny);
            edges.addEdge(p0, p1, snap); edges.addEdge(p1, p2, snap); edges.addEdge(p2, p3, snap); edges.addEdge(p3, p0, snap);
        }
        immutable joins = pts.length - 2 + (sp.closed ? 1 : 0);
        if (joins > 0) {
            // Only round joins are drawn: the page joins lines no other way.
            assert(join == Join.round, "a stroke that bends with a join other than round");
            foreach (i; 1 .. pts.length - 1) edges.addDisc(pts[i], half, snap);
            if (sp.closed) edges.addDisc(pts[0], half, snap);
        }
        if (!sp.closed && cap == Cap.round) {
            edges.addDisc(pts[0], half, snap);
            edges.addDisc(pts[$ - 1], half, snap);
        }
    }
    return edges;
}

/// A disc, wound the way strokeEdges winds its bands.
private void addDisc(ref Edge[] edges, Point c, double r, bool snap) {
    immutable n = r > TOLERANCE ? cast(int) ceil(PI / acos(1 - TOLERANCE / r)) : 8;
    immutable steps = n < 8 ? 8 : n;
    Point prev = Point(c.x + r, c.y);
    foreach (i; 1 .. steps + 1) {
        immutable t = -2 * PI * i / steps;
        immutable p = i == steps ? Point(c.x + r, c.y) : Point(c.x + r * cos(t), c.y + r * sin(t));
        edges.addEdge(prev, p, snap);
        prev = p;
    }
}

/// Coverage of a nonzero fill of edges within [x0, x1) × [y0, y1), row by row.
/// Each pixel row is sampled at SUB rows; along each, the spans inside are
/// taken exactly, to the fraction of a pixel.
private void scan(Edge[] edges, int x0, int y0, int x1, int y1, scope void delegate(int y, int from, const(float)[] cover) sink) {
    if (x1 <= x0 || y1 <= y0 || edges.length == 0) return;
    import std.algorithm : sort;
    edges.sort!((a, b) => a.y0 < b.y0);

    immutable w = x1 - x0;
    auto area = new float[](w + 1), delta = new float[](w + 2), cover = new float[](w);
    area[] = 0; // D starts a float at NaN
    delta[] = 0;
    Edge[] active;
    size_t next;
    struct Crossing { double x; int dir; int shape; }
    // Kept from one sample row to the next: filled from the start each time.
    auto buffer = new Crossing[](16);

    foreach (y; y0 .. y1) {
        // The edges this row reaches.
        size_t keep;
        foreach (e; active) if (e.y1 > y) active[keep++] = e;
        active = active[0 .. keep];
        while (next < edges.length && edges[next].y0 < y + 1) {
            if (edges[next].y1 > y) active ~= edges[next];
            next++;
        }
        if (active.length == 0) continue;

        // area and delta are zero here: each row clears what it touched.
        int lo = w, hi = -1;
        foreach (k; 0 .. SUB) {
            immutable sy = y + (k + 0.5) / SUB;
            size_t n;
            foreach (e; active) {
                if (sy < e.y0 || sy >= e.y1) continue;
                if (n == buffer.length) buffer.length *= 2;
                buffer[n++] = Crossing(e.x0 + (sy - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0), e.dir, e.shape);
            }
            auto crossings = buffer[0 .. n];
            // Few crossings a row: insertion sort.
            foreach (i; 1 .. crossings.length) {
                auto c = crossings[i];
                size_t j = i;
                while (j > 0 && crossings[j - 1].x > c.x) { crossings[j] = crossings[j - 1]; j--; }
                crossings[j] = c;
            }
            // Inside is inside either shape, each by nonzero winding.
            int[2] winding;
            double start;
            foreach (c; crossings) {
                immutable was = winding[0] != 0 || winding[1] != 0;
                winding[c.shape] += c.dir;
                immutable now = winding[0] != 0 || winding[1] != 0;
                if (!was && now) start = c.x;
                else if (was && !now) span(start - x0, c.x - x0, 1.0f / SUB, w, area, delta, lo, hi);
            }
        }
        if (hi < lo) continue;
        // Nothing lies left of lo: a span's whole pixels start after its first.
        float run = 0;
        foreach (i; lo .. hi + 1) {
            run += delta[i];
            cover[i] = area[i] + run;
        }
        sink(y, x0 + lo, cover[lo .. hi + 1]);
        area[lo .. hi + 2 < area.length ? hi + 2 : area.length] = 0;
        delta[lo .. hi + 3 < delta.length ? hi + 3 : delta.length] = 0;
    }
}

/// Adds a span from a to b (pixels from the row's start) at weight wt:
/// fractions where it begins and ends, whole pixels between as a running sum.
private void span(double a, double b, float wt, int w, float[] area, float[] delta, ref int lo, ref int hi) {
    if (a < 0) a = 0;
    if (b > w) b = w;
    if (b <= a) return;
    immutable ia = cast(int) floor(a), ib = cast(int) floor(b);
    if (ia < lo) lo = ia;
    immutable last = ib < w ? ib : w - 1;
    if (last > hi) hi = last;
    if (ia == ib) { area[ia] += cast(float)(b - a) * wt; return; }
    area[ia] += cast(float)(ia + 1 - a) * wt;
    delta[ia + 1] += wt;
    delta[ib] -= wt;
    if (ib < w) area[ib] += cast(float)(b - ib) * wt;
}

unittest {
    import plugin.font : font = sugarpie;

    // A rectangle on whole pixels covers them wholly; half a pixel, half.
    auto cv = new Canvas(4, 1, 1, font);
    cv.fillStyle = Colour(255, 0, 0, 1);
    cv.fillRect(0, 0, 1.5, 1);
    assert(cv.pixels[0 .. 4] == [255, 0, 0, 255]);
    assert(cv.pixels[4 .. 8] == [128, 0, 0, 128]);
    assert(cv.pixels[8 .. 12] == [0, 0, 0, 0]);

    // A path fill agrees with the rectangle: whole, half, none.
    auto path = new Canvas(4, 1, 1, font);
    path.beginPath();
    path.rect(0, 0, 1.5, 1);
    path.clip();
    path.fillStyle = Colour(255, 0, 0, 1);
    path.fillRect(0, 0, 4, 1);
    assert(path.pixels[0 .. 12] == cv.pixels[0 .. 12]);

    // Multiply darkens by the colour; on nothing it is the colour, as over.
    auto m = new Canvas(2, 1, 1, font);
    m.fillStyle = Colour(200, 200, 200, 1);
    m.fillRect(0, 0, 1, 1);
    m.globalCompositeOperation = Composite.multiply;
    m.fillStyle = Colour(128, 255, 0, 1);
    m.fillRect(0, 0, 2, 1);
    assert(m.pixels[0 .. 4] == [100, 200, 0, 255]);
    assert(m.pixels[4 .. 8] == [128, 255, 0, 255]);

    // On the paper's colour, what Chrome drew for the page's grid lines (over)
    // and its pencil and green blocks (multiplied), square by square.
    foreach (t; [
        [95, 102, 112, 15, 0, 206, 193, 165],
        [95, 102, 112, 34, 0, 181, 173, 152],
        [44, 40, 34, 80, 1, 76, 68, 53],
        [72, 128, 72, 55, 1, 137, 152, 106],
    ]) {
        auto sq = new Canvas(1, 1, 1, font);
        sq.fillStyle = Colour(0xe2, 0xd2, 0xae);
        sq.fillRect(0, 0, 1, 1);
        if (t[4]) sq.globalCompositeOperation = Composite.multiply;
        sq.fillStyle = Colour(t[0], t[1], t[2], t[3] / 100.0);
        sq.fillRect(0, 0, 1, 1);
        assert(sq.pixels[0 .. 3] == [t[5], t[6], t[7]]);
    }

    // Two strokes of one line crossing themselves are still one line: the
    // union, not the sum.
    auto s = new Canvas(8, 8, 1, font);
    s.strokeStyle = Colour(0, 0, 0, 1);
    s.lineWidth = 2;
    s.lineCap = Cap.round;
    s.lineJoin = Join.round;
    s.beginPath();
    s.moveTo(1, 4); s.lineTo(7, 4); s.lineTo(1, 4.0001);
    s.stroke();
    assert(s.pixels[(4 * 8 + 4) * 4 + 3] == 255);
    assert(s.pixels[(0 * 8 + 4) * 4 + 3] == 0);
}
