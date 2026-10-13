--!strict
--!native

local util = require('./util')

local exports = {}

--- A lazy scan, as `iterate` hands one out.
export type Iterator = util.Iterator

type Database = util.Database
type Request = util.Request
type Row = util.Row
type ScanResult = util.ScanResult

--- A file of the VFS, by the methods a row is filled from.
type File = {
  path: (self: File) -> string,
  size: (self: File) -> number,
  isLoose: (self: File) -> boolean,
  isArchive: (self: File) -> boolean,
  parentArchivePath: (self: File) -> string?,
  parentArchiveName: (self: File) -> string?,
}

--- A winning file under its key, as the VFS lists its entries.
type Entry = { key: string, file: File }

--- The VFS a `vfs.files` table reads. This package does not depend on the vfs package, so this is
--- the part of its VFS the adapter calls. A list it hands back is walked with a `for` by a scan
--- and a lookup, and read by its length and by index, one entry at a time, by `iterate`.
export type Vfs = {
  revision: (self: Vfs) -> number,
  contains: (self: Vfs, path: string) -> boolean,
  getFile: (self: Vfs, path: string) -> File?,
  keys: (self: Vfs, limit: number?, descending: boolean?) -> { string },
  entries: (self: Vfs, limit: number?, descending: boolean?) -> { Entry },
  keysStartingWith: (self: Vfs, prefix: string, limit: number?, descending: boolean?) -> { string },
  pathsStartingWith: (self: Vfs, prefix: string, limit: number?, descending: boolean?) -> { Entry },
}

--- `iterate` hands the files over one at a time, so a query that needs only so many of them asks
--- the VFS for only so many.
export type Provider = {
  columns: { string },
  indexes: { [string]: boolean },
  iterate: (request: Request) -> Iterator,
  scan: (request: Request) -> ScanResult,
  lookup: (column: string, value: unknown, request: Request) -> ScanResult?,
}

local Columns = table.freeze {
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

local function normalizedPrefix(value: string): boolean
  if string.byte(value, 1) == 47 then return false end
  if string.find(value, '\\', 1, true) or string.find(value, '//', 1, true) then return false end
  return string.find(value, '[A-Z]') == nil
end

local function logicalName(path: string): string
  for index = #path, 1, -1 do
    if string.byte(path, index) == 47 then return string.sub(path, index + 1) end
  end
  return path
end

local function logicalStem(path: string): string
  local start = 1
  for index = #path, 1, -1 do
    if string.byte(path, index) == 47 then start = index + 1; break end
  end

  for index = #path, start + 1, -1 do
    if string.byte(path, index) == 46 then return string.sub(path, start, index - 1) end
  end
  return string.sub(path, start)
end

local function pathPlan(request: Request): (string?, string?, boolean, boolean, ((string) -> boolean))
  local exact: string? = nil
  local prefix: string? = nil
  local localHandled = true
  local tests: { (string) -> boolean } = {}

  for _, constraint in request.constraints or {} do
    if constraint.column ~= 'path' or type(constraint.value) ~= 'string' then
      localHandled = false
    elseif constraint.op == '=' then
      local expected = constraint.value
      exact = exact or expected
      tests[#tests + 1] = function(value: string): boolean return value == expected end
    elseif constraint.op == 'LIKE' then
      local pattern = constraint.value
      local simple = util.likePrefix(pattern)
      if simple == nil then
        localHandled = false
      else
        tests[#tests + 1] = function(value: string): boolean
          return util.matchesSimpleLike(value, pattern) == true
        end

        if not string.find(pattern, '%', 1, true) then
          exact = exact or pattern
        elseif not prefix or #simple > #prefix then
          prefix = simple
        end
      end
    else
      localHandled = false
    end
  end

  return exact, prefix, request.whereComplete == true and localHandled, localHandled, function(value: string): boolean
    for _, test in tests do if not test(value) then return false end end
    return true
  end
end

local function makeRow(vfs: Vfs, key: string, wanted: { [string]: boolean }, file: File?): Row?
  local needsFile = wanted.physical_path or wanted.size or wanted.is_loose or wanted.is_archive
    or wanted.archive_path or wanted.archive_name
  if needsFile and not file then
    file = vfs:getFile(key)
    if not file then return nil end
  end
  local row: Row = {}
  if wanted.path then row.path = key end
  if wanted.physical_path and file then row.physical_path = file:path() end
  if wanted.name then row.name = logicalName(key) end
  if wanted.stem then row.stem = logicalStem(key) end
  if wanted.size and file then row.size = file:size() end
  if wanted.is_loose and file then row.is_loose = file:isLoose() end
  if wanted.is_archive and file then row.is_archive = file:isArchive() end
  if wanted.archive_path and file then row.archive_path = file:parentArchivePath() end
  if wanted.archive_name and file then row.archive_name = file:parentArchiveName() end
  return row
end

--- What a request asks of a VFS: the keys or entries to make rows of, the row each makes (none
--- when its path fails a constraint or its file is gone), whether the whole WHERE and the order
--- asked for are kept, how many rows are enough, and whether every constraint is applied.
local function plan(
  vfs: Vfs,
  request: Request
): ({ string } | { Entry }, (item: string | Entry) -> Row?, boolean, boolean, number?, boolean)
  local wanted = util.columns(request)
  local exact, prefix, handledWhere, handledConstraints, matchesPath = pathPlan(request)
  local ordered, descending = util.orderedBy(request, 'path')
  local limit = util.limit(request, handledWhere, ordered)
  local constraints = request.constraints or {}
  local needsFile = wanted.physical_path or wanted.size or wanted.is_loose or wanted.is_archive
    or wanted.archive_path or wanted.archive_name
  local keyOnly = not needsFile

  local candidates: { string } | { Entry }
  if exact ~= nil then
    if normalizedPrefix(exact) and exact ~= '' then
      if keyOnly then
        candidates = if vfs:contains(exact) then { exact } :: { string } else {}
      else
        local file = vfs:getFile(exact)
        candidates = if file ~= nil then { { key=exact, file=file } } :: { Entry } else {}
      end
    else
      candidates = {}
    end
  elseif prefix ~= nil then
    if normalizedPrefix(prefix) then
      candidates = if keyOnly
        then vfs:keysStartingWith(prefix, limit, descending)
        else vfs:pathsStartingWith(prefix, limit, descending)
    else
      candidates = {}
    end
  elseif #constraints == 0 and limit ~= nil then
    candidates = if keyOnly then vfs:keys(limit, descending) else vfs:entries(limit, descending)
  else
    candidates = if keyOnly then vfs:keys() else vfs:entries()
  end

  -- `keyOnly` chose what the candidates are: keys, or entries that carry their file.
  local function rowOf(item: string | Entry): Row?
    local key = if keyOnly then item :: string else (item :: Entry).key
    if not matchesPath(key) then return nil end

    return makeRow(vfs, key, wanted, if keyOnly then nil else (item :: Entry).file)
  end

  return candidates, rowOf, handledWhere, ordered, limit, handledConstraints
end

local function rowsFor(vfs: Vfs, request: Request): ScanResult
  local candidates, rowOf, handledWhere, ordered, limit, handledConstraints = plan(vfs, request)

  -- Room for the rows a limit allows, as far as there are candidates to make them of.
  local out: { Row } = if limit then table.create(math.min(limit, #candidates)) else {}
  local count = 0
  for _, item in candidates do
    local row = rowOf(item)
    if not row then continue end

    count += 1
    out[count] = row
    if limit and count >= limit then break end
  end

  return util.scanResult(out, handledWhere, ordered, limit ~= nil, handledConstraints)
end

local function fileIterator(vfs: Vfs, request: Request): Iterator
  local candidates, rowOf, handledWhere, ordered, _, handledConstraints = plan(vfs, request)
  local position, count = 0, #candidates

  local function nextRow(): Row?
    while position < count do
      position += 1
      local row = rowOf(candidates[position])
      if row then return row end
    end

    return nil
  end

  return {
    _jessqlIter = 'v1',
    next = nextRow,
    handledWhere = handledWhere,
    ordered = ordered,
    handledConstraints = handledConstraints,
  }
end

function exports.provider(vfs: Vfs): Provider
  local indexedRevision = -1
  local stemFirst: { [string]: string }, stemDuplicates: { [string]: { string } } = {}, {}

  local function ensureStemIndex()
    local revision = vfs:revision()
    if revision == indexedRevision then return end
    stemFirst = {}
    stemDuplicates = {}
    for _, key in vfs:keysStartingWith('') do
      local stem = logicalStem(key)
      local first = stemFirst[stem]
      if first == nil then
        stemFirst[stem] = key
      else
        local bucket = stemDuplicates[stem]
        if bucket == nil then bucket = { first, key }; stemDuplicates[stem] = bucket
        else bucket[#bucket+1] = key end
      end
    end
    indexedRevision = revision
  end

  local function lookup(column: string, value: unknown, request: Request): ScanResult?
    if column ~= 'stem' or type(value) ~= 'string' then return nil end
    ensureStemIndex()
    local wanted = util.columns(request)
    local _, _, handledWhere, handledConstraints, matchesPath = pathPlan(request)
    local out: { Row } = {}
    local first = stemFirst[value]
    if first ~= nil then
      local bucket = stemDuplicates[value]
      if bucket ~= nil then
        for _, key in bucket do
          if matchesPath(key) then
            local row = makeRow(vfs, key, wanted, nil)
            if row ~= nil then out[#out+1] = row end
          end
        end
      elseif matchesPath(first) then
        local row = makeRow(vfs, first, wanted, nil)
        if row ~= nil then out[1] = row end
      end
    end
    return util.scanResult(out, handledWhere, false, false, handledConstraints)
  end

  return {
    columns = Columns,
    indexes = { stem=true },
    iterate = function(request: Request): Iterator
      return fileIterator(vfs, request)
    end,
    scan = function(request: Request): ScanResult
      return rowsFor(vfs, request)
    end,
    lookup = lookup,
  }
end

function exports.register(db: Database, vfs: Vfs, name: string?): Database
  db:register(name or 'vfs.files', exports.provider(vfs))
  return db
end

return table.freeze(exports)
