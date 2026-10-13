--!strict
--!native

local engine = require('@jessql/engine')
local nif = require('@self/nif')
local tes3 = require('@self/tes3')
local vfs = require('@self/vfs')

local exports = {}

--- A JessQL database, as the engine makes one.
export type Database = typeof(engine.new())

export type AttachOptions = {
    vfs: vfs.Vfs?,
    tes3: tes3.Plugin?,
    nif: nif.Nif?,
}

function exports.registerVfs(db: Database, value: vfs.Vfs, name: string?): Database
    return vfs.register(db, value, name)
end

function exports.registerTes3(db: Database, value: tes3.Plugin, name: string?): Database
    return tes3.register(db, value, name)
end

function exports.registerNif(db: Database, value: nif.Nif, recordsName: string?, sceneNodesName: string?): Database
    return nif.register(db, value, recordsName, sceneNodesName)
end

function exports.attach(db: Database, options: AttachOptions): Database
    if options.vfs ~= nil then vfs.register(db, options.vfs) end
    if options.tes3 ~= nil then tes3.register(db, options.tes3) end
    if options.nif ~= nil then nif.register(db, options.nif) end
    return db
end

function exports.new(options: AttachOptions?): Database
    local db = engine.new()
    if options then exports.attach(db, options) end
    return db
end

return table.freeze(exports)
