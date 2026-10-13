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
  local template = util.template(wanted, Columns)
  local wantIndex, wantType, wantId, wantFlags = wanted.index, wanted.type, wanted.id, wanted.flags
  local wantSize, wantDirty, wantPartial = wanted.size, wanted.dirty, wanted.partial
  local onlyType, onlyId = util.text(request, 'type'), util.text(request, 'id')
  local onlyFlags, onlySize = util.number(request, 'flags'), util.number(request, 'size')
  local onlyDirty, onlyPartial = util.flag(request, 'dirty'), util.flag(request, 'partial')

  local function build(index: number): Row?
    local tag = plugin:tag(index)
    if onlyType and tag ~= onlyType then return nil end

    local id: string? = nil
    if wantId or onlyId then
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

    local row = table.clone(template)
    if wantIndex then row.index = index end
    if wantType then row.type = tag end
    if wantId then row.id = id end
    if wantFlags then row.flags = flags end
    if wantSize then row.size = size end
    if wantDirty then row.dirty = dirty end
    if wantPartial then row.partial = partial end
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
