//! Microbenchmarks for sqlite3-zig.
//!
//! Run with: `zig build bench`.
//! Reports wall-clock time + ops/sec per scenario.

const std = @import("std");
const sql = @import("sqlite3");

const N_INSERT: usize = 10_000;
const N_QUERY: usize = 10_000;

const Row = struct {
    id: ?i64,
    name: []const u8,
    age: u32,
    pub const sqlite = .{
        .table = "bench",
        .primary_key = .id,
        .autoincrement = true,
        .indexes = &.{
            .{ .cols = &.{.age} },
        },
    };
};

const Result = struct {
    label: []const u8,
    ops: usize,
    ns: u64,

    pub fn print(self: Result, w: *std.Io.Writer) !void {
        const s = @as(f64, @floatFromInt(self.ns)) / 1e9;
        const ops_per_sec = @as(f64, @floatFromInt(self.ops)) / s;
        try w.print("  {s:<40} {d:>10.3} ms  {d:>10.0} ops/sec\n", .{ self.label, s * 1000.0, ops_per_sec });
    }
};

fn bench(label: []const u8, ops: usize, body: anytype) !Result {
    var timer = try std.time.Timer.start();
    try body.run();
    return .{ .label = label, .ops = ops, .ns = timer.read() };
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_file.interface;
    try stdout.print("sqlite3-zig bench (N_INSERT={d} N_QUERY={d})\n\n", .{ N_INSERT, N_QUERY });

    // -------------------------------------------------------------
    // Scenario 1: naive inserts (no txn, no cache) — worst case.
    // -------------------------------------------------------------
    {
        var db = try sql.Conn.open(.{ .path = null, .app_defaults = false });
        defer db.close();
        try db.execNoArgs("CREATE TABLE bench(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, age INTEGER);", null);

        const body = struct {
            db_ref: *sql.Conn,
            pub fn run(self: @This()) !void {
                var i: usize = 0;
                while (i < N_INSERT) : (i += 1) {
                    try self.db_ref.exec("INSERT INTO bench(name, age) VALUES(?, ?);", .{ @as([]const u8, "x"), @as(u32, 30) }, null);
                }
            }
        }{ .db_ref = &db };
        const r = try bench("insert no-txn no-cache", N_INSERT, body);
        try r.print(stdout);
    }

    // -------------------------------------------------------------
    // Scenario 2: inserts in txn.
    // -------------------------------------------------------------
    {
        var db = try sql.Conn.open(.{ .path = null, .app_defaults = false });
        defer db.close();
        try db.execNoArgs("CREATE TABLE bench(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, age INTEGER);", null);

        const body = struct {
            db_ref: *sql.Conn,
            pub fn run(self: @This()) !void {
                var tx = try self.db_ref.begin();
                errdefer tx.rollback();
                var i: usize = 0;
                while (i < N_INSERT) : (i += 1) {
                    try self.db_ref.exec("INSERT INTO bench(name, age) VALUES(?, ?);", .{ @as([]const u8, "x"), @as(u32, 30) }, null);
                }
                try tx.commit();
            }
        }{ .db_ref = &db };
        const r = try bench("insert in 1 txn (no cache)", N_INSERT, body);
        try r.print(stdout);
    }

    // -------------------------------------------------------------
    // Scenario 3: txn + statement cache.
    // -------------------------------------------------------------
    {
        var db = try sql.Conn.open(.{ .path = null, .app_defaults = false });
        defer db.close();
        try db.enableCache(alloc);
        try db.execNoArgs("CREATE TABLE bench(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, age INTEGER);", null);

        const body = struct {
            db_ref: *sql.Conn,
            pub fn run(self: @This()) !void {
                var tx = try self.db_ref.begin();
                errdefer tx.rollback();
                var i: usize = 0;
                while (i < N_INSERT) : (i += 1) {
                    try self.db_ref.execCached("INSERT INTO bench(name, age) VALUES(?, ?);", .{ @as([]const u8, "x"), @as(u32, 30) }, null);
                }
                try tx.commit();
            }
        }{ .db_ref = &db };
        const r = try bench("insert in 1 txn + cached stmt", N_INSERT, body);
        try r.print(stdout);
    }

    // -------------------------------------------------------------
    // Scenario 4: insertMany bulk API.
    // -------------------------------------------------------------
    {
        var db = try sql.Conn.open(.{ .path = null, .app_defaults = false });
        defer db.close();
        const repo = sql.Repo(Row).init(&db, alloc);
        try repo.createTable();

        const Values = struct { name: []const u8, age: u32 };
        const buf = try alloc.alloc(Values, N_INSERT);
        defer alloc.free(buf);
        for (buf) |*v| v.* = .{ .name = "x", .age = 30 };

        const body = struct {
            repo_ref: sql.Repo(Row),
            values: []const Values,
            pub fn run(self: @This()) !void {
                try self.repo_ref.insertMany(Values, self.values);
            }
        }{ .repo_ref = repo, .values = buf };
        const r = try bench("repo.insertMany", N_INSERT, body);
        try r.print(stdout);
    }

    // -------------------------------------------------------------
    // Setup populated table for query benches.
    // -------------------------------------------------------------
    var dbq = try sql.Conn.open(.{ .path = null, .app_defaults = false });
    defer dbq.close();
    try dbq.enableCache(alloc);
    const repo = sql.Repo(Row).init(&dbq, alloc);
    try repo.createTable();
    {
        const Values = struct { name: []const u8, age: u32 };
        const buf = try alloc.alloc(Values, N_INSERT);
        defer alloc.free(buf);
        var prng: std.Random.DefaultPrng = .init(42);
        const rng = prng.random();
        for (buf) |*v| v.* = .{ .name = "x", .age = rng.intRangeAtMost(u32, 1, 100) };
        try repo.insertMany(Values, buf);
    }

    // -------------------------------------------------------------
    // Scenario 5: point lookup by PK, cached.
    // -------------------------------------------------------------
    {
        const body = struct {
            db_ref: *sql.Conn,
            alloc: std.mem.Allocator,
            pub fn run(self: @This()) !void {
                var i: usize = 0;
                while (i < N_QUERY) : (i += 1) {
                    const RowOnly = struct { id: i64 };
                    const r = try self.db_ref.queryCached(RowOnly, "SELECT id FROM bench WHERE id = ?;", .{@as(i64, @intCast((i % N_INSERT) + 1))}, self.alloc, null);
                    var it = r;
                    defer it.deinit();
                    _ = try it.next(null);
                }
            }
        }{ .db_ref = &dbq, .alloc = alloc };
        const r = try bench("point lookup by PK (cached)", N_QUERY, body);
        try r.print(stdout);
    }

    // -------------------------------------------------------------
    // Scenario 6: range scan via query builder.
    // -------------------------------------------------------------
    {
        const body = struct {
            repo_ref: sql.Repo(Row),
            alloc: std.mem.Allocator,
            pub fn run(self: @This()) !void {
                var i: usize = 0;
                while (i < 100) : (i += 1) {
                    const rows = try self.repo_ref.query()
                        .where(.{ .age = sql.op.between(@as(u32, 25), @as(u32, 35)) })
                        .limit(50)
                        .all();
                    self.repo_ref.freeAll(rows);
                }
            }
        }{ .repo_ref = repo, .alloc = alloc };
        const r = try bench("range scan (between, indexed, limit 50) x100", 100, body);
        try r.print(stdout);
    }

    try stdout.flush();
}
