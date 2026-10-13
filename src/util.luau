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

--- A lazy scan in the engine's `_jessqlIter` protocol: `next` hands out rows until it returns nil.
--- It is one of the engine's `Iterator`s that says more: its rows are its own to write, and every
--- flag the engine leaves optional is set. `volatileRows` says `next` hands out one row table
--- every time, filled anew, which it does only for a request that allows it. It is declared whole
--- because Luau cannot call a `next` narrowed by intersecting the two.
export type Iterator = {
  _jessqlIter: 'v1',
  next: () -> Row?,
  volatileRows: boolean,
  handledWhere: boolean,
  ordered: boolean,
  handledConstraints: boolean,
}

function exports.columns(request: Request): { [string]: boolean }
  local out: { [string]: boolean } = {}
  for _, name in request.columns or {} do out[name] = true end
  return out
end

--- A row for a scan to copy for each row it makes: those of a table's `columns` the request asks
--- for, each holding false, so that filling a copy never grows it. A scan fills every cell of a
--- copy; one it fills with nil is a cell the row lacks. A scan whose rows may be volatile fills
--- the template itself, over and over.
function exports.template(wanted: { [string]: boolean }, columns: { string }): Row
  local row: Row = {}
  for _, name in columns do
    if wanted[name] then row[name] = false end
  end

  return row
end

function exports.constraint(request: Request, column: string, op: string): unknown
  for _, constraint in request.constraints or {} do
    if constraint.column == column and constraint.op == op then return constraint.value end
  end
  return nil
end

--- The string a request's first `=` on `column` holds it to, when it is one.
function exports.text(request: Request, column: string): string?
  local value = exports.constraint(request, column, '=')
  return if type(value) == 'string' then value else nil
end

--- The number a request's first `=` on `column` holds it to, when it is one.
function exports.number(request: Request, column: string): number?
  local value = exports.constraint(request, column, '=')
  return if type(value) == 'number' then value else nil
end

--- The boolean a request's first `=` on `column` holds it to, when it is one.
function exports.flag(request: Request, column: string): boolean?
  local value = exports.constraint(request, column, '=')
  return if type(value) == 'boolean' then value else nil
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

--- A lazy scan of a table whose rows are numbered from 0, as a plugin numbers its records and a
--- NIF its records and its scene's nodes. `build` makes the row at an index, or nil when the
--- source or the constraints have none there. `count` is how many indices there are: it is asked
--- when the scan starts, and again whenever an upward walk reaches the count it had, so a source
--- that grows under the scan is read to its end. A request for one index is answered with that
--- row alone, and with none when the index is past the rows or no whole number; any other is
--- walked in order, from the last index down when it orders by index so. `volatile` says
--- whether `build` hands out one row table every time.
function exports.numbered(
  request: Request,
  handledConstraints: boolean,
  volatile: boolean,
  count: () -> number,
  build: (index: number) -> Row?
): Iterator
  local exact = exports.constraint(request, 'index', '=')
  local ordered, descending = exports.orderedBy(request, 'index')
  local known = count()
  local position, step = 0, 1
  local done = false

  --- Whether the walk ends where the indices it started with do: it is of one index, or downward.
  local bounded = descending
  if type(exact) == 'number' then
    bounded = true
    if exact % 1 == 0 and exact >= 0 and exact < known then
      position, known = exact, exact + 1
    else
      known = 0
    end
  elseif descending then
    position, step = known - 1, -1
  end

  local function nextRow(): Row?
    while not done do
      while position >= 0 and position < known do
        local index = position
        position += step
        local row = build(index)
        if row then return row end
      end

      if not bounded then known = count() end

      done = position < 0 or position >= known
    end

    return nil
  end

  return {
    _jessqlIter = 'v1',
    next = nextRow,
    volatileRows = volatile,
    handledWhere = request.whereComplete == true and handledConstraints,
    ordered = ordered,
    handledConstraints = handledConstraints,
  }
end

--- A lazy scan's rows as an eager one's: all of them, or as many as the request says are enough.
--- The scan's rows are each a table of their own. `capacity` is how many rows the source could
--- make, so room for a limit's rows is made only as far as there are rows.
function exports.drain(iterator: Iterator, request: Request, capacity: number): ScanResult
  local limit = exports.limit(request, iterator.handledWhere, iterator.ordered)
  local rows: { Row } = if limit then table.create(math.min(limit, capacity)) else {}
  local count = 0
  while true do
    local row = iterator.next()
    if not row then break end

    count += 1
    rows[count] = row
    if limit and count >= limit then break end
  end

  return exports.scanResult(rows, iterator.handledWhere, iterator.ordered, limit ~= nil, iterator.handledConstraints)
end

--- What a LIKE pattern is a prefix of, when it is no more than that: the pattern itself when it
--- has no wildcard, so that a value is LIKE it only by being it, and what comes before its `%`
--- when that is its one wildcard and its last byte, so that a value is LIKE it by starting so.
--- Nil for any other pattern.
function exports.likePrefix(pattern: unknown): string?
  if type(pattern) ~= 'string' then return nil end
  local percent = string.find(pattern, '%', 1, true)
  local underscore = string.find(pattern, '_', 1, true)
  if underscore then return nil end
  if not percent then return pattern end
  if percent ~= #pattern then return nil end
  return string.sub(pattern, 1, #pattern - 1)
end

return table.freeze(exports)
