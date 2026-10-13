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
--- the VFS for only so many; `count` is how many keys the VFS has, which answers a bare COUNT(*).
export type Provider = {
  columns: { string },
  count: () -> number,
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

--- Where a key's name starts, and where the dot before its extension is: 0 for a name with no
--- dot past its first byte, which has no extension. One walk back from the end finds both.
local function split(path: string): (number, number)
  local dot = 0
  for index = #path, 1, -1 do
    local byte = string.byte(path, index)
    if byte == 47 then return index + 1, if dot > index + 1 then dot else 0 end

    if byte == 46 and dot == 0 then dot = index end
  end

  return 1, if dot > 1 then dot else 0
end

--- A key's stem: its name, up to the dot before its extension.
local function logicalStem(path: string): string
  local start, dot = split(path)
  return string.sub(path, start, if dot == 0 then -1 else dot - 1)
end

--- What a request's constraints on `path` come to: the one path they name, if any; the longest
--- prefix they give, if any; whether they are the whole WHERE, and whether every constraint is
--- among them; and what holds a key to all of them, or nil when there is nothing to hold it to.
--- A path is equal to a string, or LIKE a pattern that is a path or a prefix and one `%`.
local function pathPlan(request: Request): (string?, string?, boolean, boolean, ((key: string) -> boolean)?)
  local exact: string? = nil
  local prefix: string? = nil
  local localHandled = true
  local paths: { string }, prefixes: { string } = {}, {}

  for _, constraint in request.constraints or {} do
    if constraint.column ~= 'path' or type(constraint.value) ~= 'string' then
      localHandled = false
    elseif constraint.op == '=' then
      exact = exact or constraint.value
      table.insert(paths, constraint.value)
    elseif constraint.op == 'LIKE' then
      local pattern = constraint.value
      local simple = util.likePrefix(pattern)
      if not simple then
        localHandled = false
      elseif simple == pattern then
        exact = exact or pattern
        table.insert(paths, pattern)
      else
        table.insert(prefixes, simple)
        if not prefix or #simple > #prefix then prefix = simple end
      end
    else
      localHandled = false
    end
  end

  local matches: ((key: string) -> boolean)? = nil
  if #paths + #prefixes > 0 then
    matches = function(key: string): boolean
      return all[for path in paths => key == path]
        and all[for start in prefixes => string.sub(key, 1, #start) == start]
    end
  end

  return exact, prefix, request.whereComplete == true and localHandled, localHandled, matches
end

--- What makes a request's rows, and whether a row needs its file: a function of a key, and of
--- its file when the caller has it, that answers the row, or nil when a column needs the file and
--- the VFS no longer has one under the key. `volatile` has it fill one row table for every key.
local function rowMaker(
  vfs: Vfs,
  request: Request,
  volatile: boolean
): ((key: string, given: File?) -> Row?, boolean)
  local wanted = util.columns(request)
  local template = util.template(wanted, Columns)
  local wantPath, wantPhysicalPath, wantName, wantStem = wanted.path, wanted.physical_path, wanted.name, wanted.stem
  local wantSize, wantLoose, wantArchive = wanted.size, wanted.is_loose, wanted.is_archive
  local wantArchivePath, wantArchiveName = wanted.archive_path, wanted.archive_name
  local needsFile = wantPhysicalPath or wantSize or wantLoose or wantArchive or wantArchivePath or wantArchiveName

  local function make(key: string, given: File?): Row?
    local file = given
    if needsFile and not file then
      file = vfs:getFile(key)
      if not file then return nil end
    end

    local row = if volatile then template else table.clone(template)
    if wantPath then row.path = key end
    if wantPhysicalPath and file then row.physical_path = file:path() end

    if wantName or wantStem then
      local start, dot = split(key)
      if wantName then row.name = if start == 1 then key else string.sub(key, start) end
      if wantStem then row.stem = string.sub(key, start, if dot == 0 then -1 else dot - 1) end
    end

    if wantSize and file then row.size = file:size() end
    if wantLoose and file then row.is_loose = file:isLoose() end
    if wantArchive and file then row.is_archive = file:isArchive() end
    if wantArchivePath and file then row.archive_path = file:parentArchivePath() end
    if wantArchiveName and file then row.archive_name = file:parentArchiveName() end
    return row
  end

  return make, needsFile == true
end

--- What a request asks of a VFS: the keys or entries to make rows of, the row each makes (none
--- when its path fails a constraint or its file is gone), whether the whole WHERE and the order
--- asked for are kept, how many rows are enough, and whether every constraint is applied.
--- `volatile` has every row be one table, filled anew.
local function plan(
  vfs: Vfs,
  request: Request,
  volatile: boolean
): ({ string } | { Entry }, (item: string | Entry) -> Row?, boolean, boolean, number?, boolean)
  local make, needsFile = rowMaker(vfs, request, volatile)
  local exact, prefix, handledWhere, handledConstraints, matchesPath = pathPlan(request)
  local ordered, descending = util.orderedBy(request, 'path')
  local limit = util.limit(request, handledWhere, ordered)
  local constraints = request.constraints or {}
  local keyOnly = not needsFile

  local candidates: { string } | { Entry }
  if exact ~= nil then
    if normalizedPrefix(exact) and exact ~= '' then
      if keyOnly then
        candidates = if vfs:contains(exact) then { exact } :: { string } else {}
      else
        local file = vfs:getFile(exact)
        candidates = if file ~= nil then { { key = exact, file = file } } :: { Entry } else {}
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
    if matchesPath and not matchesPath(key) then return nil end

    return make(key, if keyOnly then nil else (item :: Entry).file)
  end

  return candidates, rowOf, handledWhere, ordered, limit, handledConstraints
end

local function rowsFor(vfs: Vfs, request: Request): ScanResult
  local candidates, rowOf, handledWhere, ordered, limit, handledConstraints = plan(vfs, request, false)

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
  local volatile = request.allowVolatileRows == true
  local candidates, rowOf, handledWhere, ordered, _, handledConstraints = plan(vfs, request, volatile)
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
    volatileRows = volatile,
    handledWhere = handledWhere,
    ordered = ordered,
    handledConstraints = handledConstraints,
  }
end

--- What a lookup makes its rows with, and what the request it was worked out for said: its
--- columns and constraints as they read then, by key, and how many of each there were. An indexed
--- join looks a stem up for every row it drives with, all by one request, so the last plan is
--- kept; a caller may change a request between two lookups, so it is kept by what the request
--- said and not by which table it was.
type LookupPlan = {
  columns: { [unknown]: unknown },
  columnCount: number,
  constraints: { [unknown]: util.Constraint },
  constraintCount: number,
  whereComplete: unknown,
  make: (key: string, given: File?) -> Row?,
  handledWhere: boolean,
  handledConstraints: boolean,
  matchesPath: ((key: string) -> boolean)?,
}

local Empty = table.freeze {}

local function lookupPlan(vfs: Vfs, request: Request): LookupPlan
  local make = rowMaker(vfs, request, false)
  local _, _, handledWhere, handledConstraints, matchesPath = pathPlan(request)
  local columns: { [unknown]: unknown } = table.clone(request.columns or Empty)
  local constraints: { [unknown]: util.Constraint } = {}
  local columnCount, constraintCount = 0, 0
  for _ in columns do
    columnCount += 1
  end

  for key, constraint in request.constraints or Empty do
    constraints[key] = table.clone(constraint)
    constraintCount += 1
  end

  return {
    columns = columns,
    columnCount = columnCount,
    constraints = constraints,
    constraintCount = constraintCount,
    whereComplete = request.whereComplete,
    make = make,
    handledWhere = handledWhere,
    handledConstraints = handledConstraints,
    matchesPath = matchesPath,
  }
end

--- Whether a request says what the one a plan was worked out for said.
local function planned(plan: LookupPlan, request: Request): boolean
  if request.whereComplete ~= plan.whereComplete then return false end

  local columnCount, constraintCount = 0, 0
  for key, name in request.columns or Empty do
    if plan.columns[key] ~= name then return false end

    columnCount += 1
  end

  for key, constraint in request.constraints or Empty do
    local was = plan.constraints[key]
    if not was or was.column ~= constraint.column or was.op ~= constraint.op or was.value ~= constraint.value then
      return false
    end

    constraintCount += 1
  end

  return columnCount == plan.columnCount and constraintCount == plan.constraintCount
end

function exports.provider(vfs: Vfs): Provider
  local indexedRevision = -1
  local plan: LookupPlan? = nil

  -- The files by stem, as of the revision indexed: the first key with each stem, and every key
  -- of a stem that several have, in key order.
  local stemFirst: { [string]: string } = {}
  local stemDuplicates: { [string]: { string } } = {}

  local function ensureStemIndex()
    local revision = vfs:revision()
    if revision == indexedRevision then return end

    stemFirst, stemDuplicates = {}, {}
    for _, key in vfs:keysStartingWith('') do
      local stem = logicalStem(key)
      local first = stemFirst[stem]
      if not first then
        stemFirst[stem] = key
        continue
      end

      local bucket = stemDuplicates[stem]
      if bucket then
        table.insert(bucket, key)
      else
        stemDuplicates[stem] = { first, key }
      end
    end

    indexedRevision = revision
  end

  local function lookup(column: string, value: unknown, request: Request): ScanResult?
    if column ~= 'stem' or type(value) ~= 'string' then return nil end

    ensureStemIndex()
    local current = plan
    if not current or not planned(current, request) then
      current = lookupPlan(vfs, request)
      plan = current
    end

    local { make, matchesPath, handledWhere, handledConstraints } = current
    local out: { Row } = {}
    local count = 0

    -- One key has the stem, or every key of its bucket does.
    local first = stemFirst[value]
    for _, key in stemDuplicates[value] or { first } do
      if matchesPath and not matchesPath(key) then continue end

      local row = make(key, nil)
      if not row then continue end

      count += 1
      out[count] = row
    end

    return util.scanResult(out, handledWhere, false, false, handledConstraints)
  end

  return {
    columns = Columns,

    -- The keys are walked, as a scan walks them: a list need answer nothing but a `for`.
    count = function(): number
      local keys = 0
      for _ in vfs:keys() do
        keys += 1
      end

      return keys
    end,

    indexes = { stem = true },
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
