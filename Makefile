sql-gen:
	zig build
	zig-out/bin/sqlz generate --src src/example/sql --dest src/example/dest
