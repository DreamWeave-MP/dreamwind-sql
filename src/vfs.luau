--!strict
--!native

local util = require('./util')

local exports = {}

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
--- the part of its VFS the adapter calls.
export type Vfs = {
    revision: (self: Vfs) -> number,
    contains: (self: Vfs, path: string) -> boolean,
    getFile: (self: Vfs, path: string) -> File?,
    keys: (self: Vfs, limit: number?, descending: boolean?) -> { string },
    entries: (self: Vfs, limit: number?, descending: boolean?) -> { Entry },
    keysStartingWith: (self: Vfs, prefix: string, limit: number?, descending: boolean?) -> { string },
    pathsStartingWith: (self: Vfs, prefix: string, limit: number?, descending: boolean?) -> { Entry },
}

export type Provider = {
    columns: { string },
    indexes: { [string]: boolean },
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

local function rowsFor(vfs: Vfs, request: Request): ScanResult
    local wanted = util.columns(request)
    local exact, prefix, handledWhere, handledConstraints, matchesPath = pathPlan(request)

    local ordered = false
    local descending = false
    local orderBy = request.orderBy
    if orderBy ~= nil and #orderBy == 1 and orderBy[1].column == 'path' then
        ordered = true
        descending = orderBy[1].desc == true
    end

    local canLimit = handledWhere and (orderBy == nil or ordered)
    local limit = if canLimit then request.limitHint or request.limit else nil
    local out: { Row } = if limit ~= nil then table.create(limit) :: { Row } else {}
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
    local function emit(item: string | Entry): boolean
        local key = if keyOnly then item :: string else (item :: Entry).key
        if not matchesPath(key) then return false end
        local row = makeRow(vfs, key, wanted, if keyOnly then nil else (item :: Entry).file)
        if row == nil then return false end
        out[#out + 1] = row
        return limit ~= nil and #out >= limit
    end

    for _, item in candidates do if emit(item) then break end end
    return util.scanResult(out, handledWhere, ordered, limit ~= nil, handledConstraints)
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
