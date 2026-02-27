sql-gen:
	zig build
	zig-out/bin/sqlz generate --src src/example/sql --dest src/example/dest
sql-vet:
	zig build
	zig-out/bin/sqlz verify --src src/example/sql --dest src/example/dest
