const http = @import("wasi_http");

comptime {
    http.exportHandler("Hello, WASI!");
}
