--!strict
--!native

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
--- reads only so many.
export type Provider = {
  columns: { string },
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
local Equalities: { [string]: util.Kind } = table.freeze {
  index = 'whole',
  type = 'string',
  id = 'string',
  flags = 'number',
  size = 'number',
  dirty = 'boolean',
  partial = 'boolean',
}

local function recordIterator(plugin: Plugin, request: Request): Iterator
  local wanted = util.columns(request)
  local exactType = util.constraint(request, 'type', '=')
  local exactId = util.constraint(request, 'id', '=')
  local exactFlags = util.constraint(request, 'flags', '=')
  local exactSize = util.constraint(request, 'size', '=')
  local exactDirty = util.constraint(request, 'dirty', '=')
  local exactPartial = util.constraint(request, 'partial', '=')

  local function build(index: number): Row?
    local tag = plugin:tag(index)
    if type(exactType) == 'string' and tag ~= exactType then return nil end

    local id: string? = nil
    if wanted.id or type(exactId) == 'string' then
      id = tes3.records.id(plugin, index)
      if type(exactId) == 'string' and id ~= exactId then return nil end
    end

    local flags: number? = nil
    if wanted.flags or type(exactFlags) == 'number' then
      flags = plugin:flags(index)
      if type(exactFlags) == 'number' and flags ~= exactFlags then return nil end
    end

    local size: number? = nil
    if wanted.size or type(exactSize) == 'number' then
      size = plugin:size(index)
      if type(exactSize) == 'number' and size ~= exactSize then return nil end
    end

    local dirty: boolean? = nil
    if wanted.dirty or type(exactDirty) == 'boolean' then
      dirty = plugin:isDirty(index)
      if type(exactDirty) == 'boolean' and dirty ~= exactDirty then return nil end
    end

    local partial: boolean? = nil
    if wanted.partial or type(exactPartial) == 'boolean' then
      partial = plugin:isPartial(index)
      if type(exactPartial) == 'boolean' and partial ~= exactPartial then return nil end
    end

    local row: Row = {}
    if wanted.index then row.index = index end
    if wanted.type then row.type = tag end
    if wanted.id then row.id = id end
    if wanted.flags then row.flags = flags end
    if wanted.size then row.size = size end
    if wanted.dirty then row.dirty = dirty end
    if wanted.partial then row.partial = partial end
    return row
  end

  local function count(): number return plugin:count() end

  return util.numbered(request, util.equalities(request, Equalities), count, build)
end

function exports.provider(plugin: Plugin): Provider
  return {
    columns = Columns,
    iterate = function(request: Request): Iterator
      return recordIterator(plugin, request)
    end,
    scan = function(request: Request): ScanResult
      return util.drain(recordIterator(plugin, request), request, plugin:count())
    end,
  }
end

function exports.register(db: Database, plugin: Plugin, name: string?): Database
  db:register(name or 'tes3.records', exports.provider(plugin))
  return db
end

return table.freeze(exports)
