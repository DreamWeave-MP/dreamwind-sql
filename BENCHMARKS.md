# dreamwind-sql benchmarks

`bench/bench.jsl` times the adapter through its public API: prepared queries over a VFS of 50,000
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
- Date: the night of 2026-10-12, at the end of the run that began on 2026-10-11. The table is the
  second measurement of the night, made in review after two fixes to `vfs.files`; the first, of
  commit `f74958a`, agreed with it to within a tenth on every row but the one marked ¹ and the
  200 ns one.
- Binary: `target/l3i2/jess`, the verified release build of Jess on l3i 2.0.2 (Luau 0.742), for
  both columns: the binary is held fixed, so what Luau 0.742 itself changed cancels out. So are
  the sibling packages, JessQL among them, as they stood at the time.
- Before: commit `ce5ad6d` (the package as it was imported, with its tests and this bench), run
  with this bench file as it now is. After: commit `b1e239d`.
- Protocol: the two trees alternately, before/after/before/after, three runs of each inside one
  lock on the machine's benchmark slot. Each cell is the median of its three runs. A difference
  under about 5 percent is noise here and is given as "no change".
- The whole A/B was made twice. The second time both sides ran with
  `MALLOC_TRIM_THRESHOLD_=1073741824 MALLOC_MMAP_THRESHOLD_=1073741824`, which keeps glibc from
  handing large blocks back between batches: those are the columns marked "raised". One row needs
  it. Across the three runs of a side a workload's slowest run was at most 1.18 times its fastest
  with the thresholds raised; without, at most 1.12 but for that one row and the 200 ns one, at
  1.49 each.

```sh
flock $HOME/.cache/agents-bench.lock systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 \
  target/l3i2/jess run --package jpk/dreamwind-sql --package-path jpk jpk/dreamwind-sql/bench/bench.jsl
```

| Workload | Before | After | | Before, raised | After, raised | |
|---|---:|---:|---|---:|---:|---|
| vfs query: a page of a prefix, from the end | 22.27 ms | 19.8 µs | 1125x | 23.12 ms | 20.0 µs | 1154x |
| vfs query: a page of every key, from the end | 21.6 µs | 16.3 µs | 1.32x | 21.5 µs | 15.4 µs | 1.40x |
| vfs query: 25000 keys under a prefix | 38.94 ms | 25.39 ms | 1.53x | 40.53 ms | 25.21 ms | 1.61x |
| vfs query: 50000 files counted | 24.53 ms | 690.7 µs | 36x | 21.53 ms | 654.8 µs | 33x |
| vfs query: 50000 files, those in archives counted by archive | 44.89 ms | 26.33 ms | 1.70x | 45.86 ms | 26.42 ms | 1.74x |
| vfs scan: 25000 keys under a prefix | 29.62 ms | 12.79 ms | 2.32x | 29.37 ms | 12.49 ms | 2.35x |
| vfs scan: 50000 keys and their stems ¹ | 23.52 ms | 15.99 ms | 1.47x | 35.48 ms | 16.35 ms | 2.17x |
| vfs scan: 50000 files, every column | 69.94 ms | 52.35 ms | 1.34x | 70.92 ms | 53.13 ms | 1.33x |
| vfs lookup: the stem index of 50000 keys, built | 17.90 ms | 17.09 ms | no change | 18.64 ms | 17.80 ms | no change |
| vfs lookup: 1000 stems of two files each, the last one's rows kept | 2.22 ms | 1.19 ms | 1.86x | 2.32 ms | 1.21 ms | 1.93x |
| join query: a page of files joined to NIF records by stem, from the end | 14.94 ms | 8.73 ms | 1.71x | 14.84 ms | 9.06 ms | 1.64x |
| join query: 4032 NIF records joined to their two files each | 12.99 ms | 9.35 ms | 1.39x | 13.00 ms | 9.79 ms | 1.33x |
| tes3 scan: 20001 records, every column | 19.64 ms | 18.10 ms | 1.08x | 20.13 ms | 17.96 ms | 1.12x |
| tes3 scan: 20001 records, index and type | 7.86 ms | 4.75 ms | 1.65x | 7.97 ms | 4.85 ms | 1.64x |
| tes3 query: 2500 records of one type, with their ids | 4.64 ms | 3.41 ms | 1.36x | 4.68 ms | 3.56 ms | 1.32x |
| tes3 query: 20001 records counted | 7.63 ms | 351 ns | 21742x | 8.06 ms | 356 ns | 22630x |
| tes3 query: 20001 records counted by type | 9.85 ms | 5.17 ms | 1.90x | 9.71 ms | 5.13 ms | 1.89x |
| tes3 query: one record by its type and id, near the end | 1.59 ms | 2.07 ms | 0.77x, slower | 1.60 ms | 1.98 ms | 0.81x, slower |
| tes3 query: one record by its id, among 20001 | 7.64 ms | 5.41 ms | 1.41x | 7.60 ms | 5.30 ms | 1.43x |
| tes3 query: a page of flagged records, from the end | 4.00 ms | 44.7 µs | 90x | 4.06 ms | 45.6 µs | 89x |
| tes3 query: 20001 records, the sizes of the unflagged summed | 14.66 ms | 6.92 ms | 2.12x | 14.66 ms | 6.99 ms | 2.10x |
| nif query: a page of one type, from the end | 119.8 µs | 115.6 µs | no change | 116.8 µs | 112.9 µs | no change |
| nif query: 4096 records counted | 1.14 ms | 221.4 µs | 5.15x | 1.18 ms | 228.9 µs | 5.13x |
| nif query: 4096 records counted by type | 1.44 ms | 840.5 µs | 1.71x | 1.45 ms | 847.4 µs | 1.71x |
| nif scan: 4096 records, index and type | 1.12 ms | 805.7 µs | 1.39x | 1.12 ms | 803.3 µs | 1.40x |
| nif scan: 4096 records, every column | 2.66 ms | 2.41 ms | 1.11x | 2.74 ms | 2.45 ms | 1.12x |
| nif query: one record by its name, among 4096 | 1.58 ms | 1.51 ms | no change | 1.60 ms | 1.53 ms | no change |
| scene scan: 4096 nodes, every column | 2.72 ms | 1.81 ms | 1.50x | 2.84 ms | 1.91 ms | 1.48x |
| scene scan: 4096 nodes, their names and parents | 1.97 ms | 847.4 µs | 2.33x | 2.04 ms | 869.2 µs | 2.35x |
| scene query: 4096 nodes counted | 1.88 ms | 197 ns | 9544x | 1.83 ms | 270 ns | 6771x |
| scene query: the 63 nodes under the root, among 4096 ² | 191.1 µs | 193.9 µs | no change | 186.3 µs | 199.8 µs | 0.93x |
| scene query: a page of shapes, from the end | 1.92 ms | 14.4 µs | 134x | 1.91 ms | 14.4 µs | 133x |
| scene query: 4032 visible shapes counted, the furthest found | 2.45 ms | 728.0 µs | 3.36x | 2.47 ms | 734.2 µs | 3.36x |

¹ The old code runs this row at one of two speeds, by how the process's heap happens to lie when
it starts making 50,000 rows a call: its three runs without the thresholds were 23.2, 23.5 and
34.5 ms, and with them 35.0, 35.5 and 35.6. The new code runs it at 15.3 to 16.6 ms either way. So
the gain is 1.5x or 2.2x by which speed the old code is found at, and no one number is honest. The
first measurement of the night found it at the slow one (35.55 ms) and gave 2.18x.

² No change. The six runs a side overlap, 182 to 209 µs before and 186 to 205 µs after, and the
0.93x is one side's median falling low among them.

## What moved, and why

None of it is the dialect. The adapter builds maps keyed by column and walks sources that are not
dense arrays (a VFS's views, a plugin's and a NIF's records by index), so the comprehensions,
reducers, and the record pattern it now has are in three places in the payload and in the bench's
and tests' reference lists, and change no number above. What moved is how the adapter answers
JessQL's provider protocol.

The three largest rows are pages: `WHERE ... ORDER BY ... LIMIT 20`. JessQL hands a provider no
limit once a query has a WHERE, so a table that only scans made a row of every match and the
engine kept twenty. Every table now also hands its rows over one at a time (`iterate`, as
`nif.records` already did), and the engine stops asking when the page is full: 1125x for a page of
a VFS prefix, 90x for a plugin's records, 134x for a scene's nodes. The rows marked `counted` are a
bare `SELECT COUNT(*)`, which each table now answers from its source's own count (walking a VFS's
keys, and a NIF's record types for the ones removed) where the engine had a row made for every
record to count them.

The scans, from 1.1x to 2.3x, are rows made cheaper: each starts as a copy of a row that holds every
column asked for where it used to grow key by key, the columns and constraints of a request are
read once where every row asked again, a VFS key's name and stem come from one walk where three
were made, and a path's LIKE is worked out once per scan. The aggregates (`counted by`, `summed`,
`furthest`) gain on top of that from filling one row table over and over, which JessQL allows a
single-table query. A plugin's type is held to its tag's number and an ASCII id to its bytes where
they lie, so `WHERE id = ?` decodes no id (1.41x). A stem lookup keeps what it makes rows with
while the request says the same, which is what an indexed join's thousands of lookups do: 1.86x for
the lookups, 1.3x to 1.7x for the joins.

One row is slower. `WHERE type = ? AND id = ?` used to stop at the first such record
(`tes3.records.find`), which gave a wrong answer when a plugin held two, and raised for a type
that is not four bytes. It is now a scan like any other, to the end of the plugin, and costs 0.77x
of what the wrong answer did; with a `LIMIT 1` it stops at the first again.

What did not move is not the adapter's. Building the stem index is a walk of the VFS's keys and a
string and two table writes for each. A plugin scan with every column is `tes3.records.id` and the
header accessors, and a NIF scan with names is `nif:read` filling a record to read one field, which
is also all of finding a NIF record by its name and of the NIF page, where `nif.records` was lazy
before. The join page still makes every pair before it keeps ten: JessQL's indexed join stops
early only with no WHERE and no ORDER BY.

Two things were measured and taken back out. The stem index on a `@dream/intern` pool, with stems
read where they lie in their keys, built in the same time as the string-keyed tables it replaced
(237 ns a key against 261 in isolation, lost in the walk of the VFS's view) and looked up no
faster, since a stem handed in is already a string. Comparing an id's bytes four at a time in Luau
in place of `bytes.compare` was within a tenth, and within the noise on one of its two rows.

## What no row above times

`ORDER BY path DESC` over every file, or under a `WHERE` the table leaves to JessQL, has no row
here, because the old code answers it wrong: it listed the files rising and called them ordered, so
the bench's check of the rows would refuse it. It is right now, and is a walk of the VFS's keys
from the end.

## Which modules are native, and why

Jess compiles to machine code only what is marked (`--!native` on a module, `@native` on one
function), and every load pays for what is marked. A module carries `--!native` when a row below
spends its time there and the module is small (12 KB or less); a larger module carries `@native`
on the functions the row spends its time in, and nothing else.

Measured 2026-10-15 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load 1.08 and 1.30 at the start of the two
sessions. In each session the bench ran alternately on this package and on a copy of it with
every module marked, three fresh runs of `bench/bench.jsl` each, every run's row the median of
its batches; a column is the median of the three, and a ratio is against the all-marked runs of
the same session. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package <this package>
--package-path jpk` of a script that only requires `@dreamwind-sql`, the two sides alternating, the
median of five each after one warm-up.

| Requiring `@dreamwind-sql` | All marked | This state |
| --- | ---: | ---: |
| Unmarked | 0.155 s | 0.158 s |
| Final | 0.157 s | 0.157 s |

| Row | All marked (ms) | Unmarked / all marked | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| vfs query: a page of a prefix, from the end | 0.02155 | **1.563×** | 0.02158 | 1.001× |
| vfs query: a page of every key, from the end | 0.01691 | **1.420×** | 0.01730 | 1.023× |
| vfs query: 25000 keys under a prefix | 25.94 | **1.445×** | 25.28 | 0.975× |
| vfs query: 50000 files counted | 1.862 | **1.212×** | 1.820 | 0.977× |
| vfs query: 50000 files, those in archives counted by archive | 31.17 | **1.197×** | 31.51 | 1.011× |
| vfs scan: 25000 keys under a prefix | 13.74 | **1.831×** | 13.66 | 0.994× |
| vfs scan: 50000 keys and their stems | 16.33 | **2.198×** | 16.69 | 1.022× |
| vfs scan: 50000 files, every column | 61.83 | **1.336×** | 60.70 | 0.982× |
| vfs lookup: the stem index of 50000 keys, built | 19.17 | **1.793×** | 18.54 | 0.967× |
| vfs lookup: 1000 stems of two files each, the last one's rows kept | 1.217 | **1.476×** | 1.200 | 0.986× |
| join query: a page of files joined to NIF records by stem, from the end | 9.123 | **1.358×** | 8.809 | 0.966× |
| join query: 4032 NIF records joined to their two files each | 9.361 | **1.482×** | 9.243 | 0.987× |
| tes3 scan: 20001 records, every column | 21.51 | **1.199×** | 21.33 | 0.991× |
| tes3 scan: 20001 records, index and type | 4.661 | **1.896×** | 4.506 | 0.967× |
| tes3 query: 2500 records of one type, with their ids | 3.368 | **1.362×** | 3.235 | 0.961× |
| tes3 query: 20001 records counted | 0.00036 | 0.986× | 0.00036 | 0.986× |
| tes3 query: 20001 records counted by type | 4.981 | **1.631×** | 4.751 | 0.954× |
| tes3 query: one record by its type and id, near the end | 1.959 | **1.606×** | 1.912 | 0.976× |
| tes3 query: one record by its id, among 20001 | 5.236 | **1.358×** | 5.095 | 0.973× |
| tes3 query: a page of flagged records, from the end | 0.05121 | **1.428×** | 0.05022 | 0.981× |
| tes3 query: 20001 records, the sizes of the unflagged summed | 10.63 | **1.381×** | 10.35 | 0.974× |
| nif query: a page of one type, from the end | 0.1083 | **1.624×** | 0.1056 | 0.975× |
| nif query: 4096 records counted | 0.2078 | **1.328×** | 0.2067 | 0.995× |
| nif query: 4096 records counted by type | 0.8011 | **1.497×** | 0.7952 | 0.993× |
| nif scan: 4096 records, index and type | 0.7557 | **1.640×** | 0.7535 | 0.997× |
| nif scan: 4096 records, every column | 2.699 | **1.236×** | 2.614 | 0.968× |
| nif query: one record by its name, among 4096 | 1.572 | **1.371×** | 1.538 | 0.978× |
| scene scan: 4096 nodes, every column | 1.861 | **1.356×** | 1.823 | 0.980× |
| scene scan: 4096 nodes, their names and parents | 0.7665 | **1.980×** | 0.7663 | 1.000× |
| scene query: 4096 nodes counted | 0.00026 | **1.097×** | 0.00020 | 0.793× |
| scene query: the 63 nodes under the root, among 4096 | 0.1896 | **2.207×** | 0.1865 | 0.984× |
| scene query: a page of shapes, from the end | 0.01378 | **1.295×** | 0.01329 | 0.965× |
| scene query: 4032 visible shapes counted, the furthest found | 0.7079 | **1.904×** | 0.6904 | 0.975× |

What carries the directive (every module and function here is one a row spends its time in,
unmarked):

- Whole: `nif`, `tes3`, `util`.
- `vfs`, by function: `split`, `logicalStem`, a closure at line 128, `make`, `rowOf`, `rowsFor`,
  `nextRow`, `planned`, `ensureStemIndex`, `lookup`, `count`.
- Unmarked: `init`.

Unmarked, requiring `@dreamwind-sql` cost what all marked does (0.158 s against 0.156 s), while
the queries, scans, and joins over the VFS and NIF tables ran 1.2x to 2.2x slower. So nearly all
of it stays marked; only the entry, and what of `vfs` no row reaches, load as bytecode. No row
is more than 5% slower than all marked.
