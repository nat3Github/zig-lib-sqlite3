pub const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("sqlite3ext.h");
});
const std = @import("std");
const assert = std.debug.assert;
const expect = std.debug.expect;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;

pub fn open_in_memory() !*c.sqlite3 {
    var dbhandle: ?*c.sqlite3 = undefined;
    const db_res = c.sqlite3_open(":memory:", &dbhandle);
    if (db_res != c.SQLITE_OK) {
        std.log.debug("sqlite error: {}", .{db_res});
        return error.FAILED_TO_OPEN_SQLITE_DB;
    } else {
        std.log.debug("opened in memory sqlite3 database, returned SQLITE_OK", .{});
    }
}
pub fn close(hndl: *c.sqlite3) !void {
    const close_res = c.sqlite3_close(hndl);
    if (close_res != c.SQLITE_OK) {
        return error.Sqlite3FailedToClose;
    }
}

const Conn = struct {
    hndl: *c.sqlite3,
    pub fn init(path: ?[]const u8) !@This() {
        if (path) |p| {
            _ = p;
        } else {
            const hndl = try open_in_memory();
            return @This(){
                .hndl = hndl,
            };
        }
    }
    pub fn deinit(self: *@This()) void {
        close(self.hndl) catch {
            std.log.warn("failed to close sqlit3 connection", .{});
        };
    }
};
