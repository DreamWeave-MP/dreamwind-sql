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
--- flag the engine leaves optional is set. It is declared whole because Luau cannot call a `next`
--- narrowed by intersecting the two.
export type Iterator = {
  _jessqlIter: 'v1',
  next: () -> Row?,
  handledWhere: boolean,
  ordered: boolean,
  handledConstraints: boolean,
}

export type RecordsProvider = {
  columns: { string },
  iterate: (request: Request) -> Iterator,
  scan: (request: Request) -> ScanResult,
}

export type SceneNodesProvider = {
  columns: { string },
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

local function supportedRecordConstraints(request: Request): boolean
  if util.repeatsColumn(request) then return false end

  for _, constraint in request.constraints or {} do
    if constraint.op ~= '=' then return false end

    if constraint.column == 'index' then
      if type(constraint.value) ~= 'number' or constraint.value % 1 ~= 0 then return false end
    elseif constraint.column == 'type' or constraint.column == 'name' then
      if type(constraint.value) ~= 'string' then return false end
    elseif constraint.column == 'decoded' then
      if type(constraint.value) ~= 'boolean' then return false end
    else
      return false
    end
  end
  return true
end

local function recordIterator(nif: Nif, request: Request): Iterator
  local wanted = util.columns(request)
  local exactIndex = util.constraint(request, 'index', '=')
  local exactType = util.constraint(request, 'type', '=')
  local exactName = util.constraint(request, 'name', '=')
  local exactDecoded = util.constraint(request, 'decoded', '=')
  local scratch: { [string]: { [string]: unknown } } = {}
  local handledConstraints = supportedRecordConstraints(request)
  local handledWhere = request.whereComplete == true and handledConstraints

  local ordered = false
  local descending = false
  local orderBy = request.orderBy
  if orderBy ~= nil and #orderBy == 1 and orderBy[1].column == 'index' then
    ordered = true
    descending = orderBy[1].desc == true
  end

  local nextIndex = if descending then nif.count - 1 else 0
  local step = if descending then -1 else 1
  local exactPending = type(exactIndex) == 'number' and exactIndex % 1 == 0
  local exhausted = false

  local function build(index: number): Row?
    if index < 0 or index >= nif.count then return nil end
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

  local function nextRow(): Row?
    if exhausted then return nil end

    if exactPending and type(exactIndex) == 'number' then
      exactPending = false
      exhausted = true
      return build(exactIndex)
    elseif type(exactIndex) == 'number' then
      exhausted = true
      return nil
    end

    while nextIndex >= 0 and nextIndex < nif.count do
      local index = nextIndex
      nextIndex += step
      local row = build(index)
      if row ~= nil then return row end
    end
    exhausted = true
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

local function recordRows(nif: Nif, request: Request): ScanResult
  local iter = recordIterator(nif, request)
  local orderBy = request.orderBy
  local limit = if iter.handledWhere and (orderBy == nil or iter.ordered) then request.limitHint or request.limit else nil
  local out: { Row } = if limit ~= nil then table.create(limit) :: { Row } else {}
  while true do
    local row = iter.next()
    if row == nil then break end
    out[#out + 1] = row
    if limit ~= nil and #out >= limit then break end
  end
  return util.scanResult(out, iter.handledWhere, iter.ordered, limit ~= nil, iter.handledConstraints)
end

local function supportedSceneConstraints(request: Request): boolean
  if util.repeatsColumn(request) then return false end

  for _, constraint in request.constraints or {} do
    if constraint.op ~= '=' then return false end

    if constraint.column == 'index' then
      if type(constraint.value) ~= 'number' or constraint.value % 1 ~= 0 then return false end
    elseif constraint.column == 'source' or constraint.column == 'parent' or constraint.column == 'subtree_end' then
      if type(constraint.value) ~= 'number' then return false end
    elseif constraint.column == 'record_type' or constraint.column == 'name' or constraint.column == 'visibility' then
      if type(constraint.value) ~= 'string' then return false end
    elseif constraint.column == 'billboard' then
      if type(constraint.value) ~= 'boolean' then return false end
    else
      return false
    end
  end
  return true
end

local function nodeRows(scene: Scene, request: Request): ScanResult
  local wanted = util.columns(request)
  local out: { Row } = {}
  local exactIndex = util.constraint(request, 'index', '=')
  local exactSource = util.constraint(request, 'source', '=')
  local exactType = util.constraint(request, 'record_type', '=')
  local exactName = util.constraint(request, 'name', '=')
  local exactParent = util.constraint(request, 'parent', '=')
  local exactSubtreeEnd = util.constraint(request, 'subtree_end', '=')
  local exactBillboard = util.constraint(request, 'billboard', '=')
  local exactVisibility = util.constraint(request, 'visibility', '=')
  local handledConstraints = supportedSceneConstraints(request)
  local handledWhere = request.whereComplete == true and handledConstraints

  local ordered = false
  local descending = false
  local orderBy = request.orderBy
  if orderBy ~= nil and #orderBy == 1 and orderBy[1].column == 'index' then
    ordered = true
    descending = orderBy[1].desc == true
  end
  local limit = if handledWhere and (orderBy == nil or ordered) then request.limitHint or request.limit else nil
  if limit ~= nil then out = table.create(limit) :: { Row } end

  local function emit(index: number): boolean
    local node = scene.nodes[index + 1]
    if node == nil then return false end
    if type(exactSource) == 'number' and node.source ~= exactSource then return false end
    if type(exactType) == 'string' and node.recordType ~= exactType then return false end
    if type(exactName) == 'string' and node.name ~= exactName then return false end
    if type(exactParent) == 'number' and node.parent ~= exactParent then return false end
    if type(exactSubtreeEnd) == 'number' and node.subtreeEnd ~= exactSubtreeEnd then return false end
    if type(exactBillboard) == 'boolean' and node.billboard ~= exactBillboard then return false end
    if type(exactVisibility) == 'string' and node.visibility ~= exactVisibility then return false end

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
    out[#out + 1] = row
    return limit ~= nil and #out >= limit
  end

  -- No node is at an index that is no whole number.
  if type(exactIndex) == 'number' then
    if exactIndex % 1 == 0 then emit(exactIndex) end
  elseif descending then
    for index = #scene.nodes - 1, 0, -1 do if emit(index) then break end end
  else
    for index = 0, #scene.nodes - 1 do if emit(index) then break end end
  end
  return util.scanResult(out, handledWhere, ordered, limit ~= nil, handledConstraints)
end

function exports.recordsProvider(nif: Nif): RecordsProvider
  return {
    columns = RecordColumns,
    iterate = function(request: Request): Iterator
      return recordIterator(nif, request)
    end,
    scan = function(request: Request): ScanResult
      return recordRows(nif, request)
    end,
  }
end

function exports.sceneNodesProvider(nif: Nif): SceneNodesProvider
  local cached: Scene? = nil
  return {
    columns = SceneNodeColumns,
    scan = function(request: Request): ScanResult
      local scene = cached or sceneModule.build(nif)
      cached = scene
      return nodeRows(scene, request)
    end,
  }
end

function exports.register(db: Database, nif: Nif, recordsName: string?, sceneNodesName: string?): Database
  db:register(recordsName or 'nif.records', exports.recordsProvider(nif))
  db:register(sceneNodesName or 'nif.scene_nodes', exports.sceneNodesProvider(nif))
  return db
end

return table.freeze(exports)
