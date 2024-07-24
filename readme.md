# -> compiles static sqlite3 database

# needs:

zig (version 0.13 was used in this code)

# build:

zig build

# -> also available as zig module:

### usually you add this package to the package manager (url = the ref of this repo that you want to use!):

.dependencies = .{
.@"sqlite3-zig" = .{
.url = "https://github.com/...tar.gz",
.hash = "1220450bb9feb21c29018e21a8af457859eb2a4607a6017748bb618907b4cf18c67b",
},
},

### then adding this to your build.zig:

const sqlite3 = b.dependency("sqlite3-zig", .{
.target = target,
.optimize = optimize,
});
const sqlite_module = sqlite3.module("sqlite3-zig");
exe.root_module.addImport("sqlite3-zig", sqlite_module);

### then in your main.zig:  
@import(sqlite3-zig);
