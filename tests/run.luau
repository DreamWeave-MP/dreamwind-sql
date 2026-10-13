--!strict
-- dreamwind-sql's own cases: the rows each provider hands JessQL for a request and what it says
-- it took care of, what it asks of the VFS to make them, and queries end to end. The VFS is a
-- stand-in built here: the package takes any VFS by its methods and depends on none.
local engine = require '@jessql/engine'
local nifModule = require '@nif'
local nifTables = require '@dreamwind-sql/nif'
local sql = require '@dreamwind-sql'
local tes3 = require '@tes3'
local tes3Tables = require '@dreamwind-sql/tes3'
local test = require '@jess/test'
local vfsTables = require '@dreamwind-sql/vfs'

local suite, expect = test.new(), test.expect

type Constraint = engine.Constraint
type Request = engine.Request
type Row = engine.Row

type Hints = {
  limit: number?,
  limitHint: number?,
  orderBy: { engine.Order }?,
  --- Whether the constraints are the query's whole WHERE; they are unless this says not.
  partialWhere: boolean?,
}

local function request(columns: { string }, constraints: { Constraint }?, hints: Hints?): Request
  return {
    columns = columns,
    constraints = constraints or {},
    limit = hints and hints.limit,
    limitHint = hints and hints.limitHint,
    orderBy = hints and hints.orderBy,
    whereComplete = not (hints and hints.partialWhere),
    allowVolatileRows = false,
  }
end

local function where(column: string, op: string, value: unknown): Constraint
  return { column = column, op = op, value = value }
end

local function by(column: string, desc: boolean?): { engine.Order }
  return { { column = column, desc = desc == true } }
end

type Claims = {
  read handledWhere: boolean?,
  read handledConstraints: boolean?,
  read ordered: boolean?,
  read limited: boolean?,
}

--- What a scan or an iterator says it took care of, as the words for each thing it claims.
local function claims(result: Claims): string
  local said = {}
  if result.handledWhere then table.insert(said, 'where') end
  if result.handledConstraints then table.insert(said, 'constraints') end
  if result.ordered then table.insert(said, 'ordered') end
  if result.limited then table.insert(said, 'limited') end

  return table.concat(said, ' ')
end

--- One column of some rows, in their order.
local function column(rows: engine.SourceRows, name: string): { unknown }
  local out = {}
  for _, row in rows do
    table.insert(out, row[name])
  end

  return out
end

--- Every row an iterator has left.
local function drain(iterator: nifTables.Iterator): { Row }
  local rows = {}
  while true do
    local row = iterator.next()
    if not row then break end

    table.insert(rows, row)
  end

  return rows
end

--[[ The VFS stand-in ]]

--- A file of the stand-in VFS: its key, where its bytes are, how long it is, the archive it is in
--- if it is in one, and the name and stem a row must give its key.
type Listing = {
  key: string,
  location: string,
  length: number,
  archive: string?,
  name: string,
  stem: string,
}

--- In key order, as a VFS lists them.
local Listings: { Listing } = {
  { key = 'a.b', location = '/data/a.b', length = 1, name = 'a.b', stem = 'a' },
  { key = 'icons/a.dds', location = '/data/icons/a.dds', length = 11, name = 'a.dds', stem = 'a' },
  {
    key = 'meshes/x/rock.nif',
    location = '/data/meshes/x/rock.nif',
    length = 100,
    name = 'rock.nif',
    stem = 'rock',
  },
  {
    key = 'meshes/x/tree.nif',
    location = 'meshes\\x\\tree.nif',
    length = 200,
    archive = '/data/morrowind.bsa',
    name = 'tree.nif',
    stem = 'tree',
  },
  {
    key = 'meshes/y/rock.kf',
    location = '/mods/meshes/y/rock.kf',
    length = 30,
    name = 'rock.kf',
    stem = 'rock',
  },
  {
    key = 'meshes/y/rock.nif',
    location = 'meshes\\y\\rock.nif',
    length = 40,
    archive = '/mods/extra.bsa',
    name = 'rock.nif',
    stem = 'rock',
  },
  { key = 'readme', location = '/data/readme', length = 5, name = 'readme', stem = 'readme' },
  {
    key = 'textures/.a.b',
    location = '/data/textures/.a.b',
    length = 6,
    name = '.a.b',
    stem = '.a',
  },
  {
    key = 'textures/.hidden',
    location = '/data/textures/.hidden',
    length = 7,
    name = '.hidden',
    stem = '.hidden',
  },
  {
    key = 'textures/dir.d/plain',
    location = '/data/textures/dir.d/plain',
    length = 8,
    name = 'plain',
    stem = 'plain',
  },
  {
    key = 'textures/pack.tar.gz',
    location = '/data/textures/pack.tar.gz',
    length = 9,
    name = 'pack.tar.gz',
    stem = 'pack.tar',
  },
  {
    key = 'textures/trailing.',
    location = '/data/textures/trailing.',
    length = 10,
    name = 'trailing.',
    stem = 'trailing',
  },
}

local FileColumns = {
  'path',
  'physical_path',
  'name',
  'stem',
  'size',
  'is_loose',
  'is_archive',
  'archive_path',
  'archive_name',
}

local KeyColumns = { 'path', 'name', 'stem' }

local ByKey: { [string]: Listing } = {}

for _, listing in Listings do
  ByKey[listing.key] = listing
end

--- The row a listing makes, with the columns asked for.
local function fileRow(listing: Listing, columns: { string }): Row
  local archive = listing.archive
  local whole: Row = {
    path = listing.key,
    physical_path = listing.location,
    name = listing.name,
    stem = listing.stem,
    size = listing.length,
    is_loose = archive == nil,
    is_archive = archive ~= nil,
    archive_path = archive,
    archive_name = if archive then string.match(archive, '[^/]*$') else nil,
  }
  local row: Row = {}
  for _, name in columns do
    row[name] = whole[name]
  end

  return row
end

local function fileRows(keys: { string }, columns: { string }): { Row }
  local rows = {}
  for _, key in keys do
    table.insert(rows, fileRow(ByKey[key], columns))
  end

  return rows
end

local function allKeys(): { string }
  local keys = {}
  for _, listing in Listings do
    table.insert(keys, listing.key)
  end

  return keys
end

--- A list as the vfs package hands most of its own out: an empty table whose rows are made when
--- they are read, by index or by a generic `for`. `read` is told of each row made.
local function view<Item>(items: { Item }, read: () -> ()): { Item }
  local meta = {
    __len = function(): number return #items end,
    __index = function(_: unknown, key: unknown): Item?
      if type(key) ~= 'number' or not items[key] then return nil end

      read()
      return items[key]
    end,

    __iter = function(): () -> (number?, Item?)
      local index = 0
      return function(): (number?, Item?)
        if index >= #items then return nil, nil end

        index += 1
        read()
        return index, items[index]
      end
    end,
  }

  return (setmetatable({}, meta) :: unknown) :: { Item }
end

--- A list that can be walked with a generic `for` and read no other way.
local function walked<Item>(items: { Item }): { Item }
  local meta = {
    __iter = function(): () -> (number?, Item?)
      local index = 0
      return function(): (number?, Item?)
        index += 1
        return if items[index] ~= nil then index else nil, items[index]
      end
    end,
  }

  return (setmetatable({}, meta) :: unknown) :: { Item }
end

type Stand = {
  vfs: vfsTables.Vfs,
  --- Every listing, lookup, and file the provider asked the VFS for, in order.
  calls: { string },
  --- How many rows of its views have been made.
  reads: () -> number,
  --- Takes a file away from `getFile`, with its key still listed.
  lose: (key: string) -> (),
  add: (listing: Listing) -> (),
}

--- A VFS over `Listings`, handing its lists out as views when `lazy`, as plain arrays otherwise.
local function stand(lazy: boolean): Stand
  local listings: { [string]: Listing } = table.clone(ByKey)
  local lost: { [string]: boolean } = {}
  local calls: { string } = {}
  local revision, reads = 1, 0

  local function file(listing: Listing)
    local archive = listing.archive
    return {
      path = function(_: unknown): string return listing.location end,
      size = function(_: unknown): number return listing.length end,
      isLoose = function(_: unknown): boolean return archive == nil end,
      isArchive = function(_: unknown): boolean return archive ~= nil end,
      parentArchivePath = function(_: unknown): string? return archive end,
      parentArchiveName = function(_: unknown): string?
        return if archive then string.match(archive, '[^/]*$') else nil
      end,
    }
  end

  local function sorted(prefix: string): { string }
    local keys = {}
    for key in listings do
      if string.sub(key, 1, #prefix) == prefix then table.insert(keys, key) end
    end

    table.sort(keys)
    return keys
  end

  local function page<Item>(items: { Item }, limit: number?, descending: boolean?): { Item }
    local out = {}
    local first, last, step = 1, #items, 1
    if descending then
      first, last, step = #items, 1, -1
    end

    for index = first, last, step do
      if limit and #out >= limit then break end

      table.insert(out, items[index])
    end

    return if lazy then view(out, function() reads += 1 end) else out
  end

  local function entries(keys: { string })
    local out = {}
    for _, key in keys do
      table.insert(out, { key = key, file = file(listings[key]) })
    end

    return out
  end

  local function called(name: string, ...: unknown)
    local words = { name }
    for index = 1, select('#', ...) do
      table.insert(words, tostring((select(index, ...))))
    end

    table.insert(calls, table.concat(words, ' '))
  end

  local methods = {
    revision = function(_: unknown): number return revision end,
    contains = function(_: unknown, path: string): boolean
      called('contains', path)
      return listings[path] ~= nil
    end,

    getFile = function(_: unknown, path: string)
      called('getFile', path)
      local listing = listings[path]
      return if listing and not lost[path] then file(listing) else nil
    end,

    keys = function(_: unknown, limit: number?, descending: boolean?)
      called('keys', limit, descending)
      return page(sorted '', limit, descending)
    end,

    entries = function(_: unknown, limit: number?, descending: boolean?)
      called('entries', limit, descending)
      return page(entries(sorted ''), limit, descending)
    end,

    keysStartingWith = function(_: unknown, prefix: string, limit: number?, descending: boolean?)
      called('keysStartingWith', `'{prefix}'`, limit, descending)
      return page(sorted(prefix), limit, descending)
    end,

    pathsStartingWith = function(_: unknown, prefix: string, limit: number?, descending: boolean?)
      called('pathsStartingWith', `'{prefix}'`, limit, descending)
      return page(entries(sorted(prefix)), limit, descending)
    end,
  }

  return {
    vfs = (methods :: unknown) :: vfsTables.Vfs,
    calls = calls,
    reads = function(): number return reads end,
    lose = function(key: string) lost[key] = true end,
    add = function(listing: Listing)
      listings[listing.key] = listing
      revision += 1
    end,
  }
end

for _, lazy in { false, true } do
  suite.describe(if lazy then 'vfs.files over views' else 'vfs.files over arrays', function()
    local files: Stand
    local provider: vfsTables.Provider

    suite.beforeEach(function()
      files = stand(lazy)
      provider = vfsTables.provider(files.vfs)
    end)

    suite.it('lists its columns and the one it can look rows up by', function()
      expect(provider.columns).toEqual(FileColumns)
      expect(provider.indexes).toEqual { stem = true }
    end)

    suite.it('hands over every file, with every column', function()
      local scanned = provider.scan(request(FileColumns))
      expect(scanned._jessqlScan).toBe 'v1'
      expect(scanned.rows).toEqual(fileRows(allKeys(), FileColumns))
      expect(claims(scanned)).toBe 'where constraints'
      expect(files.calls).toEqual { 'entries nil nil' }
    end)

    suite.it('hands the files over one at a time, as it scans them', function()
      local iterator = provider.iterate(request(FileColumns))
      expect(iterator._jessqlIter).toBe 'v1'
      expect(claims(iterator)).toBe 'where constraints'
      expect(iterator.next()).toEqual(fileRow(Listings[1], FileColumns))
      expect(iterator.next()).toEqual(fileRow(Listings[2], FileColumns))
      expect(#drain(iterator)).toBe(#Listings - 2)
      expect(iterator.next()).toBeNil()
      expect(iterator.next()).toBeNil()

      local asked = {
        request(KeyColumns),
        request({ 'stem', 'size' }, { where('path', 'LIKE', 'meshes/%') }),
        request(KeyColumns, { where('path', 'LIKE', 'meshes/%') }, { orderBy = by('path', true) }),
        request(FileColumns, { where('path', 'LIKE', 'textures/%') }, { limitHint = 2, orderBy = by 'path' }),
        request(KeyColumns, nil, { limit = 3, limitHint = 3 }),
        request(FileColumns, nil, { limitHint = 4, orderBy = by('path', true) }),
        request(KeyColumns, { where('path', '=', 'readme') }),
        request(FileColumns, { where('path', '=', 'meshes/x/tree.nif') }),
        request(FileColumns, { where('path', '=', 'meshes/x/none.nif') }),
        request(KeyColumns, { where('path', '=', 'Readme') }),
        request(KeyColumns, { where('path', 'LIKE', 'meshes/%'), where('path', 'LIKE', 'meshes/y/%') }),
        request(KeyColumns, { where('path', 'LIKE', '%rock%') }),
        request(KeyColumns, { where('size', '=', 100), where('path', 'LIKE', 'icons/%') }),
        request(KeyColumns, nil, { orderBy = by 'name' }),
        request({ 'path' }, { where('path', 'LIKE', 'meshes/%') }, { partialWhere = true }),
        request {},
      }

      for _, each in asked do
        local scanned, lazily = provider.scan(each), provider.iterate(each)
        expect(lazily.handledWhere).toBe(scanned.handledWhere)
        expect(lazily.handledConstraints).toBe(scanned.handledConstraints)
        expect(lazily.ordered).toBe(scanned.ordered)
        expect(drain(lazily)).toEqual(scanned.rows)
      end
    end)

    suite.it('asks a view for no more rows than it hands over', function()
      local like = { where('path', 'LIKE', 'meshes/%') }
      local iterator = provider.iterate(request(FileColumns, like, { orderBy = by('path', true) }))
      expect(files.reads()).toBe(0)
      expect(iterator.next()).toEqual(fileRow(ByKey['meshes/y/rock.nif'], FileColumns))
      expect(iterator.next()).toEqual(fileRow(ByKey['meshes/y/rock.kf'], FileColumns))
      expect(files.reads()).toBe(if lazy then 2 else 0)
      expect(files.calls).toEqual { 'pathsStartingWith \'meshes/\' nil true' }

      local db = sql.new { vfs = files.vfs }
      local paged = db:query [[SELECT path FROM vfs.files WHERE path LIKE 'textures/%' ORDER BY path LIMIT 2]]
      expect(paged.rows).toEqual { { path = 'textures/.a.b' }, { path = 'textures/.hidden' } }
      expect(files.reads()).toBe(if lazy then 4 else 0)
    end)

    suite.it('scans a list that can only be walked', function()
      local vfs = files.vfs
      local only = setmetatable({}, {
        __index = function(_: unknown, name: string): unknown
          return function(_: unknown, ...: unknown): unknown
            local listed = (vfs :: any)[name](vfs, ...)
            if type(listed) ~= 'table' or name == 'getFile' then return listed end

            local items = {}
            for _, item in listed do
              table.insert(items, item)
            end

            return walked(items)
          end
        end,
      })
      local walking = vfsTables.provider((only :: unknown) :: vfsTables.Vfs)
      expect(walking.scan(request(FileColumns)).rows).toEqual(fileRows(allKeys(), FileColumns))
      expect(walking.scan(request(KeyColumns, { where('path', 'LIKE', 'icons/%') })).rows).toEqual(
        fileRows({ 'icons/a.dds' }, KeyColumns)
      )

      local limited = walking.scan(request(KeyColumns, nil, { limit = 2, limitHint = 2 }))
      expect(limited.rows).toEqual(fileRows({ 'a.b', 'icons/a.dds' }, KeyColumns))

      local rocks = walking.lookup('stem', 'rock', request { 'path' })
      assert(rocks)
      expect(#rocks.rows).toBe(3)
    end)

    suite.it('lists keys alone when no column needs the file', function()
      local scanned = provider.scan(request(KeyColumns))
      expect(scanned.rows).toEqual(fileRows(allKeys(), KeyColumns))
      expect(files.calls).toEqual { 'keys nil nil' }
    end)

    suite.it('fills only the columns asked for, and none when none are', function()
      expect(provider.scan(request { 'stem' }).rows).toEqual(fileRows(allKeys(), { 'stem' }))
      expect(provider.scan(request { 'archive_name', 'size' }).rows).toEqual(
        fileRows(allKeys(), { 'archive_name', 'size' })
      )

      expect(provider.scan(request {}).rows).toEqual(fileRows(allKeys(), {}))
      expect(provider.scan(({} :: unknown) :: Request).rows).toEqual(fileRows(allKeys(), {}))
    end)

    suite.it('names a key by what follows its last slash, and stems the name at its last dot', function()
      local odd = {
        { 'd.e/f', 'f', 'f' },
        { 'd/..', '..', '.' },
        { 'd/a..b', 'a..b', 'a.' },
        { 'd/e.f/', '', '' },
        { 'trail/', '', '' },
        { '.', '.', '.' },
        { '..x', '..x', '.' },
        { 'x.', 'x.', 'x' },
        { 'no/dots/here', 'here', 'here' },
        { 'a/b/c.d.e.f', 'c.d.e.f', 'c.d.e' },
      }

      for _, each in odd do
        files.add { key = each[1], location = each[1], length = 0, name = each[2], stem = each[3] }
      end

      for _, each in odd do
        local scanned = provider.scan(request(KeyColumns, { where('path', '=', each[1]) }))
        expect(scanned.rows).toEqual { { path = each[1], name = each[2], stem = each[3] } }

        local found = provider.lookup('stem', each[3], request { 'path' })
        assert(found)
        expect(found.rows).toContain { path = each[1] }
      end
    end)

    suite.it('leaves a column it lacks out of its rows', function()
      local scanned = provider.scan(request { 'stem', 'bogus', 'size', 'index' })
      expect(scanned.rows).toEqual(fileRows(allKeys(), { 'stem', 'size' }))
      expect(drain(provider.iterate(request { 'bogus', 'path' }))).toEqual(fileRows(allKeys(), { 'path' }))

      local rocks = provider.lookup('stem', 'rock', request { 'bogus', 'name' })
      assert(rocks)
      expect(rocks.rows).toEqual { { name = 'rock.nif' }, { name = 'rock.kf' }, { name = 'rock.nif' } }
    end)

    suite.it('asks for a page of keys when nothing constrains the scan', function()
      local first = provider.scan(request(KeyColumns, nil, { limit = 3, limitHint = 3 }))
      expect(first.rows).toEqual(fileRows({ 'a.b', 'icons/a.dds', 'meshes/x/rock.nif' }, KeyColumns))
      expect(claims(first)).toBe 'where constraints limited'

      local last = provider.scan(request(KeyColumns, nil, { limitHint = 2, orderBy = by('path', true) }))
      expect(last.rows).toEqual(fileRows({ 'textures/trailing.', 'textures/pack.tar.gz' }, KeyColumns))
      expect(claims(last)).toBe 'where constraints ordered limited'

      local sized = provider.scan(request({ 'path', 'size' }, nil, { limitHint = 2, orderBy = by 'path' }))
      expect(sized.rows).toEqual(fileRows({ 'a.b', 'icons/a.dds' }, { 'path', 'size' }))
      expect(files.calls).toEqual { 'keys 3 false', 'keys 2 true', 'entries 2 false' }
    end)

    suite.it('takes the hint over the limit', function()
      local scanned = provider.scan(request({ 'path' }, nil, { limit = 3, limitHint = 1 }))
      expect(column(scanned.rows, 'path')).toEqual { 'a.b' }
    end)

    suite.it('finds an exact path without listing any', function()
      local equal = { where('path', '=', 'meshes/x/rock.nif') }
      local named = provider.scan(request(KeyColumns, equal))
      expect(named.rows).toEqual(fileRows({ 'meshes/x/rock.nif' }, KeyColumns))
      expect(claims(named)).toBe 'where constraints'

      local whole = provider.scan(request(FileColumns, equal))
      expect(whole.rows).toEqual(fileRows({ 'meshes/x/rock.nif' }, FileColumns))

      local absent = { where('path', '=', 'meshes/x/none.nif') }
      expect(provider.scan(request(KeyColumns, absent)).rows).toEqual {}
      expect(provider.scan(request(FileColumns, absent)).rows).toEqual {}
      expect(files.calls).toEqual {
        'contains meshes/x/rock.nif',
        'getFile meshes/x/rock.nif',
        'contains meshes/x/none.nif',
        'getFile meshes/x/none.nif',
      }
    end)

    suite.it('holds an exact path and a prefix to the spelling keys have', function()
      for _, spelled in { 'Meshes/x/rock.nif', '/meshes/x/rock.nif', 'meshes\\x\\rock.nif', 'meshes//x/rock.nif', '' } do
        local equal = provider.scan(request(KeyColumns, { where('path', '=', spelled) }))
        expect(equal.rows).toEqual {}
        expect(claims(equal)).toBe 'where constraints'
      end

      for _, spelled in { 'Meshes/%', '/meshes/%', 'meshes\\%', 'meshes//%' } do
        local like = provider.scan(request(FileColumns, { where('path', 'LIKE', spelled) }))
        expect(like.rows).toEqual {}
        expect(claims(like)).toBe 'where constraints'
      end

      expect(files.calls).toEqual {}
    end)

    suite.it('scans a prefix as a range of keys', function()
      local like = { where('path', 'LIKE', 'meshes/%') }
      local meshes = { 'meshes/x/rock.nif', 'meshes/x/tree.nif', 'meshes/y/rock.kf', 'meshes/y/rock.nif' }
      local every = provider.scan(request(KeyColumns, like))
      expect(every.rows).toEqual(fileRows(meshes, KeyColumns))
      expect(claims(every)).toBe 'where constraints'

      local last = provider.scan(request(KeyColumns, like, { limitHint = 2, orderBy = by('path', true) }))
      expect(last.rows).toEqual(fileRows({ 'meshes/y/rock.nif', 'meshes/y/rock.kf' }, KeyColumns))
      expect(claims(last)).toBe 'where constraints ordered limited'

      local whole = provider.scan(request(FileColumns, like, { limitHint = 3, orderBy = by 'path' }))
      expect(whole.rows).toEqual(
        fileRows({ 'meshes/x/rock.nif', 'meshes/x/tree.nif', 'meshes/y/rock.kf' }, FileColumns)
      )

      expect(provider.scan(request(KeyColumns, { where('path', 'LIKE', '%') })).rows).toEqual(
        fileRows(allKeys(), KeyColumns)
      )

      expect(provider.scan(request(KeyColumns, { where('path', 'LIKE', 'sound/%') })).rows).toEqual {}
      expect(files.calls).toEqual {
        'keysStartingWith \'meshes/\' nil false',
        'keysStartingWith \'meshes/\' 2 true',
        'pathsStartingWith \'meshes/\' 3 false',
        'keysStartingWith \'\' nil false',
        'keysStartingWith \'sound/\' nil false',
      }
    end)

    suite.it('takes a pattern without a wildcard for the path it spells', function()
      local scanned = provider.scan(request(KeyColumns, { where('path', 'LIKE', 'readme') }))
      expect(scanned.rows).toEqual(fileRows({ 'readme' }, KeyColumns))
      expect(claims(scanned)).toBe 'where constraints'
      expect(files.calls).toEqual { 'contains readme' }
    end)

    suite.it('ranges over the longest prefix and holds a path to every constraint', function()
      local nested = provider.scan(
        request(KeyColumns, { where('path', 'LIKE', 'meshes/%'), where('path', 'LIKE', 'meshes/y/%') })
      )
      expect(nested.rows).toEqual(fileRows({ 'meshes/y/rock.kf', 'meshes/y/rock.nif' }, KeyColumns))

      local apart = provider.scan(
        request(KeyColumns, { where('path', 'LIKE', 'meshes/x/%'), where('path', 'LIKE', 'icons/%') })
      )
      expect(apart.rows).toEqual {}

      local outside = provider.scan(
        request(KeyColumns, { where('path', 'LIKE', 'meshes/%'), where('path', '=', 'icons/a.dds') })
      )
      expect(outside.rows).toEqual {}

      local inside = provider.scan(
        request(KeyColumns, { where('path', '=', 'meshes/x/tree.nif'), where('path', 'LIKE', 'meshes/%') })
      )
      expect(inside.rows).toEqual(fileRows({ 'meshes/x/tree.nif' }, KeyColumns))

      local two = provider.scan(request(KeyColumns, { where('path', '=', 'readme'), where('path', '=', 'a.b') }))
      expect(two.rows).toEqual {}
      expect(claims(two)).toBe 'where constraints'
      expect(files.calls).toEqual {
        'keysStartingWith \'meshes/y/\' nil false',
        'keysStartingWith \'meshes/x/\' nil false',
        'contains icons/a.dds',
        'contains meshes/x/tree.nif',
        'contains readme',
      }
    end)

    suite.it('leaves a pattern it cannot range over to the engine', function()
      for _, pattern in { 'meshes/_/rock.nif', '%rock%', 'me%es/%', 'meshes/%%' } do
        local scanned = provider.scan(request(KeyColumns, { where('path', 'LIKE', pattern) }, { limit = 1 }))
        expect(scanned.rows).toEqual(fileRows(allKeys(), KeyColumns))
        expect(claims(scanned)).toBe ''
      end

      local mixed = provider.scan(
        request(KeyColumns, { where('path', 'LIKE', 'meshes/x/%'), where('path', 'LIKE', '%.nif') }, { limit = 1 })
      )
      expect(mixed.rows).toEqual(fileRows({ 'meshes/x/rock.nif', 'meshes/x/tree.nif' }, KeyColumns))
      expect(claims(mixed)).toBe ''
      expect(files.calls).toEqual {
        'keys nil nil',
        'keys nil nil',
        'keys nil nil',
        'keys nil nil',
        'keysStartingWith \'meshes/x/\' nil false',
      }
    end)

    suite.it('leaves every other constraint to the engine', function()
      local others = {
        where('size', '=', 100),
        where('stem', '=', 'rock'),
        where('path', '=', 5),
        where('path', 'LIKE', 5),
        where('path', '!=', 'readme'),
        where('path', '<', 'm'),
      }

      for _, other in others do
        local scanned = provider.scan(request(KeyColumns, { other }, { limit = 1 }))
        expect(scanned.rows).toEqual(fileRows(allKeys(), KeyColumns))
        expect(claims(scanned)).toBe ''
      end

      local narrowed = provider.scan(
        request(KeyColumns, { where('size', '=', 100), where('path', 'LIKE', 'icons/%') }, { limit = 1 })
      )
      expect(narrowed.rows).toEqual(fileRows({ 'icons/a.dds' }, KeyColumns))
      expect(claims(narrowed)).toBe ''
    end)

    suite.it('orders by path alone, and stops at a limit only in an order it keeps', function()
      local named = provider.scan(request(KeyColumns, nil, { limitHint = 2, orderBy = by 'name' }))
      expect(named.rows).toEqual(fileRows(allKeys(), KeyColumns))
      expect(claims(named)).toBe 'where constraints'

      local two = { { column = 'path', desc = false }, { column = 'name', desc = false } }
      local both = provider.scan(request(KeyColumns, nil, { limitHint = 2, orderBy = two }))
      expect(both.rows).toEqual(fileRows(allKeys(), KeyColumns))
      expect(claims(both)).toBe 'where constraints'

      local rising = provider.scan(request(KeyColumns, nil, { orderBy = by 'path' }))
      expect(rising.rows).toEqual(fileRows(allKeys(), KeyColumns))
      expect(claims(rising)).toBe 'where constraints ordered'
    end)

    suite.it('stops at a limit only when the whole WHERE is its own', function()
      local like = { where('path', 'LIKE', 'meshes/%') }
      local scanned = provider.scan(request({ 'path' }, like, { limit = 2, limitHint = 2, partialWhere = true }))
      expect(#scanned.rows).toBe(4)
      expect(claims(scanned)).toBe 'constraints'
    end)

    suite.it('answers a stem from an index made once for each revision', function()
      local columns = { 'path', 'stem' }
      local rocks = provider.lookup('stem', 'rock', request(columns))
      assert(rocks)
      expect(rocks._jessqlScan).toBe 'v1'
      expect(rocks.rows).toEqual(
        fileRows({ 'meshes/x/rock.nif', 'meshes/y/rock.kf', 'meshes/y/rock.nif' }, columns)
      )

      expect(claims(rocks)).toBe 'where constraints'

      local tree = provider.lookup('stem', 'tree', request(FileColumns))
      assert(tree)
      expect(tree.rows).toEqual(fileRows({ 'meshes/x/tree.nif' }, FileColumns))

      for _, stem in { 'a', '.a', '.hidden', 'plain', 'pack.tar', 'trailing', 'readme' } do
        local found = provider.lookup('stem', stem, request { 'stem' })
        assert(found)
        expect(found.rows[1]).toEqual { stem = stem }
      end

      for _, stem in { 'Rock', 'rock.nif', 'pack', '' } do
        local found = provider.lookup('stem', stem, request(columns))
        assert(found)
        expect(found.rows).toEqual {}
      end

      local listed = 0
      for _, call in files.calls do
        if call == 'keysStartingWith \'\' nil nil' then
          listed += 1
        end
      end

      expect(listed).toBe(1)

      local stone: Listing = {
        key = 'meshes/z/stone.nif',
        location = '/mods/stone.nif',
        length = 3,
        name = 'stone.nif',
        stem = 'stone',
      }
      files.add(stone)
      local added = provider.lookup('stem', 'stone', request(FileColumns))
      assert(added)
      expect(added.rows).toEqual { fileRow(stone, FileColumns) }
    end)

    suite.it('holds a looked-up stem to the path constraints, and skips a file that is gone', function()
      local columns = { 'path', 'size' }
      local under = provider.lookup('stem', 'rock', request(columns, { where('path', 'LIKE', 'meshes/y/%') }))
      assert(under)
      expect(under.rows).toEqual(fileRows({ 'meshes/y/rock.kf', 'meshes/y/rock.nif' }, columns))
      expect(claims(under)).toBe 'where constraints'

      local elsewhere = provider.lookup('stem', 'tree', request(columns, { where('path', 'LIKE', 'icons/%') }))
      assert(elsewhere)
      expect(elsewhere.rows).toEqual {}

      local sized = provider.lookup('stem', 'rock', request(columns, { where('size', '=', 30) }))
      assert(sized)
      expect(#sized.rows).toBe(3)
      expect(claims(sized)).toBe ''

      files.lose 'meshes/y/rock.kf'
      files.lose 'meshes/x/tree.nif'
      local kept = provider.lookup('stem', 'rock', request(columns))
      assert(kept)
      expect(kept.rows).toEqual(fileRows({ 'meshes/x/rock.nif', 'meshes/y/rock.nif' }, columns))

      local keyed = provider.lookup('stem', 'rock', request { 'path' })
      assert(keyed)
      expect(#keyed.rows).toBe(3)

      local gone = provider.lookup('stem', 'tree', request(columns))
      assert(gone)
      expect(gone.rows).toEqual {}
    end)

    suite.it('answers each lookup by what its request says when it is made', function()
      local function rocks(asked: Request): ({ Row }, string)
        local found = provider.lookup('stem', 'rock', asked)
        assert(found)
        return found.rows, claims(found)
      end

      local all = { 'meshes/x/rock.nif', 'meshes/y/rock.kf', 'meshes/y/rock.nif' }
      local under = { 'meshes/y/rock.kf', 'meshes/y/rock.nif' }
      local asked = request({ 'path' }, { where('path', 'LIKE', 'meshes/%') })
      expect((rocks(asked))).toEqual(fileRows(all, { 'path' }))
      expect((rocks(asked))).toEqual(fileRows(all, { 'path' }))

      asked.columns[1] = 'name'
      expect((rocks(asked))).toEqual(fileRows(all, { 'name' }))
      table.insert(asked.columns, 'size')
      expect((rocks(asked))).toEqual(fileRows(all, { 'name', 'size' }))
      table.remove(asked.columns, 1)
      expect((rocks(asked))).toEqual(fileRows(all, { 'size' }))
      asked.columns = { 'path', 'stem' }
      expect((rocks(asked))).toEqual(fileRows(all, { 'path', 'stem' }))

      asked.constraints[1].value = 'meshes/y/%'
      expect((rocks(asked))).toEqual(fileRows(under, { 'path', 'stem' }))
      asked.constraints[1].op = '='
      expect((rocks(asked))).toEqual {}
      asked.constraints[1].op = 'LIKE'
      table.insert(asked.constraints, where('path', '=', 'meshes/y/rock.kf'))
      expect((rocks(asked))).toEqual(fileRows({ 'meshes/y/rock.kf' }, { 'path', 'stem' }))
      asked.constraints[2].column = 'size'
      expect(select(2, rocks(asked))).toBe ''
      expect((rocks(asked))).toEqual(fileRows(under, { 'path', 'stem' }))
      table.remove(asked.constraints)
      expect(select(2, rocks(asked))).toBe 'where constraints'
      asked.whereComplete = false
      expect(select(2, rocks(asked))).toBe 'constraints'
      asked.constraints = {}
      expect((rocks(asked))).toEqual(fileRows(all, { 'path', 'stem' }))

      local again = request({ 'path', 'stem' }, {}, { partialWhere = true })
      expect((rocks(again))).toEqual(fileRows(all, { 'path', 'stem' }))
      expect(select(2, rocks(again))).toBe 'constraints'

      local other = vfsTables.provider(stand(lazy).vfs)
      local elsewhere = other.lookup('stem', 'tree', request { 'size' })
      assert(elsewhere)
      expect(elsewhere.rows).toEqual { { size = 200 } }
      expect((rocks(again))).toEqual(fileRows(all, { 'path', 'stem' }))
    end)

    suite.it('looks rows up by stem and by nothing else', function()
      expect(provider.lookup('path', 'readme', request { 'path' })).toBeNil()
      expect(provider.lookup('name', 'readme', request { 'path' })).toBeNil()
      expect(provider.lookup('stem', 5, request { 'path' })).toBeNil()
      expect(provider.lookup('stem', nil, request { 'path' })).toBeNil()
      expect(files.calls).toEqual {}
    end)

    suite.it('answers queries', function()
      local db = sql.new { vfs = files.vfs }
      local paged = db:query [[SELECT path, stem FROM vfs.files
        WHERE path LIKE 'meshes/%' ORDER BY path DESC LIMIT 2]]
      expect(paged.rows).toEqual {
        { path = 'meshes/y/rock.nif', stem = 'rock' },
        { path = 'meshes/y/rock.kf', stem = 'rock' },
      }

      local counted = db:query [[SELECT stem, COUNT(*) AS files, SUM(size) AS bytes FROM vfs.files
        WHERE is_archive = false GROUP BY stem ORDER BY files DESC, stem LIMIT 2]]
      expect(counted.rows).toEqual {
        { stem = 'a', files = 2, bytes = 12 },
        { stem = 'rock', files = 2, bytes = 130 },
      }

      local archived = db:query('SELECT name, archive_name FROM vfs.files WHERE archive_name = ?', { 'extra.bsa' })
      expect(archived.rows).toEqual { { name = 'rock.nif', archive_name = 'extra.bsa' } }
    end)
  end)
end

--[[ A plugin ]]

local function u32(value: number): string return string.pack('<I4', value) end

local function subrecord(tag: string, payload: string): string
  return tag .. u32(#payload) .. payload
end

local function record(tag: string, payload: string, flags: number?): string
  return tag .. u32(#payload) .. u32(0) .. u32(flags or 0) .. payload
end

local RecordColumns = { 'index', 'type', 'id', 'flags', 'size', 'dirty', 'partial' }

--- A header, six records whose ids each come from the subrecord their type keeps one in, two of
--- them the same static, and a tree renamed since the plugin was opened.
local function plugin(): tes3.Plugin
  local opened = tes3.open(
    record('TES3', subrecord('HEDR', string.rep('\0', 300)))
      .. record('STAT', subrecord('NAME', 'rock\0'), 0x400)
      .. record('NPC_', subrecord('NAME', 'fargoth\0'))
      .. record('STAT', subrecord('NAME', 'tree\0'))
      .. record('SCPT', subrecord('SCHD', 'startup' .. string.rep('\0', 45)))
      .. record('INFO', subrecord('INAM', '12345\0'))
      .. record('NPC_', subrecord('NAME', 'rock\0'), 0x400)
  )
  opened:replaceSubrecord(3, 0, 'oak\0')
  return opened
end

local Records: { Row } = {
  { index = 0, type = 'TES3', flags = 0, size = 308, dirty = false, partial = false },
  { index = 1, type = 'STAT', id = 'rock', flags = 0x400, size = 13, dirty = false, partial = false },
  { index = 2, type = 'NPC_', id = 'fargoth', flags = 0, size = 16, dirty = false, partial = false },
  { index = 3, type = 'STAT', id = 'oak', flags = 0, size = 12, dirty = true, partial = false },
  { index = 4, type = 'SCPT', id = 'startup', flags = 0, size = 60, dirty = false, partial = false },
  { index = 5, type = 'INFO', id = '12345', flags = 0, size = 14, dirty = false, partial = false },
  { index = 6, type = 'NPC_', id = 'rock', flags = 0x400, size = 13, dirty = false, partial = false },
}

--- The records at these 0-based indices, with the columns asked for.
local function records(indices: { number }, columns: { string }?): { Row }
  local rows = {}
  for _, index in indices do
    local row: Row = {}
    for _, name in columns or RecordColumns do
      row[name] = Records[index + 1][name]
    end

    table.insert(rows, row)
  end

  return rows
end

suite.describe('tes3.records', function()
  local provider: tes3Tables.Provider

  suite.beforeEach(function() provider = tes3Tables.provider(plugin()) end)

  suite.it('lists its columns', function() expect(provider.columns).toEqual(RecordColumns) end)

  suite.it('hands over every record, with every column, at once and one at a time', function()
    local scanned = provider.scan(request(RecordColumns))
    expect(scanned._jessqlScan).toBe 'v1'
    expect(scanned.rows).toEqual(Records)
    expect(claims(scanned)).toBe 'where constraints'

    local iterator = provider.iterate(request(RecordColumns))
    expect(iterator._jessqlIter).toBe 'v1'
    expect(claims(iterator)).toBe 'where constraints'
    expect(iterator.next()).toEqual(Records[1])
    expect(iterator.next()).toEqual(Records[2])
    expect(drain(iterator)).toEqual { Records[3], Records[4], Records[5], Records[6], Records[7] }
    expect(iterator.next()).toBeNil()
    expect(iterator.next()).toBeNil()
  end)

  suite.it('reads no further into the plugin than the rows it is asked for', function()
    local opened = plugin()
    local read = 0
    local counting = setmetatable({}, {
      __index = function(_: unknown, name: string): unknown
        local method = (opened :: any)[name]
        if type(method) ~= 'function' then return method end

        return function(_: unknown, ...: unknown): ...unknown
          if name ~= 'count' then
            read += 1
          end

          return method(opened, ...)
        end
      end,
    })
    local iterator = tes3Tables.provider((counting :: unknown) :: tes3.Plugin).iterate(
      request({ 'index', 'type' }, { where('type', '=', 'STAT') }, { orderBy = by('index', true) })
    )
    expect(read).toBe(0)
    expect(iterator.next()).toEqual { index = 3, type = 'STAT' }
    local afterOne = read
    expect(afterOne > 0).toBe(true)
    expect(iterator.next()).toEqual { index = 1, type = 'STAT' }
    expect(read > afterOne).toBe(true)
    expect(read <= afterOne * 3).toBe(true)
  end)

  suite.it('fills only the columns asked for, and none when none are', function()
    local all = { 0, 1, 2, 3, 4, 5, 6 }
    expect(provider.scan(request { 'type' }).rows).toEqual(records(all, { 'type' }))
    expect(provider.scan(request { 'id', 'dirty' }).rows).toEqual(records(all, { 'id', 'dirty' }))
    expect(provider.scan(request { 'partial', 'size', 'flags', 'index' }).rows).toEqual(
      records(all, { 'partial', 'size', 'flags', 'index' })
    )

    expect(provider.scan(request {}).rows).toEqual(records(all, {}))
    expect(provider.scan(({} :: unknown) :: Request).rows).toEqual(records(all, {}))
    expect(provider.scan(request { 'id', 'bogus', 'name', 'index' }).rows).toEqual(records(all, { 'id', 'index' }))
    expect(drain(provider.iterate(request { 'path', 'size' }))).toEqual(records(all, { 'size' }))
  end)

  suite.it('goes straight to an index', function()
    local third = provider.scan(request(RecordColumns, { where('index', '=', 2) }))
    expect(third.rows).toEqual(records { 2 })
    expect(claims(third)).toBe 'where constraints'

    for _, outside in { 7, -1, 1e9 } do
      expect(provider.scan(request(RecordColumns, { where('index', '=', outside) })).rows).toEqual {}
      expect(provider.iterate(request(RecordColumns, { where('index', '=', outside) })).next()).toBeNil()
    end

    local once = provider.iterate(request({ 'index', 'id' }, { where('index', '=', 4) }))
    expect(once.next()).toEqual { index = 4, id = 'startup' }
    expect(once.next()).toBeNil()

    local other = provider.scan(request(RecordColumns, { where('index', '=', 2), where('type', '=', 'STAT') }))
    expect(other.rows).toEqual {}
    expect(claims(other)).toBe 'where constraints'

    local same = provider.scan(request({ 'index' }, { where('type', '=', 'NPC_'), where('index', '=', 2) }))
    expect(same.rows).toEqual { { index = 2 } }
  end)

  suite.it('finds no record at an index that is no whole number, and leaves saying so to the engine', function()
    for _, between in { 1.5, -0.5, 1 / 0, 0 / 0 } do
      local scanned = provider.scan(request(RecordColumns, { where('index', '=', between) }))
      expect(scanned.rows).toEqual {}
      expect(claims(scanned)).toBe ''
      expect(provider.iterate(request(RecordColumns, { where('index', '=', between) })).next()).toBeNil()
    end

    local db = sql.new { tes3 = plugin() }
    expect(db:query('SELECT index FROM tes3.records WHERE index = 1.5').rows).toEqual {}
    expect(db:query('SELECT index FROM tes3.records WHERE index = ?', { 2.5 }).rows).toEqual {}
    expect(db:query('SELECT index FROM tes3.records WHERE index = 2.0').rows).toEqual { { index = 2 } }
  end)

  suite.it('holds a record to each column it is asked to equal', function()
    local function matching(...: Constraint): { unknown }
      local scanned = provider.scan(request({ 'index' }, { ... }))
      expect(claims(scanned)).toBe 'where constraints'
      expect(drain(provider.iterate(request({ 'index' }, { ... })))).toEqual(scanned.rows)
      return column(scanned.rows, 'index')
    end

    expect(matching(where('type', '=', 'STAT'))).toEqual { 1, 3 }
    expect(matching(where('type', '=', 'stat'))).toEqual {}
    expect(matching(where('type', '=', 'STA'))).toEqual {}
    expect(matching(where('id', '=', 'rock'))).toEqual { 1, 6 }
    expect(matching(where('id', '=', 'Rock'))).toEqual {}
    expect(matching(where('id', '=', '12345'))).toEqual { 5 }
    expect(matching(where('id', '=', ''))).toEqual {}
    expect(matching(where('flags', '=', 0x400))).toEqual { 1, 6 }
    expect(matching(where('size', '=', 13))).toEqual { 1, 6 }
    expect(matching(where('dirty', '=', true))).toEqual { 3 }
    expect(matching(where('dirty', '=', false))).toEqual { 0, 1, 2, 4, 5, 6 }
    expect(matching(where('partial', '=', false))).toEqual { 0, 1, 2, 3, 4, 5, 6 }
    expect(matching(where('partial', '=', true))).toEqual {}
    expect(matching(where('flags', '=', 0x400), where('type', '=', 'NPC_'))).toEqual { 6 }
    expect(matching(where('size', '=', 13), where('flags', '=', 0), where('dirty', '=', false))).toEqual {}
    expect(matching(where('type', '=', 'STAT'), where('id', '=', 'oak'))).toEqual { 3 }
    expect(matching(where('id', '=', 'rock'), where('type', '=', 'NPC_'))).toEqual { 6 }
    expect(matching(where('type', '=', 'STAT'), where('id', '=', 'fargoth'))).toEqual {}
    expect(matching(where('type', '=', 'NPC_'), where('id', '=', 'rock'), where('flags', '=', 0))).toEqual {}
  end)

  suite.it('finds every record of a type and id, and none of a type that is no tag', function()
    local twice = tes3.open(
      record('STAT', subrecord('NAME', 'rock\0'))
        .. record('NPC_', subrecord('NAME', 'rock\0'))
        .. record('STAT', subrecord('NAME', 'tree\0'))
        .. record('STAT', subrecord('NAME', 'rock\0'), 0x400)
    )
    local both = { where('type', '=', 'STAT'), where('id', '=', 'rock') }
    local scanned = tes3Tables.provider(twice).scan(request({ 'index', 'flags' }, both))
    expect(scanned.rows).toEqual { { index = 0, flags = 0 }, { index = 3, flags = 0x400 } }
    expect(claims(scanned)).toBe 'where constraints'

    for _, tag in { 'STA', 'STATS', '' } do
      local none = provider.scan(request({ 'index' }, { where('type', '=', tag), where('id', '=', 'rock') }))
      expect(none.rows).toEqual {}
      expect(claims(none)).toBe 'where constraints'
    end

    local db = sql.new { tes3 = twice }
    expect(db:query('SELECT index FROM tes3.records WHERE type = \'STAT\' AND id = \'rock\'').rows).toEqual {
      { index = 0 },
      { index = 3 },
    }

    expect(db:query('SELECT COUNT(*) AS records FROM tes3.records WHERE id = ? AND type = ?', { 'rock', 'STAT' }).rows).toEqual {
      { records = 2 },
    }

    expect(db:query('SELECT index FROM tes3.records WHERE type = \'STA\' AND id = \'rock\'').rows).toEqual {}
  end)

  suite.it('holds an id to the text it reads as, whatever bytes spell it', function()
    local function ids(opened: tes3.Plugin, id: string, columns: { string }?): { Row }
      return tes3Tables.provider(opened).scan(request(columns or { 'index' }, { where('id', '=', id) })).rows
    end

    local opened = plugin()
    expect(ids(opened, 'startup', { 'index', 'type', 'id' })).toEqual { { index = 4, type = 'SCPT', id = 'startup' } }
    expect(ids(opened, 'fargoth', { 'id', 'size' })).toEqual { { id = 'fargoth', size = 16 } }

    for _, near in { 'fargot', 'fargoth ', 'fargoth\0', 'fargotH', 'targoth', 'roc\0', '\0', 'startup\0\0' } do
      expect(ids(opened, near)).toEqual {}
    end

    -- A byte past ASCII reads as its character in the plugin's code page, here Windows-1252.
    local accented = tes3.open(
      record('STAT', subrecord('NAME', 'caf\233\0'))
        .. record('STAT', subrecord('NAME', 'cafe\0'))
        .. record('STAT', subrecord('NAME', 'caf\0\233\0'))
        .. record('STAT', subrecord('NAME', ''))
        .. record('STAT', subrecord('DATA', 'cafe\0'))
    )
    expect(ids(accented, 'caf\u{e9}', { 'index', 'id' })).toEqual { { index = 0, id = 'caf\u{e9}' } }
    expect(ids(accented, 'caf\233')).toEqual {}
    expect(ids(accented, 'cafe')).toEqual { { index = 1 } }
    expect(ids(accented, 'caf')).toEqual { { index = 2 } }
    expect(ids(accented, '', { 'index', 'id' })).toEqual { { index = 3, id = '' } }

    -- A save's ids are typed: a string after its kind byte, or an exterior cell's grid.
    local save = tes3.open(
      record('NPC_', subrecord('NAME', '\2rock'))
        .. record('CELL', subrecord('NAME', '\6' .. string.pack('<i4i4', -2, -9)))
        .. record('STAT', subrecord('NAME', '#-2 -9\0')),
      { profile = 'omwsave' }
    )
    expect(ids(save, 'rock', { 'index', 'id' })).toEqual { { index = 0, id = 'rock' } }
    expect(ids(save, '\2rock')).toEqual {}
    expect(ids(save, '#-2 -9', { 'index', 'type' })).toEqual {
      { index = 1, type = 'CELL' },
      { index = 2, type = 'STAT' },
    }
  end)

  suite.it('reads an id only where one is asked for or compared', function()
    local scanned = provider.scan(request({ 'type', 'id' }, { where('type', '=', 'SCPT') }))
    expect(scanned.rows).toEqual { { type = 'SCPT', id = 'startup' } }

    local header = provider.scan(request({ 'index', 'id' }, { where('type', '=', 'TES3') }))
    expect(header.rows).toEqual { { index = 0 } }
  end)

  suite.it('leaves every other constraint to the engine', function()
    local others = {
      where('type', '!=', 'STAT'),
      where('type', 'LIKE', 'ST%'),
      where('type', '=', 5),
      where('id', '=', 5),
      where('id', '<', 'm'),
      where('index', '=', '2'),
      where('index', '>', 2),
      where('flags', '=', '0'),
      where('size', '>=', 13),
      where('dirty', '=', 1),
      where('partial', '=', 'no'),
      where('bogus', '=', 1),
    }

    for _, other in others do
      local scanned = provider.scan(request({ 'index' }, { other }, { limit = 1 }))
      expect(column(scanned.rows, 'index')).toEqual { 0, 1, 2, 3, 4, 5, 6 }
      expect(claims(scanned)).toBe ''
    end

    local narrowed = provider.scan(request({ 'index' }, { where('type', '=', 'STAT'), where('size', '>', 12) }))
    expect(column(narrowed.rows, 'index')).toEqual { 1, 3 }
    expect(claims(narrowed)).toBe ''
  end)

  suite.it('leaves a column held to two values to the engine', function()
    local pairs = {
      { where('type', '=', 'STAT'), where('type', '=', 'NPC_') },
      { where('id', '=', 'rock'), where('id', '=', 'oak') },
      { where('index', '=', 1), where('index', '=', 2) },
      { where('flags', '=', 0x400), where('flags', '=', 0) },
      { where('size', '=', 13), where('type', '=', 'STAT'), where('size', '=', 12) },
      { where('dirty', '=', false), where('dirty', '=', true) },
      { where('partial', '=', false), where('partial', '=', false) },
    }

    for _, pair in pairs do
      expect(claims(provider.scan(request({ 'index' }, pair)))).toBe ''
    end

    local db = sql.new { tes3 = plugin() }
    expect(db:query('SELECT index FROM tes3.records WHERE type = \'STAT\' AND type = \'NPC_\'').rows).toEqual {}
    expect(db:query('SELECT index FROM tes3.records WHERE index = 1 AND index = 2').rows).toEqual {}
    expect(db:query('SELECT index FROM tes3.records WHERE id = ? AND id = ?', { 'rock', 'oak' }).rows).toEqual {}
    expect(db:query('SELECT index FROM tes3.records WHERE flags = 1024 AND type = \'NPC_\' AND flags = 0').rows).toEqual {}
    expect(db:query('SELECT index FROM tes3.records WHERE dirty = true AND dirty = true').rows).toEqual { { index = 3 } }
  end)

  suite.it('orders by index alone, and stops at a limit only in an order it keeps', function()
    local last = provider.scan(request({ 'index' }, nil, { limitHint = 2, orderBy = by('index', true) }))
    expect(column(last.rows, 'index')).toEqual { 6, 5 }
    expect(claims(last)).toBe 'where constraints ordered limited'

    local first = provider.scan(request({ 'index' }, nil, { limitHint = 2, orderBy = by 'index' }))
    expect(column(first.rows, 'index')).toEqual { 0, 1 }

    local falling = provider.scan(request({ 'index' }, { where('type', '=', 'NPC_') }, { orderBy = by('index', true) }))
    expect(column(falling.rows, 'index')).toEqual { 6, 2 }
    expect(claims(falling)).toBe 'where constraints ordered'

    local lazy = provider.iterate(request({ 'index' }, { where('type', '=', 'NPC_') }, { orderBy = by('index', true) }))
    expect(claims(lazy)).toBe 'where constraints ordered'
    expect(column(drain(lazy), 'index')).toEqual { 6, 2 }
    expect(claims(provider.iterate(request({ 'index' }, nil, { orderBy = by 'type' })))).toBe 'where constraints'
    expect(claims(provider.iterate(request({ 'index' }, nil, { partialWhere = true })))).toBe 'constraints'

    local typed = provider.scan(request({ 'index' }, nil, { limitHint = 2, orderBy = by 'type' }))
    expect(#typed.rows).toBe(7)
    expect(claims(typed)).toBe 'where constraints'

    local unordered = provider.scan(request({ 'index' }, { where('flags', '=', 0) }, { limit = 3, limitHint = 3 }))
    expect(column(unordered.rows, 'index')).toEqual { 0, 2, 3 }
    expect(claims(unordered)).toBe 'where constraints limited'

    local hinted = provider.scan(request({ 'index' }, nil, { limit = 5, limitHint = 1 }))
    expect(column(hinted.rows, 'index')).toEqual { 0 }
  end)

  suite.it('stops at a limit only when the whole WHERE is its own', function()
    local some = provider.scan(request({ 'index' }, nil, { limit = 2, limitHint = 2, partialWhere = true }))
    expect(#some.rows).toBe(7)
    expect(claims(some)).toBe 'constraints'
  end)

  suite.it('says which records a filtered open left in part', function()
    local header = subrecord('NAME', 'cell\0') .. subrecord('DATA', string.rep('\0', 12))
    local references = subrecord('FRMR', u32(1)) .. subrecord('NAME', 'ref\0')
    local opened = tes3.open(record('STAT', subrecord('NAME', 'rock\0')) .. record('CELL', header .. references), {
      keep = function(tag: string): tes3.Keep
        return if tag == 'CELL' then { references = false } else 'whole'
      end,
    })
    local cells = tes3Tables.provider(opened)
    expect(cells.scan(request { 'type', 'id', 'partial' }).rows).toEqual {
      { type = 'STAT', id = 'rock', partial = false },
      { type = 'CELL', id = 'cell', partial = true },
    }

    local part = cells.scan(request({ 'index' }, { where('partial', '=', true) }))
    expect(part.rows).toEqual { { index = 1 } }
  end)

  suite.it('answers queries', function()
    local db = sql.new { tes3 = plugin() }
    expect(db:query('SELECT * FROM tes3.records').rows).toEqual(Records)
    expect(db:query('SELECT type, COUNT(*) AS records FROM tes3.records GROUP BY type ORDER BY type').rows).toEqual {
      { type = 'INFO', records = 1 },
      { type = 'NPC_', records = 2 },
      { type = 'SCPT', records = 1 },
      { type = 'STAT', records = 2 },
      { type = 'TES3', records = 1 },
    }

    expect(db:query('SELECT index, id FROM tes3.records WHERE type = ? ORDER BY index DESC LIMIT 1', { 'STAT' }).rows).toEqual {
      { index = 3, id = 'oak' },
    }

    expect(db:query('SELECT id FROM tes3.records WHERE size > 13 AND size < 100 AND dirty = false ORDER BY id').rows).toEqual {
      { id = '12345' },
      { id = 'fargoth' },
      { id = 'startup' },
    }
  end)
end)

--[[ A NIF ]]

local NifRecordColumns = { 'index', 'type', 'name', 'decoded' }

local NodeColumns = {
  'index',
  'source',
  'record_type',
  'name',
  'parent',
  'subtree_end',
  'billboard',
  'visibility',
  'local_x',
  'local_y',
  'local_z',
  'world_x',
  'world_y',
  'world_z',
}

--- A root with a moved child that holds a moved shape, and a hidden billboard beside the child.
local function model(): nifModule.Nif
  local file = nifModule.new()
  local root = file:insert { type = 'NiNode', name = 'Root' }
  local child = file:insert { type = 'NiNode', name = 'Child', translation = vector.create(1, 2, 3) }
  local shape = file:insert { type = 'NiTriShape', name = 'Shape', translation = vector.create(10, 0, -1) }
  file:insert { type = 'NiTriShapeData' }
  local billboard = file:insert { type = 'NiBillboardNode', name = 'Child', flags = 1 }
  file:attach(root, child)
  file:attach(child, shape)
  file:attach(root, billboard)
  file.roots = { root }
  return file
end

--- `model`'s records as a built file has them, every one decoded.
local Built: { Row } = {
  { index = 0, type = 'NiNode', name = 'Root', decoded = true },
  { index = 1, type = 'NiNode', name = 'Child', decoded = true },
  { index = 2, type = 'NiTriShape', name = 'Shape', decoded = true },
  { index = 3, type = 'NiTriShapeData', decoded = true },
  { index = 4, type = 'NiBillboardNode', name = 'Child', decoded = true },
}

--- The scene's nodes: the records that are drawn objects, in the order the graph reaches them.
local Nodes: { Row } = {
  {
    index = 0,
    source = 0,
    record_type = 'NiNode',
    name = 'Root',
    subtree_end = 4,
    billboard = false,
    visibility = 'Visible',
    local_x = 0,
    local_y = 0,
    local_z = 0,
    world_x = 0,
    world_y = 0,
    world_z = 0,
  },
  {
    index = 1,
    source = 1,
    record_type = 'NiNode',
    name = 'Child',
    parent = 0,
    subtree_end = 3,
    billboard = false,
    visibility = 'Visible',
    local_x = 1,
    local_y = 2,
    local_z = 3,
    world_x = 1,
    world_y = 2,
    world_z = 3,
  },
  {
    index = 2,
    source = 2,
    record_type = 'NiTriShape',
    name = 'Shape',
    parent = 1,
    subtree_end = 3,
    billboard = false,
    visibility = 'Visible',
    local_x = 10,
    local_y = 0,
    local_z = -1,
    world_x = 11,
    world_y = 2,
    world_z = 2,
  },
  {
    index = 3,
    source = 4,
    record_type = 'NiBillboardNode',
    name = 'Child',
    parent = 0,
    subtree_end = 4,
    billboard = true,
    visibility = 'Hidden',
    local_x = 0,
    local_y = 0,
    local_z = 0,
    world_x = 0,
    world_y = 0,
    world_z = 0,
  },
}

--- Some of `rows`, by 0-based index, with the columns asked for.
local function pick(rows: { Row }, indices: { number }, columns: { string }): { Row }
  local out = {}
  for _, index in indices do
    local row: Row = {}
    for _, name in columns do
      row[name] = rows[index + 1][name]
    end

    table.insert(out, row)
  end

  return out
end

suite.describe('nif.records', function()
  local file: nifModule.Nif
  local provider: nifTables.RecordsProvider

  suite.beforeEach(function()
    file = model()
    provider = nifTables.recordsProvider(file)
  end)

  suite.it('lists its columns', function() expect(provider.columns).toEqual(NifRecordColumns) end)

  suite.it('hands over every record, at once and one at a time', function()
    local scanned = provider.scan(request(NifRecordColumns))
    expect(scanned._jessqlScan).toBe 'v1'
    expect(scanned.rows).toEqual(Built)
    expect(claims(scanned)).toBe 'where constraints'

    local iterator = provider.iterate(request(NifRecordColumns))
    expect(iterator._jessqlIter).toBe 'v1'
    expect(claims(iterator)).toBe 'where constraints'
    expect(iterator.next()).toEqual(Built[1])
    expect(iterator.next()).toEqual(Built[2])
    expect(drain(iterator)).toEqual { Built[3], Built[4], Built[5] }
    expect(iterator.next()).toBeNil()
    expect(iterator.next()).toBeNil()
  end)

  suite.it('hands each row over as a table of its own', function()
    local iterator = provider.iterate(request(NifRecordColumns))
    local first, second = iterator.next(), iterator.next()
    expect(first).toEqual(Built[1])
    expect(second).toEqual(Built[2])
  end)

  suite.it('fills only the columns asked for, and none when none are', function()
    local all = { 0, 1, 2, 3, 4 }
    expect(provider.scan(request { 'type' }).rows).toEqual(pick(Built, all, { 'type' }))
    expect(provider.scan(request { 'name', 'index' }).rows).toEqual(pick(Built, all, { 'name', 'index' }))
    expect(provider.scan(request { 'decoded' }).rows).toEqual(pick(Built, all, { 'decoded' }))
    expect(provider.scan(request {}).rows).toEqual(pick(Built, all, {}))
    expect(drain(provider.iterate(({} :: unknown) :: Request))).toEqual(pick(Built, all, {}))
    expect(provider.scan(request { 'name', 'bogus', 'id', 'index' }).rows).toEqual(pick(Built, all, { 'name', 'index' }))
    expect(drain(provider.iterate(request { 'source', 'type' }))).toEqual(pick(Built, all, { 'type' }))
  end)

  suite.it('goes straight to an index', function()
    local third = provider.scan(request(NifRecordColumns, { where('index', '=', 2) }))
    expect(third.rows).toEqual { Built[3] }
    expect(claims(third)).toBe 'where constraints'

    for _, outside in { 5, -1, 1e9 } do
      local iterator = provider.iterate(request(NifRecordColumns, { where('index', '=', outside) }))
      expect(iterator.next()).toBeNil()
      expect(iterator.next()).toBeNil()
      expect(claims(iterator)).toBe 'where constraints'
    end

    local other = provider.scan(request(NifRecordColumns, { where('index', '=', 2), where('type', '=', 'NiNode') }))
    expect(other.rows).toEqual {}

    local once = provider.iterate(request({ 'index' }, { where('name', '=', 'Shape'), where('index', '=', 2) }))
    expect(once.next()).toEqual { index = 2 }
    expect(once.next()).toBeNil()
  end)

  suite.it('finds no record at an index that is no whole number, and leaves saying so to the engine', function()
    for _, between in { 1.5, -0.5, 1 / 0, 0 / 0 } do
      local scanned = provider.scan(request(NifRecordColumns, { where('index', '=', between) }))
      expect(scanned.rows).toEqual {}
      expect(claims(scanned)).toBe ''
      expect(provider.iterate(request(NifRecordColumns, { where('index', '=', between) })).next()).toBeNil()
    end

    local db = sql.new { nif = file }
    expect(db:query('SELECT index FROM nif.records WHERE index = 1.5').rows).toEqual {}
    expect(db:query('SELECT index FROM nif.records WHERE index = 2.0').rows).toEqual { { index = 2 } }
  end)

  suite.it('holds a record to each column it is asked to equal', function()
    local function matching(...: Constraint): { unknown }
      local scanned = provider.scan(request({ 'index' }, { ... }))
      expect(claims(scanned)).toBe 'where constraints'
      expect(drain(provider.iterate(request({ 'index' }, { ... })))).toEqual(scanned.rows)
      return column(scanned.rows, 'index')
    end

    expect(matching(where('type', '=', 'NiNode'))).toEqual { 0, 1 }
    expect(matching(where('type', '=', 'ninode'))).toEqual {}
    expect(matching(where('name', '=', 'Child'))).toEqual { 1, 4 }
    expect(matching(where('name', '=', 'child'))).toEqual {}
    expect(matching(where('name', '=', ''))).toEqual {}
    expect(matching(where('decoded', '=', true))).toEqual { 0, 1, 2, 3, 4 }
    expect(matching(where('decoded', '=', false))).toEqual {}
    expect(matching(where('name', '=', 'Child'), where('type', '=', 'NiBillboardNode'))).toEqual { 4 }
    expect(matching(where('type', '=', 'NiNode'), where('decoded', '=', true), where('name', '=', 'Root'))).toEqual { 0 }
    expect(matching(where('type', '=', 'NiTriShapeData'), where('name', '=', 'Shape'))).toEqual {}
  end)

  suite.it('leaves every other constraint to the engine', function()
    local others = {
      where('type', '!=', 'NiNode'),
      where('type', 'LIKE', 'Ni%'),
      where('type', '=', 5),
      where('name', '=', 5),
      where('name', '<', 'D'),
      where('index', '=', '2'),
      where('index', '>', 2),
      where('decoded', '=', 1),
      where('decoded', '!=', true),
      where('bogus', '=', 1),
    }

    for _, other in others do
      local scanned = provider.scan(request({ 'index' }, { other }, { limit = 1 }))
      expect(column(scanned.rows, 'index')).toEqual { 0, 1, 2, 3, 4 }
      expect(claims(scanned)).toBe ''
      expect(claims(provider.iterate(request({ 'index' }, { other })))).toBe ''
    end

    local narrowed = provider.scan(request({ 'index' }, { where('type', '=', 'NiNode'), where('index', '>', 0) }))
    expect(column(narrowed.rows, 'index')).toEqual { 0, 1 }
    expect(claims(narrowed)).toBe ''
  end)

  suite.it('leaves a column held to two values to the engine', function()
    local pairs = {
      { where('type', '=', 'NiNode'), where('type', '=', 'NiTriShape') },
      { where('name', '=', 'Child'), where('name', '=', 'Root') },
      { where('index', '=', 1), where('index', '=', 2) },
      { where('decoded', '=', true), where('type', '=', 'NiNode'), where('decoded', '=', false) },
      { where('type', '=', 'NiNode'), where('type', '=', 'NiNode') },
    }

    for _, pair in pairs do
      expect(claims(provider.scan(request({ 'index' }, pair)))).toBe ''
      expect(claims(provider.iterate(request({ 'index' }, pair)))).toBe ''
    end

    local db = sql.new { nif = file }
    expect(db:query('SELECT index FROM nif.records WHERE type = \'NiNode\' AND type = \'NiTriShape\'').rows).toEqual {}
    expect(db:query('SELECT index FROM nif.records WHERE index = 1 AND index = 2').rows).toEqual {}
    expect(db:query('SELECT index FROM nif.records WHERE name = ? AND name = ?', { 'Child', 'Root' }).rows).toEqual {}
    expect(db:query('SELECT index FROM nif.records WHERE decoded = true AND decoded = false').rows).toEqual {}
    expect(db:query('SELECT index FROM nif.records WHERE name = \'Root\' AND name = \'Root\'').rows).toEqual { { index = 0 } }
  end)

  suite.it('orders by index alone, and stops at a limit only in an order it keeps', function()
    local last = provider.scan(request({ 'index' }, nil, { limitHint = 2, orderBy = by('index', true) }))
    expect(column(last.rows, 'index')).toEqual { 4, 3 }
    expect(claims(last)).toBe 'where constraints ordered limited'

    local first = provider.scan(request({ 'index' }, nil, { limitHint = 2, orderBy = by 'index' }))
    expect(column(first.rows, 'index')).toEqual { 0, 1 }

    local falling = provider.iterate(request({ 'index' }, { where('name', '=', 'Child') }, { orderBy = by('index', true) }))
    expect(claims(falling)).toBe 'where constraints ordered'
    expect(column(drain(falling), 'index')).toEqual { 4, 1 }

    local named = provider.scan(request({ 'index' }, nil, { limitHint = 2, orderBy = by 'name' }))
    expect(#named.rows).toBe(5)
    expect(claims(named)).toBe 'where constraints'

    local unordered = provider.scan(request({ 'index' }, { where('type', '=', 'NiNode') }, { limit = 1, limitHint = 1 }))
    expect(column(unordered.rows, 'index')).toEqual { 0 }
    expect(claims(unordered)).toBe 'where constraints limited'

    local hinted = provider.scan(request({ 'index' }, nil, { limit = 4, limitHint = 1 }))
    expect(column(hinted.rows, 'index')).toEqual { 0 }

    local partial = provider.scan(request({ 'index' }, nil, { limit = 2, limitHint = 2, partialWhere = true }))
    expect(#partial.rows).toBe(5)
    expect(claims(partial)).toBe 'constraints'
  end)

  suite.it('skips a record that was removed, and sees one added since', function()
    file:remove(1)
    expect(column(provider.scan(request { 'index' }).rows, 'index')).toEqual { 0, 2, 3, 4 }
    expect(provider.scan(request({ 'index' }, { where('index', '=', 1) })).rows).toEqual {}

    local iterator = provider.iterate(request({ 'index', 'name' }, nil, { orderBy = by 'index' }))
    expect(iterator.next()).toEqual { index = 0, name = 'Root' }
    local added = file:insert { type = 'NiNode', name = 'Late' }
    expect(column(drain(iterator), 'index')).toEqual { 2, 3, 4, added }
  end)

  suite.it('reads the names of a file\'s records without decoding them', function()
    local opened = nifModule.open(file:save())
    local read = nifTables.recordsProvider(opened)
    local saved: { Row } = {
      { index = 0, type = 'NiNode', name = 'Root', decoded = false },
      { index = 1, type = 'NiNode', name = 'Child', decoded = false },
      { index = 2, type = 'NiTriShape', name = 'Shape', decoded = false },
      { index = 3, type = 'NiBillboardNode', name = 'Child', decoded = false },
    }
    expect(read.scan(request(NifRecordColumns)).rows).toEqual(saved)
    expect(column(read.scan(request({ 'index' }, { where('name', '=', 'Child') })).rows, 'index')).toEqual { 1, 3 }
    expect(read.scan(request { 'name' }).rows).toEqual(pick(saved, { 0, 1, 2, 3 }, { 'name' }))
    expect(read.scan(request(NifRecordColumns, { where('decoded', '=', true) })).rows).toEqual {}

    for index = 0, 3 do
      expect(opened:isDecoded(index)).toBe(false)
    end

    opened:record(2)
    saved[3].decoded = true
    expect(read.scan(request(NifRecordColumns)).rows).toEqual(saved)
    expect(read.scan(request(NifRecordColumns, { where('decoded', '=', true) })).rows).toEqual { saved[3] }
    expect(column(read.scan(request({ 'index' }, { where('decoded', '=', false) })).rows, 'index')).toEqual { 0, 1, 3 }
  end)

  suite.it('answers queries', function()
    local db = sql.new { nif = file }
    expect(db:query('SELECT * FROM nif.records').rows).toEqual(Built)
    expect(db:query('SELECT index, type FROM nif.records WHERE type = \'NiNode\' ORDER BY index DESC LIMIT 1').rows).toEqual {
      { index = 1, type = 'NiNode' },
    }

    expect(db:query('SELECT name, COUNT(*) AS records FROM nif.records WHERE name != ? GROUP BY name ORDER BY records DESC, name', { '' }).rows).toEqual {
      { name = 'Child', records = 2 },
      { name = 'Root', records = 1 },
      { name = 'Shape', records = 1 },
    }

    expect(db:query('SELECT MAX(index) AS last FROM nif.records WHERE name = ?', { 'Child' }).rows).toEqual { { last = 4 } }
  end)
end)

suite.describe('nif.scene_nodes', function()
  local file: nifModule.Nif
  local provider: nifTables.SceneNodesProvider

  suite.beforeEach(function()
    file = model()
    provider = nifTables.sceneNodesProvider(file)
  end)

  suite.it('lists its columns', function() expect(provider.columns).toEqual(NodeColumns) end)

  suite.it('hands over every node, with every column, at once and one at a time', function()
    local scanned = provider.scan(request(NodeColumns))
    expect(scanned._jessqlScan).toBe 'v1'
    expect(scanned.rows).toEqual(Nodes)
    expect(claims(scanned)).toBe 'where constraints'

    local iterator = provider.iterate(request(NodeColumns))
    expect(iterator._jessqlIter).toBe 'v1'
    expect(claims(iterator)).toBe 'where constraints'
    expect(iterator.next()).toEqual(Nodes[1])
    expect(drain(iterator)).toEqual { Nodes[2], Nodes[3], Nodes[4] }
    expect(iterator.next()).toBeNil()
    expect(iterator.next()).toBeNil()
  end)

  suite.it('fills only the columns asked for, and none when none are', function()
    local all = { 0, 1, 2, 3 }
    for _, columns in { { 'name' }, { 'local_y' }, { 'world_z', 'world_x' }, { 'parent', 'local_x', 'billboard' }, {} } do
      expect(provider.scan(request(columns)).rows).toEqual(pick(Nodes, all, columns))
    end

    expect(provider.scan(({} :: unknown) :: Request).rows).toEqual(pick(Nodes, all, {}))
    expect(provider.scan(request { 'parent', 'bogus', 'type', 'world_y' }).rows).toEqual(
      pick(Nodes, all, { 'parent', 'world_y' })
    )

    expect(drain(provider.iterate(request { 'decoded', 'local_z' }))).toEqual(pick(Nodes, all, { 'local_z' }))
  end)

  suite.it('goes straight to an index', function()
    local third = provider.scan(request(NodeColumns, { where('index', '=', 2) }))
    expect(third.rows).toEqual { Nodes[3] }
    expect(claims(third)).toBe 'where constraints'

    for _, outside in { 4, -1, 1e9 } do
      expect(provider.scan(request(NodeColumns, { where('index', '=', outside) })).rows).toEqual {}
      expect(provider.iterate(request(NodeColumns, { where('index', '=', outside) })).next()).toBeNil()
    end

    local once = provider.iterate(request({ 'index', 'name' }, { where('index', '=', 3) }))
    expect(once.next()).toEqual { index = 3, name = 'Child' }
    expect(once.next()).toBeNil()

    local other = provider.scan(request(NodeColumns, { where('index', '=', 2), where('name', '=', 'Root') }))
    expect(other.rows).toEqual {}
  end)

  suite.it('finds no node at an index that is no whole number, and leaves saying so to the engine', function()
    for _, between in { 1.5, -0.5, 1 / 0, 0 / 0 } do
      local scanned = provider.scan(request(NodeColumns, { where('index', '=', between) }))
      expect(scanned.rows).toEqual {}
      expect(claims(scanned)).toBe ''
      expect(provider.iterate(request(NodeColumns, { where('index', '=', between) })).next()).toBeNil()
    end

    local db = sql.new { nif = file }
    expect(db:query('SELECT index FROM nif.scene_nodes WHERE index = 1.5').rows).toEqual {}
    expect(db:query('SELECT index FROM nif.scene_nodes WHERE index = ?', { 2.5 }).rows).toEqual {}
    expect(db:query('SELECT index FROM nif.scene_nodes WHERE index = 2.0').rows).toEqual { { index = 2 } }
  end)

  suite.it('holds a node to each column it is asked to equal', function()
    local function matching(...: Constraint): { unknown }
      local scanned = provider.scan(request({ 'index' }, { ... }))
      expect(claims(scanned)).toBe 'where constraints'
      expect(drain(provider.iterate(request({ 'index' }, { ... })))).toEqual(scanned.rows)
      return column(scanned.rows, 'index')
    end

    expect(matching(where('source', '=', 4))).toEqual { 3 }
    expect(matching(where('source', '=', 3))).toEqual {}
    expect(matching(where('record_type', '=', 'NiNode'))).toEqual { 0, 1 }
    expect(matching(where('name', '=', 'Child'))).toEqual { 1, 3 }
    expect(matching(where('parent', '=', 0))).toEqual { 1, 3 }
    expect(matching(where('parent', '=', 3))).toEqual {}
    expect(matching(where('subtree_end', '=', 3))).toEqual { 1, 2 }
    expect(matching(where('billboard', '=', true))).toEqual { 3 }
    expect(matching(where('billboard', '=', false))).toEqual { 0, 1, 2 }
    expect(matching(where('visibility', '=', 'Hidden'))).toEqual { 3 }
    expect(matching(where('visibility', '=', 'Visible'))).toEqual { 0, 1, 2 }
    expect(matching(where('name', '=', 'Child'), where('billboard', '=', false))).toEqual { 1 }
    expect(matching(where('parent', '=', 0), where('subtree_end', '=', 4), where('source', '=', 4))).toEqual { 3 }
  end)

  suite.it('leaves every other constraint to the engine', function()
    local others = {
      where('record_type', '!=', 'NiNode'),
      where('name', 'LIKE', 'Ch%'),
      where('name', '=', 5),
      where('visibility', '=', true),
      where('index', '=', '2'),
      where('index', '>', 2),
      where('source', '=', '4'),
      where('parent', '<', 1),
      where('subtree_end', '=', false),
      where('billboard', '=', 1),
      where('local_x', '=', 1),
      where('world_z', '=', 2),
      where('bogus', '=', 1),
    }

    for _, other in others do
      local scanned = provider.scan(request({ 'index' }, { other }, { limit = 1 }))
      expect(column(scanned.rows, 'index')).toEqual { 0, 1, 2, 3 }
      expect(claims(scanned)).toBe ''
    end

    local narrowed = provider.scan(request({ 'index' }, { where('name', '=', 'Child'), where('world_x', '=', 1) }))
    expect(column(narrowed.rows, 'index')).toEqual { 1, 3 }
    expect(claims(narrowed)).toBe ''
  end)

  suite.it('leaves a column held to two values to the engine', function()
    local pairs = {
      { where('record_type', '=', 'NiNode'), where('record_type', '=', 'NiTriShape') },
      { where('name', '=', 'Child'), where('name', '=', 'Root') },
      { where('index', '=', 1), where('index', '=', 2) },
      { where('source', '=', 1), where('source', '=', 4) },
      { where('parent', '=', 0), where('billboard', '=', true), where('parent', '=', 1) },
      { where('subtree_end', '=', 3), where('subtree_end', '=', 4) },
      { where('billboard', '=', true), where('billboard', '=', false) },
      { where('visibility', '=', 'Hidden'), where('visibility', '=', 'Hidden') },
    }

    for _, pair in pairs do
      expect(claims(provider.scan(request({ 'index' }, pair)))).toBe ''
    end

    local db = sql.new { nif = file }
    expect(db:query('SELECT index FROM nif.scene_nodes WHERE name = \'Child\' AND name = \'Root\'').rows).toEqual {}
    expect(db:query('SELECT index FROM nif.scene_nodes WHERE index = 1 AND index = 2').rows).toEqual {}
    expect(db:query('SELECT index FROM nif.scene_nodes WHERE parent = ? AND parent = ?', { 0, 1 }).rows).toEqual {}
    expect(db:query('SELECT index FROM nif.scene_nodes WHERE billboard = true AND billboard = false').rows).toEqual {}
    expect(db:query('SELECT index FROM nif.scene_nodes WHERE source = 4 AND source = 4').rows).toEqual { { index = 3 } }
  end)

  suite.it('orders by index alone, and stops at a limit only in an order it keeps', function()
    local last = provider.scan(request({ 'index' }, nil, { limitHint = 2, orderBy = by('index', true) }))
    expect(column(last.rows, 'index')).toEqual { 3, 2 }
    expect(claims(last)).toBe 'where constraints ordered limited'

    local first = provider.scan(request({ 'index' }, nil, { limitHint = 2, orderBy = by 'index' }))
    expect(column(first.rows, 'index')).toEqual { 0, 1 }

    local falling = provider.scan(request({ 'index' }, { where('name', '=', 'Child') }, { orderBy = by('index', true) }))
    expect(column(falling.rows, 'index')).toEqual { 3, 1 }
    expect(claims(falling)).toBe 'where constraints ordered'

    local lazy = provider.iterate(request({ 'index' }, { where('name', '=', 'Child') }, { orderBy = by('index', true) }))
    expect(claims(lazy)).toBe 'where constraints ordered'
    expect(column(drain(lazy), 'index')).toEqual { 3, 1 }
    expect(claims(provider.iterate(request({ 'index' }, nil, { orderBy = by 'name' })))).toBe 'where constraints'
    expect(claims(provider.iterate(request({ 'index' }, nil, { partialWhere = true })))).toBe 'constraints'

    local named = provider.scan(request({ 'index' }, nil, { limitHint = 2, orderBy = by 'name' }))
    expect(#named.rows).toBe(4)
    expect(claims(named)).toBe 'where constraints'

    local unordered = provider.scan(request({ 'index' }, { where('parent', '=', 0) }, { limit = 1, limitHint = 1 }))
    expect(column(unordered.rows, 'index')).toEqual { 1 }
    expect(claims(unordered)).toBe 'where constraints limited'

    local hinted = provider.scan(request({ 'index' }, nil, { limit = 3, limitHint = 1 }))
    expect(column(hinted.rows, 'index')).toEqual { 0 }

    local partial = provider.scan(request({ 'index' }, nil, { limit = 2, limitHint = 2, partialWhere = true }))
    expect(#partial.rows).toBe(4)
    expect(claims(partial)).toBe 'constraints'
  end)

  suite.it('builds the scene at the first scan and keeps it', function()
    local lazy = nifTables.sceneNodesProvider(file)
    file:remove(4)
    expect(#drain(lazy.iterate(request { 'index' }))).toBe(3)
    expect(#lazy.scan(request { 'index' }).rows).toBe(3)

    expect(#provider.scan(request { 'index' }).rows).toBe(3)
    file:remove(2)
    expect(#provider.scan(request { 'index' }).rows).toBe(3)
    expect(#lazy.scan(request { 'index' }).rows).toBe(3)
  end)

  suite.it('answers queries', function()
    local db = sql.new { nif = file }
    expect(db:query('SELECT * FROM nif.scene_nodes').rows).toEqual(Nodes)
    expect(db:query('SELECT name, world_x FROM nif.scene_nodes WHERE visibility = \'Visible\' ORDER BY index DESC LIMIT 2').rows).toEqual {
      { name = 'Shape', world_x = 11 },
      { name = 'Child', world_x = 1 },
    }

    expect(db:query [[SELECT n.name, r.type FROM nif.scene_nodes n
      JOIN nif.records r ON n.source = r.index WHERE n.billboard = true]].rows).toEqual {
      { name = 'Child', type = 'NiBillboardNode' },
    }
  end)
end)

suite.describe('a request that allows volatile rows', function()
  local function allowing(asked: Request): Request
    asked.allowVolatileRows = true
    return asked
  end

  --- Holds an iterator to handing `expected` over in one table, filled anew each time.
  local function reuses(iterator: nifTables.Iterator, expected: { Row })
    expect(iterator.volatileRows).toBe(true)
    local first = iterator.next()
    expect(first).toEqual(expected[1])
    for position = 2, #expected do
      local row = iterator.next()
      expect(row).toBe(first)
      expect(row).toEqual(expected[position])
    end

    expect(iterator.next()).toBeNil()
  end

  --- Holds rows to being `expected`, each a table of its own.
  local function apart(rows: engine.SourceRows, expected: { Row })
    expect(rows).toEqual(expected)
    local seen: { [engine.SourceRow]: boolean } = {}
    for _, row in rows do
      expect(seen[row]).toBeNil()
      seen[row] = true
    end
  end

  suite.it('is handed a plugin\'s records in one row, with the cells of each and no other', function()
    local provider = tes3Tables.provider(plugin())
    local falling = { Records[7], Records[6], Records[5], Records[4], Records[3], Records[2], Records[1] }
    reuses(provider.iterate(allowing(request(RecordColumns, nil, { orderBy = by('index', true) }))), falling)
    reuses(provider.iterate(allowing(request(RecordColumns, { where('type', '=', 'STAT') }))), records { 1, 3 })

    local kept = provider.iterate(request(RecordColumns))
    expect(kept.volatileRows).toBe(false)
    apart(drain(kept), Records)
    apart(provider.scan(allowing(request(RecordColumns))).rows, Records)
  end)

  suite.it('is handed a NIF\'s records and its scene\'s nodes in one row each', function()
    local file = model()
    local records, nodes = nifTables.recordsProvider(file), nifTables.sceneNodesProvider(file)
    reuses(records.iterate(allowing(request(NifRecordColumns))), Built)
    reuses(
      nodes.iterate(allowing(request(NodeColumns, nil, { orderBy = by('index', true) }))),
      { Nodes[4], Nodes[3], Nodes[2], Nodes[1] }
    )

    expect(records.iterate(request(NifRecordColumns)).volatileRows).toBe(false)
    expect(nodes.iterate(request(NodeColumns)).volatileRows).toBe(false)
    apart(drain(records.iterate(request(NifRecordColumns))), Built)
    apart(drain(nodes.iterate(request(NodeColumns))), Nodes)
    apart(records.scan(allowing(request(NifRecordColumns))).rows, Built)
    apart(nodes.scan(allowing(request(NodeColumns))).rows, Nodes)
  end)

  suite.it('is handed a VFS\'s files in one row, and a looked-up stem\'s in a row each', function()
    for _, lazy in { false, true } do
      local provider = vfsTables.provider(stand(lazy).vfs)
      reuses(provider.iterate(allowing(request(FileColumns))), fileRows(allKeys(), FileColumns))
      reuses(
        provider.iterate(allowing(request(KeyColumns, { where('path', 'LIKE', 'meshes/%') }))),
        fileRows({ 'meshes/x/rock.nif', 'meshes/x/tree.nif', 'meshes/y/rock.kf', 'meshes/y/rock.nif' }, KeyColumns)
      )

      expect(provider.iterate(request(FileColumns)).volatileRows).toBe(false)
      apart(drain(provider.iterate(request(FileColumns))), fileRows(allKeys(), FileColumns))
      apart(provider.scan(allowing(request(FileColumns))).rows, fileRows(allKeys(), FileColumns))

      local rocks = provider.lookup('stem', 'rock', allowing(request(FileColumns)))
      assert(rocks)
      apart(rocks.rows, fileRows({ 'meshes/x/rock.nif', 'meshes/y/rock.kf', 'meshes/y/rock.nif' }, FileColumns))
    end
  end)
end)

suite.describe('a limit past the rows there are', function()
  local huge = { 100000000, 4000000000, 2 ^ 53 }

  suite.it('makes room for no more rows than a VFS lists', function()
    for _, lazy in { false, true } do
      local provider = vfsTables.provider(stand(lazy).vfs)
      for _, limit in huge do
        local keys = provider.scan(request({ 'path' }, nil, { limit = limit, limitHint = limit }))
        expect(#keys.rows).toBe(#Listings)
        expect(claims(keys)).toBe 'where constraints limited'

        local under = provider.scan(
          request(FileColumns, { where('path', 'LIKE', 'meshes/%') }, { limit = limit, limitHint = limit })
        )
        expect(#under.rows).toBe(4)
      end
    end
  end)

  suite.it('makes room for no more rows than a plugin or a NIF holds', function()
    local file = model()
    local scans = {
      tes3Tables.provider(plugin()).scan,
      nifTables.recordsProvider(file).scan,
      nifTables.sceneNodesProvider(file).scan,
    }

    for position, scan in scans do
      for _, limit in huge do
        local scanned = scan(request({ 'index' }, nil, { limit = limit, limitHint = limit }))
        expect(#scanned.rows).toBe(({ 7, 5, 4 })[position])
        expect(claims(scanned)).toBe 'where constraints limited'
      end
    end

    local db = sql.new { tes3 = plugin(), nif = file }
    expect(#db:query('SELECT index FROM tes3.records LIMIT 4000000000').rows).toBe(7)
    expect(#db:query('SELECT index FROM nif.records LIMIT 4000000000').rows).toBe(5)
    expect(#db:query('SELECT index FROM nif.scene_nodes LIMIT 4000000000').rows).toBe(4)
    expect(#db:query('SELECT index FROM nif.scene_nodes ORDER BY index DESC LIMIT 100000000').rows).toBe(4)
  end)
end)

suite.describe('a database', function()
  local function names(db: sql.Database): { string }
    local out = {}
    for _, info in db:tables() do
      table.insert(out, info.name)
    end

    table.sort(out)
    return out
  end

  suite.it('holds the tables of what it is given, under their own names or the ones asked for', function()
    local files = stand(true)
    expect(names(sql.new())).toEqual {}
    expect(names(sql.new {})).toEqual {}
    expect(names(sql.new { vfs = files.vfs })).toEqual { 'vfs.files' }
    expect(names(sql.new { tes3 = plugin() })).toEqual { 'tes3.records' }
    expect(names(sql.new { nif = model() })).toEqual { 'nif.records', 'nif.scene_nodes' }
    expect(names(sql.new { vfs = files.vfs, tes3 = plugin(), nif = model() })).toEqual {
      'nif.records',
      'nif.scene_nodes',
      'tes3.records',
      'vfs.files',
    }

    local db = engine.new()
    expect(sql.attach(db, { nif = model() })).toBe(db)
    expect(sql.registerVfs(db, files.vfs, 'files')).toBe(db)
    expect(sql.registerVfs(db, files.vfs)).toBe(db)
    expect(sql.registerTes3(db, plugin(), 'records')).toBe(db)
    expect(sql.registerTes3(db, plugin())).toBe(db)
    expect(sql.registerNif(db, model(), 'blocks', 'nodes')).toBe(db)
    expect(sql.registerNif(db, model(), 'blocks.only')).toBe(db)
    expect(names(db)).toEqual {
      'blocks',
      'blocks.only',
      'files',
      'nif.records',
      'nif.scene_nodes',
      'nodes',
      'records',
      'tes3.records',
      'vfs.files',
    }
  end)

  suite.it('joins a VFS\'s files to a NIF\'s records by stem, through the stem index', function()
    local files = stand(true)
    local file = nifModule.new()
    for _, name in { 'tree', 'rock', 'stone', 'rock' } do
      file:insert { type = 'NiNode', name = name }
    end

    local db = sql.new { vfs = files.vfs, nif = file }
    local plan = db:prepare [[SELECT f.path, n.index FROM vfs.files f
      JOIN nif.records n ON f.stem = n.name
      WHERE f.path LIKE 'meshes/%'
      ORDER BY n.index DESC LIMIT 3]]
    expect(plan.explain().joins[1].strategy).toBe 'index-left'
    expect(plan.run().rows).toEqual {
      { path = 'meshes/x/rock.nif', index = 3 },
      { path = 'meshes/y/rock.kf', index = 3 },
      { path = 'meshes/y/rock.nif', index = 3 },
    }

    local every = db:query [[SELECT f.path, n.index FROM vfs.files f
      JOIN nif.records n ON f.stem = n.name ORDER BY n.index, f.path]]
    expect(every.rows).toEqual {
      { path = 'meshes/x/tree.nif', index = 0 },
      { path = 'meshes/x/rock.nif', index = 1 },
      { path = 'meshes/y/rock.kf', index = 1 },
      { path = 'meshes/y/rock.nif', index = 1 },
      { path = 'meshes/x/rock.nif', index = 3 },
      { path = 'meshes/y/rock.kf', index = 3 },
      { path = 'meshes/y/rock.nif', index = 3 },
    }
  end)

  suite.it('joins a plugin\'s records to a NIF\'s by id and name', function()
    local file = nifModule.new()
    file:insert { type = 'NiNode', name = 'rock' }
    file:insert { type = 'NiNode', name = 'oak' }
    local db = sql.new { tes3 = plugin(), nif = file }
    local joined = db:query [[SELECT r.type, r.id, n.index FROM tes3.records r
      JOIN nif.records n ON r.id = n.name ORDER BY r.index]]
    expect(joined.rows).toEqual {
      { type = 'STAT', id = 'rock', index = 0 },
      { type = 'STAT', id = 'oak', index = 1 },
      { type = 'NPC_', id = 'rock', index = 0 },
    }
  end)
end)

return suite
