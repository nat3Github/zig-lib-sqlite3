pub const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("sqlite3ext.h");
});
const std = @import("std");
const assert = std.debug.assert;
const expect = std.debug.expect;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const Type = std.builtin.Type;

const sql = struct {
    pub fn comptime_join(comptime list: []const []const u8, sep: []const u8) []const u8 {
        comptime {
            var s: []const u8 = "";
            if (list.len == 0) return s;
            s = list[0];
            for (list[1..]) |e| {
                s = s ++ sep ++ e;
            }
            return s;
        }
    }
    fn ending_after_last_dot_comptime(comptime str: []const u8) []const u8 {
        comptime var pos: usize = 0;
        inline while (comptime std.ascii.indexOfIgnoreCasePos(str, pos, ".")) |p| pos = p + 1;
        return str[pos..];
    }

    // NOTE: sqlite doesnt require data types
    fn simple_table_from_struct(comptime T: type) []const u8 {
        const fields = @typeInfo(T).@"struct".fields;
        comptime {
            var list: [fields.len][]const u8 = undefined;
            for (&list, fields) |*l, f| {
                l.* = f.name;
            }
            const body = comptime_join(&list, ",\n");
            const t_str = std.fmt.comptimePrint("{}", .{T});
            const table_name = ending_after_last_dot_comptime(t_str);
            return create_table(table_name, body);
        }
    }
    fn create_table(comptime table_name: []const u8, comptime body: []const u8) []const u8 {
        comptime {
            const CREATE_TABLE =
                \\CREATE TABLE
                \\IF NOT EXISTS {s} (
                \\{s}
                \\);
            ;
            return std.fmt.comptimePrint(CREATE_TABLE, .{ table_name, body });
        }
    }
    fn primary_key(comptime body: []const u8) []const u8 {
        const PRIMARY_KEY =
            \\PRIMARY KEY (
            \\)
        ;
        std.fmt.comptimePrint(PRIMARY_KEY, .{body});
    }
    fn foreign_key(comptime body: []const u8) []const u8 {
        const FOREIGN_KEY =
            \\FOREIGN KEY (
            \\{s}
            \\) REFERENCES {} ({}) 
        ;
        std.fmt.comptimePrint(FOREIGN_KEY, .{body});
    }

    const Action = enum {
        Cascade,
        NoAction,
        fn stringify(self: *const @This()) []const u8 {
            const NO_ACTION = "NO ACTION";
            const CASCADE = "CASCADE";
            return switch (self.*) {
                .Cascade => CASCADE,
                .NoAction => NO_ACTION,
            };
        }
        fn on_delete(comptime action: Action) []const u8 {
            const FMT_ON_DELETE = "ON DELETE {s}";
            return std.fmt.comptimePrint(FMT_ON_DELETE, .{action.stringify()});
        }
        fn on_update(comptime action: Action) []const u8 {
            const FMT_ON_UPDATE = "ON UPDATE {s}";
            return std.fmt.comptimePrint(FMT_ON_UPDATE, .{action.stringify()});
        }
    };
};

test "sqlite3 table from struct" {
    const MyStruct = struct {
        x: f32,
        y: i32,
        data: []const u8,
    };
    const table = comptime sql.simple_table_from_struct(MyStruct);
    const db = try Conn.init(null);

    std.log.warn("simple table sql definition: {s}", .{table});
}

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

pub fn exec(hndl: *c.sqlite3, sql_str: [:0]const u8, T: type, t_ptr: *T, cb: fn (*T) void) !void {
    const X = struct {
        fn cbw(ud: ?*anyopaque, res_column_count: c_int, y: [*c][*c]u8, z: [*c][*c]u8) callconv(.c) c_int {
            const tp: *T = @ptrCast(ud);
            var slc: []const [*c]u8 = undefined;
            slc.len = res_column_count;
            // todo: can we cast this slc to []const [:0]u8
            _ = .{ tp, res_column_count, y, z, cb };
        }
    };
    const callback: ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int = X.cbw;
    const user_data: ?*anyopaque = @ptrCast(t_ptr);
    var err_msg: [:0]const u8 = "";
    if (c.SQLITE_OK == c.sqlite3_exec(hndl, sql_str.ptr, callback, user_data, &err_msg)) {
        std.log.err("exec error: {s}", .{err_msg});
        return error.Sqlite3Error;
    }
}
pub fn prepare(hndl: *c.sqlite3, sql_str: []const u8) !*c.sqlite3_stmt {
    var ppStmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(hndl, sql_str, @intCast(sql_str.len), &ppStmt, null);
    if (ppStmt) |ptr| {
        return ptr;
    } else return error.Sqlite3FailedToCreatePrepareStatement;
}
pub fn step_through(stmt: *c.sqlite3_stmt, T: type, t: *T, cb: fn (*T, *c.sqlite3_stmt) void) !void {
    if (c.sqlite3_reset(stmt) != c.SQLITE_OK) return error.Sqlite3ResetFailed;
    while (true) {
        const res = c.sqlite3_step(stmt);
        switch (res) {
            c.SQLITE_MISUSE => @panic("misuse of sqlite3"),
            c.SQLITE_DONE => {
                if (c.sqlite3_reset(stmt) != c.SQLITE_OK) return error.Sqlite3ResetFailed;
                return;
            },
            c.SQLITE_BUSY => return error.Sqlite3IsBusy,
            c.SQLITE_ROW => cb(t, stmt),
            else => return error.Sqlite3Error,
        }
    }
}

/// Convenience wrapper for opening a Database Connection, executing statements
///
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
    pub fn prepare_statement(self: *@This(), sql_str: []const u8) void {
        const ps = try prepare(self.hndl, sql_str);
        return PreparedStatement{
            .pstmt = ps,
        };
    }
};

const PreparedStatement = struct {
    pstmt: *c.sqlite3_stmt,
    pub fn deinit(self: *@This()) void {
        _ = c.sqlite3_finalize(self.pstmt);
    }
    pub fn exec(self: *@This(), T: type, cb_ctx: *T, cb: fn (*T, *c.sqlite3) void) !void {
        try step_through(self.pstmt, T, cb_ctx, cb);
    }
};
