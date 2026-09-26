/// PNG, written: the weekly strip leaves datapunt as one, for QNTX's mail to
/// carry inline (teranos/QNTX#1002 takes image/png only).
module plugin.png;

import std.digest.crc : crc32Of;
import std.zlib : compress;

/// RGBA, 8 bits a channel, not premultiplied: what a canvas hands toDataURL.
/// Every row is filtered with Paeth, and deflated at level 9.
ubyte[] encodePNG(const(ubyte)[] rgba, uint width, uint height) {
    assert(rgba.length == cast(size_t) width * height * 4, "rgba is not width * height pixels");
    immutable stride = cast(size_t) width * 4;

    auto filtered = new ubyte[](height * (stride + 1));
    foreach (y; 0 .. height) {
        auto row = rgba[y * stride .. (y + 1) * stride];
        auto up = y ? rgba[(y - 1) * stride .. y * stride] : null;
        auto out_ = filtered[y * (stride + 1) .. (y + 1) * (stride + 1)];
        out_[0] = 4; // Paeth
        foreach (i; 0 .. stride) {
            int a = i >= 4 ? row[i - 4] : 0;
            int b = up ? up[i] : 0;
            int c = up && i >= 4 ? up[i - 4] : 0;
            out_[i + 1] = cast(ubyte)(row[i] - paeth(a, b, c));
        }
    }

    ubyte[] png = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'];
    ubyte[13] header;
    header[0 .. 4] = be(width);
    header[4 .. 8] = be(height);
    header[8] = 8;  // bits a channel
    header[9] = 6;  // RGBA
    header[10] = 0; // deflate
    header[11] = 0; // adaptive filtering
    header[12] = 0; // not interlaced
    chunk(png, "IHDR", header[]);
    chunk(png, "IDAT", compress(filtered, 9));
    chunk(png, "IEND", null);
    return png;
}

private int paeth(int a, int b, int c) {
    immutable p = a + b - c;
    immutable pa = p > a ? p - a : a - p;
    immutable pb = p > b ? p - b : b - p;
    immutable pc = p > c ? p - c : c - p;
    if (pa <= pb && pa <= pc) return a;
    return pb <= pc ? b : c;
}

private ubyte[4] be(uint v) {
    return [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];
}

private void chunk(ref ubyte[] png, string type, const(ubyte)[] data) {
    png ~= be(cast(uint) data.length);
    auto typed = cast(const(ubyte)[]) type ~ data;
    png ~= typed;
    // crc32Of gives the checksum least significant byte first; PNG stores it
    // most significant first.
    auto crc = crc32Of(typed);
    png ~= [crc[3], crc[2], crc[1], crc[0]];
}

unittest {
    import std.zlib : uncompress;

    // Two pixels on two rows, read back: the signature, IHDR, and the rows
    // under their filter byte.
    ubyte[] rgba = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
    auto png = encodePNG(rgba, 2, 2);
    assert(png[0 .. 8] == [0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n']);
    assert(png[12 .. 16] == "IHDR");
    assert(png[16 .. 24] == [0, 0, 0, 2, 0, 0, 0, 2]);
    // IHDR's crc, as zlib computes it over "IHDR" and its 13 bytes.
    auto ihdrCrc = crc32Of(png[12 .. 29]);
    assert(png[29 .. 33] == [ihdrCrc[3], ihdrCrc[2], ihdrCrc[1], ihdrCrc[0]]);

    immutable idatLength = (png[33] << 24) | (png[34] << 16) | (png[35] << 8) | png[36];
    assert(png[37 .. 41] == "IDAT");
    auto rows = cast(ubyte[]) uncompress(png[41 .. 41 + idatLength]);
    assert(rows.length == 2 * (1 + 8));

    // Undo Paeth and the pixels come back.
    ubyte[] back;
    foreach (y; 0 .. 2) {
        assert(rows[y * 9] == 4);
        foreach (i; 0 .. 8) {
            int a = i >= 4 ? back[y * 8 + i - 4] : 0;
            int b = y ? back[(y - 1) * 8 + i] : 0;
            int c = y && i >= 4 ? back[(y - 1) * 8 + i - 4] : 0;
            back ~= cast(ubyte)(rows[y * 9 + 1 + i] + paeth(a, b, c));
        }
    }
    assert(back == rgba);
    assert(png[$ - 8 .. $ - 4] == "IEND");
}
