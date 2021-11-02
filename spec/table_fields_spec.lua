local helper = require "spec.helper"

local function assert_warnings(warnings, src)
   assert.same(warnings, helper.get_stage_warnings("check_table_fields", src))
end

describe("table field checks", function()
   it("detects unused and undefined table fields", function()
      assert_warnings({
         {code = "315", line = 2, column = 3, end_column = 3, name = 'x', field = 'y'},
         {code = "315", line = 3, column = 3, end_column = 3, name = 'x', field = 'y'},
         {code = "315", line = 4, column = 3, end_column = 3, name = 'x', field = 1},
         {code = "325", line = 4, column = 10, end_column = 10, name = 'x', field = 'z'},
         {code = "315", line = 5, column = 3, end_column = 3, name = 'x', field = 'a'},
         {code = "325", line = 5, column = 9, end_column = 9, name = 'x', field = 'a'},
         {code = "315", line = 6, column = 12, end_column = 15, name = 'x', field = 'func'},
      }, [[
local x = {}
x.y = 1
x.y = 2
x[1] = x.z
x.a = x.a
function x.func() end
      ]])
   end)

   it("detects complicated unused and undefined table fields", function()
      assert_warnings({
         {line = 4, column = 11, name = 't', end_column = 11, field = 'b', code = '325', },
         {line = 10, column = 3, name = 'a', end_column = 3, field = 1, code = '315', },
      }, [[
local x = {1}
local t = {}
t.a = 1
t.x = x[t.b]
x[t.a + 1] = x[t.x]

local b = {}
b[1] = 1
local a = {}
a[1] = {}
a[1][1] = 1
a[2] = {}
a[1][b[1] + 1] = a[2][1]
      ]])
   end)

   it("handles upvalue references after definition", function()
      assert_warnings({}, [[
local x = {}
x.y = 1
function x.func() print(x) end
      ]])
   end)

   it("handles upvalue references before definition", function()
      assert_warnings({}, [[
local x
function func() print(x[1]) end
x = {1}
      ]])
   end)

   it("handles upvalues references in returned functions", function()
      assert_warnings({}, [[
function inner()
   local x = {1}
   return function() print(x[1]) end
end
      ]])
   end)

   -- Handled separately, in detect_unused_fields
   it("doesn't detect duplicate keys in initialization", function()
      assert_warnings({}, [[
local x = {key = 1, key = 1}
local y = {1, [1] = 1}
return x,y
      ]])
   end)

   it("handles table assignments", function()
      assert_warnings({}, [[
function new_scope()
   local c = {1}
   return {key = c}
end

function new_scope2()
   local t = {}
   t[1] = 1
   return { [t[1] ] = 1}
end

local x = {1}
local y = {x}
local b = {key = y}
local a = {1}
a[b or x] = 1
local d = {[a] = 1}
return {d} or {d}
      ]])
   end)

   it("detects unused and undefined table fields inside control blocks", function()
      assert_warnings({
         {line = 4, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
         {line = 10, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
         {line = 16, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
         {line = 22, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
         {line = 28, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
         {line = 34, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
      }, [[
do
   local x = {}
   x.y = 1
   x[1] = x.z
end

if true then
   local x = {}
   x.y = 1
   x[1] = x.z
end

while true do
   local x = {}
   x.y = 1
   x[1] = x.z
end

repeat
   local x = {}
   x.y = 1
   x[1] = x.z
until false

for i=1,2 do
   local x = {}
   x.y = 1
   x[1] = x.z
end

for _,_ in pairs({}) do
   local x = {}
   x.y = 1
   x[1] = x.z
end
      ]])
   end)

   it("accounts for returned tables", function()
      assert_warnings({
         {code = "315", line = 6, column = 3, end_column = 3, name = 't', field = 'x'},
      }, [[
local x = {}
x[1] = 1
x.y = 1
local t = {}
t.y = 1
t.x = 1
return x, t.y
      ]])
   end)

   it("more complicated function calls", function()
      assert_warnings({}, [[
local t = {}
function t.func(var) print(var) end

local x = {}
x.y = 1
t.func(x)
      ]])
   end)

   it("handles initialized tables", function()
      assert_warnings({
         {code = "315", line = 1, column = 12, end_column = 12, name = 'x', field = 1},
         {code = "315", line = 1, column = 15, end_column = 15, name = 'x', field = 2},
         {code = "315", line = 1, column = 18, end_column = 18, name = 'x', field = 'a'},
         {code = "315", line = 2, column = 3, end_column = 3, name = 'x', field = 1},
         {code = "325", line = 2, column = 10, end_column = 10, name = 'x', field = 'z'},
         {code = "315", line = 3, column = 3, end_column = 3, name = 'x', field = 'y'}
      }, [[
local x = {1, 2, a = 3}
x[1] = x.z
x.y = 1
      ]])
   end)

   it("handles tables that are upvalues", function()
      assert_warnings({
         {code = "325", line = 5, column = 13, end_column = 13, name = 'x', field = 'a'},
      }, [[
local x

function func()
   x = {}
   x[1] = x.a
end

local t

print(function()
   t = {t.a}
end)
      ]])
   end)

   it("handles table assignments to existing local variables", function()
      assert_warnings({
         {code = "315", line = 3, column = 3, end_column = 3, name = 'x', field = 'y'},
         {code = "315", line = 6, column = 3, end_column = 3, name = 'y', field = 'y'},
         {code = "315", line = 8, column = 3, end_column = 3, name = 'y', field = 'y'},
      }, [[
local x
x = {}
x.y = 1

local y = {}
y.y = 1
y = {}
y.y = 1
      ]])
   end)

   it("doesn't track table overwrites or unused fields inside control blocks", function()
      assert_warnings({}, [[
local x = {}
local y
x.y = 1
if true then
   x = {}
   y = {}
   y[1] = 1
   x[1] = 1
end
x[2] = x[3]
      ]])
   end)

   it("handles nil sets correctly", function()
      assert_warnings({
         {line = 2, column = 3, name = 'x', end_column = 3, field = 'y', code = '315', },
         {line = 4, column = 3, name = 'x', end_column = 3, field = 'z', code = '315', },
         {line = 4, column = 9, name = 'x', end_column = 9, field = 'y', code = '325', },
         {line = 5, column = 3, name = 'x', end_column = 3, field = 'y', code = '315', },
      }, [[
local x = {}
x.y = 1
x.y = nil
x.z = x.y
x.y = 1
      ]])
   end)

   it("handles balanced multiple assignment correctly", function()
      assert_warnings({
         {code = "325", line = 2, column = 22, end_column = 22, name = 't', field = 'b'},
         {code = "325", line = 3, column = 20, end_column = 20, name = 't', field = 'z'}
      }, [[
local t = {}
t.x, t.y, t.z = 1, t.b
return t.x, t.y, t.z
      ]])
   end)

   it("handles multiple assignment of tables", function()
      assert_warnings({
         {code = "315", line = 3, column = 3, end_column = 3, name = 'x', field = 'a'},
         {code = "325", line = 4, column = 10, end_column = 10, name = 'b', field = 'c'}
      }, [[
local x,y = {}, {}
local a,b = {}, {}
x.a = 1
return b.c
      ]])
   end)

   it("handles imbalanced multiple assignment correctly", function()
      assert_warnings({
         {code = "315", line = 2, column = 3, end_column = 3, name = 't', field = 'x'},
         {code = "325", line = 3, column = 10, end_column = 10, name = 't', field = 'y'},
      }, [[
local t = {}
t.x, t.y = 1
return t.y
      ]])
   end)

   it("tables used as keys create a reference to them", function()
      assert_warnings({}, [[
local t = {}
local y = {1}
t[y or 3] = 1
return t
      ]])
   end)

   it("understands the difference between string and number keys", function()
      assert_warnings({
         {code = "315", line = 2, column = 3, end_column = 3, name = 't', field = 1},
         {code = "315", line = 3, column = 3, end_column = 5, name = 't', field = '2'},
         {code = "325", line = 3, column = 12, end_column = 14, name = 't', field = '1'},
      }, [[
local t = {}
t[1] = 1
t["2"] = t["1"]
      ]])
   end)

   it("continues checking if the table variable itself is accessed without creating a reference", function()
      assert_warnings({
         {code = "315", line = 2, column = 3, end_column = 3, name = 'x', field = 'y'},
         {code = "315", line = 5, column = 3, end_column = 3, name = 'x', field = 'y'}
      }, [[
local x = {}
x.y = 1
local t = {1}
t[1] = t[x]
x.y = 1
      ]])
   end)

   it("warns on non-atomic key access to an entirely empty table", function()
      assert_warnings({
         {code = "325", line = 3, column = 11, end_column = 13, name = 't2', field = '[Non-atomic key]'},
         {code = "325", line = 4, column = 11, end_column = 11, name = 't2', field = 't'},
      }, [[
local t = {}
local t2 = {}
t[1] = t2[1+1]
t[2] = t2[t]
return t
      ]])
   end)

   it("handles aliases correctly", function()
      assert_warnings({
         {code = "315", line = 2, column = 3, end_column = 3, name = 'x', field = 1},
         {code = "325", line = 2, column = 10, end_column = 10, name = 'x', field = 'z'},
         {code = "315", line = 3, column = 3, end_column = 3, name = 'x', field = 'y'},
         {code = "315", line = 6, column = 3, end_column = 3, name = 't', field = 'y'},
         {code = "315", line = 7, column = 3, end_column = 3, name = 't', field = 1},
         {code = "325", line = 7, column = 10, end_column = 10, name = 't', field = 'z'},
      }, [[
local x = {}
x[1] = x.z
x.y = 1
x.x = 1
local t = x
t.y = 1
t[1] = t.z
return t.x
      ]])
   end)

   it("an alias being overwritten doesn't end processing for the other aliases", function()
      assert_warnings({
         {code = "315", line = 5, column = 3, end_column = 3, name = 'x', field = 1},
      }, [[
local x = {}
local t = x
t[2] = 2
t = 1
x[1] = 1
x[1] = 1
return x, t
      ]])
   end)

   it("any alias being externally referenced blocks unused warnings", function()
      assert_warnings({}, [[
local t
function inner()
   local x = {1}
   t = x
end
      ]])
   end)

   -- TODO: Improve this to reduce false negatives
   it("does nothing for globals", function()
      assert_warnings({}, [[
x = {}
x[1] = 1
x[2] = x.y
x[1] = 1

y[1] = 1
y[2] = x.y
y[1] = 1
      ]])
   end)

   -- TODO: Improve this to reduce false negatives
   it("does nothing for table parameters that aren't declared in scope", function()
      assert_warnings({}, [[
function func(x)
   x[1] = x.z
   x[1] = 1
end
      ]])
   end)

   -- TODO: Improve this to reduce false negatives
   it("assumes that all non-atomic values can be nil", function()
      assert_warnings({
         {line = 3, column = 3, name = 'x', end_column = 3, field = 'y', code = '315', }
      }, [[
local x = {}
local var = 1
x.y = 1
x.y = var
x.z = x.y
x.y = var
x.y = 1 -- Ideally, would be reported as an overwrite, as var is non-nil

return x
      ]])
   end)

   -- TODO: Improve this to reduce false negatives
   it("assumes that non-constant keys leave all table keys permanently potentially accessed", function()
      assert_warnings({}, [[
local var = 1

local x = {1}
local t = {}
t[1] = x[var]
x.y = 1 -- Ideally, would be reported as unused

local a = {1}
t[2] = a[1 + 1]
a.y = 1 -- Ideally, would be reported as unused
return t
      ]])
   end)

   -- TODO: Improve this to reduce false negatives
   -- See comments in the file
   it("stops checking if a function is called", function()
      assert_warnings({
         {line = 8, column = 3, name = 'y', end_column = 3, field = 'x', code = '315', },
         {line = 8, column = 9, name = 'y', end_column = 9, field = 'a', code = '325', },
         {line = 14, column = 9, name = 't', end_column = 9, field = 'a', code = '325', },
      }, [[
local x = {}
x.y = 1
print("Unrelated text")
x.y = 2
x[1] = x.z

local y = {}
y.x = y.a
y.x = 1
function y:func() return 1 end
y:func()

local t = {}
t.x = t.a
local var = 'func'
t.x = y[var]() + 1
      ]])
   end)

   -- TODO: Improve this to reduce false negatives
   -- See comments in the file
   it("stops checking a table definition if we change scopes", function()
      assert_warnings({
         {code = "325", line = 3, column = 10, end_column = 10, name = 'x', field = 'z'},
         {code = "315", line = 11, column = 6, end_column = 6, name = 'x', field = 1},
         {code = "325", line = 13, column = 13, end_column = 13, name = 'x', field = 'z'},
      }, [[
local x = {}
x.y = 1
x[1] = x.z
if true then
   x.y = 2
   x[2] = x.a
end

if true then
   x = {}
   x[1] = 1
   x[1] = 1
   x[3] = x.z
end
x[1] = x.z
      ]])
   end)
end)
