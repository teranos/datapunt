/// Where the plugin starts. Everything it does is plugin.service, where a test
/// can reach it: dub test leaves this file out.
module plugin.entry;

import plugin.grpc : GrpcServer;
import plugin.log;
import plugin.service : registerHandlers, PLUGIN_NAME, PLUGIN_VERSION;

import std.stdio : stdout, writefln;

void main(string[] args) {
    ushort port = 9080;
    for (size_t i = 1; i < args.length; i++) {
        import std.conv : to;
        if (args[i] == "--port" && i + 1 < args.length) {
            port = args[++i].to!ushort;
        } else if (args[i] == "--address" && i + 1 < args.length) {
            auto addr = args[++i];
            foreach_reverse (j, c; addr) if (c == ':') { port = addr[j + 1 .. $].to!ushort; break; }
        } else if (args[i] == "--version") {
            writefln("qntx-%s-plugin %s", PLUGIN_NAME, PLUGIN_VERSION);
            return;
        } else if (args[i] == "--weekpost" && i + 2 < args.length) {
            // The weekly strip of a week given as the page's window.WEEKPOST,
            // as PNG on stdout, at the device pixels to the pixel named.
            import plugin.weekpost : drawWeek, weekFromJSON;
            import std.file : readText;
            auto week = weekFromJSON(readText(args[i + 1]));
            stdout.rawWrite(drawWeek(week, args[i + 2].to!double));
            return;
        }
    }

    GrpcServer server;
    registerHandlers(server);
    auto bound = server.bind(port);
    if (bound == 0) {
        logError("[datapunt] could not bind to port %d or the 63 above it", port);
        return;
    }
    // The loader reads the port it was given off stdout.
    writefln("QNTX_PLUGIN_PORT=%d", bound);
    stdout.flush();
    logInfo("[datapunt] %s listening on 127.0.0.1:%d", PLUGIN_VERSION, bound);
    server.serve();
}
