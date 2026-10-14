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
--- flag the engine leaves optional is set. `volatileRows` says `next` hands out one row table
--- every time, filled anew, which it does only for a request that allows it.
export type Iterator = util.Iterator

--- `count` is how many records the NIF holds, which answers a bare COUNT(*).
export type RecordsProvider = {
  columns: { string },
  count: () -> number,
  iterate: (request: Request) -> Iterator,
  scan: (request: Request) -> ScanResult,
}

--- `iterate` hands the nodes over one at a time, so a query that needs only so many of them
--- makes only so many rows; `count` is how many nodes the scene has.
export type SceneNodesProvider = {
  columns: { string },
  count: () -> number,
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
local RecordEqualities: { [string]: util.Kind } = table.freeze({
  index = 'whole',
  type = 'string',
  name = 'string',
  decoded = 'boolean',
} :: { [string]: util.Kind })

--- What a scan holds a scene node to.
local SceneNodeEqualities: { [string]: util.Kind } = table.freeze({
  index = 'whole',
  source = 'number',
  record_type = 'string',
  name = 'string',
  parent = 'number',
  subtree_end = 'number',
  billboard = 'boolean',
  visibility = 'string',
} :: { [string]: util.Kind })

--- A lazy scan of a NIF's records. `volatile` has it fill one row table for every record, which
--- only a request that allows it may be answered with.
local function recordIterator(nif: Nif, request: Request, volatile: boolean): Iterator
  local wanted = util.columns(request)
  local template = util.template(wanted, RecordColumns)
  local wantIndex, wantType, wantName, wantDecoded = wanted.index, wanted.type, wanted.name, wanted.decoded
  local onlyType, onlyName = util.text(request, 'type'), util.text(request, 'name')
  local onlyDecoded = util.flag(request, 'decoded')
  local scratch: { [string]: { [string]: unknown } } = {}

  local function build(index: number): Row?
    local kind = nif:typeOf(index)
    if not kind or (onlyType and kind ~= onlyType) then return nil end

    -- Whether a record is decoded is held to false as much as to true.
    local decoded: boolean? = nil
    if wantDecoded or onlyDecoded ~= nil then
      decoded = nif:isDecoded(index)
      if onlyDecoded ~= nil and decoded ~= onlyDecoded then return nil end
    end

    local name: string? = nil
    if wantName or onlyName then
      -- Which fields a record has depends on its type, so it is read as a table of whatever
      -- it holds, and its name counts only if it is a string.
      local value: { [string]: unknown }? = nil
      if decoded == true or nif:isDecoded(index) then
        value = nif:record(index) :: { [string]: unknown }?
      else
        local into = scratch[kind]
        if not into then
          into = {}
          scratch[kind] = into
        end

        value = nif:read(index, into) :: { [string]: unknown }?
      end

      local candidate = if value then value.name else nil
      if type(candidate) == 'string' then name = candidate end
      if onlyName and name ~= onlyName then return nil end
    end

    local row = if volatile then template else table.clone(template)
    if wantIndex then row.index = index end
    if wantType then row.type = kind end
    if wantName then row.name = name end
    if wantDecoded then row.decoded = decoded end
    return row
  end

  local function count(): number return nif.count end

  return util.numbered(request, util.equalities(request, RecordEqualities), volatile, count, build)
end

--- A lazy scan of a scene's nodes, filling one row table for every node when `volatile`.
local function nodeIterator(scene: Scene, request: Request, volatile: boolean): Iterator
  local wanted = util.columns(request)
  local template = util.template(wanted, SceneNodeColumns)
  local nodes = scene.nodes
  local wantIndex, wantSource, wantType, wantName = wanted.index, wanted.source, wanted.record_type, wanted.name
  local wantParent, wantSubtreeEnd = wanted.parent, wanted.subtree_end
  local wantBillboard, wantVisibility = wanted.billboard, wanted.visibility
  local wantLocalX, wantLocalY, wantLocalZ = wanted.local_x, wanted.local_y, wanted.local_z
  local wantWorldX, wantWorldY, wantWorldZ = wanted.world_x, wanted.world_y, wanted.world_z
  local wantLocal, wantWorld = wantLocalX or wantLocalY or wantLocalZ, wantWorldX or wantWorldY or wantWorldZ
  local onlySource, onlyParent = util.number(request, 'source'), util.number(request, 'parent')
  local onlySubtreeEnd = util.number(request, 'subtree_end')
  local onlyType, onlyName = util.text(request, 'record_type'), util.text(request, 'name')
  local onlyVisibility = util.text(request, 'visibility')
  local onlyBillboard = util.flag(request, 'billboard')

  local function build(index: number): Row?
    local node = nodes[index + 1]
    if onlySource and node.source ~= onlySource then return nil end
    if onlyType and node.recordType ~= onlyType then return nil end
    if onlyName and node.name ~= onlyName then return nil end
    if onlyParent and node.parent ~= onlyParent then return nil end
    if onlySubtreeEnd and node.subtreeEnd ~= onlySubtreeEnd then return nil end

    -- Whether a node is a billboard is held to false as much as to true.
    if onlyBillboard ~= nil and node.billboard ~= onlyBillboard then return nil end
    if onlyVisibility and node.visibility ~= onlyVisibility then return nil end

    local row = if volatile then template else table.clone(template)
    if wantIndex then row.index = index end
    if wantSource then row.source = node.source end
    if wantType then row.record_type = node.recordType end
    if wantName then row.name = node.name end
    if wantParent then row.parent = node.parent end
    if wantSubtreeEnd then row.subtree_end = node.subtreeEnd end
    if wantBillboard then row.billboard = node.billboard end
    if wantVisibility then row.visibility = node.visibility end

    if wantLocal then
      local translation = node['local'][4]
      if wantLocalX then row.local_x = translation.x end
      if wantLocalY then row.local_y = translation.y end
      if wantLocalZ then row.local_z = translation.z end
    end

    if wantWorld then
      local translation = node.world[4]
      if wantWorldX then row.world_x = translation.x end
      if wantWorldY then row.world_y = translation.y end
      if wantWorldZ then row.world_z = translation.z end
    end

    return row
  end

  local function count(): number return #nodes end

  return util.numbered(request, util.equalities(request, SceneNodeEqualities), volatile, count, build)
end

function exports.recordsProvider(nif: Nif): RecordsProvider
  return {
    columns = RecordColumns,

    -- A record that was removed has left its index empty, and is no row.
    count = function(): number return #[for index in range(0, nif.count - 1) if nif:typeOf(index) => index] end,
    iterate = function(request: Request): Iterator
      return recordIterator(nif, request, request.allowVolatileRows == true)
    end,
    scan = function(request: Request): ScanResult
      return util.drain(recordIterator(nif, request, false), request, nif.count)
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
    count = function(): number return #scene().nodes end,
    iterate = function(request: Request): Iterator
      return nodeIterator(scene(), request, request.allowVolatileRows == true)
    end,
    scan = function(request: Request): ScanResult
      local built = scene()
      return util.drain(nodeIterator(built, request, false), request, #built.nodes)
    end,
  }
end

function exports.register(db: Database, nif: Nif, recordsName: string?, sceneNodesName: string?): Database
  db:register(recordsName or 'nif.records', exports.recordsProvider(nif))
  db:register(sceneNodesName or 'nif.scene_nodes', exports.sceneNodesProvider(nif))
  return db
end

return table.freeze(exports)
