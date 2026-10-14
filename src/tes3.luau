--!strict
--!native

local bytes = require('@dream/bytes')
local tes3 = require('@tes3')
local util = require('./util')

local exports = {}

export type Plugin = tes3.Plugin

--- A lazy scan, as `iterate` hands one out.
export type Iterator = util.Iterator

type Database = util.Database
type Request = util.Request
type Row = util.Row
type ScanResult = util.ScanResult

--- `iterate` hands the records over one at a time, so a query that needs only so many of them
--- reads only so many; `count` is how many records there are, which answers a bare COUNT(*).
export type Provider = {
  columns: { string },
  count: () -> number,
  iterate: (request: Request) -> Iterator,
  scan: (request: Request) -> ScanResult,
}

local Columns = table.freeze {
  'index',
  'type',
  'id',
  'flags',
  'size',
  'dirty',
  'partial',
}

--- What a scan holds a record to: each of these columns, equal to a value of its kind.
local Equalities: { [string]: util.Kind } = table.freeze({
  index = 'whole',
  type = 'string',
  id = 'string',
  flags = 'number',
  size = 'number',
  dirty = 'boolean',
  partial = 'boolean',
} :: { [string]: util.Kind })

--- A lazy scan of a plugin's records. `volatile` has it fill one row table for every record,
--- which only a request that allows it may be answered with.
local function recordIterator(plugin: Plugin, request: Request, volatile: boolean): Iterator
  local wanted = util.columns(request)
  local template = util.template(wanted, Columns)
  local wantIndex, wantType, wantId, wantFlags = wanted.index, wanted.type, wanted.id, wanted.flags
  local wantSize, wantDirty, wantPartial = wanted.size, wanted.dirty, wanted.partial
  local onlyType, onlyId = util.text(request, 'type'), util.text(request, 'id')
  local onlyFlags, onlySize = util.number(request, 'flags'), util.number(request, 'size')
  local onlyDirty, onlyPartial = util.flag(request, 'dirty'), util.flag(request, 'partial')

  -- A tag is four bytes, read as a number: a record is of the type asked for when its number is
  -- that type's, and none is of a type of any other length, whose number is left nil.
  local onlyCode: number? = if onlyType and #onlyType == 4 then tes3.tags.code(onlyType) else nil

  -- An id that is ASCII is spelled in a plugin's code page as it is when decoded, so a record has
  -- it when the bytes of its id are the same, and no id is decoded to find that out. A save's ids
  -- are typed, and compare as the text they read as.
  local onlySpelling: string? = if onlyId and plugin.profile ~= 'omwsave' and not string.find(onlyId, '[\128-\255]')
    then onlyId
    else nil

  local function build(index: number): Row?
    if onlyType and plugin:code(index) ~= onlyCode then return nil end

    local id: string? = nil
    if onlySpelling then
      local source, at, length = tes3.records.idSpan(plugin, index)
      if not source or length ~= #onlySpelling then return nil end
      if bytes.compare(source, at, onlySpelling, 0, length) ~= 0 then return nil end

      id = onlySpelling
    elseif wantId or onlyId then
      id = tes3.records.id(plugin, index)
      if onlyId and id ~= onlyId then return nil end
    end

    local flags: number? = nil
    if wantFlags or onlyFlags then
      flags = plugin:flags(index)
      if onlyFlags and flags ~= onlyFlags then return nil end
    end

    local size: number? = nil
    if wantSize or onlySize then
      size = plugin:size(index)
      if onlySize and size ~= onlySize then return nil end
    end

    -- Whether a record is dirty or in part is held to false as much as to true.
    local dirty: boolean? = nil
    if wantDirty or onlyDirty ~= nil then
      dirty = plugin:isDirty(index)
      if onlyDirty ~= nil and dirty ~= onlyDirty then return nil end
    end

    local partial: boolean? = nil
    if wantPartial or onlyPartial ~= nil then
      partial = plugin:isPartial(index)
      if onlyPartial ~= nil and partial ~= onlyPartial then return nil end
    end

    local row = if volatile then template else table.clone(template)
    if wantIndex then row.index = index end
    if wantType then row.type = onlyType or plugin:tag(index) end
    if wantId then row.id = id end
    if wantFlags then row.flags = flags end
    if wantSize then row.size = size end
    if wantDirty then row.dirty = dirty end
    if wantPartial then row.partial = partial end
    return row
  end

  local function count(): number return plugin:count() end

  return util.numbered(request, util.equalities(request, Equalities), volatile, count, build)
end

function exports.provider(plugin: Plugin): Provider
  return {
    columns = Columns,
    count = function(): number return plugin:count() end,
    iterate = function(request: Request): Iterator
      return recordIterator(plugin, request, request.allowVolatileRows == true)
    end,
    scan = function(request: Request): ScanResult
      return util.drain(recordIterator(plugin, request, false), request, plugin:count())
    end,
  }
end

function exports.register(db: Database, plugin: Plugin, name: string?): Database
  db:register(name or 'tes3.records', exports.provider(plugin))
  return db
end

return table.freeze(exports)
