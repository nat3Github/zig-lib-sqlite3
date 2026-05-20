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
    cache: ?*StmtCache = null,

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
        if (self.cache) |cache| {
            cache.deinit();
            cache.alloc.destroy(cache);
            self.cache = null;
        }
        // sqlite3_close_v2 defers close if statements still live.
        _ = c.sqlite3_close_v2(self.db);
    }

    /// Enable a statement cache. Subsequent `execCached` / `queryCached` will
    /// reuse prepared statements keyed by SQL string.
    pub fn enableCache(self: *Conn, alloc: Allocator) Error!void {
        if (self.cache != null) return;
        const cache = alloc.create(StmtCache) catch return error.OutOfMemory;
        cache.* = StmtCache.init(alloc, self.db);
        self.cache = cache;
    }

    /// Cached variant of `exec`. Requires `enableCache` first.
    pub fn execCached(self: *Conn, comptime sql: [:0]const u8, args: anytype, diag: ?*Diag) Error!void {
        const cache = self.cache orelse return error.SqliteMisuse;
        const stmt = try cache.getOrPrepare(sql);
        try stmt.reset();
        stmt.clearBindings();
        try stmt.bindAll(args, diag);
        try stmt.execDone(diag);
    }

    /// Cached variant of `query`. Iterator does NOT own the statement.
    pub fn queryCached(
        self: *Conn,
        comptime Row: type,
        comptime sql: []const u8,
        args: anytype,
        alloc: Allocator,
        diag: ?*Diag,
    ) Error!Iterator(Row) {
        const cache = self.cache orelse return error.SqliteMisuse;
        const stmt = try cache.getOrPrepare(sql);
        try stmt.reset();
        stmt.clearBindings();
        try stmt.bindAll(args, diag);
        return Iterator(Row){ .stmt = stmt.*, .alloc = alloc, .owns_stmt = false };
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
// Statement cache
// ============================================================================

/// Caches prepared statements keyed by SQL text. Each call to `getOrPrepare`
/// returns the same `*Stmt`; caller is responsible for `reset`+`clearBindings`
/// before reuse (Conn.execCached / queryCached do this).
pub const StmtCache = struct {
    map: std.StringHashMap(*Stmt),
    alloc: Allocator,
    db: *c.sqlite3,

    pub fn init(alloc: Allocator, db: *c.sqlite3) StmtCache {
        return .{ .map = std.StringHashMap(*Stmt).init(alloc), .alloc = alloc, .db = db };
    }

    pub fn deinit(self: *StmtCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn getOrPrepare(self: *StmtCache, sql: []const u8) Error!*Stmt {
        if (self.map.get(sql)) |s| return s;
        var raw: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &raw, null);
        try codeToError(rc);
        const stmt = raw orelse return error.SqliteError;
        const boxed = self.alloc.create(Stmt) catch return error.OutOfMemory;
        boxed.* = Stmt{ .stmt = stmt, .db = self.db };
        self.map.put(sql, boxed) catch return error.OutOfMemory;
        return boxed;
    }
};

// ============================================================================
// Query operators
// ============================================================================

/// SQL operator markers. Use as `op.gte(18)`, `op.like("a%")`, etc.
/// Comptime detected via the `sql_op` decl.
pub const op = struct {
    fn Op(comptime opstr: []const u8, comptime T: type) type {
        return struct {
            v: T,
            pub const sql_op: []const u8 = opstr;
            pub const sql_is_null = false;
        };
    }

    pub fn eq(v: anytype) Op("=", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn neq(v: anytype) Op("!=", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn lt(v: anytype) Op("<", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn lte(v: anytype) Op("<=", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn gt(v: anytype) Op(">", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn gte(v: anytype) Op(">=", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn like(v: []const u8) Op("LIKE", []const u8) {
        return .{ .v = v };
    }

    pub const IsNull = struct {
        pub const sql_op: []const u8 = "IS NULL";
        pub const sql_is_null = true;
    };
    pub const NotNull = struct {
        pub const sql_op: []const u8 = "IS NOT NULL";
        pub const sql_is_null = true;
    };
    pub const isNull = IsNull{};
    pub const notNull = NotNull{};

    fn isOpType(comptime T: type) bool {
        return @hasDecl(T, "sql_op");
    }
};

// ============================================================================
// Repo + Query (ORM-ish layer)
// ============================================================================

fn entityCfg(comptime T: type) type {
    if (!@hasDecl(T, "sqlite")) @compileError(@typeName(T) ++ " missing `pub const sqlite = .{...}` decl");
    return @TypeOf(T.sqlite);
}

fn entityTable(comptime T: type) []const u8 {
    const cfg = T.sqlite;
    if (@hasField(entityCfg(T), "table")) return cfg.table;
    // default: lowercased type name.
    const name = @typeName(T);
    // strip leading namespace dots if any.
    var last_dot: usize = 0;
    for (name, 0..) |ch, i| if (ch == '.') {
        last_dot = i + 1;
    };
    return name[last_dot..];
}

fn entityPk(comptime T: type) []const u8 {
    const cfg = T.sqlite;
    if (@hasField(entityCfg(T), "primary_key")) return @tagName(cfg.primary_key);
    @compileError(@typeName(T) ++ ": sqlite config missing .primary_key");
}

fn entityAutoinc(comptime T: type) bool {
    const cfg = T.sqlite;
    if (@hasField(entityCfg(T), "autoincrement")) return cfg.autoincrement;
    return false;
}

fn fieldType(comptime T: type, comptime name: []const u8) type {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError(@typeName(T) ++ " has no field " ++ name);
}

/// Comma-separated column list for a struct's fields.
fn columnList(comptime T: type) []const u8 {
    comptime {
        const fields = @typeInfo(T).@"struct".fields;
        var s: []const u8 = "";
        for (fields, 0..) |f, i| {
            if (i > 0) s = s ++ ", ";
            s = s ++ f.name;
        }
        return s;
    }
}

pub fn Repo(comptime T: type) type {
    return struct {
        conn: *Conn,
        alloc: Allocator,

        const Self = @This();
        const table = entityTable(T);
        const pk = entityPk(T);
        const all_cols = columnList(T);

        pub fn init(conn: *Conn, alloc: Allocator) Self {
            return .{ .conn = conn, .alloc = alloc };
        }

        /// Insert. `values` is an anon struct with a subset of T's fields.
        /// Returns the inserted row with PK populated (if autoincrement).
        pub fn insert(self: Self, values: anytype) Error!T {
            const V = @TypeOf(values);
            const v_fields = @typeInfo(V).@"struct".fields;
            comptime var cols: []const u8 = "";
            comptime var qs: []const u8 = "";
            comptime {
                for (v_fields, 0..) |f, i| {
                    if (i > 0) {
                        cols = cols ++ ", ";
                        qs = qs ++ ", ";
                    }
                    cols = cols ++ f.name;
                    qs = qs ++ "?";
                }
            }
            const sql_text = comptime ("INSERT INTO " ++ table ++ "(" ++ cols ++ ") VALUES(" ++ qs ++ ");\x00")[0 .. ("INSERT INTO " ++ table ++ "(" ++ cols ++ ") VALUES(" ++ qs ++ ");").len :0];

            var stmt = try self.conn.prepare(sql_text, null);
            defer stmt.deinit();
            try stmt.bindAll(values, null);
            try stmt.execDone(null);

            const rowid = self.conn.lastInsertRowid();
            // Fetch back to populate any defaults / autoincrement PK.
            return (try self.findRowid(rowid)) orelse error.SqliteError;
        }

        /// Find by primary key value.
        pub fn find(self: Self, pk_value: anytype) Error!?T {
            const sql_text = comptime ("SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE " ++ pk ++ " = ?;\x00")[0 .. ("SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE " ++ pk ++ " = ?;").len :0];
            return try self.conn.queryOne(T, sql_text, .{pk_value}, self.alloc, null);
        }

        /// Find by sqlite rowid (used internally after insert).
        fn findRowid(self: Self, rowid: i64) Error!?T {
            const sql_text = comptime ("SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE rowid = ?;\x00")[0 .. ("SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE rowid = ?;").len :0];
            return try self.conn.queryOne(T, sql_text, .{rowid}, self.alloc, null);
        }

        /// Find first row matching exact field equality.
        pub fn findBy(self: Self, comptime field: std.meta.FieldEnum(T), value: anytype) Error!?T {
            const fname = @tagName(field);
            const sql_text = comptime ("SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE " ++ fname ++ " = ?;\x00")[0 .. ("SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE " ++ fname ++ " = ?;").len :0];
            return try self.conn.queryOne(T, sql_text, .{value}, self.alloc, null);
        }

        /// Fetch all rows. Caller owns slice + slice fields; use `freeAll`.
        pub fn all(self: Self) Error![]T {
            const sql_text = comptime ("SELECT " ++ all_cols ++ " FROM " ++ table ++ ";\x00")[0 .. ("SELECT " ++ all_cols ++ " FROM " ++ table ++ ";").len :0];
            var it = try self.conn.query(T, sql_text, .{}, self.alloc, null);
            defer it.deinit();
            var list = std.ArrayList(T).init(self.alloc);
            errdefer {
                for (list.items) |row| freeRow(T, self.alloc, row);
                list.deinit();
            }
            while (try it.next(null)) |row| {
                list.append(row) catch return error.OutOfMemory;
            }
            return list.toOwnedSlice() catch return error.OutOfMemory;
        }

        /// Count rows.
        pub fn count(self: Self) Error!i64 {
            const sql_text = comptime ("SELECT COUNT(*) FROM " ++ table ++ ";\x00")[0 .. ("SELECT COUNT(*) FROM " ++ table ++ ";").len :0];
            const Row = struct { c: i64 };
            const r = try self.conn.queryOne(Row, sql_text, .{}, self.alloc, null);
            return if (r) |row| row.c else 0;
        }

        /// Update fields listed in `changes` for row matching PK.
        pub fn update(self: Self, pk_value: anytype, changes: anytype) Error!void {
            const C = @TypeOf(changes);
            const c_fields = @typeInfo(C).@"struct".fields;
            if (c_fields.len == 0) @compileError("update: empty changes struct");
            comptime var sets: []const u8 = "";
            comptime {
                for (c_fields, 0..) |f, i| {
                    if (i > 0) sets = sets ++ ", ";
                    sets = sets ++ f.name ++ " = ?";
                }
            }
            const sql_str = "UPDATE " ++ table ++ " SET " ++ sets ++ " WHERE " ++ pk ++ " = ?;";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];

            var stmt = try self.conn.prepare(sql_text, null);
            defer stmt.deinit();
            inline for (c_fields, 0..) |f, i| {
                try stmt.bindAny(@intCast(i + 1), @field(changes, f.name), null);
            }
            try stmt.bindAny(@intCast(c_fields.len + 1), pk_value, null);
            try stmt.execDone(null);
        }

        /// Delete row by PK.
        pub fn delete(self: Self, pk_value: anytype) Error!void {
            const sql_text = comptime ("DELETE FROM " ++ table ++ " WHERE " ++ pk ++ " = ?;\x00")[0 .. ("DELETE FROM " ++ table ++ " WHERE " ++ pk ++ " = ?;").len :0];
            try self.conn.exec(sql_text, .{pk_value}, null);
        }

        /// Free a slice of rows returned by `all` / `query.all`.
        pub fn freeAll(self: Self, rows: []T) void {
            for (rows) |row| freeRow(T, self.alloc, row);
            self.alloc.free(rows);
        }

        pub fn query(self: Self) QueryBuilder(T) {
            return QueryBuilder(T).init(self.conn, self.alloc);
        }

        /// Run `CREATE TABLE IF NOT EXISTS` for this entity.
        pub fn createTable(self: Self) Error!void {
            const ddl = comptime schema.createTable(T, table);
            try self.conn.execNoArgs(ddl, null);
        }
    };
}

/// Comptime query builder for `Repo(T)`. Methods take comptime spec structs;
/// SQL is generated at comptime. Bound values flow into a runtime tuple.
pub fn QueryBuilder(comptime T: type) type {
    return struct {
        conn: *Conn,
        alloc: Allocator,

        const Self = @This();
        const table = entityTable(T);
        const all_cols = columnList(T);

        pub fn init(conn: *Conn, alloc: Allocator) Self {
            return .{ .conn = conn, .alloc = alloc };
        }

        /// Returns a typed where-clause buffer with `.orderBy(...).limit(...).all()`.
        /// `conds` is an anon struct: field name = column, value = scalar (eq) or op marker.
        pub fn where(self: Self, conds: anytype) Where(T, @TypeOf(conds)) {
            return Where(T, @TypeOf(conds)){ .conn = self.conn, .alloc = self.alloc, .conds = conds };
        }

        pub fn all(self: Self) Error![]T {
            const sql_text = comptime ("SELECT " ++ all_cols ++ " FROM " ++ table ++ ";\x00")[0 .. ("SELECT " ++ all_cols ++ " FROM " ++ table ++ ";").len :0];
            return try collectAll(T, self.conn, sql_text, .{}, self.alloc);
        }
    };
}

fn collectAll(
    comptime T: type,
    conn: *Conn,
    comptime sql_text: [:0]const u8,
    args: anytype,
    alloc: Allocator,
) Error![]T {
    var it = try conn.query(T, sql_text, args, alloc, null);
    defer it.deinit();
    var list = std.ArrayList(T).init(alloc);
    errdefer {
        for (list.items) |row| freeRow(T, alloc, row);
        list.deinit();
    }
    while (try it.next(null)) |row| {
        list.append(row) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice() catch return error.OutOfMemory;
}

/// Build WHERE clause SQL fragment + bind tuple from a struct of conditions.
/// Each field of `Conds` becomes one predicate:
/// - field value with `sql_op` decl → `<col> <op> ?` (or `IS NULL` / `IS NOT NULL`)
/// - any other value → `<col> = ?` (eq)
fn Where(comptime T: type, comptime Conds: type) type {
    return struct {
        conn: *Conn,
        alloc: Allocator,
        conds: Conds,
        order_clause: []const u8 = "",
        limit_n: ?i64 = null,
        offset_n: ?i64 = null,

        const Self = @This();
        const table = entityTable(T);
        const all_cols = columnList(T);

        /// True iff `FT` is an op marker (has `sql_op` decl). Safe for non-struct types.
        fn isOp(comptime FT: type) bool {
            return switch (@typeInfo(FT)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(FT, "sql_op"),
                else => false,
            };
        }

        /// Returns the comptime WHERE clause text (without leading "WHERE ").
        fn whereSql() []const u8 {
            return comptime blk: {
                const fields = @typeInfo(Conds).@"struct".fields;
                if (fields.len == 0) break :blk "1";
                var s: []const u8 = "";
                for (fields, 0..) |f, i| {
                    if (i > 0) s = s ++ " AND ";
                    if (isOp(f.type)) {
                        if (f.type.sql_is_null) {
                            s = s ++ f.name ++ " " ++ f.type.sql_op;
                        } else {
                            s = s ++ f.name ++ " " ++ f.type.sql_op ++ " ?";
                        }
                    } else {
                        s = s ++ f.name ++ " = ?";
                    }
                }
                break :blk s;
            };
        }

        /// Returns count of `?` placeholders in WHERE.
        fn placeholderCount() usize {
            return comptime blk: {
                const fields = @typeInfo(Conds).@"struct".fields;
                var n: usize = 0;
                for (fields) |f| {
                    if (isOp(f.type) and f.type.sql_is_null) continue;
                    n += 1;
                }
                break :blk n;
            };
        }

        fn bindConds(self: Self, stmt: *Stmt) Error!void {
            const fields = @typeInfo(Conds).@"struct".fields;
            comptime var idx: c_int = 1;
            inline for (fields) |f| {
                const fv = @field(self.conds, f.name);
                if (comptime isOp(f.type)) {
                    if (!f.type.sql_is_null) {
                        try stmt.bindAny(idx, fv.v, null);
                        idx += 1;
                    }
                } else {
                    try stmt.bindAny(idx, fv, null);
                    idx += 1;
                }
            }
        }

        pub fn orderBy(self: Self, comptime field: std.meta.FieldEnum(T), comptime dir: enum { asc, desc }) Self {
            var copy = self;
            copy.order_clause = comptime " ORDER BY " ++ @tagName(field) ++ if (dir == .asc) " ASC" else " DESC";
            return copy;
        }

        pub fn limit(self: Self, n: i64) Self {
            var copy = self;
            copy.limit_n = n;
            return copy;
        }

        pub fn offset(self: Self, n: i64) Self {
            var copy = self;
            copy.offset_n = n;
            return copy;
        }

        /// Execute and collect all rows.
        pub fn all(self: Self) Error![]T {
            const w = comptime whereSql();
            const base = comptime "SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE " ++ w;
            // Pre-compose at comptime parts that don't depend on runtime opts; append at runtime.
            const ord = self.order_clause;
            const has_lim = self.limit_n != null;
            const has_off = self.offset_n != null;

            // Build full SQL with std.fmt at runtime (small alloc).
            var buf = std.ArrayList(u8).init(self.alloc);
            defer buf.deinit();
            buf.appendSlice(base) catch return error.OutOfMemory;
            buf.appendSlice(ord) catch return error.OutOfMemory;
            if (has_lim) buf.appendSlice(" LIMIT ?") catch return error.OutOfMemory;
            if (has_off) buf.appendSlice(" OFFSET ?") catch return error.OutOfMemory;
            buf.append(';') catch return error.OutOfMemory;
            buf.append(0) catch return error.OutOfMemory;
            const sql_text = buf.items[0 .. buf.items.len - 1 :0];

            var stmt = try self.conn.prepare(sql_text, null);
            defer stmt.deinit();
            try self.bindConds(&stmt);
            var next_idx: c_int = @intCast(placeholderCount() + 1);
            if (self.limit_n) |n| {
                try stmt.bindAny(next_idx, n, null);
                next_idx += 1;
            }
            if (self.offset_n) |n| {
                try stmt.bindAny(next_idx, n, null);
            }

            var list = std.ArrayList(T).init(self.alloc);
            errdefer {
                for (list.items) |row| freeRow(T, self.alloc, row);
                list.deinit();
            }
            while (true) {
                const rc = c.sqlite3_step(stmt.stmt);
                switch (rc) {
                    c.SQLITE_ROW => {
                        const row = try decodeRow(T, &stmt, self.alloc);
                        list.append(row) catch return error.OutOfMemory;
                    },
                    c.SQLITE_DONE => break,
                    else => try codeToError(rc),
                }
            }
            return list.toOwnedSlice() catch return error.OutOfMemory;
        }

        pub fn first(self: Self) Error!?T {
            const rows = try self.limit(1).all();
            defer self.alloc.free(rows);
            if (rows.len == 0) return null;
            return rows[0];
        }

        pub fn count(self: Self) Error!i64 {
            const w = comptime whereSql();
            const base = comptime "SELECT COUNT(*) FROM " ++ table ++ " WHERE " ++ w;
            const sql_with_term = base ++ ";";
            const sql_text = comptime (sql_with_term ++ "\x00")[0..sql_with_term.len :0];
            var stmt = try self.conn.prepare(sql_text, null);
            defer stmt.deinit();
            try self.bindConds(&stmt);
            const rc = c.sqlite3_step(stmt.stmt);
            if (rc != c.SQLITE_ROW) try codeToError(rc);
            return stmt.columnI64(0);
        }

        /// Delete all matching rows.
        pub fn delete(self: Self) Error!void {
            const w = comptime whereSql();
            const base = comptime "DELETE FROM " ++ table ++ " WHERE " ++ w;
            const sql_with_term = base ++ ";";
            const sql_text = comptime (sql_with_term ++ "\x00")[0..sql_with_term.len :0];
            var stmt = try self.conn.prepare(sql_text, null);
            defer stmt.deinit();
            try self.bindConds(&stmt);
            try stmt.execDone(null);
        }
    };
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

// ----- ORM entity used by Repo / Query tests -----

const Person = struct {
    id: ?i64,
    name: []const u8,
    age: ?u32,
    pub const sqlite = .{
        .table = "person",
        .primary_key = .id,
        .autoincrement = true,
        .unique = &.{.name},
    };
};

test "Repo: insert, find, update, delete, count" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();

    const repo = Repo(Person).init(&db, alloc);
    try repo.createTable();

    const alice = try repo.insert(.{ .name = "alice", .age = @as(?u32, 30) });
    defer freeRow(Person, alloc, alice);
    try testing.expect(alice.id != null);
    try testing.expectEqualStrings("alice", alice.name);

    const bob = try repo.insert(.{ .name = "bob", .age = @as(?u32, null) });
    defer freeRow(Person, alloc, bob);

    const found = try repo.find(alice.id.?);
    try testing.expect(found != null);
    defer freeRow(Person, alloc, found.?);
    try testing.expectEqualStrings("alice", found.?.name);

    const by_name = try repo.findBy(.name, "bob");
    try testing.expect(by_name != null);
    defer freeRow(Person, alloc, by_name.?);

    try testing.expectEqual(@as(i64, 2), try repo.count());

    try repo.update(alice.id.?, .{ .name = @as([]const u8, "alicia") });
    const renamed = (try repo.find(alice.id.?)).?;
    defer freeRow(Person, alloc, renamed);
    try testing.expectEqualStrings("alicia", renamed.name);

    try repo.delete(bob.id.?);
    try testing.expectEqual(@as(i64, 1), try repo.count());
}

test "Query: where eq + ops + orderBy + limit" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();

    const repo = Repo(Person).init(&db, alloc);
    try repo.createTable();

    inline for (.{
        .{ "a", @as(?u32, 10) },
        .{ "b", @as(?u32, 20) },
        .{ "c", @as(?u32, 30) },
        .{ "d", @as(?u32, 40) },
    }) |row| {
        const r = try repo.insert(.{ .name = @as([]const u8, row[0]), .age = row[1] });
        freeRow(Person, alloc, r);
    }

    // age >= 20 ordered desc, limit 2
    const top2 = try repo.query()
        .where(.{ .age = op.gte(@as(u32, 20)) })
        .orderBy(.age, .desc)
        .limit(2)
        .all();
    defer repo.freeAll(top2);
    try testing.expectEqual(@as(usize, 2), top2.len);
    try testing.expectEqualStrings("d", top2[0].name);
    try testing.expectEqualStrings("c", top2[1].name);

    // name LIKE 'a%'
    const a_only = try repo.query()
        .where(.{ .name = op.like("a%") })
        .all();
    defer repo.freeAll(a_only);
    try testing.expectEqual(@as(usize, 1), a_only.len);

    // count where eq
    const n = try repo.query().where(.{ .age = @as(?u32, 30) }).count();
    try testing.expectEqual(@as(i64, 1), n);
}

test "Query: delete where" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();

    const repo = Repo(Person).init(&db, alloc);
    try repo.createTable();
    const r1 = try repo.insert(.{ .name = @as([]const u8, "x"), .age = @as(?u32, 5) });
    freeRow(Person, alloc, r1);
    const r2 = try repo.insert(.{ .name = @as([]const u8, "y"), .age = @as(?u32, 50) });
    freeRow(Person, alloc, r2);

    try repo.query().where(.{ .age = op.lt(@as(u32, 10)) }).delete();
    try testing.expectEqual(@as(i64, 1), try repo.count());
}

test "StmtCache: execCached + queryCached reuse" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    try db.enableCache(alloc);

    try db.execNoArgs("CREATE TABLE t(x INTEGER);", null);
    for (0..3) |i| {
        try db.execCached("INSERT INTO t VALUES(?);", .{@as(i64, @intCast(i))}, null);
    }

    const Row = struct { x: i64 };
    var it = try db.queryCached(Row, "SELECT x FROM t ORDER BY x;", .{}, alloc, null);
    defer it.deinit();
    var sum: i64 = 0;
    while (try it.next(null)) |row| sum += row.x;
    try testing.expectEqual(@as(i64, 0 + 1 + 2), sum);

    // Second query reuses same cached stmt — should not double-finalize.
    var it2 = try db.queryCached(Row, "SELECT x FROM t ORDER BY x;", .{}, alloc, null);
    defer it2.deinit();
    var n: usize = 0;
    while (try it2.next(null)) |_| n += 1;
    try testing.expectEqual(@as(usize, 3), n);
}
