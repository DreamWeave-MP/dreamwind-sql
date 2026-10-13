--!strict
--!native

local tes3 = require('@tes3')
local util = require('./util')

local exports = {}

export type Plugin = tes3.Plugin

type Database = util.Database
type Request = util.Request
type Row = util.Row
type ScanResult = util.ScanResult

export type Provider = {
    columns: { string },
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

local function exactIndex(request: Request): number?
    local value = util.constraint(request, 'index', '=')
    if type(value) == 'number' and value % 1 == 0 then return value end
    return nil
end

local function matchingIndices(plugin: Plugin, request: Request): { number }?
    local index = exactIndex(request)
    if index ~= nil then return { index } end

    local kind = util.constraint(request, 'type', '=')
    local id = util.constraint(request, 'id', '=')
    if type(kind) == 'string' and type(id) == 'string' then
        local found = tes3.records.find(plugin, kind, id)
        return if found == nil then {} else { found }
    end
    return nil
end

local function supportedConstraints(request: Request): boolean
    for _, constraint in request.constraints or {} do
        if constraint.op ~= '=' then return false end

        if constraint.column == 'index' or constraint.column == 'flags' or constraint.column == 'size' then
            if type(constraint.value) ~= 'number' then return false end
        elseif constraint.column == 'type' or constraint.column == 'id' then
            if type(constraint.value) ~= 'string' then return false end
        elseif constraint.column == 'dirty' or constraint.column == 'partial' then
            if type(constraint.value) ~= 'boolean' then return false end
        else
            return false
        end
    end
    return true
end

local function rowsFor(plugin: Plugin, request: Request): ScanResult
    local wanted = util.columns(request)
    local direct = matchingIndices(plugin, request)
    local out: { Row } = {}
    local count = plugin:count()
    local exactType = util.constraint(request, 'type', '=')
    local exactId = util.constraint(request, 'id', '=')
    local exactFlags = util.constraint(request, 'flags', '=')
    local exactSize = util.constraint(request, 'size', '=')
    local exactDirty = util.constraint(request, 'dirty', '=')
    local exactPartial = util.constraint(request, 'partial', '=')
    local handledConstraints = supportedConstraints(request)
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
        if index < 0 or index >= count then return false end
        local tag = plugin:tag(index)
        if type(exactType) == 'string' and tag ~= exactType then return false end

        local id: string? = nil
        if wanted.id or type(exactId) == 'string' then
            id = tes3.records.id(plugin, index)
            if type(exactId) == 'string' and id ~= exactId then return false end
        end

        local flags: number? = nil
        if wanted.flags or type(exactFlags) == 'number' then
            flags = plugin:flags(index)
            if type(exactFlags) == 'number' and flags ~= exactFlags then return false end
        end

        local size: number? = nil
        if wanted.size or type(exactSize) == 'number' then
            size = plugin:size(index)
            if type(exactSize) == 'number' and size ~= exactSize then return false end
        end

        local dirty: boolean? = nil
        if wanted.dirty or type(exactDirty) == 'boolean' then
            dirty = plugin:isDirty(index)
            if type(exactDirty) == 'boolean' and dirty ~= exactDirty then return false end
        end

        local partial: boolean? = nil
        if wanted.partial or type(exactPartial) == 'boolean' then
            partial = plugin:isPartial(index)
            if type(exactPartial) == 'boolean' and partial ~= exactPartial then return false end
        end

        local row: Row = {}
        if wanted.index then row.index = index end
        if wanted.type then row.type = tag end
        if wanted.id then row.id = id end
        if wanted.flags then row.flags = flags end
        if wanted.size then row.size = size end
        if wanted.dirty then row.dirty = dirty end
        if wanted.partial then row.partial = partial end
        out[#out + 1] = row
        return limit ~= nil and #out >= limit
    end

    if direct ~= nil then
        for _, index in direct do if emit(index) then break end end
    elseif descending then
        for index = count - 1, 0, -1 do if emit(index) then break end end
    else
        for index = 0, count - 1 do if emit(index) then break end end
    end
    return util.scanResult(out, handledWhere, ordered, limit ~= nil, handledConstraints)
end

function exports.provider(plugin: Plugin): Provider
    return {
        columns = Columns,
        scan = function(request: Request): ScanResult
            return rowsFor(plugin, request)
        end,
    }
end

function exports.register(db: Database, plugin: Plugin, name: string?): Database
    db:register(name or 'tes3.records', exports.provider(plugin))
    return db
end

return table.freeze(exports)
