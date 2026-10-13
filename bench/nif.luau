-- A type filter, ordered and limited, over a NIF's records. Run from the folder the packages are in:
-- jess run --package dreamwind-sql --package-path . dreamwind-sql/bench/nif.luau
local sql=require('@dreamwind-sql'); local nifmod=require('@nif'); local count=tonumber((...)) or 100000
local nif=nifmod.new(); for index=1,count do nif:insert({type=if index%2==0 then 'NiNode' else 'NiTriShape', name='n'..tostring(index)}) end
local db=sql.new{nif=nif}; local plan=db:prepare("SELECT index, type FROM nif.records WHERE type = 'NiNode' ORDER BY index DESC LIMIT 20")
for round=1,5 do local started=os.clock(); local result=plan.run(); print(round,(os.clock()-started)*1000,#result.rows,result.rows[1].index) end
