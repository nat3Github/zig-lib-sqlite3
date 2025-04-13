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
    fn simple_table_from_struct(comptime T: type, table_name: []const u8) [:0]const u8 {
        const fields = @typeInfo(T).@"struct".fields;
        comptime {
            var list: [fields.len][]const u8 = undefined;
            for (&list, fields) |*l, f| {
                l.* = f.name;
            }
            const body = comptime_join(&list, ",\n");
            return create_table(table_name, body);
        }
    }
    fn type_name_as_str(T: type) []const u8 {
        const t_str = std.fmt.comptimePrint("{}", .{T});
        const table_name = ending_after_last_dot_comptime(t_str);
        return table_name;
    }

    fn create_table(comptime table_name: []const u8, comptime body: []const u8) [:0]const u8 {
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
    fn insert(table_name: []const u8, values: []const u8) [:0]const u8 {
        const insert_statement =
            \\INSERT INTO
            \\{s}
            \\VALUES (
            \\{s}
            \\);
        ;
        return std.fmt.comptimePrint(insert_statement, .{ table_name, values });
    }
    // fn primary_key(comptime body: []const u8) [:0]const u8 {
    //     const PRIMARY_KEY =
    //         \\PRIMARY KEY (
    //         \\{s}
    //         \\)
    //     ;
    //     std.fmt.comptimePrint(PRIMARY_KEY, .{body});
    // }
    // fn foreign_key(comptime body: []const u8) [:0]const u8 {
    //     const FOREIGN_KEY =
    //         \\FOREIGN KEY (
    //         \\{s}
    //         \\) REFERENCES {} ({}) {}
    //     ;
    //     std.fmt.comptimePrint(FOREIGN_KEY, .{body});
    // }

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

test "test coerce [*c]u8 to [:0]const u8" {
    const slice: [:0]const u8 = "abc";
    const t: [*c]const u8 = slice.ptr;
    const x: [*]const u8 = t;
    const y: [*:0]const u8 = @ptrCast(x);
    std.log.warn("y: {s}", .{y});

    const column_name: [*c][*c]u8 = undefined;
    const coerce1: ?[*]?[*]u8 = column_name;
    const coerce2: ?[*]?[*:0]const u8 = @ptrCast(coerce1);
    _ = coerce2;
}
test "test sqlite3 table from struct" {
    const MyStruct = struct {
        x: f32,
        y: i32,
        data: []const u8,
    };
    var db = try Conn.init("./test1.db");
    defer db.deinit();

    const select_all =
        \\SELECT *
        \\FROM
        \\mystruct;
    ;
    // const create_with_dtypes =
    //     \\CREATE TABLE
    //     \\IF NOT EXISTS MyStruct (
    //     \\x FLOAT,
    //     \\y INT,
    //     \\data
    //     \\);
    // ;
    // try db.execute(create_with_dtypes, void, void_ptr, no_op);
    // _ = .{MyStruct};

    const create_mystruct = comptime sql.simple_table_from_struct(MyStruct, sql.type_name_as_str(MyStruct));
    try db.execute(create_mystruct, void, void_ptr, no_op);

    // std.log.warn("{s}", .{create_mystruct});

    // const insert = comptime sql.insert("mystruct",
    //     \\1.0,
    //     \\2,
    //     \\"hello"
    // );
    // try db.execute(insert, void, void_ptr, no_op);

    // const select_count =
    //     \\SELECT COUNT(*) as Entries
    //     \\FROM
    //     \\mystruct
    //     \\where y = 2;
    // ;
    // try db.execute(select_count, void, void_ptr, print_row_result);

    // NOTE: indices of ?NNN must be between ?1 and ?32766
    const select_where =
        \\SELECT COUNT(*) as Entries
        \\FROM
        \\mystruct
        \\where y = ?1;
    ;

    var where_x_equals = try db.prepare_statement(select_where);
    try where_x_equals.bind_i32(1, 2);
    try where_x_equals.exec(void, void_ptr, print_count);
    defer where_x_equals.deinit();

    _ = .{select_all};
    // std.log.warn("simple table sql definition: {s}", .{MyStruct});
}

fn print_count(_: *void, stmt: *c.sqlite3_stmt) void {
    const cols = namespace_stmt.column_count(stmt);
    assert(cols == 1);
    const count = namespace_stmt.column_i32(stmt, 0);
    std.log.warn("count: {}", .{count});
}

pub const void_ptr: *void = @constCast(&{});
pub fn no_op(_: *void, _: []const ?[*:0]const u8, _: []const ?[*:0]const u8) !void {}

fn print_row_result(_: *void, column_name: []const ?[*:0]const u8, column_text: []const ?[*:0]const u8) !void {
    for (column_name, column_text) |col, e| {
        const name_str = col orelse unreachable;
        const content = e orelse "NULL";
        std.log.warn("column {s}: {s}", .{ name_str, content });
    }
}
pub fn errify(err: c_int) !void {
    errify2(err) catch |e| {
        std.log.err("{}", .{e});
        return e;
    };
}
pub fn errify2(err: c_int) !void {
    return switch (err) {
        101 => {}, //sqlite done
        0 => {}, //sqlite ok
        100 => {}, //sqlite row
        4 => error.SqliteAbort,
        23 => error.SqliteAuth,
        5 => error.SqliteBusy,
        14 => error.SqliteCantopen,
        19 => error.SqliteConstraint,
        11 => error.SqliteCorrupt,
        16 => error.SqliteEmpty,
        1 => error.SqliteError,
        24 => error.SqliteFormat,
        13 => error.SqliteFull,
        2 => error.SqliteInternal,
        9 => error.SqliteInterrupt,
        10 => error.SqliteIoerr,
        6 => error.SqliteLocked,
        20 => error.SqliteMismatch,
        21 => error.SqliteMisuse,
        22 => error.SqliteNolfs,
        7 => error.SqliteNomem,
        26 => error.SqliteNotaDB,
        12 => error.SqliteNotfound,
        27 => error.SqliteNotice,
        3 => error.SqlitePerm,
        15 => error.SqliteProtocol,
        25 => error.SqliteRange,
        8 => error.SqliteReadonly,
        17 => error.SqliteSchema,
        18 => error.SqliteToobig,
        28 => error.SqliteWarning,
        else => unreachable,
    };
}

pub fn open(path_or_in_memory: ?[:0]const u8) !*c.sqlite3 {
    var dbhandle: ?*c.sqlite3 = undefined;
    const path = if (path_or_in_memory) |p| p else ":memory";
    const db_res = c.sqlite3_open(path, &dbhandle);
    try errify(db_res);
    if (dbhandle) |h| {
        return h;
    } else unreachable;
}

pub fn close(hndl: *c.sqlite3) !void {
    const close_res = c.sqlite3_close(hndl);
    try errify(close_res);
}

pub fn exec(hndl: *c.sqlite3, sql_str: [:0]const u8, T: type, t_ptr: *T, result_row_callback: *const fn (*T, []const ?[*:0]const u8, []const ?[*:0]const u8) anyerror!void) !void {
    const Wrapper = struct {
        t: *T,
        f: *const fn (*T, []const ?[*:0]const u8, []const ?[*:0]const u8) anyerror!void,
        fn cbw(ud: ?*anyopaque, column_count: c_int, column_text: [*c][*c]u8, column_name: [*c][*c]u8) callconv(.c) c_int {
            const wrapper: *@This() = @ptrCast(@alignCast(ud));
            const count: usize = @intCast(column_count);
            var name_slice: []const ?[*:0]const u8 = undefined;
            name_slice.len = count;
            const name_ptr: ?[*]?[*:0]const u8 = @ptrCast(column_name);
            name_slice.ptr = name_ptr.?;

            var text_slice: []const ?[*:0]const u8 = undefined;
            text_slice.len = count;
            const text_ptr: ?[*]?[*:0]const u8 = @ptrCast(column_text);
            text_slice.ptr = text_ptr.?;

            wrapper.f(wrapper.t, name_slice, text_slice) catch |e| {
                std.log.warn("exec error in callback: {any}", .{e});
                return 1;
            };
            return 0;
        }
    };
    var wrapper = Wrapper{
        .f = result_row_callback,
        .t = t_ptr,
    };
    const wrapper_type_erased: ?*anyopaque = @ptrCast(&wrapper);
    const err_msg: ?*[*c]u8 = null;
    const res = c.sqlite3_exec(hndl, sql_str, Wrapper.cbw, wrapper_type_erased, err_msg);
    errify(res) catch |e| {
        if (err_msg) |msg| {
            std.log.warn("exec error: {any}", .{msg});
        }
        return e;
    };
}

pub fn prepare(hndl: *c.sqlite3, sql_str: []const u8) !*c.sqlite3_stmt {
    var ppStmt: ?*c.sqlite3_stmt = null;
    const res = c.sqlite3_prepare_v2(hndl, sql_str.ptr, @intCast(sql_str.len), &ppStmt, null);
    try errify(res);
    if (ppStmt) |ptr| {
        return ptr;
    } else unreachable;
}

/// Convenience wrapper for opening a Database Connection, executing statements
///
const Conn = struct {
    const auto_prefix = "AUTO";
    hndl: *c.sqlite3,

    pub fn init(path: ?[:0]const u8) !@This() {
        const hndl = try open(path);
        return @This(){
            .hndl = hndl,
        };
    }
    pub fn deinit(self: *@This()) void {
        close(self.hndl) catch {
            std.log.warn("failed to close sqlit3 connection", .{});
        };
    }
    pub fn execute(self: *@This(), sql_str: [:0]const u8, T: type, t_ptr: *T, cb: *const fn (*T, []const ?[*:0]const u8, []const ?[*:0]const u8) anyerror!void) !void {
        try exec(self.hndl, sql_str, T, t_ptr, cb);
    }
    pub fn prepare_statement(self: *@This(), sql_str: []const u8) !PreparedStatement {
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
    pub fn exec(self: *@This(), T: type, cb_ctx: *T, cb: *const fn (*T, *c.sqlite3_stmt) void) !void {
        try namespace_stmt.step_through(self.pstmt, T, cb_ctx, cb);
    }
    pub fn column_count(self: *@This()) usize {
        return namespace_stmt.column_count(self.pstmt);
    }

    pub fn column_blob_or_utf8_bytes(self: *@This(), column_index: usize) usize {
        return namespace_stmt.column_blob_or_utf8_bytes(self.pstmt, column_index);
    }

    pub fn column_text_u8(self: *@This(), column_index: usize) [*:0]const u8 {
        return namespace_stmt.column_text_u8(self.pstmt, column_index);
    }

    pub fn column_f64(self: *@This(), column_index: usize) f64 {
        return namespace_stmt.column_f64(self.pstmt, column_index);
    }

    pub fn column_i64(self: *@This(), column_index: usize) i64 {
        return namespace_stmt.column_i64(self.pstmt, column_index);
    }
    pub fn column_i32(self: *@This(), column_index: usize) i32 {
        return namespace_stmt.column_i32(self.pstmt, column_index);
    }
    pub fn column_blob(self: *@This(), column_index: usize, T: type) ?*T {
        return namespace_stmt.column_blob(self.pstmt, column_index, T);
    }
    pub fn bind_blob(self: *@This(), parameter_index: usize, T: type, value: *const T) !void {
        try namespace_stmt.bind_blob(self.pstmt, parameter_index, T, value);
    }
    pub fn bind_f64(self: *@This(), parameter_index: usize, value: f64) !void {
        try namespace_stmt.bind_f64(self.pstmt, parameter_index, value);
    }
    pub fn bind_i64(self: *@This(), parameter_index: usize, value: i64) !void {
        try namespace_stmt.bind_i64(self.pstmt, parameter_index, value);
    }
    pub fn bind_i32(self: *@This(), parameter_index: usize, value: i32) !void {
        try namespace_stmt.bind_i32(self.pstmt, parameter_index, value);
    }
    pub fn bind_text_u8(self: *@This(), parameter_index: usize, text: []const u8) !void {
        try namespace_stmt.bind_text_u8(self.pstmt, parameter_index, text);
    }
};

const namespace_stmt = struct {
    pub fn column_count(stmt: *c.sqlite3_stmt) usize {
        const count = c.sqlite3_column_count(stmt);
        return @intCast(count);
    }

    pub fn column_blob_or_utf8_bytes(stmt: *c.sqlite3_stmt, column_index: usize) usize {
        const res = c.sqlite3_column_bytes(stmt, @intCast(column_index));
        const resu: usize = @intCast(res);
        return resu;
    }

    pub fn column_text_u8(stmt: *c.sqlite3_stmt, column_index: usize) [*:0]const u8 {
        const res = c.sqlite3_column_text(stmt, @intCast(column_index));
        const restr: [*:0]const u8 = @ptrCast(res);
        return restr;
    }

    pub fn column_f64(stmt: *c.sqlite3_stmt, column_index: usize) f64 {
        const res = c.sqlite3_column_double(stmt, @intCast(column_index));
        return res;
    }

    pub fn column_i64(stmt: *c.sqlite3_stmt, column_index: usize) i64 {
        const res = c.sqlite3_column_int64(stmt, @intCast(column_index));
        return res;
    }
    pub fn column_i32(stmt: *c.sqlite3_stmt, column_index: usize) i32 {
        const res = c.sqlite3_column_int(stmt, @intCast(column_index));
        return res;
    }
    pub fn column_blob(stmt: *c.sqlite3_stmt, column_index: usize, T: type) ?*T {
        const res = c.sqlite3_column_blob(stmt, @intCast(column_index));
        if (res) |ptr| {
            const tptr: *T = @ptrCast(@alignCast(ptr));
            return tptr;
        } else return null;
    }
    pub fn step_through(stmt: *c.sqlite3_stmt, T: type, t: *T, cb: *const fn (*T, *c.sqlite3_stmt) void) !void {
        if (c.sqlite3_reset(stmt) != c.SQLITE_OK) return error.Sqlite3ResetFailed;
        while (true) {
            const res = c.sqlite3_step(stmt);
            switch (res) {
                c.SQLITE_MISUSE => @panic("misuse of sqlite3"),
                c.SQLITE_DONE => {
                    if (c.sqlite3_reset(stmt) != c.SQLITE_OK) return error.Sqlite3ResetFailed else return;
                },
                c.SQLITE_BUSY => return error.Sqlite3IsBusy,
                c.SQLITE_ROW => cb(t, stmt),
                else => return errify(res),
            }
        }
    }
    pub fn bind_blob(stmt: *c.sqlite3_stmt, parameter_index: usize, T: type, value: *const T) !void {
        const t_bytes = @sizeOf(T);
        const anyp: *const anyopaque = @ptrCast(value);
        const res = c.sqlite3_bind_blob(stmt, @intCast(parameter_index), anyp, @intCast(t_bytes), c.SQLITE_STATIC);
        try errify(res);
    }
    pub fn bind_f64(stmt: *c.sqlite3_stmt, parameter_index: usize, value: f64) !void {
        const res = c.sqlite3_bind_double(stmt, @intCast(parameter_index), value);
        try errify(res);
    }
    pub fn bind_i64(stmt: *c.sqlite3_stmt, parameter_index: usize, value: i64) !void {
        const res = c.sqlite3_bind_int64(stmt, @intCast(parameter_index), value);
        try errify(res);
    }
    pub fn bind_i32(stmt: *c.sqlite3_stmt, parameter_index: usize, value: i32) !void {
        const res = c.sqlite3_bind_int64(stmt, @intCast(parameter_index), value);
        try errify(res);
    }
    pub fn bind_text_u8(stmt: *c.sqlite3_stmt, parameter_index: usize, text: []const u8) !void {
        const res = c.sqlite3_bind_text(stmt, @intCast(parameter_index), text.ptr, @intCast(text.len), c.SQLITE_STATIC);
        try errify(res);
    }
};
