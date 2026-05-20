const std = @import("std");
const sql = @import("sqlite3");

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

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try sql.Conn.open(.{ .path = null, .app_defaults = false });
    defer db.close();

    const repo = sql.Repo(User).init(&db, alloc);
    try repo.createTable();

    const alice = try repo.insert(.{ .name = @as([]const u8, "alice"), .age = @as(?u32, 30) });
    defer sql.freeRow(User, alloc, alice);
    const bob = try repo.insert(.{ .name = @as([]const u8, "bob"), .age = @as(?u32, null) });
    defer sql.freeRow(User, alloc, bob);
    const carol = try repo.insert(.{ .name = @as([]const u8, "carol"), .age = @as(?u32, 25) });
    defer sql.freeRow(User, alloc, carol);

    std.debug.print("count = {}\n", .{try repo.count()});

    const adults = try repo.query()
        .where(.{ .age = sql.op.gte(@as(u32, 18)) })
        .orderBy(.age, .desc)
        .all();
    defer repo.freeAll(adults);
    for (adults) |u| std.debug.print("adult: id={?} name={s} age={?}\n", .{ u.id, u.name, u.age });

    if (try repo.findBy(.name, "alice")) |found| {
        defer sql.freeRow(User, alloc, found);
        std.debug.print("found alice: id={?}\n", .{found.id});
    }
}
