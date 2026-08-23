const database = @import("database");
const config = @import("../../config.zon");
const std = @import("std");
const builtin = @import("builtin");
const http_client = @import("http_client");
const telemetry = @import("telemetry");
const root = @import("root");
const missing_resource = @embedFile("../../missing.json");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

pub fn handle() void {
    _ = database;
    _ = config;
    _ = std;
    _ = builtin;
    _ = http_client;
    _ = telemetry;
    _ = root;
    _ = missing_resource;
    _ = sqlite;
}
