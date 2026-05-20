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

    var db = try sql.Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();

    const migrations = [_][]const u8{
        comptime sql.schema.createTable(User, "user"),
    };
    try db.migrate(&migrations);

    const ins = comptime sql.schema.insert(User, "user", &.{"id"});
    try db.exec(ins, .{ "alice", @as(?u32, 30) }, null);
    try db.exec(ins, .{ "bob", @as(?u32, null) }, null);

    var it = try db.query(User, "SELECT id, name, age FROM user ORDER BY id;", .{}, alloc, null);
    defer it.deinit();
    while (try it.next(null)) |row| {
        defer sql.freeRow(User, alloc, row);
        std.debug.print("id={?} name={s} age={?}\n", .{ row.id, row.name, row.age });
    }
}
