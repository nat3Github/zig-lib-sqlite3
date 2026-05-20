//! sqlite3-zig — typed, comptime-driven wrapper around sqlite3.
//!
//! Layered API:
//!   - `Conn`            : connection (open, exec, prepare, transactions, migrations)
//!   - `Stmt`            : prepared statement with typed bind/scan
//!   - `Iterator(T)`     : `while (try it.next()) |row|` row decoding
//!   - `schema`          : CREATE TABLE generation from a struct
//!   - `Diag`            : error message capture
//!
//! Targets zig 0.14.0.

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

const std = @import("std");
const builtin = std.builtin;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

// ============================================================================
// Errors
// ============================================================================

pub const Error = error{
    SqliteError,
    SqliteInternal,
    SqlitePerm,
    SqliteAbort,
    SqliteBusy,
    SqliteLocked,
    SqliteNomem,
    SqliteReadonly,
    SqliteInterrupt,
    SqliteIoerr,
    SqliteCorrupt,
    SqliteNotfound,
    SqliteFull,
    SqliteCantopen,
    SqliteProtocol,
    SqliteEmpty,
    SqliteSchema,
    SqliteToobig,
    SqliteConstraint,
    SqliteMismatch,
    SqliteMisuse,
    SqliteNolfs,
    SqliteAuth,
    SqliteFormat,
    SqliteRange,
    SqliteNotaDB,
    SqliteNotice,
    SqliteWarning,
    SqliteUnknown,
    SqliteRowExpected,
    SqliteTypeUnsupported,
    SqliteMigrationChanged,
    OutOfMemory,
};

/// C bridge: forwards to `sqlite3_bind_text` with `SQLITE_TRANSIENT`.
/// Workaround: zig 0.14 cannot construct the SQLITE_TRANSIENT sentinel at comptime.
extern fn sqlite_zig_bind_text_transient(*c.sqlite3_stmt, c_int, [*c]const u8, c_int) c_int;
extern fn sqlite_zig_bind_blob_transient(*c.sqlite3_stmt, c_int, ?*const anyopaque, c_int) c_int;

/// Convert a primary sqlite result code (low 8 bits of an extended code) to error.
pub fn codeToError(code: c_int) Error!void {
    return switch (code & 0xFF) {
        c.SQLITE_OK, c.SQLITE_ROW, c.SQLITE_DONE => {},
        c.SQLITE_ERROR => error.SqliteError,
        c.SQLITE_INTERNAL => error.SqliteInternal,
        c.SQLITE_PERM => error.SqlitePerm,
        c.SQLITE_ABORT => error.SqliteAbort,
        c.SQLITE_BUSY => error.SqliteBusy,
        c.SQLITE_LOCKED => error.SqliteLocked,
        c.SQLITE_NOMEM => error.SqliteNomem,
        c.SQLITE_READONLY => error.SqliteReadonly,
        c.SQLITE_INTERRUPT => error.SqliteInterrupt,
        c.SQLITE_IOERR => error.SqliteIoerr,
        c.SQLITE_CORRUPT => error.SqliteCorrupt,
        c.SQLITE_NOTFOUND => error.SqliteNotfound,
        c.SQLITE_FULL => error.SqliteFull,
        c.SQLITE_CANTOPEN => error.SqliteCantopen,
        c.SQLITE_PROTOCOL => error.SqliteProtocol,
        c.SQLITE_EMPTY => error.SqliteEmpty,
        c.SQLITE_SCHEMA => error.SqliteSchema,
        c.SQLITE_TOOBIG => error.SqliteToobig,
        c.SQLITE_CONSTRAINT => error.SqliteConstraint,
        c.SQLITE_MISMATCH => error.SqliteMismatch,
        c.SQLITE_MISUSE => error.SqliteMisuse,
        c.SQLITE_NOLFS => error.SqliteNolfs,
        c.SQLITE_AUTH => error.SqliteAuth,
        c.SQLITE_FORMAT => error.SqliteFormat,
        c.SQLITE_RANGE => error.SqliteRange,
        c.SQLITE_NOTADB => error.SqliteNotaDB,
        c.SQLITE_NOTICE => error.SqliteNotice,
        c.SQLITE_WARNING => error.SqliteWarning,
        else => error.SqliteUnknown,
    };
}

/// Caller-provided diagnostics struct. Pass `&diag` into ops to capture sqlite
/// error message + extended code.
pub const Diag = struct {
    code: c_int = 0,
    extended: c_int = 0,
    /// borrowed from db handle; valid until next call on the same connection.
    msg: []const u8 = "",

    pub fn capture(self: *Diag, db: ?*c.sqlite3) void {
        if (db == null) return;
        self.code = c.sqlite3_errcode(db);
        self.extended = c.sqlite3_extended_errcode(db);
        if (c.sqlite3_errmsg(db)) |m| {
            self.msg = std.mem.span(m);
        }
    }
};

inline fn check(rc: c_int, db: ?*c.sqlite3, diag: ?*Diag) Error!void {
    codeToError(rc) catch |e| {
        if (diag) |d| d.capture(db);
        return e;
    };
}

// ============================================================================
// Connection
// ============================================================================

pub const OpenOptions = struct {
    /// `null` -> in-memory db.
    path: ?[:0]const u8 = null,
    /// Apply WAL + sane defaults for app storage.
    app_defaults: bool = true,
    /// busy timeout in ms (0 = disabled).
    busy_timeout_ms: c_int = 5_000,
    /// Enable foreign key enforcement.
    foreign_keys: bool = true,
};

pub const Conn = struct {
    db: *c.sqlite3,

    pub fn open(opts: OpenOptions) Error!Conn {
        var raw: ?*c.sqlite3 = null;
        const path: [:0]const u8 = opts.path orelse ":memory:";
        const rc = c.sqlite3_open(path.ptr, &raw);
        if (rc != c.SQLITE_OK) {
            if (raw) |r| _ = c.sqlite3_close(r);
            try codeToError(rc);
            unreachable;
        }
        const db = raw orelse return error.SqliteCantopen;
        var self = Conn{ .db = db };

        if (opts.busy_timeout_ms > 0) {
            _ = c.sqlite3_busy_timeout(db, opts.busy_timeout_ms);
        }
        if (opts.foreign_keys) {
            self.execNoArgs("PRAGMA foreign_keys = ON;", null) catch {};
        }
        if (opts.app_defaults) {
            // best-effort pragmas. Failures non-fatal (e.g. WAL on :memory:).
            self.execNoArgs("PRAGMA journal_mode = WAL;", null) catch {};
            self.execNoArgs("PRAGMA synchronous = NORMAL;", null) catch {};
            self.execNoArgs("PRAGMA temp_store = MEMORY;", null) catch {};
            self.execNoArgs("PRAGMA cache_size = -64000;", null) catch {};
            self.execNoArgs("PRAGMA mmap_size = 268435456;", null) catch {};
        }
        return self;
    }

    pub fn close(self: *Conn) void {
        // sqlite3_close_v2 defers close if statements still live.
        _ = c.sqlite3_close_v2(self.db);
    }

    /// Run a SQL string with no parameters and no row collection.
    pub fn execNoArgs(self: *Conn, sql: [:0]const u8, diag: ?*Diag) Error!void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql.ptr, null, null, &err_msg);
        // err_msg is owned by us; sqlite3_errmsg has the same string until next call.
        if (err_msg != null) c.sqlite3_free(err_msg);
        try check(rc, self.db, diag);
    }

    /// Prepare + bind + step-to-done. For queries that return rows, use `query`.
    pub fn exec(self: *Conn, comptime sql: [:0]const u8, args: anytype, diag: ?*Diag) Error!void {
        var stmt = try self.prepare(sql, diag);
        defer stmt.deinit();
        try stmt.bindAll(args, diag);
        try stmt.execDone(diag);
    }

    /// Prepare a typed iterator over rows returning `Row`.
    /// Caller `bind`s, then `iter(RowType)`.
    pub fn prepare(self: *Conn, sql: []const u8, diag: ?*Diag) Error!Stmt {
        var raw: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &raw, null);
        try check(rc, self.db, diag);
        return Stmt{ .stmt = raw orelse return error.SqliteError, .db = self.db };
    }

    /// Convenience: prepare + bind + return an `Iterator(Row)` ready to step.
    /// Statement lifetime owned by iterator; iterator.deinit() finalizes.
    pub fn query(
        self: *Conn,
        comptime Row: type,
        comptime sql: []const u8,
        args: anytype,
        alloc: Allocator,
        diag: ?*Diag,
    ) Error!Iterator(Row) {
        var stmt = try self.prepare(sql, diag);
        errdefer stmt.deinit();
        try stmt.bindAll(args, diag);
        return Iterator(Row){ .stmt = stmt, .alloc = alloc, .owns_stmt = true };
    }

    /// Convenience: prepare + bind + step once. Returns `?Row` (null if no rows).
    pub fn queryOne(
        self: *Conn,
        comptime Row: type,
        comptime sql: []const u8,
        args: anytype,
        alloc: Allocator,
        diag: ?*Diag,
    ) Error!?Row {
        var it = try self.query(Row, sql, args, alloc, diag);
        defer it.deinit();
        return try it.next(diag);
    }

    pub fn lastInsertRowid(self: *Conn) i64 {
        return c.sqlite3_last_insert_rowid(self.db);
    }

    pub fn changes(self: *Conn) i64 {
        return c.sqlite3_changes64(self.db);
    }

    // ---- transactions ---------------------------------------------------

    pub const Tx = struct {
        conn: *Conn,
        finished: bool = false,

        pub fn commit(self: *Tx) Error!void {
            if (self.finished) return;
            self.finished = true;
            try self.conn.execNoArgs("COMMIT;", null);
        }
        pub fn rollback(self: *Tx) void {
            if (self.finished) return;
            self.finished = true;
            self.conn.execNoArgs("ROLLBACK;", null) catch {};
        }
    };

    pub fn begin(self: *Conn) Error!Tx {
        try self.execNoArgs("BEGIN;", null);
        return Tx{ .conn = self };
    }

    pub fn beginImmediate(self: *Conn) Error!Tx {
        try self.execNoArgs("BEGIN IMMEDIATE;", null);
        return Tx{ .conn = self };
    }

    // ---- migrations -----------------------------------------------------

    /// Apply `migrations` in order, each in its own transaction, tracking
    /// progress via `PRAGMA user_version`. Migrations must be append-only:
    /// once applied at version N, that slot's content is locked.
    ///
    /// Detection of changed past migration uses content hash stored in
    /// `_sqlite_zig_migrations(version INTEGER PRIMARY KEY, hash BLOB)`.
    pub fn migrate(self: *Conn, migrations: []const []const u8) Error!void {
        try self.execNoArgs(
            \\CREATE TABLE IF NOT EXISTS _sqlite_zig_migrations(
            \\  version INTEGER PRIMARY KEY,
            \\  hash BLOB NOT NULL,
            \\  applied_at INTEGER NOT NULL
            \\);
        , null);

        const now: i64 = std.time.timestamp();
        for (migrations, 0..) |sql_text, i| {
            const version: i64 = @intCast(i + 1);
            const hash = sha256(sql_text);

            // Check existing record.
            var sel = try self.prepare(
                "SELECT hash FROM _sqlite_zig_migrations WHERE version = ?;",
                null,
            );
            defer sel.deinit();
            try sel.bindI64(1, version);
            const step_rc = sel.stepRaw();
            if (step_rc == c.SQLITE_ROW) {
                const existing = sel.columnBlobRaw(0);
                if (!std.mem.eql(u8, existing, &hash)) {
                    return error.SqliteMigrationChanged;
                }
                continue; // already applied, matches.
            } else if (step_rc != c.SQLITE_DONE) {
                try codeToError(step_rc);
            }

            // Apply.
            var tx = try self.beginImmediate();
            errdefer tx.rollback();

            // Migration body may contain multiple statements; use execNoArgs.
            // Caller must null-terminate or we copy. Allocate a sentinel buffer.
            try execMulti(self, sql_text);

            var ins = try self.prepare(
                "INSERT INTO _sqlite_zig_migrations(version, hash, applied_at) VALUES(?, ?, ?);",
                null,
            );
            defer ins.deinit();
            try ins.bindI64(1, version);
            try ins.bindBlob(2, &hash);
            try ins.bindI64(3, now);
            try ins.execDone(null);

            try tx.commit();
        }
    }
};

fn execMulti(self: *Conn, sql_text: []const u8) Error!void {
    // sqlite3_exec needs null-terminated. Copy onto a stack buffer if small,
    // else heap. We use sqlite3_prepare_v2 in a loop instead to avoid copy.
    var rest_ptr: [*c]const u8 = sql_text.ptr;
    const end: [*c]const u8 = sql_text.ptr + sql_text.len;
    while (@intFromPtr(rest_ptr) < @intFromPtr(end)) {
        var raw: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        const remaining: c_int = @intCast(@intFromPtr(end) - @intFromPtr(rest_ptr));
        const rc = c.sqlite3_prepare_v2(self.db, rest_ptr, remaining, &raw, &tail);
        try codeToError(rc);
        if (raw) |st| {
            defer _ = c.sqlite3_finalize(st);
            while (true) {
                const sr = c.sqlite3_step(st);
                if (sr == c.SQLITE_DONE) break;
                if (sr == c.SQLITE_ROW) continue;
                try codeToError(sr);
            }
        }
        if (tail == null or tail == rest_ptr) break;
        rest_ptr = tail;
    }
}

// ============================================================================
// Statement
// ============================================================================

pub const Stmt = struct {
    stmt: *c.sqlite3_stmt,
    db: *c.sqlite3,

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn reset(self: *Stmt) Error!void {
        try codeToError(c.sqlite3_reset(self.stmt));
    }

    pub fn clearBindings(self: *Stmt) void {
        _ = c.sqlite3_clear_bindings(self.stmt);
    }

    /// Step once, returning raw sqlite code. Use for low-level loops.
    pub fn stepRaw(self: *Stmt) c_int {
        return c.sqlite3_step(self.stmt);
    }

    /// Step until `SQLITE_DONE`. Errors on `SQLITE_ROW` (caller said "no rows").
    pub fn execDone(self: *Stmt, diag: ?*Diag) Error!void {
        while (true) {
            const rc = c.sqlite3_step(self.stmt);
            switch (rc) {
                c.SQLITE_DONE => return,
                c.SQLITE_ROW => continue, // tolerate rows in exec; discard.
                else => try check(rc, self.db, diag),
            }
        }
    }

    // ---- typed bind ------------------------------------------------------

    /// Bind a tuple/struct of values to `?1`, `?2`, ... in order.
    /// Supported field types: bool, integers, floats, []const u8 (text),
    /// `Blob`, `?T` (null binds NULL), enums (as integer tag).
    pub fn bindAll(self: *Stmt, args: anytype, diag: ?*Diag) Error!void {
        const A = @TypeOf(args);
        const info = @typeInfo(A);
        switch (info) {
            .@"struct" => |s| {
                inline for (s.fields, 0..) |f, i| {
                    try self.bindAny(@intCast(i + 1), @field(args, f.name), diag);
                }
            },
            .void => {},
            else => @compileError("bindAll expects a tuple/struct, got " ++ @typeName(A)),
        }
    }

    pub fn bindAny(self: *Stmt, idx: c_int, value: anytype, diag: ?*Diag) Error!void {
        const V = @TypeOf(value);
        const info = @typeInfo(V);
        switch (info) {
            .optional => {
                if (value) |v| {
                    try self.bindAny(idx, v, diag);
                } else {
                    try check(c.sqlite3_bind_null(self.stmt, idx), self.db, diag);
                }
            },
            .bool => try check(c.sqlite3_bind_int(self.stmt, idx, if (value) 1 else 0), self.db, diag),
            .int => |int_info| {
                if (int_info.bits <= 32) {
                    try check(c.sqlite3_bind_int(self.stmt, idx, @intCast(value)), self.db, diag);
                } else {
                    try check(c.sqlite3_bind_int64(self.stmt, idx, @intCast(value)), self.db, diag);
                }
            },
            .comptime_int => try check(c.sqlite3_bind_int64(self.stmt, idx, value), self.db, diag),
            .float, .comptime_float => try check(c.sqlite3_bind_double(self.stmt, idx, @floatCast(value)), self.db, diag),
            .@"enum" => try check(c.sqlite3_bind_int64(self.stmt, idx, @intCast(@intFromEnum(value))), self.db, diag),
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    try check(sqlite_zig_bind_text_transient(self.stmt, idx, value.ptr, @intCast(value.len)), self.db, diag);
                } else if (p.size == .one) {
                    // *const [N:0]u8 (string literal) and *const [N]u8 → bind as text.
                    const child_info = @typeInfo(p.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        const slice: []const u8 = value;
                        try check(sqlite_zig_bind_text_transient(self.stmt, idx, slice.ptr, @intCast(slice.len)), self.db, diag);
                    } else if (V == *Blob or V == *const Blob) {
                        try self.bindBlob(idx, value.bytes);
                    } else @compileError("unsupported single-pointer bind: " ++ @typeName(V));
                } else @compileError("unsupported pointer bind: " ++ @typeName(V));
            },
            .@"struct" => {
                if (V == Blob) {
                    try self.bindBlob(idx, value.bytes);
                } else @compileError("unsupported struct bind: " ++ @typeName(V));
            },
            .null => try check(c.sqlite3_bind_null(self.stmt, idx), self.db, diag),
            else => @compileError("unsupported bind type: " ++ @typeName(V)),
        }
    }

    pub fn bindI64(self: *Stmt, idx: c_int, value: i64) Error!void {
        try codeToError(c.sqlite3_bind_int64(self.stmt, idx, value));
    }
    pub fn bindF64(self: *Stmt, idx: c_int, value: f64) Error!void {
        try codeToError(c.sqlite3_bind_double(self.stmt, idx, value));
    }
    pub fn bindText(self: *Stmt, idx: c_int, text: []const u8) Error!void {
        try codeToError(sqlite_zig_bind_text_transient(self.stmt, idx, text.ptr, @intCast(text.len)));
    }
    pub fn bindBlob(self: *Stmt, idx: c_int, bytes: []const u8) Error!void {
        try codeToError(sqlite_zig_bind_blob_transient(self.stmt, idx, bytes.ptr, @intCast(bytes.len)));
    }

    // ---- raw column access ----------------------------------------------

    pub fn columnCount(self: *Stmt) usize {
        return @intCast(c.sqlite3_column_count(self.stmt));
    }
    pub fn columnType(self: *Stmt, idx: usize) c_int {
        return c.sqlite3_column_type(self.stmt, @intCast(idx));
    }
    pub fn columnI64(self: *Stmt, idx: usize) i64 {
        return c.sqlite3_column_int64(self.stmt, @intCast(idx));
    }
    pub fn columnF64(self: *Stmt, idx: usize) f64 {
        return c.sqlite3_column_double(self.stmt, @intCast(idx));
    }
    pub fn columnTextRaw(self: *Stmt, idx: usize) []const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, @intCast(idx));
        if (ptr == null) return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, @intCast(idx)));
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }
    pub fn columnBlobRaw(self: *Stmt, idx: usize) []const u8 {
        const ptr = c.sqlite3_column_blob(self.stmt, @intCast(idx));
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, @intCast(idx)));
        if (ptr == null or len == 0) return "";
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }
};

/// Marker type to bind `[]const u8` as BLOB instead of TEXT.
pub const Blob = struct {
    bytes: []const u8,
    pub fn from(b: []const u8) Blob {
        return .{ .bytes = b };
    }
};

// ============================================================================
// Iterator + row decoding
// ============================================================================

pub fn Iterator(comptime Row: type) type {
    return struct {
        stmt: Stmt,
        alloc: Allocator,
        owns_stmt: bool,
        done: bool = false,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            if (self.owns_stmt) self.stmt.deinit();
        }

        /// Step once. Returns null when no more rows.
        /// Slice fields in `Row` are owned by caller, allocated via `self.alloc`.
        pub fn next(self: *Self, diag: ?*Diag) Error!?Row {
            if (self.done) return null;
            const rc = c.sqlite3_step(self.stmt.stmt);
            switch (rc) {
                c.SQLITE_ROW => {},
                c.SQLITE_DONE => {
                    self.done = true;
                    return null;
                },
                else => {
                    self.done = true;
                    try check(rc, self.stmt.db, diag);
                    return null;
                },
            }
            return try decodeRow(Row, &self.stmt, self.alloc);
        }
    };
}

pub fn decodeRow(comptime T: type, stmt: *Stmt, alloc: Allocator) Error!T {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            var out: T = undefined;
            assert(stmt.columnCount() >= s.fields.len);
            inline for (s.fields, 0..) |f, i| {
                @field(out, f.name) = try decodeField(f.type, stmt, i, alloc);
            }
            return out;
        },
        else => {
            // single-column scalar row
            return try decodeField(T, stmt, 0, alloc);
        },
    }
}

fn decodeField(comptime T: type, stmt: *Stmt, idx: usize, alloc: Allocator) Error!T {
    const info = @typeInfo(T);
    switch (info) {
        .optional => |o| {
            if (stmt.columnType(idx) == c.SQLITE_NULL) return null;
            return try decodeField(o.child, stmt, idx, alloc);
        },
        .bool => return stmt.columnI64(idx) != 0,
        .int => return @intCast(stmt.columnI64(idx)),
        .float => return @floatCast(stmt.columnF64(idx)),
        .@"enum" => |e| return @enumFromInt(@as(e.tag_type, @intCast(stmt.columnI64(idx)))),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                const raw = stmt.columnTextRaw(idx);
                return try alloc.dupe(u8, raw);
            }
            @compileError("unsupported decode pointer: " ++ @typeName(T));
        },
        .@"struct" => {
            if (T == Blob) {
                const raw = stmt.columnBlobRaw(idx);
                return Blob{ .bytes = try alloc.dupe(u8, raw) };
            }
            @compileError("unsupported decode struct: " ++ @typeName(T));
        },
        else => @compileError("unsupported decode type: " ++ @typeName(T)),
    }
}

/// Free a row whose struct contains `[]const u8` / `Blob` fields allocated by
/// the iterator. Caller must use the same allocator.
pub fn freeRow(comptime T: type, alloc: Allocator, row: T) void {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                freeField(f.type, alloc, @field(row, f.name));
            }
        },
        else => freeField(T, alloc, row),
    }
}

fn freeField(comptime T: type, alloc: Allocator, value: T) void {
    const info = @typeInfo(T);
    switch (info) {
        .optional => |o| {
            if (value) |v| freeField(o.child, alloc, v);
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) alloc.free(value);
        },
        .@"struct" => {
            if (T == Blob) alloc.free(value.bytes);
        },
        else => {},
    }
}

// ============================================================================
// Schema generation from struct
// ============================================================================

pub const schema = struct {
    pub const ColumnOpts = struct {
        primary_key: bool = false,
        autoincrement: bool = false,
        not_null: bool = false,
        unique: bool = false,
        default: ?[]const u8 = null,
    };

    /// Map a zig type to a sqlite column type literal.
    pub fn sqlTypeOf(comptime T: type) []const u8 {
        const inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        return switch (@typeInfo(inner)) {
            .bool, .int, .@"enum" => "INTEGER",
            .float => "REAL",
            .pointer => |p| if (p.size == .slice and p.child == u8) "TEXT" else @compileError("unsupported schema type"),
            .@"struct" => if (inner == Blob) "BLOB" else @compileError("unsupported schema struct " ++ @typeName(inner)),
            else => @compileError("unsupported schema type " ++ @typeName(inner)),
        };
    }

    pub fn isNullable(comptime T: type) bool {
        return @typeInfo(T) == .optional;
    }

    /// Generate `CREATE TABLE IF NOT EXISTS <table>(...);` from a struct.
    /// Optional `T.sqlite` decl can override column opts:
    /// ```
    /// pub const sqlite = .{
    ///     .primary_key = .id,
    ///     .autoincrement = true,
    ///     .unique = &.{.email},
    ///     .not_null = &.{.email, .name},
    /// };
    /// ```
    pub fn createTable(comptime T: type, comptime table_name: []const u8) [:0]const u8 {
        comptime {
            const fields = @typeInfo(T).@"struct".fields;
            const cfg = if (@hasDecl(T, "sqlite")) T.sqlite else .{};
            const pk_field: ?[]const u8 = if (@hasField(@TypeOf(cfg), "primary_key"))
                @tagName(cfg.primary_key)
            else
                null;
            const ai: bool = if (@hasField(@TypeOf(cfg), "autoincrement")) cfg.autoincrement else false;
            const unique_set: []const []const u8 = if (@hasField(@TypeOf(cfg), "unique")) tagNames(cfg.unique) else &.{};
            const nn_set: []const []const u8 = if (@hasField(@TypeOf(cfg), "not_null")) tagNames(cfg.not_null) else &.{};

            var out: []const u8 = "CREATE TABLE IF NOT EXISTS " ++ table_name ++ " (\n";
            for (fields, 0..) |f, i| {
                var line: []const u8 = "  " ++ f.name ++ " " ++ sqlTypeOf(f.type);
                if (pk_field != null and std.mem.eql(u8, pk_field.?, f.name)) {
                    line = line ++ " PRIMARY KEY";
                    if (ai) line = line ++ " AUTOINCREMENT";
                }
                if (containsName(unique_set, f.name)) line = line ++ " UNIQUE";
                if (!isNullable(f.type) and !(pk_field != null and std.mem.eql(u8, pk_field.?, f.name))) {
                    line = line ++ " NOT NULL";
                } else if (containsName(nn_set, f.name)) {
                    line = line ++ " NOT NULL";
                }
                if (i + 1 < fields.len) line = line ++ ",";
                out = out ++ line ++ "\n";
            }
            out = out ++ ");";
            return out[0..out.len :0];
        }
    }

    fn tagNames(comptime arr: anytype) []const []const u8 {
        comptime {
            // Accept: pointer to array, pointer to tuple struct, or array/tuple directly.
            const T = @TypeOf(arr);
            const deref = switch (@typeInfo(T)) {
                .pointer => arr.*,
                else => arr,
            };
            const D = @TypeOf(deref);
            switch (@typeInfo(D)) {
                .@"struct" => |s| {
                    var out: [s.fields.len][]const u8 = undefined;
                    for (s.fields, 0..) |f, i| {
                        out[i] = @tagName(@field(deref, f.name));
                    }
                    const fixed = out;
                    return &fixed;
                },
                .array => |a| {
                    var out: [a.len][]const u8 = undefined;
                    for (deref, 0..) |item, i| {
                        out[i] = @tagName(item);
                    }
                    const fixed = out;
                    return &fixed;
                },
                else => @compileError("expected tuple/array of enum literals, got " ++ @typeName(D)),
            }
        }
    }

    fn containsName(comptime set: []const []const u8, comptime name: []const u8) bool {
        comptime {
            for (set) |s| {
                if (std.mem.eql(u8, s, name)) return true;
            }
            return false;
        }
    }

    /// Build `INSERT INTO table(col1, col2, ...) VALUES(?, ?, ...);` from a struct.
    /// Skips fields listed in `skip` (e.g. autoincrement PK).
    pub fn insert(comptime T: type, comptime table_name: []const u8, comptime skip: []const []const u8) [:0]const u8 {
        comptime {
            const fields = @typeInfo(T).@"struct".fields;
            var cols: []const u8 = "";
            var vals: []const u8 = "";
            var first = true;
            for (fields) |f| {
                var skipped = false;
                for (skip) |s| {
                    if (std.mem.eql(u8, s, f.name)) {
                        skipped = true;
                        break;
                    }
                }
                if (skipped) continue;
                if (!first) {
                    cols = cols ++ ", ";
                    vals = vals ++ ", ";
                }
                first = false;
                cols = cols ++ f.name;
                vals = vals ++ "?";
            }
            const s = "INSERT INTO " ++ table_name ++ "(" ++ cols ++ ") VALUES(" ++ vals ++ ");";
            return s[0..s.len :0];
        }
    }
};

// ============================================================================
// Internal helpers
// ============================================================================

fn sha256(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &out, .{});
    return out;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const User = struct {
    id: ?i64,
    name: []const u8,
    age: ?u32,
    pub const sqlite = .{
        .primary_key = .id,
        .autoincrement = true,
        .unique = &.{.name},
    };
};

test "open in-memory, create table, insert, query" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();

    const create = comptime schema.createTable(User, "user");
    try db.execNoArgs(create, null);

    const ins = comptime schema.insert(User, "user", &.{"id"});
    try db.exec(ins, .{ "alice", @as(?u32, 30) }, null);
    try db.exec(ins, .{ "bob", @as(?u32, null) }, null);

    var it = try db.query(User, "SELECT id, name, age FROM user ORDER BY id;", .{}, alloc, null);
    defer it.deinit();

    var count: usize = 0;
    while (try it.next(null)) |row| {
        defer freeRow(User, alloc, row);
        count += 1;
        if (count == 1) {
            try testing.expectEqualStrings("alice", row.name);
            try testing.expectEqual(@as(?u32, 30), row.age);
        } else if (count == 2) {
            try testing.expectEqualStrings("bob", row.name);
            try testing.expectEqual(@as(?u32, null), row.age);
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "queryOne single scalar" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    try db.execNoArgs("CREATE TABLE t(x INTEGER);", null);
    try db.exec("INSERT INTO t VALUES(?);", .{@as(i64, 42)}, null);

    const Row = struct { x: i64 };
    const r = try db.queryOne(Row, "SELECT x FROM t WHERE x = ?;", .{@as(i64, 42)}, alloc, null);
    try testing.expect(r != null);
    try testing.expectEqual(@as(i64, 42), r.?.x);
}

test "transactions: commit + rollback" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    try db.execNoArgs("CREATE TABLE t(x INTEGER);", null);

    {
        var tx = try db.begin();
        errdefer tx.rollback();
        try db.exec("INSERT INTO t VALUES(?);", .{@as(i64, 1)}, null);
        try tx.commit();
    }
    {
        var tx = try db.begin();
        try db.exec("INSERT INTO t VALUES(?);", .{@as(i64, 999)}, null);
        tx.rollback();
    }

    const CountRow = struct { c: i64 };
    const r = try db.queryOne(CountRow, "SELECT COUNT(*) FROM t;", .{}, alloc, null);
    try testing.expectEqual(@as(i64, 1), r.?.c);
}

test "migrations: apply, idempotent, detect change" {
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();

    const migs = [_][]const u8{
        "CREATE TABLE a(x INTEGER);",
        "CREATE TABLE b(y TEXT);",
    };
    try db.migrate(&migs);
    // Re-apply: idempotent.
    try db.migrate(&migs);

    // Tamper: change migration 1 content.
    const tampered = [_][]const u8{
        "CREATE TABLE a(x INTEGER, z INTEGER);",
        "CREATE TABLE b(y TEXT);",
    };
    const e = db.migrate(&tampered);
    try testing.expectError(error.SqliteMigrationChanged, e);
}

test "diagnostics captured on error" {
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    var diag: Diag = .{};
    const e = db.execNoArgs("SELECT * FROM nonexistent;", &diag);
    try testing.expectError(error.SqliteError, e);
    try testing.expect(diag.msg.len > 0);
}

test "blob bind + decode" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    try db.execNoArgs("CREATE TABLE t(b BLOB);", null);

    const payload = [_]u8{ 1, 2, 3, 4, 5 };
    try db.exec("INSERT INTO t VALUES(?);", .{Blob.from(&payload)}, null);

    const Row = struct { b: Blob };
    const r = try db.queryOne(Row, "SELECT b FROM t;", .{}, alloc, null);
    try testing.expect(r != null);
    defer alloc.free(r.?.b.bytes);
    try testing.expectEqualSlices(u8, &payload, r.?.b.bytes);
}

test "enum bind + decode" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const Color = enum(u8) { red = 1, green = 2, blue = 3 };
    try db.execNoArgs("CREATE TABLE t(c INTEGER);", null);
    try db.exec("INSERT INTO t VALUES(?);", .{Color.green}, null);
    const Row = struct { c: Color };
    const r = try db.queryOne(Row, "SELECT c FROM t;", .{}, alloc, null);
    try testing.expectEqual(Color.green, r.?.c);
}
