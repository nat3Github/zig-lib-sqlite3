# sqlite3-zig

Statically-compiled sqlite3 (3.46.0) with a typed, comptime-driven zig wrapper.

Targets **zig 0.14.0**.

## Build

```
zig build test     # run library tests
zig build run      # run example
```

## Use as dependency

`build.zig.zon`:

```zig
.dependencies = .{
    .sqlite3 = .{
        .url = "https://github.com/.../archive/<ref>.tar.gz",
        .hash = "<hash>",
    },
},
```

`build.zig`:

```zig
const sqlite3 = b.dependency("sqlite3", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("sqlite3", sqlite3.module("sqlite3"));
```

## Quickstart

```zig
const std = @import("std");
const sql = @import("sqlite3");

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

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try sql.Conn.open(.{ .path = "./app.db" });   // WAL + pragmas
    defer db.close();

    try db.migrate(&.{ comptime sql.schema.createTable(User, "user") });

    const ins = comptime sql.schema.insert(User, "user", &.{"id"});
    try db.exec(ins, .{ "alice", @as(?u32, 30) }, null);

    var it = try db.query(User, "SELECT id, name, age FROM user;", .{}, alloc, null);
    defer it.deinit();
    while (try it.next(null)) |row| {
        defer sql.freeRow(User, alloc, row);
        std.debug.print("{?} {s} {?}\n", .{ row.id, row.name, row.age });
    }
}
```

## API

- `Conn.open(opts)` — opens db. `app_defaults: true` enables WAL, NORMAL sync,
  64MB cache, mmap, foreign keys, 5s busy timeout.
- `Conn.exec(sql, args, diag)` — prepare/bind/step-to-done. `args` is a tuple.
- `Conn.query(Row, sql, args, alloc, diag)` — returns `Iterator(Row)`.
- `Conn.queryOne(Row, sql, args, alloc, diag)` — single row convenience.
- `Conn.begin() / beginImmediate()` — returns `Tx` with `commit` / `rollback`.
- `Conn.migrate(&migrations)` — append-only migrations, content-hash protected,
  tracked in `_sqlite_zig_migrations`.
- `schema.createTable(T, name)` — CREATE TABLE from struct + optional
  `pub const sqlite = .{ .primary_key, .autoincrement, .unique, .not_null }` decl.
- `schema.insert(T, name, skip)` — INSERT statement skipping listed fields.
- `Iterator(T).next(diag)` — `?T`. Slice fields owned by caller's allocator.
- `freeRow(T, alloc, row)` — releases allocated slice/Blob fields.
- `Blob` — wrapper to bind/decode `[]const u8` as BLOB instead of TEXT.
- `Diag` — capture sqlite errcode/extended/errmsg on error.

## Type mapping

| Zig type        | SQLite |
|-----------------|--------|
| `bool`, `int`, `enum` | INTEGER |
| `f32`, `f64`    | REAL   |
| `[]const u8`    | TEXT   |
| `Blob`          | BLOB   |
| `?T`            | nullable + same as T |
