--!strict
--!native

local engine = require('@jessql/engine')

local exports = {}

--- A JessQL database, as the engine declares it.
export type Database = engine.Database

--- One predicate JessQL pushed down. Its value is whatever the query compared with: a literal of
--- any SQL type, or a bound parameter.
export type Constraint = engine.Constraint

export type Order = engine.Order

--- What JessQL hands a provider, as the engine declares it.
export type Request = engine.Request

--- A row: the columns a request asked for, each holding whatever its source does.
export type Row = engine.Row

--- A provider's answer to a scan or a lookup: the engine's `ScanResult`, and whether the rows were
--- cut short at a limit, which the engine does not read.
export type ScanResult = engine.ScanResult & { read limited: boolean }

function exports.columns(request: Request): { [string]: boolean }
  local out: { [string]: boolean } = {}
  for _, name in request.columns or {} do out[name] = true end
  return out
end

function exports.constraint(request: Request, column: string, op: string): unknown
  for _, constraint in request.constraints or {} do
    if constraint.column == column and constraint.op == op then return constraint.value end
  end
  return nil
end

--- What a column is held equal to: `whole` is a number without a fraction, which is what a row's
--- index is.
export type Kind = 'number' | 'whole' | 'string' | 'boolean'

--- Whether every constraint of a request is one a scan applies in full: a column of `kinds` held
--- equal to a value of its kind, and no column twice. A scan reads one constraint for each column
--- and holds its rows to the first alone, so a WHERE with two on one is the engine's to apply.
function exports.equalities(request: Request, kinds: { [string]: Kind }): boolean
  local seen: { [string]: boolean } = {}
  for _, constraint in request.constraints or {} do
    local kind, value = kinds[constraint.column], constraint.value
    if constraint.op ~= '=' or not kind or seen[constraint.column] then return false end

    if kind == 'whole' then
      if type(value) ~= 'number' or value % 1 ~= 0 then return false end
    elseif type(value) ~= kind then
      return false
    end

    seen[constraint.column] = true
  end

  return true
end

--- Whether a request orders by `column` alone, and if so whether downward. A scan whose rows
--- come in that order says so, and only then may it stop at the request's limit.
function exports.orderedBy(request: Request, column: string): (boolean, boolean)
  local orderBy = request.orderBy
  if not orderBy or #orderBy ~= 1 or orderBy[1].column ~= column then return false, false end

  return true, orderBy[1].desc == true
end

--- How many rows are enough for a request, or nil when a scan must hand over every one: it may
--- stop only when the whole WHERE is its own and its rows are in whatever order was asked for.
function exports.limit(request: Request, handledWhere: boolean, ordered: boolean): number?
  if not handledWhere or (request.orderBy and not ordered) then return nil end

  return request.limitHint or request.limit
end

function exports.hasConstraint(request: Request, column: string): boolean
  for _, constraint in request.constraints or {} do
    if constraint.column == column then return true end
  end
  return false
end

function exports.limitReached(out: { Row }, request: Request): boolean
  local limit = request.limit
  return limit ~= nil and #out >= limit
end

function exports.scanResult(rows: { Row }, handledWhere: boolean, ordered: boolean, limited: boolean, handledConstraints: boolean?): ScanResult
  return {
    _jessqlScan = 'v1',
    rows = rows,
    handledWhere = handledWhere,
    ordered = ordered,
    limited = limited,
    handledConstraints = handledConstraints == true,
  }
end

function exports.likePrefix(pattern: unknown): string?
  if type(pattern) ~= 'string' then return nil end
  local percent = string.find(pattern, '%', 1, true)
  local underscore = string.find(pattern, '_', 1, true)
  if underscore then return nil end
  if not percent then return pattern end
  if percent ~= #pattern then return nil end
  return string.sub(pattern, 1, #pattern - 1)
end

function exports.matchesSimpleLike(value: string, pattern: string): boolean?
  local underscore = string.find(pattern, '_', 1, true)
  if underscore then return nil end
  local first = string.find(pattern, '%', 1, true)
  if not first then return value == pattern end
  if first ~= #pattern or string.find(pattern, '%', first + 1, true) then return nil end
  local prefix = string.sub(pattern, 1, -2)
  return #value >= #prefix and string.sub(value, 1, #prefix) == prefix
end

return table.freeze(exports)
