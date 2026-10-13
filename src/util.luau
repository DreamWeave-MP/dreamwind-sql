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

--- Whether two of a request's constraints are on one column. A scan that reads one constraint
--- for each column holds its rows to the first alone, so such a WHERE is the engine's to apply.
function exports.repeatsColumn(request: Request): boolean
  local seen: { [string]: boolean } = {}
  for _, constraint in request.constraints or {} do
    if seen[constraint.column] then return true end

    seen[constraint.column] = true
  end

  return false
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
