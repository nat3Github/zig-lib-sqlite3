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

### Low-level (raw SQL)

- `Conn.open(opts)` — opens db. `app_defaults: true` enables WAL, NORMAL sync,
  64MB cache, mmap, foreign keys, 5s busy timeout.
- `Conn.exec(sql, args, diag)` — prepare/bind/step-to-done. `args` is a tuple.
- `Conn.query(Row, sql, args, alloc, diag)` — returns `Iterator(Row)`.
- `Conn.queryOne(Row, sql, args, alloc, diag)` — single row convenience.
- `Conn.begin() / beginImmediate()` — returns `Tx` with `commit` / `rollback`.
- `Conn.migrate(&migrations)` — append-only migrations, content-hash protected,
  tracked in `_sqlite_zig_migrations`.
- `Conn.enableCache(alloc)` + `Conn.execCached` / `queryCached` — statement
  cache keyed by SQL string. Auto-reset+rebind on reuse.
- `schema.createTable(T, name)` — CREATE TABLE from struct + optional
  `pub const sqlite = .{ .primary_key, .autoincrement, .unique, .not_null }` decl.
- `schema.insert(T, name, skip)` — INSERT statement skipping listed fields.
- `Iterator(T).next(diag)` — `?T`. Slice fields owned by caller's allocator.
- `freeRow(T, alloc, row)` — releases allocated slice/Blob fields.
- `Blob` — wrapper to bind/decode `[]const u8` as BLOB instead of TEXT.
- `Diag` — capture sqlite errcode/extended/errmsg on error.

### ORM (`Repo` / `Query`)

```zig
const User = struct {
    id: ?i64,
    name: []const u8,
    age: ?u32,
    pub const sqlite = .{
        .table = "user",
        .primary_key = .id,
        .autoincrement = true,
        .unique = &.{.name},
    };
};

const repo = sql.Repo(User).init(&db, alloc);
try repo.createTable();

const u = try repo.insert(.{ .name = "alice", .age = @as(?u32, 30) });
const found = try repo.find(u.id.?);                 // ?User by PK
const by_name = try repo.findBy(.name, "alice");     // ?User by any field
const n = try repo.count();
try repo.update(u.id.?, .{ .name = "alicia" });      // partial update
try repo.delete(u.id.?);

const adults = try repo.query()
    .where(.{ .age = sql.op.gte(@as(u32, 18)) })
    .orderBy(.age, .desc)
    .limit(10)
    .all();
defer repo.freeAll(adults);
```

**Operators** (`sql.op`): `eq`, `neq`, `lt`, `lte`, `gt`, `gte`, `like`,
`isNull`, `notNull`, `in(.{...})`, `between(lo, hi)`. Bare values in
`.where(.{...})` mean equality.

**Query builder methods**: `.where(...)`, `.orderBy(.field, .asc/.desc)`,
`.limit(n)`, `.offset(n)`, `.all()`, `.first()`, `.count()`, `.delete()`.

### Timestamps + soft delete

```zig
const Item = struct {
    id: ?i64,
    name: []const u8,
    created_at: ?i64,
    updated_at: ?i64,
    deleted_at: ?i64,
    pub const sqlite = .{
        .table = "item",
        .primary_key = .id,
        .autoincrement = true,
        .timestamps = .{ .created_at = .created_at, .updated_at = .updated_at },
        .soft_delete = .deleted_at,
    };
};
```

- `insert` auto-populates `created_at` + `updated_at` (unix epoch seconds).
- `update` auto-bumps `updated_at`.
- `delete` sets `deleted_at = now()`; rows hidden from `find`, `all`, `query`.
- `deleteHard` for true DELETE.
- `restore` clears `deleted_at`.
- `findIncludingDeleted` reads soft-deleted rows.

### Relations

```zig
const posts = try userRepo.hasMany(Post, "user_id", alice.id.?);
defer postRepo.freeAll(posts);
```

### JSON columns

```zig
const Cfg = struct { theme: []const u8, count: u32 };
const Doc = struct {
    id: ?i64,
    config: sql.Json(Cfg),
    pub const sqlite = .{ .table = "doc", .primary_key = .id, .autoincrement = true };
};

const j = try sql.Json(Cfg).encode(alloc, .{ .theme = "dark", .count = 3 });
defer j.free(alloc);
const doc = try repo.insert(.{ .config = j });
// ...
const parsed = try got.config.parse(alloc);
defer parsed.deinit();
parsed.value.theme; // "dark"
```

### Connection pool

```zig
var pool = try sql.Pool.init(alloc, .{ .path = "./app.db" }, 4);
defer pool.deinit();

const conn = pool.acquire();
defer pool.release(conn);
try conn.exec("INSERT INTO t VALUES(?);", .{42}, null);
```

`acquire` blocks until a connection is free. WAL mode lets multiple readers
run concurrently with one writer.

### Arena allocation

`query` / `Repo` accept any `Allocator`. Pass an arena to skip per-row
`freeRow`/`freeAll` cleanup:

```zig
var arena = std.heap.ArenaAllocator.init(gpa);
defer arena.deinit();
const rows = try repo.query().where(.{...}).all();
// no freeAll needed — arena.deinit handles all row slices.
```

## Type mapping

| Zig type        | SQLite |
|-----------------|--------|
| `bool`, `int`, `enum` | INTEGER |
| `f32`, `f64`    | REAL   |
| `[]const u8`    | TEXT   |
| `Blob`          | BLOB   |
| `?T`            | nullable + same as T |
