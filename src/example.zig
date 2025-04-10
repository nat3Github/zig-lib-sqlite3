const std = @import("std");
const dbs = @import("sqlite3-zig").c;
pub fn main() !void {
    var dbhandle: ?*dbs.sqlite3 = undefined;
    defer {
        const close_res = dbs.sqlite3_close(dbhandle);
        if (close_res != dbs.SQLITE_OK) {
            std.debug.print("failed to close db\n", .{});
        } else {
            std.debug.print("successfully closed db\n", .{});
        }
    }

    const db_res = dbs.sqlite3_open(":memory:", &dbhandle);
    if (db_res != dbs.SQLITE_OK) {
        std.debug.print("sqlite error: {}\n", .{db_res});
        return error.FAILED_TO_OPEN_SQLITE_DB;
    } else {
        std.debug.print("opened in memory sqlite3 database, returned SQLITE_OK\n", .{});
    }
}
