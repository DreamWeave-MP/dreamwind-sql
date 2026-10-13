--!strict
--!native

local nifModule = require('@nif')
local sceneModule = require('@nif/scene')
local util = require('./util')

local exports = {}

export type Nif = nifModule.Nif

type Database = util.Database
type Request = util.Request
type Row = util.Row
type ScanResult = util.ScanResult
type Scene = sceneModule.Scene

--- A lazy scan in the engine's `_jessqlIter` protocol: `next` hands out rows until it returns nil.
--- It is one of the engine's `Iterator`s that says more: its rows are its own to write, and every
--- flag the engine leaves optional is set.
export type Iterator = util.Iterator

export type RecordsProvider = {
  columns: { string },
  iterate: (request: Request) -> Iterator,
  scan: (request: Request) -> ScanResult,
}

--- `iterate` hands the nodes over one at a time, so a query that needs only so many of them
--- makes only so many rows.
export type SceneNodesProvider = {
  columns: { string },
  iterate: (request: Request) -> Iterator,
  scan: (request: Request) -> ScanResult,
}

local RecordColumns = table.freeze {
  'index',
  'type',
  'name',
  'decoded',
}

local SceneNodeColumns = table.freeze {
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

--- What a scan holds a record to: each of these columns, equal to a value of its kind.
local RecordEqualities: { [string]: util.Kind } = table.freeze {
  index = 'whole',
  type = 'string',
  name = 'string',
  decoded = 'boolean',
}

--- What a scan holds a scene node to.
local SceneNodeEqualities: { [string]: util.Kind } = table.freeze {
  index = 'whole',
  source = 'number',
  record_type = 'string',
  name = 'string',
  parent = 'number',
  subtree_end = 'number',
  billboard = 'boolean',
  visibility = 'string',
}

local function recordIterator(nif: Nif, request: Request): Iterator
  local wanted = util.columns(request)
  local exactType = util.constraint(request, 'type', '=')
  local exactName = util.constraint(request, 'name', '=')
  local exactDecoded = util.constraint(request, 'decoded', '=')
  local scratch: { [string]: { [string]: unknown } } = {}

  local function build(index: number): Row?
    local kind = nif:typeOf(index)
    if kind == nil then return nil end
    if type(exactType) == 'string' and kind ~= exactType then return nil end

    local decoded: boolean? = nil
    if wanted.decoded or type(exactDecoded) == 'boolean' then
      decoded = nif:isDecoded(index)
      if type(exactDecoded) == 'boolean' and decoded ~= exactDecoded then return nil end
    end

    local name: string? = nil
    if wanted.name or type(exactName) == 'string' then
      -- Which fields a record has depends on its type, so it is read as a table of whatever
      -- it holds, and its name counts only if it is a string.
      local value: { [string]: unknown }? = nil
      if decoded == true or nif:isDecoded(index) then
        value = nif:record(index) :: { [string]: unknown }?
      else
        local into = scratch[kind]
        if into == nil then into = {}; scratch[kind] = into end
        value = nif:read(index, into) :: { [string]: unknown }?
      end
      local candidate = if value then value.name else nil
      if type(candidate) == 'string' then name = candidate end
      if type(exactName) == 'string' and name ~= exactName then return nil end
    end

    local row: Row = {}
    if wanted.index then row.index = index end
    if wanted.type then row.type = kind end
    if wanted.name then row.name = name end
    if wanted.decoded then row.decoded = if decoded ~= nil then decoded else nif:isDecoded(index) end
    return row
  end

  local function count(): number return nif.count end

  return util.numbered(request, util.equalities(request, RecordEqualities), count, build)
end

local function nodeIterator(scene: Scene, request: Request): Iterator
  local wanted = util.columns(request)
  local nodes = scene.nodes
  local exactSource = util.constraint(request, 'source', '=')
  local exactType = util.constraint(request, 'record_type', '=')
  local exactName = util.constraint(request, 'name', '=')
  local exactParent = util.constraint(request, 'parent', '=')
  local exactSubtreeEnd = util.constraint(request, 'subtree_end', '=')
  local exactBillboard = util.constraint(request, 'billboard', '=')
  local exactVisibility = util.constraint(request, 'visibility', '=')

  local function build(index: number): Row?
    local node = nodes[index + 1]
    if type(exactSource) == 'number' and node.source ~= exactSource then return nil end
    if type(exactType) == 'string' and node.recordType ~= exactType then return nil end
    if type(exactName) == 'string' and node.name ~= exactName then return nil end
    if type(exactParent) == 'number' and node.parent ~= exactParent then return nil end
    if type(exactSubtreeEnd) == 'number' and node.subtreeEnd ~= exactSubtreeEnd then return nil end
    if type(exactBillboard) == 'boolean' and node.billboard ~= exactBillboard then return nil end
    if type(exactVisibility) == 'string' and node.visibility ~= exactVisibility then return nil end

    local row: Row = {}
    if wanted.index then row.index = index end
    if wanted.source then row.source = node.source end
    if wanted.record_type then row.record_type = node.recordType end
    if wanted.name then row.name = node.name end
    if wanted.parent then row.parent = node.parent end
    if wanted.subtree_end then row.subtree_end = node.subtreeEnd end
    if wanted.billboard then row.billboard = node.billboard end
    if wanted.visibility then row.visibility = node.visibility end

    if wanted.local_x or wanted.local_y or wanted.local_z then
      local translation = node['local'][4]
      if wanted.local_x then row.local_x = translation.x end
      if wanted.local_y then row.local_y = translation.y end
      if wanted.local_z then row.local_z = translation.z end
    end

    if wanted.world_x or wanted.world_y or wanted.world_z then
      local translation = node.world[4]
      if wanted.world_x then row.world_x = translation.x end
      if wanted.world_y then row.world_y = translation.y end
      if wanted.world_z then row.world_z = translation.z end
    end

    return row
  end

  local function count(): number return #nodes end

  return util.numbered(request, util.equalities(request, SceneNodeEqualities), count, build)
end

function exports.recordsProvider(nif: Nif): RecordsProvider
  return {
    columns = RecordColumns,
    iterate = function(request: Request): Iterator
      return recordIterator(nif, request)
    end,
    scan = function(request: Request): ScanResult
      return util.drain(recordIterator(nif, request), request, nif.count)
    end,
  }
end

function exports.sceneNodesProvider(nif: Nif): SceneNodesProvider
  local cached: Scene? = nil

  --- The NIF's scene, built when it is first asked for and kept.
  local function scene(): Scene
    local built = cached or sceneModule.build(nif)
    cached = built
    return built
  end

  return {
    columns = SceneNodeColumns,
    iterate = function(request: Request): Iterator
      return nodeIterator(scene(), request)
    end,
    scan = function(request: Request): ScanResult
      local built = scene()
      return util.drain(nodeIterator(built, request), request, #built.nodes)
    end,
  }
end

function exports.register(db: Database, nif: Nif, recordsName: string?, sceneNodesName: string?): Database
  db:register(recordsName or 'nif.records', exports.recordsProvider(nif))
  db:register(sceneNodesName or 'nif.scene_nodes', exports.sceneNodesProvider(nif))
  return db
end

return table.freeze(exports)
