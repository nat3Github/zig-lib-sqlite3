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
    tx_depth: u32 = 0,

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
        depth: u32,
        finished: bool = false,

        pub fn commit(self: *Tx) Error!void {
            if (self.finished) return;
            self.finished = true;
            if (self.depth == 1) {
                try self.conn.execNoArgs("COMMIT;", null);
            } else {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrintZ(&buf, "RELEASE sp{d};", .{self.depth}) catch unreachable;
                try self.conn.execNoArgs(s, null);
            }
            self.conn.tx_depth -|= 1;
        }
        pub fn rollback(self: *Tx) void {
            if (self.finished) return;
            self.finished = true;
            if (self.depth == 1) {
                self.conn.execNoArgs("ROLLBACK;", null) catch {};
            } else {
                var buf: [64]u8 = undefined;
                const s1 = std.fmt.bufPrintZ(&buf, "ROLLBACK TO sp{d};", .{self.depth}) catch unreachable;
                self.conn.execNoArgs(s1, null) catch {};
                var buf2: [64]u8 = undefined;
                const s2 = std.fmt.bufPrintZ(&buf2, "RELEASE sp{d};", .{self.depth}) catch unreachable;
                self.conn.execNoArgs(s2, null) catch {};
            }
            self.conn.tx_depth -|= 1;
        }
    };

    /// Begin transaction. Nested calls create SAVEPOINTs. Each Tx must be
    /// committed or rolled back; mismatched nesting is your bug.
    pub fn begin(self: *Conn) Error!Tx {
        const new_depth = self.tx_depth + 1;
        if (new_depth == 1) {
            try self.execNoArgs("BEGIN;", null);
        } else {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrintZ(&buf, "SAVEPOINT sp{d};", .{new_depth}) catch unreachable;
            try self.execNoArgs(s, null);
        }
        self.tx_depth = new_depth;
        return Tx{ .conn = self, .depth = new_depth };
    }

    pub fn beginImmediate(self: *Conn) Error!Tx {
        if (self.tx_depth > 0) return self.begin(); // nested: SAVEPOINT only
        try self.execNoArgs("BEGIN IMMEDIATE;", null);
        self.tx_depth = 1;
        return Tx{ .conn = self, .depth = 1 };
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
// Connection pool
// ============================================================================

/// Bounded connection pool. Useful under WAL mode where multiple readers can
/// run concurrently with a single writer. `acquire` blocks until a connection
/// is free; `release` returns it.
pub const Pool = struct {
    conns: []Conn,
    in_use: []bool,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    alloc: Allocator,

    pub fn init(alloc: Allocator, opts: OpenOptions, size: usize) Error!Pool {
        if (size == 0) return error.SqliteMisuse;
        const conns = alloc.alloc(Conn, size) catch return error.OutOfMemory;
        errdefer alloc.free(conns);
        const in_use = alloc.alloc(bool, size) catch return error.OutOfMemory;
        errdefer alloc.free(in_use);
        @memset(in_use, false);

        var opened: usize = 0;
        errdefer for (conns[0..opened]) |*conn| conn.close();
        while (opened < size) : (opened += 1) {
            conns[opened] = try Conn.open(opts);
        }

        return .{
            .conns = conns,
            .in_use = in_use,
            .mutex = .{},
            .cond = .{},
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.conns) |*conn| conn.close();
        self.alloc.free(self.conns);
        self.alloc.free(self.in_use);
    }

    /// Block until a connection is available.
    pub fn acquire(self: *Pool) *Conn {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            for (self.in_use, 0..) |used, i| {
                if (!used) {
                    self.in_use[i] = true;
                    return &self.conns[i];
                }
            }
            self.cond.wait(&self.mutex);
        }
    }

    pub fn release(self: *Pool, conn: *Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const base = @intFromPtr(self.conns.ptr);
        const offset = @intFromPtr(conn) - base;
        const idx = offset / @sizeOf(Conn);
        std.debug.assert(idx < self.in_use.len);
        self.in_use[idx] = false;
        self.cond.signal();
    }
};

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
                if (comptime V == Blob) {
                    try self.bindBlob(idx, value.bytes);
                } else if (comptime isJsonType(V)) {
                    try check(sqlite_zig_bind_text_transient(self.stmt, idx, value.bytes.ptr, @intCast(value.bytes.len)), self.db, diag);
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

/// Marker wrapper: stores JSON-encoded bytes of `T`. Bind serializes to TEXT;
/// decode dupes the text into `bytes`. Caller `parse(alloc)` to recover `T`,
/// `free(alloc)` to release the encoded bytes.
///
/// ```zig
/// const Cfg = struct { theme: []const u8, count: u32 };
/// const j = try sql.Json(Cfg).encode(alloc, .{ .theme = "dark", .count = 3 });
/// defer j.free(alloc);
/// try repo.insert(.{ .name = "x", .config = j });
/// ```
pub fn Json(comptime T: type) type {
    return struct {
        bytes: []const u8,
        _sql_json_marker: void = {},

        pub const Inner: type = T;

        const JsonSelf = @This();

        pub fn encode(alloc: Allocator, value: T) Error!JsonSelf {
            const bytes = std.json.Stringify.valueAlloc(alloc, value, .{}) catch return error.OutOfMemory;
            return .{ .bytes = bytes };
        }

        pub fn parse(self: JsonSelf, alloc: Allocator) Error!std.json.Parsed(T) {
            return std.json.parseFromSlice(T, alloc, self.bytes, .{}) catch return error.SqliteError;
        }

        pub fn free(self: JsonSelf, alloc: Allocator) void {
            alloc.free(self.bytes);
        }
    };
}

fn isJsonType(comptime FT: type) bool {
    if (@typeInfo(FT) != .@"struct") return false;
    return @hasField(FT, "_sql_json_marker");
}

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
            if (comptime T == Blob) {
                const raw = stmt.columnBlobRaw(idx);
                return Blob{ .bytes = try alloc.dupe(u8, raw) };
            }
            if (comptime isJsonType(T)) {
                const raw = stmt.columnTextRaw(idx);
                return T{ .bytes = try alloc.dupe(u8, raw) };
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
            if (comptime T == Blob) alloc.free(value.bytes);
            if (comptime isJsonType(T)) alloc.free(value.bytes);
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
            .@"struct" => if (inner == Blob) "BLOB" else if (isJsonType(inner)) "TEXT" else @compileError("unsupported schema struct " ++ @typeName(inner)),
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
            const pk_cols: []const []const u8 = if (@hasField(@TypeOf(cfg), "primary_key"))
                pkColsFromCfg(cfg.primary_key)
            else
                &.{};
            const ai: bool = if (@hasField(@TypeOf(cfg), "autoincrement")) cfg.autoincrement else false;
            const unique_set: []const []const u8 = if (@hasField(@TypeOf(cfg), "unique")) tagNames(cfg.unique) else &.{};
            const nn_set: []const []const u8 = if (@hasField(@TypeOf(cfg), "not_null")) tagNames(cfg.not_null) else &.{};
            const composite_pk = pk_cols.len > 1;

            var out: []const u8 = "CREATE TABLE IF NOT EXISTS " ++ table_name ++ " (\n";
            for (fields, 0..) |f, i| {
                const is_single_pk = pk_cols.len == 1 and std.mem.eql(u8, pk_cols[0], f.name);
                const is_any_pk = containsName(pk_cols, f.name);
                var line: []const u8 = "  " ++ f.name ++ " " ++ sqlTypeOf(f.type);
                if (is_single_pk) {
                    line = line ++ " PRIMARY KEY";
                    if (ai) line = line ++ " AUTOINCREMENT";
                }
                if (containsName(unique_set, f.name)) line = line ++ " UNIQUE";
                if (!isNullable(f.type) and !is_any_pk) {
                    line = line ++ " NOT NULL";
                } else if (containsName(nn_set, f.name)) {
                    line = line ++ " NOT NULL";
                }
                if (i + 1 < fields.len or composite_pk) line = line ++ ",";
                out = out ++ line ++ "\n";
            }
            if (composite_pk) {
                var pk_list: []const u8 = "";
                for (pk_cols, 0..) |pkc, i| {
                    if (i > 0) pk_list = pk_list ++ ", ";
                    pk_list = pk_list ++ pkc;
                }
                out = out ++ "  PRIMARY KEY (" ++ pk_list ++ ")\n";
            }
            out = out ++ ");";
            return out[0..out.len :0];
        }
    }

    /// CREATE INDEX statements derived from `T.sqlite.indexes` config. One
    /// statement per entry; empty list yields a no-op stub.
    pub fn createIndexes(comptime T: type, comptime table_name: []const u8) []const [:0]const u8 {
        return comptime blk: {
            const idxs = entityIndexes(T);
            var stmts: [idxs.len][:0]const u8 = undefined;
            for (idxs, 0..) |spec, i| {
                var cols_list: []const u8 = "";
                var name_part: []const u8 = "";
                for (spec.cols, 0..) |col, j| {
                    if (j > 0) {
                        cols_list = cols_list ++ ", ";
                        name_part = name_part ++ "_";
                    }
                    cols_list = cols_list ++ col;
                    name_part = name_part ++ col;
                }
                const unique_kw: []const u8 = if (spec.unique) "UNIQUE " else "";
                const idx_name = "idx_" ++ table_name ++ "_" ++ name_part;
                const sql_str = "CREATE " ++ unique_kw ++ "INDEX IF NOT EXISTS " ++ idx_name ++ " ON " ++ table_name ++ "(" ++ cols_list ++ ");";
                stmts[i] = (sql_str ++ "\x00")[0..sql_str.len :0];
            }
            const fixed = stmts;
            break :blk &fixed;
        };
    }

    fn pkColsFromCfg(comptime pk: anytype) []const []const u8 {
        return comptime switch (@typeInfo(@TypeOf(pk))) {
            .enum_literal => &.{@tagName(pk)},
            .@"struct" => |s| blk: {
                var out: [s.fields.len][]const u8 = undefined;
                for (s.fields, 0..) |f, i| {
                    out[i] = @tagName(@field(pk, f.name));
                }
                const fixed = out;
                break :blk &fixed;
            },
            else => @compileError(".primary_key must be enum literal or tuple of enum literals"),
        };
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

pub const OpKind = enum { scalar, is_null, is_not_null, in_op, not_in_op, between_op, not_between_op };

/// SQL operator markers. Use as `op.gte(18)`, `op.like("a%")`,
/// `op.in(.{1,2,3})`, `op.between(10, 20)`, `op.isNull`, `op.notNull`.
/// Comptime detected via the `sql_op_kind` decl.
pub const op = struct {
    fn Scalar(comptime opstr: []const u8, comptime T: type) type {
        return struct {
            v: T,
            pub const sql_op_kind: OpKind = .scalar;
            pub const sql_op_str: []const u8 = opstr;
        };
    }

    pub fn eq(v: anytype) Scalar("=", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn neq(v: anytype) Scalar("!=", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn lt(v: anytype) Scalar("<", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn lte(v: anytype) Scalar("<=", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn gt(v: anytype) Scalar(">", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn gte(v: anytype) Scalar(">=", @TypeOf(v)) {
        return .{ .v = v };
    }
    pub fn like(v: []const u8) Scalar("LIKE", []const u8) {
        return .{ .v = v };
    }

    pub const IsNull = struct {
        pub const sql_op_kind: OpKind = .is_null;
    };
    pub const NotNull = struct {
        pub const sql_op_kind: OpKind = .is_not_null;
    };
    pub const isNull = IsNull{};
    pub const notNull = NotNull{};

    fn In(comptime ValuesT: type) type {
        return struct {
            v: ValuesT,
            pub const sql_op_kind: OpKind = .in_op;
        };
    }
    /// `op.in(.{1, 2, 3})` → `col IN (?, ?, ?)`. Values must be a tuple/array
    /// whose length is comptime-known.
    pub fn in(values: anytype) In(@TypeOf(values)) {
        return .{ .v = values };
    }

    fn BetweenT(comptime T: type) type {
        return struct {
            lo: T,
            hi: T,
            pub const sql_op_kind: OpKind = .between_op;
        };
    }
    pub fn between(lo: anytype, hi: anytype) BetweenT(@TypeOf(lo)) {
        return .{ .lo = lo, .hi = hi };
    }

    pub fn glob(v: []const u8) Scalar("GLOB", []const u8) {
        return .{ .v = v };
    }
    pub fn notLike(v: []const u8) Scalar("NOT LIKE", []const u8) {
        return .{ .v = v };
    }
    pub fn notIn(values: anytype) NotIn(@TypeOf(values)) {
        return .{ .v = values };
    }
    fn NotIn(comptime ValuesT: type) type {
        return struct {
            v: ValuesT,
            pub const sql_op_kind: OpKind = .not_in_op;
        };
    }
    pub fn notBetween(lo: anytype, hi: anytype) NotBetweenT(@TypeOf(lo)) {
        return .{ .lo = lo, .hi = hi };
    }
    fn NotBetweenT(comptime T: type) type {
        return struct {
            lo: T,
            hi: T,
            pub const sql_op_kind: OpKind = .not_between_op;
        };
    }
};

fn isOpType(comptime FT: type) bool {
    return switch (@typeInfo(FT)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(FT, "sql_op_kind"),
        else => false,
    };
}

fn inValueCount(comptime FT: type) usize {
    inline for (@typeInfo(FT).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, "v")) {
            return switch (@typeInfo(f.type)) {
                .@"struct" => |s| s.fields.len,
                .array => |a| a.len,
                else => @compileError("op.in expects tuple/array of values"),
            };
        }
    }
    @compileError("In missing .v field");
}

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
    // Single-PK convenience: returns the lone column name. compileError if composite.
    const cols = entityPkCols(T);
    if (cols.len != 1) @compileError(@typeName(T) ++ ": composite primary key — use entityPkCols");
    return cols[0];
}

/// Returns one or more PK column names. Supports single (`.primary_key = .id`)
/// and composite (`.primary_key = .{.user_id, .post_id}`).
fn entityPkCols(comptime T: type) []const []const u8 {
    if (!@hasField(entityCfg(T), "primary_key"))
        @compileError(@typeName(T) ++ ": sqlite config missing .primary_key");
    const pk = T.sqlite.primary_key;
    const PK = @TypeOf(pk);
    return comptime switch (@typeInfo(PK)) {
        .enum_literal => &.{@tagName(pk)},
        .@"struct" => |s| blk: {
            var out: [s.fields.len][]const u8 = undefined;
            for (s.fields, 0..) |f, i| {
                out[i] = @tagName(@field(pk, f.name));
            }
            const fixed = out;
            break :blk &fixed;
        },
        else => @compileError(@typeName(T) ++ ": .primary_key must be enum literal or tuple of enum literals"),
    };
}

/// `c1 = ? AND c2 = ?` for binding PK lookups.
fn pkWhereFragment(comptime T: type) []const u8 {
    return comptime blk: {
        const cols = entityPkCols(T);
        var s: []const u8 = "";
        for (cols, 0..) |col, i| {
            if (i > 0) s = s ++ " AND ";
            s = s ++ col ++ " = ?";
        }
        break :blk s;
    };
}

/// Bind a scalar OR tuple `pk_value` to `?1..?N` of `stmt`. Returns next idx.
fn bindPk(stmt: *Stmt, start_idx: c_int, pk_value: anytype) Error!c_int {
    const PKV = @TypeOf(pk_value);
    const info = @typeInfo(PKV);
    if (info == .@"struct") {
        var idx = start_idx;
        inline for (info.@"struct".fields) |f| {
            try stmt.bindAny(idx, @field(pk_value, f.name), null);
            idx += 1;
        }
        return idx;
    }
    try stmt.bindAny(start_idx, pk_value, null);
    return start_idx + 1;
}

const IndexSpec = struct { cols: []const []const u8, unique: bool };

fn entityIndexes(comptime T: type) []const IndexSpec {
    if (!@hasField(entityCfg(T), "indexes")) return &.{};
    const idx_arr = T.sqlite.indexes;
    return comptime blk: {
        const deref = switch (@typeInfo(@TypeOf(idx_arr))) {
            .pointer => idx_arr.*,
            else => idx_arr,
        };
        const D = @TypeOf(deref);
        const fields = @typeInfo(D).@"struct".fields;
        var out: [fields.len]IndexSpec = undefined;
        for (fields, 0..) |f, i| {
            const item = @field(deref, f.name);
            const cols_arr = item.cols;
            const cols_deref = switch (@typeInfo(@TypeOf(cols_arr))) {
                .pointer => cols_arr.*,
                else => cols_arr,
            };
            const CD = @TypeOf(cols_deref);
            const cfields = @typeInfo(CD).@"struct".fields;
            var cols: [cfields.len][]const u8 = undefined;
            for (cfields, 0..) |cf, ci| {
                cols[ci] = @tagName(@field(cols_deref, cf.name));
            }
            const fixed_cols = cols;
            out[i] = .{
                .cols = &fixed_cols,
                .unique = if (@hasField(@TypeOf(item), "unique")) item.unique else false,
            };
        }
        const fixed = out;
        break :blk &fixed;
    };
}

fn entityAutoinc(comptime T: type) bool {
    const cfg = T.sqlite;
    if (@hasField(entityCfg(T), "autoincrement")) return cfg.autoincrement;
    return false;
}

fn createdAtField(comptime T: type) ?[]const u8 {
    const cfg = T.sqlite;
    if (!@hasField(entityCfg(T), "timestamps")) return null;
    const ts = cfg.timestamps;
    if (@hasField(@TypeOf(ts), "created_at")) return @tagName(ts.created_at);
    return null;
}

fn updatedAtField(comptime T: type) ?[]const u8 {
    const cfg = T.sqlite;
    if (!@hasField(entityCfg(T), "timestamps")) return null;
    const ts = cfg.timestamps;
    if (@hasField(@TypeOf(ts), "updated_at")) return @tagName(ts.updated_at);
    return null;
}

fn softDeleteField(comptime T: type) ?[]const u8 {
    const cfg = T.sqlite;
    if (@hasField(entityCfg(T), "soft_delete")) return @tagName(cfg.soft_delete);
    return null;
}

fn aliveFilter(comptime T: type) []const u8 {
    if (softDeleteField(T)) |f| return f ++ " IS NULL";
    return "1";
}

/// Build SQL fragment for one op-or-scalar condition on `field_name`.
fn opFragment(comptime FT: type, comptime field_name: []const u8) []const u8 {
    comptime {
        if (!isOpType(FT)) return field_name ++ " = ?";
        switch (FT.sql_op_kind) {
            .scalar => return field_name ++ " " ++ FT.sql_op_str ++ " ?",
            .is_null => return field_name ++ " IS NULL",
            .is_not_null => return field_name ++ " IS NOT NULL",
            .in_op, .not_in_op => {
                const n = inValueCount(FT);
                if (n == 0) @compileError("op.in/notIn: empty value list");
                const kw: []const u8 = if (FT.sql_op_kind == .not_in_op) " NOT IN (" else " IN (";
                var s: []const u8 = field_name ++ kw;
                for (0..n) |i| {
                    if (i > 0) s = s ++ ", ";
                    s = s ++ "?";
                }
                return s ++ ")";
            },
            .between_op => return field_name ++ " BETWEEN ? AND ?",
            .not_between_op => return field_name ++ " NOT BETWEEN ? AND ?",
        }
    }
}

fn opPlaceholders(comptime FT: type) usize {
    if (!isOpType(FT)) return 1;
    return switch (FT.sql_op_kind) {
        .scalar => 1,
        .is_null, .is_not_null => 0,
        .in_op, .not_in_op => inValueCount(FT),
        .between_op, .not_between_op => 2,
    };
}

/// Bind values for one op-or-scalar condition. Returns next placeholder index.
fn bindOp(stmt: *Stmt, idx: c_int, comptime FT: type, value: anytype) Error!c_int {
    if (comptime !isOpType(FT)) {
        try stmt.bindAny(idx, value, null);
        return idx + 1;
    }
    switch (comptime FT.sql_op_kind) {
        .scalar => {
            try stmt.bindAny(idx, value.v, null);
            return idx + 1;
        },
        .is_null, .is_not_null => return idx,
        .in_op, .not_in_op => {
            var cur = idx;
            const vs = value.v;
            inline for (@typeInfo(@TypeOf(vs)).@"struct".fields) |vf| {
                try stmt.bindAny(cur, @field(vs, vf.name), null);
                cur += 1;
            }
            return cur;
        },
        .between_op, .not_between_op => {
            try stmt.bindAny(idx, value.lo, null);
            try stmt.bindAny(idx + 1, value.hi, null);
            return idx + 2;
        },
    }
}

fn fieldType(comptime T: type, comptime name: []const u8) type {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError(@typeName(T) ++ " has no field " ++ name);
}

/// Comma-separated column list for a struct's fields.
fn columnList(comptime T: type) []const u8 {
    return comptime blk: {
        const fields = @typeInfo(T).@"struct".fields;
        var s: []const u8 = "";
        for (fields, 0..) |f, i| {
            if (i > 0) s = s ++ ", ";
            s = s ++ f.name;
        }
        break :blk s;
    };
}

pub fn Repo(comptime T: type) type {
    return struct {
        conn: *Conn,
        alloc: Allocator,
        diag: ?*Diag = null,

        const Self = @This();
        const table = entityTable(T);
        const pk_cols = entityPkCols(T);
        const pk_where = pkWhereFragment(T);
        const all_cols = columnList(T);
        const ts_created = createdAtField(T);
        const ts_updated = updatedAtField(T);
        const soft_field = softDeleteField(T);

        pub fn init(conn: *Conn, alloc: Allocator) Self {
            return .{ .conn = conn, .alloc = alloc };
        }

        /// Returns a copy of this Repo wired to capture sqlite error info into `d`.
        pub fn withDiag(self: Self, d: *Diag) Self {
            var copy = self;
            copy.diag = d;
            return copy;
        }

        const StmtLease = struct {
            stmt_storage: Stmt = undefined,
            cached_ptr: ?*Stmt = null,

            pub fn ptr(self: *StmtLease) *Stmt {
                return self.cached_ptr orelse &self.stmt_storage;
            }
            pub fn deinit(self: *StmtLease) void {
                if (self.cached_ptr == null) self.stmt_storage.deinit();
            }
        };

        /// Cache-aware statement acquisition. If `conn.cache` is set, returns
        /// the cached `*Stmt` (reset + cleared). Otherwise prepares fresh into
        /// `lease.stmt_storage`. Caller `defer lease.deinit()`.
        fn lease(self: Self, comptime sql_text: [:0]const u8) Error!StmtLease {
            var l: StmtLease = .{};
            if (self.conn.cache) |cache| {
                const s = try cache.getOrPrepare(sql_text);
                try s.reset();
                s.clearBindings();
                l.cached_ptr = s;
            } else {
                l.stmt_storage = try self.conn.prepare(sql_text, self.diag);
            }
            return l;
        }

        /// Insert. `values` is an anon struct with a subset of T's fields.
        /// Returns the inserted row with PK populated (if autoincrement).
        /// Auto-populates timestamps fields if configured on entity.
        pub fn insert(self: Self, values: anytype) Error!T {
            const V = @TypeOf(values);
            const v_fields = @typeInfo(V).@"struct".fields;

            comptime var cols: []const u8 = "";
            comptime var qs: []const u8 = "";
            comptime {
                var first = true;
                for (v_fields) |f| {
                    if (!first) {
                        cols = cols ++ ", ";
                        qs = qs ++ ", ";
                    }
                    first = false;
                    cols = cols ++ f.name;
                    qs = qs ++ "?";
                }
                if (ts_created) |ts_c| {
                    if (!first) {
                        cols = cols ++ ", ";
                        qs = qs ++ ", ";
                    }
                    first = false;
                    cols = cols ++ ts_c;
                    qs = qs ++ "?";
                }
                if (ts_updated) |ts_u| {
                    if (!first) {
                        cols = cols ++ ", ";
                        qs = qs ++ ", ";
                    }
                    cols = cols ++ ts_u;
                    qs = qs ++ "?";
                }
            }
            const sql_str = "INSERT INTO " ++ table ++ "(" ++ cols ++ ") VALUES(" ++ qs ++ ");";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];

            var l = try self.lease(sql_text);
            defer l.deinit();
            const stmt = l.ptr();
            var idx: c_int = 1;
            inline for (v_fields) |f| {
                try stmt.bindAny(idx, @field(values, f.name), self.diag);
                idx += 1;
            }
            const now: i64 = std.time.timestamp();
            if (ts_created != null) {
                try stmt.bindAny(idx, now, self.diag);
                idx += 1;
            }
            if (ts_updated != null) {
                try stmt.bindAny(idx, now, self.diag);
                idx += 1;
            }
            try stmt.execDone(self.diag);

            const rowid = self.conn.lastInsertRowid();
            return (try self.findRowid(rowid)) orelse error.SqliteError;
        }

        /// Find by primary key value. Honors soft-delete filter.
        /// For composite PK, pass a tuple `.{a, b}`.
        pub fn find(self: Self, pk_value: anytype) Error!?T {
            const cond = comptime aliveFilter(T);
            const sql_str = "SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE " ++ pk_where ++ " AND " ++ cond ++ ";";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
            var l = try self.lease(sql_text);
            defer l.deinit();
            const stmt = l.ptr();
            _ = try bindPk(stmt, 1, pk_value);
            return try stepOne(T, stmt, self.alloc);
        }

        /// Find a row including soft-deleted entries.
        pub fn findIncludingDeleted(self: Self, pk_value: anytype) Error!?T {
            const sql_str = "SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE " ++ pk_where ++ ";";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
            var l = try self.lease(sql_text);
            defer l.deinit();
            const stmt = l.ptr();
            _ = try bindPk(stmt, 1, pk_value);
            return try stepOne(T, stmt, self.alloc);
        }

        fn findRowid(self: Self, rowid: i64) Error!?T {
            const sql_str = "SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE rowid = ?;";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
            return try self.conn.queryOne(T, sql_text, .{rowid}, self.alloc, self.diag);
        }

        /// Find first row matching exact field equality. Honors soft-delete.
        pub fn findBy(self: Self, comptime field: std.meta.FieldEnum(T), value: anytype) Error!?T {
            const fname = @tagName(field);
            const cond = comptime aliveFilter(T);
            const sql_str = "SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE " ++ fname ++ " = ? AND " ++ cond ++ ";";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
            return try self.conn.queryOne(T, sql_text, .{value}, self.alloc, self.diag);
        }

        /// Fetch all rows. Caller owns slice + slice fields; use `freeAll`.
        pub fn all(self: Self) Error![]T {
            const cond = comptime aliveFilter(T);
            const sql_str = "SELECT " ++ all_cols ++ " FROM " ++ table ++ " WHERE " ++ cond ++ ";";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
            return try collectAll(T, self.conn, sql_text, .{}, self.alloc, self.diag);
        }

        pub fn count(self: Self) Error!i64 {
            const cond = comptime aliveFilter(T);
            const sql_str = "SELECT COUNT(*) FROM " ++ table ++ " WHERE " ++ cond ++ ";";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
            const Row = struct { c: i64 };
            const r = try self.conn.queryOne(Row, sql_text, .{}, self.alloc, self.diag);
            return if (r) |row| row.c else 0;
        }

        /// Update fields listed in `changes` for row matching PK.
        /// Auto-updates `updated_at` if configured.
        pub fn update(self: Self, pk_value: anytype, changes: anytype) Error!void {
            const C = @TypeOf(changes);
            const c_fields = @typeInfo(C).@"struct".fields;
            if (c_fields.len == 0 and ts_updated == null) @compileError("update: empty changes struct");
            comptime var sets: []const u8 = "";
            comptime {
                var first = true;
                for (c_fields) |f| {
                    if (!first) sets = sets ++ ", ";
                    first = false;
                    sets = sets ++ f.name ++ " = ?";
                }
                if (ts_updated) |u| {
                    if (!first) sets = sets ++ ", ";
                    sets = sets ++ u ++ " = ?";
                }
            }
            const sql_str = "UPDATE " ++ table ++ " SET " ++ sets ++ " WHERE " ++ pk_where ++ ";";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];

            var l = try self.lease(sql_text);
            defer l.deinit();
            const stmt = l.ptr();
            var idx: c_int = 1;
            inline for (c_fields) |f| {
                try stmt.bindAny(idx, @field(changes, f.name), self.diag);
                idx += 1;
            }
            if (ts_updated != null) {
                try stmt.bindAny(idx, @as(i64, std.time.timestamp()), self.diag);
                idx += 1;
            }
            _ = try bindPk(stmt, idx, pk_value);
            try stmt.execDone(self.diag);
        }

        /// Delete by PK. When `soft_delete` configured, sets the field to now()
        /// instead of removing. Use `deleteHard` for unconditional removal.
        pub fn delete(self: Self, pk_value: anytype) Error!void {
            if (comptime soft_field) |f| {
                const sql_str = "UPDATE " ++ table ++ " SET " ++ f ++ " = ? WHERE " ++ pk_where ++ ";";
                const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
                var l = try self.lease(sql_text);
                defer l.deinit();
                const stmt = l.ptr();
                try stmt.bindAny(1, @as(i64, std.time.timestamp()), self.diag);
                _ = try bindPk(stmt, 2, pk_value);
                try stmt.execDone(self.diag);
            } else {
                const sql_str = "DELETE FROM " ++ table ++ " WHERE " ++ pk_where ++ ";";
                const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
                var l = try self.lease(sql_text);
                defer l.deinit();
                const stmt = l.ptr();
                _ = try bindPk(stmt, 1, pk_value);
                try stmt.execDone(self.diag);
            }
        }

        /// Unconditional DELETE FROM, bypassing soft-delete.
        pub fn deleteHard(self: Self, pk_value: anytype) Error!void {
            const sql_str = "DELETE FROM " ++ table ++ " WHERE " ++ pk_where ++ ";";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
            var l = try self.lease(sql_text);
            defer l.deinit();
            const stmt = l.ptr();
            _ = try bindPk(stmt, 1, pk_value);
            try stmt.execDone(self.diag);
        }

        /// Clear the soft-delete marker. Compile-time error if soft-delete not configured.
        pub fn restore(self: Self, pk_value: anytype) Error!void {
            const f = comptime soft_field orelse @compileError(@typeName(T) ++ ": restore requires .soft_delete config");
            const sql_str = "UPDATE " ++ table ++ " SET " ++ f ++ " = NULL WHERE " ++ pk_where ++ ";";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
            var l = try self.lease(sql_text);
            defer l.deinit();
            const stmt = l.ptr();
            _ = try bindPk(stmt, 1, pk_value);
            try stmt.execDone(self.diag);
        }

        /// Insert OR update on PK conflict. Returns row with PK set.
        /// `values` must include PK columns when not autoincrement.
        pub fn upsert(self: Self, values: anytype) Error!T {
            const V = @TypeOf(values);
            const v_fields = @typeInfo(V).@"struct".fields;
            if (v_fields.len == 0) @compileError("upsert: empty values");

            comptime var cols: []const u8 = "";
            comptime var qs: []const u8 = "";
            comptime var set_clause: []const u8 = "";
            comptime {
                for (v_fields, 0..) |f, i| {
                    if (i > 0) {
                        cols = cols ++ ", ";
                        qs = qs ++ ", ";
                    }
                    cols = cols ++ f.name;
                    qs = qs ++ "?";
                    // Skip PK columns in DO UPDATE SET.
                    var is_pk = false;
                    for (pk_cols) |pc| {
                        if (std.mem.eql(u8, pc, f.name)) {
                            is_pk = true;
                            break;
                        }
                    }
                    if (!is_pk) {
                        if (set_clause.len > 0) set_clause = set_clause ++ ", ";
                        set_clause = set_clause ++ f.name ++ " = excluded." ++ f.name;
                    }
                }
                if (ts_updated) |u| {
                    if (set_clause.len > 0) set_clause = set_clause ++ ", ";
                    set_clause = set_clause ++ u ++ " = ?";
                }
            }
            const conflict_target = comptime blk: {
                var s: []const u8 = "";
                for (pk_cols, 0..) |pc, i| {
                    if (i > 0) s = s ++ ", ";
                    s = s ++ pc;
                }
                break :blk s;
            };
            const sql_str = if (comptime set_clause.len == 0)
                "INSERT INTO " ++ table ++ "(" ++ cols ++ ") VALUES(" ++ qs ++ ") ON CONFLICT(" ++ conflict_target ++ ") DO NOTHING;"
            else
                "INSERT INTO " ++ table ++ "(" ++ cols ++ ") VALUES(" ++ qs ++ ") ON CONFLICT(" ++ conflict_target ++ ") DO UPDATE SET " ++ set_clause ++ ";";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];

            var l = try self.lease(sql_text);
            defer l.deinit();
            const stmt = l.ptr();
            var idx: c_int = 1;
            inline for (v_fields) |f| {
                try stmt.bindAny(idx, @field(values, f.name), self.diag);
                idx += 1;
            }
            if (ts_updated != null and comptime set_clause.len > 0) {
                try stmt.bindAny(idx, @as(i64, std.time.timestamp()), self.diag);
                idx += 1;
            }
            try stmt.execDone(self.diag);

            const rowid = self.conn.lastInsertRowid();
            return (try self.findRowid(rowid)) orelse error.SqliteError;
        }

        /// Load children where `<fk_field> = parent_pk_value`.
        ///
        /// ```zig
        /// const posts = try userRepo.hasMany(Post, "user_id", alice.id.?);
        /// ```
        pub fn hasMany(self: Self, comptime ChildT: type, comptime fk_field: []const u8, parent_pk_value: anytype) Error![]ChildT {
            const child_table = comptime entityTable(ChildT);
            const child_cols = comptime columnList(ChildT);
            const cond = comptime aliveFilter(ChildT);
            const sql_str = comptime "SELECT " ++ child_cols ++ " FROM " ++ child_table ++ " WHERE " ++ fk_field ++ " = ? AND " ++ cond ++ ";";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];
            return try collectAll(ChildT, self.conn, sql_text, .{parent_pk_value}, self.alloc, self.diag);
        }

        /// Look up the parent referenced by `fk_value` (typically `child.fk_field`).
        /// Equivalent to `Repo(ParentT).init(...).find(fk_value)` with the same alloc.
        pub fn belongsTo(self: Self, comptime ParentT: type, fk_value: anytype) Error!?ParentT {
            const r = Repo(ParentT).init(self.conn, self.alloc);
            return try r.find(fk_value);
        }

        /// Bulk insert N rows of a homogeneous value struct in a single
        /// transaction with one prepared statement. ~10-100x faster than
        /// looping `insert`. Does not return inserted rows (use individual
        /// `insert` if you need PK populated per row).
        pub fn insertMany(self: Self, comptime V: type, values: []const V) Error!void {
            if (values.len == 0) return;
            const v_fields = @typeInfo(V).@"struct".fields;

            comptime var cols: []const u8 = "";
            comptime var qs: []const u8 = "";
            comptime {
                var first = true;
                for (v_fields) |f| {
                    if (!first) {
                        cols = cols ++ ", ";
                        qs = qs ++ ", ";
                    }
                    first = false;
                    cols = cols ++ f.name;
                    qs = qs ++ "?";
                }
                if (ts_created) |ts_c| {
                    if (!first) {
                        cols = cols ++ ", ";
                        qs = qs ++ ", ";
                    }
                    first = false;
                    cols = cols ++ ts_c;
                    qs = qs ++ "?";
                }
                if (ts_updated) |ts_u| {
                    if (!first) {
                        cols = cols ++ ", ";
                        qs = qs ++ ", ";
                    }
                    cols = cols ++ ts_u;
                    qs = qs ++ "?";
                }
            }
            const sql_str = "INSERT INTO " ++ table ++ "(" ++ cols ++ ") VALUES(" ++ qs ++ ");";
            const sql_text = comptime (sql_str ++ "\x00")[0..sql_str.len :0];

            var tx = try self.conn.begin();
            errdefer tx.rollback();
            var l = try self.lease(sql_text);
            defer l.deinit();
            const stmt = l.ptr();

            const now: i64 = std.time.timestamp();
            for (values) |val| {
                try stmt.reset();
                stmt.clearBindings();
                var idx: c_int = 1;
                inline for (v_fields) |f| {
                    try stmt.bindAny(idx, @field(val, f.name), self.diag);
                    idx += 1;
                }
                if (ts_created != null) {
                    try stmt.bindAny(idx, now, self.diag);
                    idx += 1;
                }
                if (ts_updated != null) {
                    try stmt.bindAny(idx, now, self.diag);
                    idx += 1;
                }
                try stmt.execDone(self.diag);
            }
            try tx.commit();
        }

        /// Return existing row matching `field == lookup_value`, else insert
        /// `defaults` (which must include lookup_value).
        pub fn findOrCreate(
            self: Self,
            comptime field: std.meta.FieldEnum(T),
            lookup_value: anytype,
            defaults: anytype,
        ) Error!T {
            if (try self.findBy(field, lookup_value)) |existing| return existing;
            return try self.insert(defaults);
        }


        /// Batched eager-load: returns map keyed by parent PK → owned slice of children.
        /// Issues one `WHERE fk IN (...)` query, groups in-memory.
        /// Caller frees each value slice with the corresponding child repo's `freeAll`
        /// and the map with `map.deinit()`.
        pub fn loadChildrenBatched(
            self: Self,
            comptime ChildT: type,
            comptime fk_field: []const u8,
            parents: []const T,
        ) Error!std.AutoHashMap(i64, []ChildT) {
            // Build "?, ?, ?" placeholder list at runtime (length depends on parents.len).
            var sql_buf: std.ArrayList(u8) = .empty;
            defer sql_buf.deinit(self.alloc);
            const child_table = comptime entityTable(ChildT);
            const child_cols = comptime columnList(ChildT);
            const cond = comptime aliveFilter(ChildT);
            sql_buf.appendSlice(self.alloc, "SELECT " ++ child_cols ++ " FROM " ++ child_table ++ " WHERE " ++ fk_field ++ " IN (") catch return error.OutOfMemory;
            if (parents.len == 0) {
                sql_buf.appendSlice(self.alloc, "NULL)") catch return error.OutOfMemory;
            } else {
                for (parents, 0..) |_, i| {
                    if (i > 0) sql_buf.appendSlice(self.alloc, ", ") catch return error.OutOfMemory;
                    sql_buf.append(self.alloc, '?') catch return error.OutOfMemory;
                }
                sql_buf.append(self.alloc, ')') catch return error.OutOfMemory;
            }
            sql_buf.appendSlice(self.alloc, " AND ") catch return error.OutOfMemory;
            sql_buf.appendSlice(self.alloc, cond) catch return error.OutOfMemory;
            sql_buf.append(self.alloc, ';') catch return error.OutOfMemory;
            sql_buf.append(self.alloc, 0) catch return error.OutOfMemory;
            const sql_text = sql_buf.items[0 .. sql_buf.items.len - 1 :0];

            // Runtime-length SQL cannot benefit from cache; prepare directly.
            var stmt_storage = try self.conn.prepare(sql_text, self.diag);
            defer stmt_storage.deinit();
            const stmt = &stmt_storage;
            var idx: c_int = 1;
            for (parents) |p| {
                const pkv = @field(p, pk_cols[0]); // single-PK only
                try stmt.bindAny(idx, pkv, self.diag);
                idx += 1;
            }

            // Locate fk column index in child row.
            const fk_col_idx: usize = comptime blk: {
                for (@typeInfo(ChildT).@"struct".fields, 0..) |f, i| {
                    if (std.mem.eql(u8, f.name, fk_field)) break :blk i;
                }
                @compileError(@typeName(ChildT) ++ " missing field " ++ fk_field);
            };

            var map = std.AutoHashMap(i64, std.ArrayList(ChildT)).init(self.alloc);
            errdefer {
                var it = map.valueIterator();
                while (it.next()) |v| {
                    for (v.items) |row| freeRow(ChildT, self.alloc, row);
                    v.deinit(self.alloc);
                }
                map.deinit();
            }
            while (true) {
                const rc = c.sqlite3_step(stmt.stmt);
                switch (rc) {
                    c.SQLITE_ROW => {
                        const row = try decodeRow(ChildT, stmt, self.alloc);
                        const key = stmt.columnI64(fk_col_idx);
                        const gop = map.getOrPut(key) catch return error.OutOfMemory;
                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                        gop.value_ptr.append(self.alloc, row) catch return error.OutOfMemory;
                    },
                    c.SQLITE_DONE => break,
                    else => try codeToError(rc),
                }
            }
            // Convert ArrayLists to owned slices.
            var out = std.AutoHashMap(i64, []ChildT).init(self.alloc);
            errdefer {
                var it = out.valueIterator();
                while (it.next()) |slice_ptr| {
                    for (slice_ptr.*) |row| freeRow(ChildT, self.alloc, row);
                    self.alloc.free(slice_ptr.*);
                }
                out.deinit();
            }
            var iter = map.iterator();
            while (iter.next()) |entry| {
                const slice = entry.value_ptr.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
                out.put(entry.key_ptr.*, slice) catch return error.OutOfMemory;
            }
            map.deinit();
            return out;
        }

        /// Free a slice of rows returned by `all` / `query.all`.
        pub fn freeAll(self: Self, rows: []T) void {
            for (rows) |row| freeRow(T, self.alloc, row);
            self.alloc.free(rows);
        }

        pub fn query(self: Self) QueryBuilder(T) {
            return .{ .conn = self.conn, .alloc = self.alloc, .diag = self.diag };
        }

        /// Run `CREATE TABLE IF NOT EXISTS` + any `CREATE INDEX` from .indexes config.
        pub fn createTable(self: Self) Error!void {
            const ddl = comptime schema.createTable(T, table);
            try self.conn.execNoArgs(ddl, self.diag);
            const idx_stmts = comptime schema.createIndexes(T, table);
            inline for (idx_stmts) |stmt| {
                try self.conn.execNoArgs(stmt, self.diag);
            }
        }
    };
}

/// Step a prepared statement once and decode the row, or return null on DONE.
fn stepOne(comptime Row: type, stmt: *Stmt, alloc: Allocator) Error!?Row {
    const rc = c.sqlite3_step(stmt.stmt);
    switch (rc) {
        c.SQLITE_ROW => return try decodeRow(Row, stmt, alloc),
        c.SQLITE_DONE => return null,
        else => {
            try codeToError(rc);
            return null;
        },
    }
}

/// Comptime query builder for `Repo(T)`. Methods take comptime spec structs;
/// SQL is generated at comptime. Bound values flow into a runtime tuple.
pub fn QueryBuilder(comptime T: type) type {
    return struct {
        conn: *Conn,
        alloc: Allocator,
        diag: ?*Diag = null,

        const Self = @This();
        const table = entityTable(T);
        const all_cols = columnList(T);

        pub fn init(conn: *Conn, alloc: Allocator) Self {
            return .{ .conn = conn, .alloc = alloc };
        }

        /// Returns a typed where-clause buffer with `.orderBy(...).limit(...).all()`.
        /// `conds` is an anon struct: field name = column, value = scalar (eq) or op marker.
        pub fn where(self: Self, conds: anytype) Where(T, @TypeOf(conds)) {
            return Where(T, @TypeOf(conds)){ .conn = self.conn, .alloc = self.alloc, .conds = conds, .diag = self.diag };
        }

        pub fn all(self: Self) Error![]T {
            const sql_text = comptime ("SELECT " ++ all_cols ++ " FROM " ++ table ++ ";\x00")[0 .. ("SELECT " ++ all_cols ++ " FROM " ++ table ++ ";").len :0];
            return try collectAll(T, self.conn, sql_text, .{}, self.alloc, self.diag);
        }
    };
}

fn collectAll(
    comptime T: type,
    conn: *Conn,
    comptime sql_text: [:0]const u8,
    args: anytype,
    alloc: Allocator,
    diag: ?*Diag,
) Error![]T {
    var it = try conn.query(T, sql_text, args, alloc, diag);
    defer it.deinit();
    var list: std.ArrayList(T) = .empty;
    errdefer {
        for (list.items) |row| freeRow(T, alloc, row);
        list.deinit(alloc);
    }
    while (try it.next(diag)) |row| {
        list.append(alloc, row) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(alloc) catch return error.OutOfMemory;
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
        diag: ?*Diag = null,
        order_clause: []const u8 = "",
        limit_n: ?i64 = null,
        offset_n: ?i64 = null,

        const Self = @This();
        const table = entityTable(T);
        const all_cols = columnList(T);

        /// Returns the comptime WHERE clause text (without leading "WHERE "),
        /// prefixed with entity's alive-filter when soft-delete is configured.
        fn whereSql() []const u8 {
            return comptime blk: {
                const fields = @typeInfo(Conds).@"struct".fields;
                var s: []const u8 = aliveFilter(T);
                for (fields) |f| {
                    s = s ++ " AND ";
                    s = s ++ opFragment(f.type, f.name);
                }
                break :blk s;
            };
        }

        fn bindConds(self: Self, stmt: *Stmt) Error!void {
            const fields = @typeInfo(Conds).@"struct".fields;
            var idx: c_int = 1;
            inline for (fields) |f| {
                const fv = @field(self.conds, f.name);
                idx = try bindOp(stmt, idx, f.type, fv);
            }
        }

        fn placeholderCount() usize {
            return comptime blk: {
                const fields = @typeInfo(Conds).@"struct".fields;
                var n: usize = 0;
                for (fields) |f| n += opPlaceholders(f.type);
                break :blk n;
            };
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

        /// 1-indexed pagination. `page = 1` is first page.
        pub fn paginate(self: Self, page: i64, per_page: i64) Self {
            const off: i64 = if (page > 1) (page - 1) * per_page else 0;
            return self.limit(per_page).offset(off);
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
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.alloc);
            buf.appendSlice(self.alloc, base) catch return error.OutOfMemory;
            buf.appendSlice(self.alloc, ord) catch return error.OutOfMemory;
            if (has_lim) buf.appendSlice(self.alloc, " LIMIT ?") catch return error.OutOfMemory;
            if (has_off) buf.appendSlice(self.alloc, " OFFSET ?") catch return error.OutOfMemory;
            buf.append(self.alloc, ';') catch return error.OutOfMemory;
            buf.append(self.alloc, 0) catch return error.OutOfMemory;
            const sql_text = buf.items[0 .. buf.items.len - 1 :0];

            var stmt = try self.conn.prepare(sql_text, self.diag);
            defer stmt.deinit();
            try self.bindConds(&stmt);
            var next_idx: c_int = @intCast(placeholderCount() + 1);
            if (self.limit_n) |n| {
                try stmt.bindAny(next_idx, n, self.diag);
                next_idx += 1;
            }
            if (self.offset_n) |n| {
                try stmt.bindAny(next_idx, n, self.diag);
            }

            var list: std.ArrayList(T) = .empty;
            errdefer {
                for (list.items) |row| freeRow(T, self.alloc, row);
                list.deinit(self.alloc);
            }
            while (true) {
                const rc = c.sqlite3_step(stmt.stmt);
                switch (rc) {
                    c.SQLITE_ROW => {
                        const row = try decodeRow(T, &stmt, self.alloc);
                        list.append(self.alloc, row) catch return error.OutOfMemory;
                    },
                    c.SQLITE_DONE => break,
                    else => try codeToError(rc),
                }
            }
            return list.toOwnedSlice(self.alloc) catch return error.OutOfMemory;
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
            var stmt = try self.conn.prepare(sql_text, self.diag);
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
            var stmt = try self.conn.prepare(sql_text, self.diag);
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

test "ops: in + between" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();

    const repo = Repo(Person).init(&db, alloc);
    try repo.createTable();
    inline for (.{ "a", "b", "c", "d", "e" }, .{ 5, 10, 15, 20, 25 }) |n, a| {
        const r = try repo.insert(.{ .name = @as([]const u8, n), .age = @as(?u32, a) });
        freeRow(Person, alloc, r);
    }

    const in_rows = try repo.query()
        .where(.{ .age = op.in(.{ @as(u32, 10), @as(u32, 25) }) })
        .orderBy(.age, .asc)
        .all();
    defer repo.freeAll(in_rows);
    try testing.expectEqual(@as(usize, 2), in_rows.len);
    try testing.expectEqualStrings("b", in_rows[0].name);
    try testing.expectEqualStrings("e", in_rows[1].name);

    const between_rows = try repo.query()
        .where(.{ .age = op.between(@as(u32, 10), @as(u32, 20)) })
        .orderBy(.age, .asc)
        .all();
    defer repo.freeAll(between_rows);
    try testing.expectEqual(@as(usize, 3), between_rows.len);
}

const TestCfg = struct { theme: []const u8, count: u32 };
const TestJsonDoc = struct {
    id: ?i64,
    config: Json(TestCfg),
    pub const sqlite = .{
        .table = "doc",
        .primary_key = .id,
        .autoincrement = true,
    };
};

test "Json marker: encode, store, retrieve, parse" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();

    const repo = Repo(TestJsonDoc).init(&db, alloc);
    try repo.createTable();

    const j = try Json(TestCfg).encode(alloc, .{ .theme = "dark", .count = 7 });
    defer j.free(alloc);

    const inserted = try repo.insert(.{ .config = j });
    defer freeRow(TestJsonDoc, alloc, inserted);

    const got = (try repo.find(inserted.id.?)).?;
    defer freeRow(TestJsonDoc, alloc, got);
    const parsed = try got.config.parse(alloc);
    defer parsed.deinit();
    try testing.expectEqualStrings("dark", parsed.value.theme);
    try testing.expectEqual(@as(u32, 7), parsed.value.count);
}

test "timestamps: created_at + updated_at" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const Item = struct {
        id: ?i64,
        name: []const u8,
        created_at: ?i64,
        updated_at: ?i64,
        pub const sqlite = .{
            .table = "item",
            .primary_key = .id,
            .autoincrement = true,
            .timestamps = .{ .created_at = .created_at, .updated_at = .updated_at },
        };
    };

    const repo = Repo(Item).init(&db, alloc);
    try repo.createTable();
    const r1 = try repo.insert(.{ .name = @as([]const u8, "foo") });
    defer freeRow(Item, alloc, r1);
    try testing.expect(r1.created_at != null);
    try testing.expect(r1.updated_at != null);

    std.Thread.sleep(std.time.ns_per_ms * 1100); // ensure timestamp advances
    try repo.update(r1.id.?, .{ .name = @as([]const u8, "bar") });
    const r2 = (try repo.find(r1.id.?)).?;
    defer freeRow(Item, alloc, r2);
    try testing.expect(r2.updated_at.? >= r1.updated_at.?);
}

test "soft delete: delete sets marker; queries hide" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const Entry = struct {
        id: ?i64,
        name: []const u8,
        deleted_at: ?i64,
        pub const sqlite = .{
            .table = "entry",
            .primary_key = .id,
            .autoincrement = true,
            .soft_delete = .deleted_at,
        };
    };

    const repo = Repo(Entry).init(&db, alloc);
    try repo.createTable();
    const r = try repo.insert(.{ .name = @as([]const u8, "x") });
    defer freeRow(Entry, alloc, r);

    try repo.delete(r.id.?);
    try testing.expect((try repo.find(r.id.?)) == null);
    try testing.expectEqual(@as(i64, 0), try repo.count());

    const including = (try repo.findIncludingDeleted(r.id.?)).?;
    defer freeRow(Entry, alloc, including);
    try testing.expect(including.deleted_at != null);

    try repo.restore(r.id.?);
    const restored = (try repo.find(r.id.?)).?;
    defer freeRow(Entry, alloc, restored);
    try testing.expect(restored.deleted_at == null);
}

test "hasMany relation helper" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();

    const Author = struct {
        id: ?i64,
        name: []const u8,
        pub const sqlite = .{ .table = "author", .primary_key = .id, .autoincrement = true };
    };
    const Book = struct {
        id: ?i64,
        author_id: i64,
        title: []const u8,
        pub const sqlite = .{ .table = "book", .primary_key = .id, .autoincrement = true };
    };

    const ar = Repo(Author).init(&db, alloc);
    const br = Repo(Book).init(&db, alloc);
    try ar.createTable();
    try br.createTable();

    const a = try ar.insert(.{ .name = @as([]const u8, "Tolkien") });
    defer freeRow(Author, alloc, a);
    inline for (.{ "Hobbit", "Fellowship", "Two Towers" }) |t| {
        const b = try br.insert(.{ .author_id = a.id.?, .title = @as([]const u8, t) });
        freeRow(Book, alloc, b);
    }

    const books = try ar.hasMany(Book, "author_id", a.id.?);
    defer br.freeAll(books);
    try testing.expectEqual(@as(usize, 3), books.len);
}

test "upsert: insert then update on conflict" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const Kv = struct {
        key: []const u8,
        val: i64,
        pub const sqlite = .{ .table = "kv", .primary_key = .key };
    };
    const repo = Repo(Kv).init(&db, alloc);
    try repo.createTable();
    const r1 = try repo.upsert(.{ .key = @as([]const u8, "x"), .val = @as(i64, 1) });
    defer freeRow(Kv, alloc, r1);
    const r2 = try repo.upsert(.{ .key = @as([]const u8, "x"), .val = @as(i64, 42) });
    defer freeRow(Kv, alloc, r2);
    try testing.expectEqual(@as(i64, 1), try repo.count());
    const got = (try repo.find(@as([]const u8, "x"))).?;
    defer freeRow(Kv, alloc, got);
    try testing.expectEqual(@as(i64, 42), got.val);
}

test "composite PK: find + update + delete" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const Edge = struct {
        from_id: i64,
        to_id: i64,
        weight: f64,
        pub const sqlite = .{
            .table = "edge",
            .primary_key = .{ .from_id, .to_id },
        };
    };
    const repo = Repo(Edge).init(&db, alloc);
    try repo.createTable();
    _ = try repo.insert(.{ .from_id = @as(i64, 1), .to_id = @as(i64, 2), .weight = @as(f64, 0.5) });
    _ = try repo.insert(.{ .from_id = @as(i64, 1), .to_id = @as(i64, 3), .weight = @as(f64, 0.7) });
    const e = (try repo.find(.{ @as(i64, 1), @as(i64, 2) })).?;
    try testing.expectEqual(@as(f64, 0.5), e.weight);

    try repo.update(.{ @as(i64, 1), @as(i64, 2) }, .{ .weight = @as(f64, 0.9) });
    const after = (try repo.find(.{ @as(i64, 1), @as(i64, 2) })).?;
    try testing.expectEqual(@as(f64, 0.9), after.weight);

    try repo.delete(.{ @as(i64, 1), @as(i64, 3) });
    try testing.expectEqual(@as(i64, 1), try repo.count());
}

test "indexes: createTable applies CREATE INDEX" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const Note = struct {
        id: ?i64,
        author: []const u8,
        title: []const u8,
        pub const sqlite = .{
            .table = "note",
            .primary_key = .id,
            .autoincrement = true,
            .indexes = &.{
                .{ .cols = &.{.author}, .unique = false },
                .{ .cols = &.{.title}, .unique = true },
            },
        };
    };
    const repo = Repo(Note).init(&db, alloc);
    try repo.createTable();

    const CountRow = struct { c: i64 };
    const r = try db.queryOne(
        CountRow,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name LIKE 'idx_note_%';",
        .{},
        alloc,
        null,
    );
    try testing.expectEqual(@as(i64, 2), r.?.c);

    const first = try repo.insert(.{ .author = @as([]const u8, "a"), .title = @as([]const u8, "T1") });
    defer freeRow(Note, alloc, first);
    // UNIQUE index on title should reject duplicate.
    const dup = repo.insert(.{ .author = @as([]const u8, "b"), .title = @as([]const u8, "T1") });
    try testing.expectError(error.SqliteConstraint, dup);
}

test "belongsTo lookup" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const Author = struct {
        id: ?i64,
        name: []const u8,
        pub const sqlite = .{ .table = "author", .primary_key = .id, .autoincrement = true };
    };
    const Book = struct {
        id: ?i64,
        author_id: i64,
        title: []const u8,
        pub const sqlite = .{ .table = "book", .primary_key = .id, .autoincrement = true };
    };
    const ar = Repo(Author).init(&db, alloc);
    const br = Repo(Book).init(&db, alloc);
    try ar.createTable();
    try br.createTable();
    const a = try ar.insert(.{ .name = @as([]const u8, "Tolkien") });
    defer freeRow(Author, alloc, a);
    const b = try br.insert(.{ .author_id = a.id.?, .title = @as([]const u8, "Hobbit") });
    defer freeRow(Book, alloc, b);

    const parent = (try br.belongsTo(Author, b.author_id)).?;
    defer freeRow(Author, alloc, parent);
    try testing.expectEqualStrings("Tolkien", parent.name);
}

test "loadChildrenBatched: one query for N parents" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const Author = struct {
        id: ?i64,
        name: []const u8,
        pub const sqlite = .{ .table = "author", .primary_key = .id, .autoincrement = true };
    };
    const Book = struct {
        id: ?i64,
        author_id: i64,
        title: []const u8,
        pub const sqlite = .{ .table = "book", .primary_key = .id, .autoincrement = true };
    };
    const ar = Repo(Author).init(&db, alloc);
    const br = Repo(Book).init(&db, alloc);
    try ar.createTable();
    try br.createTable();
    const a1 = try ar.insert(.{ .name = @as([]const u8, "A") });
    defer freeRow(Author, alloc, a1);
    const a2 = try ar.insert(.{ .name = @as([]const u8, "B") });
    defer freeRow(Author, alloc, a2);
    inline for (.{ "x", "y", "z" }) |t| {
        const b = try br.insert(.{ .author_id = a1.id.?, .title = @as([]const u8, t) });
        freeRow(Book, alloc, b);
    }
    const b_only = try br.insert(.{ .author_id = a2.id.?, .title = @as([]const u8, "lone") });
    freeRow(Book, alloc, b_only);

    const parents = [_]Author{ a1, a2 };
    var map = try ar.loadChildrenBatched(Book, "author_id", &parents);
    defer {
        var it = map.valueIterator();
        while (it.next()) |slice_ptr| {
            for (slice_ptr.*) |row| freeRow(Book, alloc, row);
            alloc.free(slice_ptr.*);
        }
        map.deinit();
    }
    try testing.expectEqual(@as(usize, 3), map.get(a1.id.?).?.len);
    try testing.expectEqual(@as(usize, 1), map.get(a2.id.?).?.len);
}

test "insertMany: bulk insert" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const repo = Repo(Person).init(&db, alloc);
    try repo.createTable();
    const Values = struct { name: []const u8, age: ?u32 };
    const rows = [_]Values{
        .{ .name = "a", .age = 1 },
        .{ .name = "b", .age = 2 },
        .{ .name = "c", .age = 3 },
    };
    try repo.insertMany(Values, &rows);
    try testing.expectEqual(@as(i64, 3), try repo.count());
}

test "findOrCreate" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const repo = Repo(Person).init(&db, alloc);
    try repo.createTable();
    const a = try repo.findOrCreate(.name, "alice", .{ .name = @as([]const u8, "alice"), .age = @as(?u32, 30) });
    defer freeRow(Person, alloc, a);
    const a2 = try repo.findOrCreate(.name, "alice", .{ .name = @as([]const u8, "alice"), .age = @as(?u32, 99) });
    defer freeRow(Person, alloc, a2);
    try testing.expectEqual(a.id, a2.id);
    try testing.expectEqual(@as(i64, 1), try repo.count());
}

test "paginate" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const repo = Repo(Person).init(&db, alloc);
    try repo.createTable();
    const Values = struct { name: []const u8, age: ?u32 };
    var rows: [10]Values = undefined;
    var name_buf: [10][1]u8 = undefined;
    for (&rows, 0..) |*r, i| {
        name_buf[i] = .{@as(u8, @intCast('a' + i))};
        r.* = .{ .name = &name_buf[i], .age = @as(u32, @intCast(i)) };
    }
    try repo.insertMany(Values, &rows);

    const page1 = try repo.query().where(.{}).orderBy(.age, .asc).paginate(1, 3).all();
    defer repo.freeAll(page1);
    try testing.expectEqual(@as(usize, 3), page1.len);
    try testing.expectEqual(@as(?u32, 0), page1[0].age);

    const page2 = try repo.query().where(.{}).orderBy(.age, .asc).paginate(2, 3).all();
    defer repo.freeAll(page2);
    try testing.expectEqual(@as(?u32, 3), page2[0].age);
}

test "ops: notIn + notBetween + glob" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const repo = Repo(Person).init(&db, alloc);
    try repo.createTable();
    const Values = struct { name: []const u8, age: ?u32 };
    const rows = [_]Values{
        .{ .name = "alpha", .age = 5 },
        .{ .name = "beta", .age = 15 },
        .{ .name = "gamma", .age = 25 },
        .{ .name = "delta", .age = 35 },
    };
    try repo.insertMany(Values, &rows);

    const not_in = try repo.query()
        .where(.{ .age = op.notIn(.{ @as(u32, 5), @as(u32, 35) }) })
        .all();
    defer repo.freeAll(not_in);
    try testing.expectEqual(@as(usize, 2), not_in.len);

    const not_between = try repo.query()
        .where(.{ .age = op.notBetween(@as(u32, 10), @as(u32, 30)) })
        .all();
    defer repo.freeAll(not_between);
    try testing.expectEqual(@as(usize, 2), not_between.len);

    const glob_match = try repo.query()
        .where(.{ .name = op.glob("a*") })
        .all();
    defer repo.freeAll(glob_match);
    try testing.expectEqual(@as(usize, 1), glob_match.len);
    try testing.expectEqualStrings("alpha", glob_match[0].name);
}

test "nested savepoints" {
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    try db.execNoArgs("CREATE TABLE t(x INTEGER);", null);

    var outer = try db.begin();
    errdefer outer.rollback();
    try db.exec("INSERT INTO t VALUES(?);", .{@as(i64, 1)}, null);

    {
        var inner = try db.begin(); // SAVEPOINT
        try db.exec("INSERT INTO t VALUES(?);", .{@as(i64, 99)}, null);
        inner.rollback(); // discard 99
    }

    try db.exec("INSERT INTO t VALUES(?);", .{@as(i64, 2)}, null);
    try outer.commit();

    const Row = struct { x: i64 };
    const r = try db.queryOne(Row, "SELECT COUNT(*) FROM t;", .{}, testing.allocator, null);
    try testing.expectEqual(@as(i64, 2), r.?.x);
    try testing.expectEqual(@as(u32, 0), db.tx_depth);
}

test "Repo diag captures sqlite errmsg" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    const Uniq = struct {
        id: ?i64,
        name: []const u8,
        pub const sqlite = .{ .table = "uniq", .primary_key = .id, .autoincrement = true, .unique = &.{.name} };
    };
    const repo = Repo(Uniq).init(&db, alloc);
    try repo.createTable();
    const r = try repo.insert(.{ .name = @as([]const u8, "x") });
    defer freeRow(Uniq, alloc, r);

    var diag: Diag = .{};
    const dup_repo = repo.withDiag(&diag);
    const dup = dup_repo.insert(.{ .name = @as([]const u8, "x") });
    try testing.expectError(error.SqliteConstraint, dup);
    try testing.expect(diag.msg.len > 0);
}

test "Repo with cache: integration works" {
    const alloc = testing.allocator;
    var db = try Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();
    try db.enableCache(alloc);
    const repo = Repo(Person).init(&db, alloc);
    try repo.createTable();
    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        var name_buf: [4]u8 = undefined;
        const n = std.fmt.bufPrint(&name_buf, "n{d}", .{i}) catch unreachable;
        const row = try repo.insert(.{ .name = n, .age = @as(?u32, @intCast(i)) });
        freeRow(Person, alloc, row);
    }
    // Repeated finds reuse cached stmt.
    var j: i64 = 1;
    while (j <= 5) : (j += 1) {
        const r = (try repo.find(j)).?;
        defer freeRow(Person, alloc, r);
    }
    try testing.expectEqual(@as(i64, 5), try repo.count());
}

test "Pool: acquire + release" {
    const alloc = testing.allocator;
    var pool = try Pool.init(alloc, .{ .path = null, .app_defaults = false }, 2);
    defer pool.deinit();
    const c1 = pool.acquire();
    const c2 = pool.acquire();
    try testing.expect(c1 != c2);
    try c1.execNoArgs("CREATE TABLE t(x INTEGER);", null);
    pool.release(c2);
    pool.release(c1);
    const c3 = pool.acquire();
    defer pool.release(c3);
    try c3.execNoArgs("INSERT INTO t VALUES(1);", null);
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
