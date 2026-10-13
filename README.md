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

- lexical VFS path-prefix scans use the `vfs` package's sorted-key range index;
- `ORDER BY path ... LIMIT` pages directly from that range;
- VFS `stem` is an indexed lookup target for JessQL equijoins;
- the stem index is revision-keyed and invalidates after VFS mutation;
- TES3 record index/type/id constraints are pushed into record traversal;
- NIF record index/type/name/decoded constraints are pushed down;
- NIF records expose a lazy ordered iterator, so indexed joins can stop after enough rows;
- NIF `type` queries use `typeOf()` without decoding records;
- names use the `nif` package's refill-in-place reader only when needed;
- `nif.scene_nodes` builds/caches the scene only when queried.

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

## 0.1.1 benchmark snapshot

Synthetic timings on the supplied Jess binary:

- 100k-entry VFS prefix/order/limit query: ~35 ms cold index build, **~0.04-0.07 ms warm**.
- 100k-record NIF type/order/limit query: **~0.02-0.04 ms**.
- 50k x 50k VFS↔NIF indexed join/order/limit: ~35 ms cold, **~0.07-0.09 ms warm**.

The cold VFS number includes construction of the sorted VFS key index and lazy stem index; both are
reused until the VFS revision changes. See `bench/` for the workloads.

## Running the benchmarks

Each script takes an optional row count. Run them from the folder the packages are checked out in.
`bench/vfs.luau` and `bench/cross-domain.luau` build a VFS to query, so they name the `vfs` package
outright; `--package-path .` finds what the packages depend on.

```sh
jess run --package dreamwind-sql --package-path . dreamwind-sql/bench/nif.luau 100000
jess run --package dreamwind-sql --package vfs --package-path . dreamwind-sql/bench/vfs.luau 50000
jess run --package dreamwind-sql --package vfs --package-path . dreamwind-sql/bench/cross-domain.luau 50000
```
