# dreamwind-sql benchmarks

`bench/bench.luau` times the adapter through its public API: prepared queries over a VFS of 50,000
files, a plugin of 20,001 records, and a NIF of 4,096 records and its scene, and under them the
provider scans and stem lookups with JessQL left out. A `query` row is the adapter and the engine
together; a `scan` or `lookup` row is the adapter alone. The VFS is a stand-in built in the bench,
with the vfs package's shapes (a frozen array of keys, and views whose rows are made as they are
read), so the bench needs only what the package depends on and times the adapter rather than the
VFS behind it. The plugin is built from bytes and the NIF is read back from its saved bytes, so no
record of either is decoded before the timing.

Every workload's rows are checked, before the first batch and after the last and outside the time,
by a checksum against the rows the data built must give, worked out in the bench by its own
arithmetic. A workload is warmed up, then timed as the median of seven batches of about a tenth of
a second each, with a full collection before each batch.

## Moving onto l3i 2.0: before and after

- Machine: Intel(R) Core(TM) i7-10870H CPU @ 2.20GHz, 15 GB, with other agents' test runs on it.
- Date: 2026-10-12, at the end of the run that began on 2026-10-11.
- Binary: `target/l3i2/jess`, the verified release build of Jess on l3i 2.0.2 (Luau 0.742), for
  both columns: the binary is held fixed, so what Luau 0.742 itself changed cancels out. So are
  the sibling packages, JessQL among them, as they stood at the time.
- Before: commit `ce5ad6d` (the package as it was imported, with its tests and this bench), run
  with this bench file as it now is. After: commit `f74958a`, the last that changes the payload.
- Protocol: the two trees alternately, before/after/before/after, three runs of each inside one
  lock on the machine's benchmark slot. Each cell is the median of its three runs; across the
  three, a workload's slowest run was at most 1.32 times its fastest, and for most under 1.1. A
  difference under about 5 percent is noise here and is given as "no change".

```sh
flock $HOME/.cache/agents-bench.lock systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 \
  target/l3i2/jess run --package jpk/dreamwind-sql --package-path jpk jpk/dreamwind-sql/bench/bench.luau
```

| Workload | Before | After | |
|---|---:|---:|---|
| vfs query: a page of a prefix, from the end | 22.78 ms | 20.1 µs | 1131x |
| vfs query: a page of every key, from the end | 21.6 µs | 16.5 µs | 1.31x |
| vfs query: 25000 keys under a prefix | 39.76 ms | 25.28 ms | 1.57x |
| vfs query: 50000 files counted | 24.58 ms | 695.0 µs | 35x |
| vfs query: 50000 files, those in archives counted by archive | 45.53 ms | 27.41 ms | 1.66x |
| vfs scan: 25000 keys under a prefix | 29.64 ms | 13.48 ms | 2.20x |
| vfs scan: 50000 keys and their stems | 35.55 ms | 16.30 ms | 2.18x |
| vfs scan: 50000 files, every column | 71.15 ms | 55.09 ms | 1.29x |
| vfs lookup: the stem index of 50000 keys, built | 17.99 ms | 18.65 ms | no change |
| vfs lookup: 1000 stems of two files each, the last one's rows kept | 2.28 ms | 1.22 ms | 1.87x |
| join query: a page of files joined to NIF records by stem, from the end | 15.93 ms | 9.44 ms | 1.69x |
| join query: 4032 NIF records joined to their two files each | 13.22 ms | 9.87 ms | 1.34x |
| tes3 scan: 20001 records, every column | 20.23 ms | 18.45 ms | 1.10x |
| tes3 scan: 20001 records, index and type | 7.95 ms | 4.97 ms | 1.60x |
| tes3 query: 2500 records of one type, with their ids | 4.65 ms | 3.60 ms | 1.29x |
| tes3 query: 20001 records counted | 7.89 ms | 371 ns | 21270x |
| tes3 query: 20001 records counted by type | 10.11 ms | 5.20 ms | 1.95x |
| tes3 query: one record by its type and id, near the end | 1.61 ms | 2.05 ms | 0.78x, slower |
| tes3 query: one record by its id, among 20001 | 7.87 ms | 5.33 ms | 1.48x |
| tes3 query: a page of flagged records, from the end | 3.97 ms | 45.2 µs | 88x |
| tes3 query: 20001 records, the sizes of the unflagged summed | 14.86 ms | 6.88 ms | 2.16x |
| nif query: a page of one type, from the end | 122.4 µs | 111.9 µs | 1.09x |
| nif query: 4096 records counted | 1.16 ms | 218.6 µs | 5.31x |
| nif query: 4096 records counted by type | 1.47 ms | 826.2 µs | 1.78x |
| nif scan: 4096 records, index and type | 1.18 ms | 779.3 µs | 1.51x |
| nif scan: 4096 records, every column | 2.73 ms | 2.42 ms | 1.13x |
| nif query: one record by its name, among 4096 | 1.61 ms | 1.50 ms | 1.07x |
| scene scan: 4096 nodes, every column | 2.85 ms | 1.81 ms | 1.58x |
| scene scan: 4096 nodes, their names and parents | 1.93 ms | 795.0 µs | 2.43x |
| scene query: 4096 nodes counted | 1.83 ms | 279 ns | 6574x |
| scene query: the 63 nodes under the root, among 4096 | 196.3 µs | 190.7 µs | no change |
| scene query: a page of shapes, from the end | 1.97 ms | 14.7 µs | 135x |
| scene query: 4032 visible shapes counted, the furthest found | 2.53 ms | 726.5 µs | 3.48x |

## What moved, and why

None of it is the dialect. The adapter builds maps keyed by column and walks sources that are not
dense arrays (a VFS's views, a plugin's and a NIF's records by index), so the comprehensions,
reducers, and the record pattern it now has are in three places in the payload and in the bench's
and tests' reference lists, and change no number above. What moved is how the adapter answers
JessQL's provider protocol.

The three largest rows are pages: `WHERE ... ORDER BY ... LIMIT 20`. JessQL hands a provider no
limit once a query has a WHERE, so a table that only scans made a row of every match and the
engine kept twenty. Every table now also hands its rows over one at a time (`iterate`, as
`nif.records` already did), and the engine stops asking when the page is full: 1131x for a page of
a VFS prefix, 88x for a plugin's records, 135x for a scene's nodes. The rows marked `counted` are a
bare `SELECT COUNT(*)`, which each table now answers from its source's own count (walking a VFS's
keys, and a NIF's record types for the ones removed) where the engine had a row made for every
record to count them.

The scans, from 1.1x to 2.4x, are rows made cheaper: each starts as a copy of a row that holds every
column asked for where it used to grow key by key, the columns and constraints of a request are
read once where every row asked again, a VFS key's name and stem come from one walk where three
were made, and a path's LIKE is worked out once per scan. The aggregates (`counted by`, `summed`,
`furthest`) gain on top of that from filling one row table over and over, which JessQL allows a
single-table query. A plugin's type is held to its tag's number and an ASCII id to its bytes where
they lie, so `WHERE id = ?` decodes no id (1.48x). A stem lookup keeps what it makes rows with
while the request says the same, which is what an indexed join's thousands of lookups do: 1.87x for
the lookups, 1.3x to 1.7x for the joins.

One row is slower. `WHERE type = ? AND id = ?` used to stop at the first such record
(`tes3.records.find`), which gave a wrong answer when a plugin held two, and raised for a type
that is not four bytes. It is now a scan like any other, to the end of the plugin, and costs 0.78x
of what the wrong answer did; with a `LIMIT 1` it stops at the first again.

What did not move is not the adapter's. Building the stem index is a walk of the VFS's keys and a
string and two table writes for each. A plugin scan with every column is `tes3.records.id` and the
header accessors, and a NIF scan with names is `nif:read` filling a record to read one field. The
join page still makes every pair before it keeps ten: JessQL's indexed join stops early only with
no WHERE and no ORDER BY.

Two things were measured and taken back out. The stem index on a `@dream/intern` pool, with stems
read where they lie in their keys, built in the same time as the string-keyed tables it replaced
(237 ns a key against 261 in isolation, lost in the walk of the VFS's view) and looked up no
faster, since a stem handed in is already a string. Comparing an id's bytes four at a time in Luau
in place of `bytes.compare` was within a tenth, and within the noise on one of its two rows.
