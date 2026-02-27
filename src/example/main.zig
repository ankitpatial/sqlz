const std = @import("std");
const pg = @import("pg");
const db = @import("dest/root.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    // Arena allocator for query results — frees all duped strings at once
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Try .env file first, then fall back to environment variable
    const db_url = loadDotEnvValue(allocator, ".env", "DATABASE_URL") orelse
        std.process.getEnvVarOwned(allocator, "DATABASE_URL") catch {
        std.debug.print("error: DATABASE_URL not found in .env file or environment\n", .{});
        return;
    };
    defer allocator.free(db_url);

    const uri = std.Uri.parse(db_url) catch {
        std.debug.print("error: invalid DATABASE_URL\n", .{});
        return;
    };

    var pool = pg.Pool.initUri(allocator, uri, .{ .size = 5 }) catch |err| {
        std.debug.print("error: failed to init pool: {}\n", .{err});
        return;
    };
    defer pool.deinit();

    std.debug.print("Connected to PostgreSQL\n\n", .{});

    // Clean up previous run data so the example is re-runnable
    _ = try pool.exec("DELETE FROM comments", .{});
    _ = try pool.exec("DELETE FROM post_tags", .{});
    _ = try pool.exec("DELETE FROM posts", .{});
    _ = try pool.exec("DELETE FROM tags", .{});
    _ = try pool.exec("DELETE FROM users", .{});

    // ── INSERT ──────────────────────────────────────────

    // Create a new user (returns the created row)
    const user = try db.insert.createUser(pool, allocator, "Alice", "alice@example.com", "Zig enthusiast") orelse return;
    std.debug.print("Created user: {s} (id={})\n", .{ user.name, user.id });

    // Create a post using the returned user id
    const post = try db.insert.createPost(pool, allocator, user.id, "Hello World", "My first post") orelse return;
    std.debug.print("Created post: {s} (id={})\n", .{ post.title, post.id });

    // Add a comment on the post
    const comment = try db.insert.addComment(pool, allocator, post.id, user.id, "Great post!") orelse return;
    std.debug.print("Added comment id={}\n", .{comment.id});

    // Seed a tag (no generated insert-tag query, use raw SQL)
    const tag_id: i32 = blk: {
        if (try pool.row("INSERT INTO tags (name) VALUES ($1) ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id", .{"zig"})) |r| {
            var row = r;
            defer row.deinit() catch {};
            break :blk try row.get(i32, 0);
        }
        return;
    };
    std.debug.print("Tag 'zig' id={}\n", .{tag_id});

    // Tag the post
    try db.insert.tagPost(pool, post.id, tag_id);
    std.debug.print("Tagged post\n", .{});

    // ── SELECT ──────────────────────────────────────────

    // Find a single user by ID
    if (try db.select.findUserById(pool, allocator, user.id)) |u| {
        std.debug.print("\nFound user: {s} <{s}>\n", .{ u.name, u.email });
    }

    // List all users
    std.debug.print("\nAll users:\n", .{});
    const users = try db.select.listUsers(pool, allocator);
    for (users) |u| {
        std.debug.print("  - {s} (active={})\n", .{ u.name, u.is_active });
    }

    // Get post with author name (JOIN)
    if (try db.select.getPostWithAuthor(pool, allocator, post.id)) |p| {
        std.debug.print("\nPost '{s}' by {s}\n", .{ p.title, p.author_name });
    }

    // List comments on a post
    std.debug.print("\nComments on post:\n", .{});
    const comments = try db.select.listPostComments(pool, allocator, post.id);
    for (comments) |c| {
        std.debug.print("  {s}: {s}\n", .{ c.commenter_name, c.body });
    }

    // Count posts per user (GROUP BY)
    std.debug.print("\nPost counts:\n", .{});
    const counts = try db.select.countPostsByUser(pool, allocator);
    for (counts) |row| {
        std.debug.print("  {s}: {} posts\n", .{ row.name, row.post_count orelse 0 });
    }

    // List posts by tag (many-to-many)
    std.debug.print("\nPosts tagged 'zig':\n", .{});
    const tagged = try db.select.listPostsByTag(pool, allocator, "zig");
    for (tagged) |p| {
        std.debug.print("  [{s}] {s}\n", .{ p.author_name, p.title });
    }

    // Search posts with filters (uses Params struct for >3 params)
    std.debug.print("\nSearch results:\n", .{});
    const results = try db.select.searchPosts(pool, allocator, .{
        .author_id = user.id,
        .title_keyword = "hello",
        .body_keyword = "",
        .published = false,
        .created_after = 0,
        .created_before = std.math.maxInt(i64),
        .limit = 10,
        .offset = 0,
    });
    for (results) |r| {
        std.debug.print("  [{s}] {s}\n", .{ r.author_name, r.title });
    }

    // ── UPDATE ──────────────────────────────────────────

    // Update a single field — returns the updated row
    if (try db.update.updateUserEmail(pool, allocator, user.id, "newalice@example.com")) |updated| {
        std.debug.print("\nUpdated email: {s}\n", .{updated.email});
    }

    // Update multiple fields (uses Params struct for >3 params)
    if (try db.update.updateUser(pool, allocator, .{
        .id = user.id,
        .name = "Alice Z",
        .email = "alice@zig.dev",
        .bio = "Now a Zig expert",
        .is_active = true,
    })) |updated| {
        std.debug.print("Updated user: {s}\n", .{updated.name});
    }

    // Publish a post (exec — returns void)
    try db.update.publishPost(pool, post.id);
    std.debug.print("Published post\n", .{});

    // Deactivate a user (execrows — returns affected row count)
    if (try db.update.deactivateUser(pool, user.id)) |n| {
        std.debug.print("Deactivated {} user(s)\n", .{n});
    }

    // ── DELETE ──────────────────────────────────────────

    // Remove a tag from a post
    try db.delete.removePostTag(pool, post.id, tag_id);
    std.debug.print("\nRemoved tag from post\n", .{});

    // Delete a post (cascades to comments and post_tags)
    try db.delete.deletePost(pool, post.id);
    std.debug.print("Deleted post\n", .{});

    std.debug.print("\nDone!\n", .{});
}

/// Load a single value from a .env file. Returns null if file or key not found.
fn loadDotEnvValue(allocator: std.mem.Allocator, path: []const u8, key: []const u8) ?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024) catch return null;
    defer allocator.free(content);

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            const k = std.mem.trim(u8, trimmed[0..eq], &std.ascii.whitespace);
            if (std.mem.eql(u8, k, key)) {
                const v = std.mem.trim(u8, trimmed[eq + 1 ..], &std.ascii.whitespace);
                return allocator.dupe(u8, v) catch null;
            }
        }
    }
    return null;
}
