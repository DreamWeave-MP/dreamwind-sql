# dreamwind-sql

Relational views over TES3 plugins, NIF models, and an OpenMW VFS for `jessql`. This package owns
no Bethesda/OpenMW semantics and no SQL engine; it is the adapter between the `tes3`, `nif`, and
`vfs` packages and JessQL.

## Package

- package: `org.dreamweave.dreamwind-sql` 0.1.1
- layer: `dream.sql`
- dependencies: `tes3` 0.1, `nif` 0.1, `jessql` 0.1.1

A VFS is handed in by the caller and used through its methods, so the package does not depend on
`vfs`: a program that queries one supplies that package itself.

## Default virtual tables

- `vfs.files`: `path`, `physical_path`, `name`, `stem`, `size`, `is_loose`, `is_archive`, `archive_path`, `archive_name`
- `tes3.records`: `index`, `type`, `id`, `flags`, `size`, `dirty`, `partial`
- `nif.records`: `index`, `type`, `name`, `decoded`
- `nif.scene_nodes`: scene hierarchy/visibility and local/world translation components

`vfs.files.name` and `stem` describe the **logical VFS key**, not the backing loose/archive path.
Physical metadata is touched only when selected.

## Pushdown and lazy execution

The adapter uses each package's own structure instead of decoding/materializing first:

- every table hands its rows to JessQL one at a time (`iterate`), in index order for a plugin's and
  a NIF's and in path order for a VFS's, so a single-table query with a `LIMIT` reads no more rows
  than it keeps, with a `WHERE` the table applies or without one;
- every table answers a bare `SELECT COUNT(*)` from its source's own count, with no row made;
- a single-table query's rows are one table filled over and over (JessQL's volatile rows), so an
  aggregate over a whole table allocates no row;
- lexical VFS path-prefix scans use the `vfs` package's sorted-key range index;
- `ORDER BY path ... LIMIT` pages directly from that range;
- VFS `stem` is an indexed lookup target for JessQL equijoins;
- the stem index is revision-keyed and invalidates after VFS mutation;
- TES3 record index/type/id constraints are pushed into record traversal: a type is compared as its
  tag's number, and an ASCII id by its bytes where they lie, with no id decoded;
- NIF record index/type/name/decoded constraints are pushed down;
- NIF `type` queries use `typeOf()` without decoding records;
- names use the `nif` package's refill-in-place reader only when needed;
- `nif.scene_nodes` builds/caches the scene only when queried.

A table says it applied a `WHERE` only when every constraint is one it applies in full: `=` on its
own columns with a value of the column's kind, one constraint to a column (and for `vfs.files`,
`=` or a prefix `LIKE` on `path`, any number of them). Anything else it leaves to JessQL, which then
filters the rows itself.

## Example

```luau
local sql = require '@dreamwind-sql'
local db = sql.new { vfs = myVfs, tes3 = plugin, nif = model }

local result = db:query([[SELECT f.path, n.index
FROM vfs.files f
JOIN nif.records n ON f.stem = n.name
WHERE f.path LIKE 'meshes/generated/%'
ORDER BY n.index DESC
LIMIT 20]])
```

Yes, this is SQL joining Morrowind's VFS against its NIF records in Luau.

## Benchmarks

`BENCHMARKS.md` has the numbers, measured on a verified release build, and what each is made of.
In short, on 50,000 files, 20,001 records, and a 4,096-record NIF: a page of twenty rows from any
one table takes 15 to 110 µs whatever the `WHERE` the table applies, a bare `COUNT(*)` under a
millisecond, a scan of a whole table 0.2 to 1.1 µs a row, and a stem lookup about 1.2 µs. The
indexed join of the example above still makes every pair before it keeps twenty (9 ms for 4,032
NIF records against 50,000 files): JessQL's indexed join stops early only for a query with no
`WHERE` and no `ORDER BY`.

The VFS's sorted key index and the stem index are built on first use and kept until the VFS
revision changes.

## Running the benchmarks

`bench/bench.luau` is the measured one: it times queries, scans, and lookups over a VFS stand-in, a
plugin, and a NIF it builds, checks every workload's rows, and prints a line for each. It needs
only what the package depends on, and takes an optional filter on the workload names. Run it from
the folder the packages are checked out in.

```sh
jess run --package dreamwind-sql --package-path . dreamwind-sql/bench/bench.luau
jess run --package dreamwind-sql --package-path . dreamwind-sql/bench/bench.luau 'vfs scan'
```

The three older scripts each run one query a few times and print what it took. Each takes an
optional row count. `bench/vfs.luau` and `bench/cross-domain.luau` build a real VFS to query, so
they name the `vfs` package outright; `--package-path .` finds what the packages depend on.

```sh
jess run --package dreamwind-sql --package-path . dreamwind-sql/bench/nif.luau 100000
jess run --package dreamwind-sql --package vfs --package-path . dreamwind-sql/bench/vfs.luau 50000
jess run --package dreamwind-sql --package vfs --package-path . dreamwind-sql/bench/cross-domain.luau 50000
```
