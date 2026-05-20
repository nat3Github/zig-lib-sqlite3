// Forward sqlite3 bind calls with SQLITE_TRANSIENT baked in.
// Workaround: zig 0.14 cannot construct the SQLITE_TRANSIENT sentinel pointer
// at comptime (unaligned address).
#include "sqlite3.h"

int sqlite_zig_bind_text_transient(sqlite3_stmt *s, int i, const char *p, int n) {
    return sqlite3_bind_text(s, i, p, n, SQLITE_TRANSIENT);
}

int sqlite_zig_bind_blob_transient(sqlite3_stmt *s, int i, const void *p, int n) {
    return sqlite3_bind_blob(s, i, p, n, SQLITE_TRANSIENT);
}
