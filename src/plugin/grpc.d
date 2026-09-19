/// gRPC over HTTP/2, both ways: the plugin answers the node, and asks the
/// node's ATSStore. Forked from faal's grpc.d in QNTX.
///
/// Three things differ. A response is split into frames the peer accepts; a
/// call reads until the stream ends, not for a fixed number of frames; and a
/// call that ends with a grpc-status other than 0 says so instead of handing
/// back nothing.
module plugin.grpc;

import plugin.hpack;
import plugin.log;
import std.socket;
import std.conv : to;
import core.time : dur;

// ---------------------------------------------------------------------------
// HTTP/2 frames
// ---------------------------------------------------------------------------

enum FrameType : ubyte {
    DATA          = 0x0,
    HEADERS       = 0x1,
    PRIORITY      = 0x2,
    RST_STREAM    = 0x3,
    SETTINGS      = 0x4,
    PUSH_PROMISE  = 0x5,
    PING          = 0x6,
    GOAWAY        = 0x7,
    WINDOW_UPDATE = 0x8,
    CONTINUATION  = 0x9,
}

enum FrameFlags : ubyte {
    NONE        = 0x0,
    END_STREAM  = 0x1,
    ACK         = 0x1,
    END_HEADERS = 0x4,
}

struct Frame {
    uint length;
    FrameType type;
    ubyte flags;
    uint streamId;
    ubyte[] payload;
}

enum H2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

// SETTINGS_MAX_FRAME_SIZE's initial value (RFC 9113, 6.5.2). Neither side here
// asks for more, so no frame this sends may carry more.
enum MAX_FRAME = 16_384;

ubyte[] readExact(Socket sock, size_t n) {
    if (n == 0) return [];
    auto buf = new ubyte[n];
    size_t total = 0;
    while (total < n) {
        auto received = sock.receive(buf[total .. n]);
        if (received <= 0) return null;
        total += received;
    }
    return buf;
}

Frame* readFrame(Socket sock) {
    auto header = readExact(sock, 9);
    if (header is null) return null;

    auto f = new Frame;
    f.length = (cast(uint)header[0] << 16) | (cast(uint)header[1] << 8) | header[2];
    f.type = cast(FrameType)header[3];
    f.flags = header[4];
    f.streamId = ((cast(uint)header[5] << 24) | (cast(uint)header[6] << 16) |
                  (cast(uint)header[7] << 8) | header[8]) & 0x7FFFFFFF;
    if (f.length > 0) {
        f.payload = readExact(sock, f.length);
        if (f.payload is null) return null;
    }
    return f;
}

bool writeFrame(Socket sock, FrameType type, ubyte flags, uint streamId, const ubyte[] payload) {
    uint len = cast(uint)payload.length;
    ubyte[9] header;
    header[0] = cast(ubyte)(len >> 16);
    header[1] = cast(ubyte)(len >> 8);
    header[2] = cast(ubyte)(len);
    header[3] = cast(ubyte)type;
    header[4] = flags;
    header[5] = cast(ubyte)(streamId >> 24);
    header[6] = cast(ubyte)(streamId >> 16);
    header[7] = cast(ubyte)(streamId >> 8);
    header[8] = cast(ubyte)(streamId);

    if (sock.send(header[]) != 9) return false;
    size_t sent = 0;
    while (sent < payload.length) {
        auto n = sock.send(payload[sent .. $]);
        if (n <= 0) return false;
        sent += n;
    }
    return true;
}

/// DATA frames of at most MAX_FRAME bytes, the last one ending the stream when
/// asked to. An empty payload is one empty frame.
bool writeData(Socket sock, uint streamId, const ubyte[] data, bool endStream) {
    size_t at = 0;
    do {
        auto end = at + MAX_FRAME < data.length ? at + MAX_FRAME : data.length;
        ubyte flags = (endStream && end == data.length) ? FrameFlags.END_STREAM : FrameFlags.NONE;
        if (!writeFrame(sock, FrameType.DATA, flags, streamId, data[at .. end])) return false;
        at = end;
    } while (at < data.length);
    return true;
}

bool sendSettings(Socket sock) {
    return writeFrame(sock, FrameType.SETTINGS, 0, 0, []);
}

bool sendSettingsAck(Socket sock) {
    return writeFrame(sock, FrameType.SETTINGS, FrameFlags.ACK, 0, []);
}

bool sendWindowUpdate(Socket sock, uint streamId, uint increment) {
    ubyte[4] payload;
    payload[0] = cast(ubyte)(increment >> 24);
    payload[1] = cast(ubyte)(increment >> 16);
    payload[2] = cast(ubyte)(increment >> 8);
    payload[3] = cast(ubyte)(increment);
    return writeFrame(sock, FrameType.WINDOW_UPDATE, 0, streamId, payload[]);
}

// ---------------------------------------------------------------------------
// gRPC message framing: [compressed:1][length:4][data:N]
// ---------------------------------------------------------------------------

ubyte[] grpcFrame(const ubyte[] protoBytes) {
    ubyte[] result;
    result.length = 5 + protoBytes.length;
    auto len = cast(uint)protoBytes.length;
    result[1] = cast(ubyte)(len >> 24);
    result[2] = cast(ubyte)(len >> 16);
    result[3] = cast(ubyte)(len >> 8);
    result[4] = cast(ubyte)(len);
    if (protoBytes.length > 0) result[5 .. $] = protoBytes[];
    return result;
}

/// The message inside gRPC framing. False is a frame cut short; an empty
/// message is not that, and its dup is null in D.
bool grpcUnframe(const ubyte[] data, out ubyte[] message) {
    if (data.length < 5) return false;
    uint len = (cast(uint)data[1] << 24) | (cast(uint)data[2] << 16) |
               (cast(uint)data[3] << 8) | data[4];
    if (5 + cast(size_t)len > data.length) return false;
    message = data[5 .. 5 + len].dup;
    return true;
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

alias RpcHandler = ubyte[] delegate(const ubyte[] requestData);

private struct StreamContext {
    string method;
    ubyte[] data;
}

struct GrpcServer {
    RpcHandler[string] handlers;
    Socket listener;
    bool running;

    void registerHandler(string method, RpcHandler handler) {
        handlers[method] = handler;
    }

    /// Bind on loopback at the port asked for or one of the 63 above it.
    /// Zero is none of them.
    ushort bind(ushort requestedPort) {
        listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        foreach (attempt; 0 .. 64) {
            ushort tryPort = cast(ushort)(requestedPort + attempt);
            try {
                listener.bind(new InternetAddress("127.0.0.1", tryPort));
                listener.listen(5);
                running = true;
                return tryPort;
            } catch (SocketOSException) {
                continue;
            }
        }
        return 0;
    }

    /// One connection at a time, which is how the node holds one.
    void serve() {
        while (running) {
            auto client = listener.accept();
            if (client !is null) serveConnection(client);
        }
    }

    private void serveConnection(Socket sock) {
        scope(exit) sock.close();

        auto preface = readExact(sock, 24);
        if (preface is null || cast(string)preface != H2_PREFACE) return;

        sendSettings(sock);
        if (readFrame(sock) is null) return;
        sendSettingsAck(sock);
        sendWindowUpdate(sock, 0, 1_073_741_823);

        DynamicTable dynTable;
        StreamContext[uint] streams;

        while (running) {
            auto frame = readFrame(sock);
            if (frame is null) break;

            switch (frame.type) {
                case FrameType.SETTINGS:
                    if ((frame.flags & FrameFlags.ACK) == 0) sendSettingsAck(sock);
                    break;
                case FrameType.PING:
                    writeFrame(sock, FrameType.PING, FrameFlags.ACK, 0, frame.payload);
                    break;
                case FrameType.GOAWAY:
                    return;
                case FrameType.HEADERS:
                    auto id = frame.streamId;
                    if (id !in streams) streams[id] = StreamContext.init;
                    foreach (hf; decodeHeaders(frame.payload, dynTable)) {
                        if (hf.name == ":path") streams[id].method = hf.value;
                    }
                    if ((frame.flags & FrameFlags.END_STREAM) != 0) {
                        answer(sock, id, streams[id]);
                        streams.remove(id);
                    }
                    break;
                case FrameType.DATA:
                    auto id = frame.streamId;
                    if (auto ctx = id in streams) {
                        ctx.data ~= frame.payload;
                        if ((frame.flags & FrameFlags.END_STREAM) != 0) {
                            answer(sock, id, *ctx);
                            streams.remove(id);
                        }
                    }
                    if (frame.length > 0) {
                        sendWindowUpdate(sock, 0, frame.length);
                        sendWindowUpdate(sock, id, frame.length);
                    }
                    break;
                case FrameType.RST_STREAM:
                    streams.remove(frame.streamId);
                    break;
                default:
                    break;
            }
        }
    }

    private void answer(Socket sock, uint streamId, ref StreamContext ctx) {
        auto handler = ctx.method in handlers;
        if (handler is null) {
            logError("[datapunt] no handler for %s", ctx.method);
            writeFrame(sock, FrameType.HEADERS, FrameFlags.END_HEADERS, streamId, encodeResponseHeaders());
            writeFrame(sock, FrameType.HEADERS, FrameFlags.END_STREAM | FrameFlags.END_HEADERS, streamId,
                encodeLiteralHeader("grpc-status", "12") ~ encodeLiteralHeader("grpc-message", "unimplemented: " ~ ctx.method));
            return;
        }
        ubyte[] request;
        if (!grpcUnframe(ctx.data, request)) {
            logError("[datapunt] %s: the request message is cut short", ctx.method);
        }
        auto response = (*handler)(request);

        writeFrame(sock, FrameType.HEADERS, FrameFlags.END_HEADERS, streamId, encodeResponseHeaders());
        writeData(sock, streamId, grpcFrame(response), false);
        writeFrame(sock, FrameType.HEADERS, FrameFlags.END_STREAM | FrameFlags.END_HEADERS, streamId, encodeGrpcTrailers());
    }
}

// ---------------------------------------------------------------------------
// Client: one unary call
// ---------------------------------------------------------------------------

/// What one call came back with: the response message, or why there is none.
struct Called {
    ubyte[] message;
    string error;
}

/// `address` is "host:port", `method` "/protocol.ATSStoreService/…".
Called grpcCall(string address, string method, const ubyte[] requestProto, int timeoutMs = 30_000) {
    auto colon = lastIndexOf(address, ':');
    if (colon < 0) return Called(null, "no port in " ~ address);
    string host = address[0 .. colon];
    ushort port;
    try {
        port = to!ushort(address[colon + 1 .. $]);
    } catch (Exception e) {
        return Called(null, "not a port in " ~ address ~ ": " ~ e.msg);
    }

    Socket sock;
    try {
        sock = new TcpSocket();
        sock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(timeoutMs));
        sock.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, dur!"msecs"(timeoutMs));
        sock.connect(new InternetAddress(host, port));
    } catch (Exception e) {
        return Called(null, "connect to " ~ address ~ " failed: " ~ e.msg);
    }
    scope(exit) sock.close();

    if (sock.send(cast(const(ubyte)[])H2_PREFACE) != 24 || !sendSettings(sock))
        return Called(null, "could not open HTTP/2 to " ~ address);
    sendWindowUpdate(sock, 0, 1_073_741_823);

    uint streamId = 1;
    ubyte[] headers;
    headers ~= encodeIndexedHeader(3); // :method POST
    headers ~= encodeIndexedHeader(6); // :scheme http
    headers ~= encodeLiteralHeader(":path", method);
    headers ~= encodeLiteralHeader(":authority", address);
    headers ~= encodeLiteralHeader("content-type", "application/grpc");
    headers ~= encodeLiteralHeader("te", "trailers");
    writeFrame(sock, FrameType.HEADERS, FrameFlags.END_HEADERS, streamId, headers);
    writeData(sock, streamId, grpcFrame(requestProto), true);

    DynamicTable dynTable;
    ubyte[] data;
    string status, message;
    while (true) {
        auto f = readFrame(sock);
        if (f is null) return Called(null, method ~ ": the connection closed before the call ended");

        switch (f.type) {
            case FrameType.SETTINGS:
                if ((f.flags & FrameFlags.ACK) == 0) sendSettingsAck(sock);
                break;
            case FrameType.PING:
                if ((f.flags & FrameFlags.ACK) == 0) writeFrame(sock, FrameType.PING, FrameFlags.ACK, 0, f.payload);
                break;
            case FrameType.DATA:
                data ~= f.payload;
                if (f.length > 0) {
                    sendWindowUpdate(sock, 0, f.length);
                    sendWindowUpdate(sock, f.streamId, f.length);
                }
                break;
            case FrameType.HEADERS:
                foreach (hf; decodeHeaders(f.payload, dynTable)) {
                    if (hf.name == "grpc-status") status = hf.value;
                    if (hf.name == "grpc-message") message = hf.value;
                }
                break;
            case FrameType.RST_STREAM:
                return Called(null, method ~ ": the node reset the stream");
            case FrameType.GOAWAY:
                return Called(null, method ~ ": the node went away");
            default:
                break;
        }
        if ((f.type == FrameType.HEADERS || f.type == FrameType.DATA) && (f.flags & FrameFlags.END_STREAM) != 0)
            break;
    }

    if (status != "0") {
        return Called(null, method ~ " ended with grpc-status " ~ (status.length ? status : "(none)") ~
            (message.length ? ": " ~ message : ""));
    }
    ubyte[] proto;
    if (!grpcUnframe(data, proto)) return Called(null, method ~ ": the response message is cut short");
    return Called(proto, null);
}

private ptrdiff_t lastIndexOf(string s, char c) {
    for (ptrdiff_t i = cast(ptrdiff_t)s.length - 1; i >= 0; i--) {
        if (s[i] == c) return i;
    }
    return -1;
}

unittest {
    auto data = cast(ubyte[])[1, 2, 3, 4, 5];
    ubyte[] message;
    assert(grpcUnframe(grpcFrame(data), message) && message == data);
    assert(grpcUnframe(grpcFrame([]), message) && message.length == 0);
    assert(!grpcUnframe([0, 0, 0, 0, 9, 1], message));
}
