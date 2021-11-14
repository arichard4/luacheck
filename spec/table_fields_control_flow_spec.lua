local helper = require "spec.helper"

local function assert_warnings(warnings, src)
   assert.same(warnings, helper.get_stage_warnings("check_table_fields", src))
end

describe("table field control flow", function()
   it("detects unused and undefined table fields inside control blocks", function()
      assert_warnings({
         {line = 3, column = 6, name = 'x', end_column = 6, field = 1, code = '315', set_is_nil = ''},
         {line = 3, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
         {line = 8, column = 6, name = 'x', end_column = 6, field = 1, code = '315', set_is_nil = ''},
         {line = 8, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
         {line = 13, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
         {line = 18, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
         {line = 23, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
         {line = 28, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
      }, [[
do
   local x = {}
   x[1] = x.z
end

if var then
   local x = {}
   x[1] = x.z
end

while true do
   local x = {}
   x[1] = x.z
end

repeat
   local x = {}
   x[1] = x.z
until false

for i=1,2 do
   local x = {}
   x[1] = x.z
end

for _,_ in pairs({}) do
   local x = {}
   x[1] = x.z
end
      ]])
   end)

   it("handles inheriting outer scope definitions", function()
      assert_warnings({
         {line = 2, column = 3, name = 'x', end_column = 3, field = 1, code = '315', set_is_nil = ''},
         {line = 6, column = 6, name = 'x', end_column = 6, field = 2, code = '315', set_is_nil = ''},
      }, [[
local x = {}
x[1] = 1

do
   x[1] = 1
   x[2] = 2
   x[3] = 1
end

print(x[1], x[3])
      ]])
   end)

   it("handles overwriting outer scope definitions", function()
      assert_warnings({
         {line = 2, column = 3, name = 'x', end_column = 3, field = 1, code = '315', set_is_nil = ''},
      }, [[
local x = {}
x[1] = 1

do
   x = {}
   x[1] = 1
   x[2] = 1
end

print(x[1], x[2])
      ]])
   end)

   it("handles shadowing outer scope definitions", function()
      assert_warnings({
         {line = 3, column = 3, name = 'x', end_column = 3, field = 3, code = '315', set_is_nil = '' },
         {line = 9, column = 24, name = 'x', end_column = 24, field = 3, code = '325', },
         {line = 12, column = 15, name = 'x', end_column = 15, field = 2, code = '325', },
      }, [[
local x = {}
x[1] = 1
x[3] = 1

do
   local x = {}
   x[1] = 1
   x[2] = 1
   print(x[1], x[2], x[3])
end

print(x[1], x[2])
      ]])
   end)

   it("handles shadowed variables that are modified in-scope", function()
      assert_warnings({
         {line = 12, column = 21, name = 'y', end_column = 21, field = 2, code = '325', },
      }, [[
local x = {}
local y = {}
do
   x[1] = 1
   y[1] = 1
   local x = 1
   local y = {}
   y[1] = 1
   y[2] = 2
   print(x, y)
end
print(x[1], y[1], y[2])
      ]])
   end)

   it("handles nested scopes", function()
      assert_warnings({
         {code = "325", line = 10, column = 15, end_column = 15, name = 'x', field = 2},
      }, [[
local x = {1}
do
   local x = {1, 1}
   do
      local x = {1, 1, 1}
      print(x)
   end
   print(x)
end
print(x[1], x[2])
      ]])
   end)

   it("handles aliases that get shadowed", function()
      assert_warnings({}, [[
local x = {}
local y = x
do
   x[1] = 1
   local y = {}
end
print(x[1], y[1])

local x = {}
local y = x
do
   local y = {}
   x[1] = 1
end
print(x[1], y[1])

local x = {}
local y = x
do
   y[1] = 1
   local y = {}
end
print(x[1], y[1])

local x = {}
local y
do
   y = x
   y[1] = 1
   local y = {}
end
print(x[1], y[1])
      ]])
   end)

   it("handles aliases in a do block", function()
      assert_warnings({
         {code = "325", line = 7, column = 15, end_column = 15, name = 'x', field = 2},
         {code = "325", line = 15, column = 15, end_column = 15, name = 'x', field = 2},
         {code = "325", line = 24, column = 15, end_column = 15, name = 'x', field = 2},
      }, [[
local x = {}
do
   local y = x
   y[1] = 1
   local x = 1
end
print(x[1], x[2])

local x = {}
do
   local y = x
   local x = 1
   y[1] = 1
end
print(x[1], x[2])

local x = {}
do
   local y = x
   local x = 1
   y[1] = 1
   y = 1
end
print(x[1], x[2])
      ]])
   end)

   it("handles redeclared locals in the same scope", function()
      assert_warnings({
         {code = "315", line = 1, column = 12, end_column = 12, name = 'x', field = 1, set_is_nil = ''},
         {code = "315", line = 2, column = 12, end_column = 12, name = 'x', field = 1, set_is_nil = ''},
         {code = "325", line = 3, column = 9, end_column = 9, name = 'x', field = 2,}
      }, [[
local x = {1}
local x = {1}
print(x[2])
      ]])
   end)

   it("propagates analysis halts to outer scopes", function()
      assert_warnings({}, [[
local t = {1}
if undef_global then
   for _, _ in pairs(t) do end
end
print(t[2])

local y = {1}
do
   for _, _ in pairs(y) do end
end
print(y[2])
      ]])
   end)

   it("doesn't warn on overwrites in only some branches", function()
      assert_warnings({}, [[
local y = {1}
if unknown_var then
   y = {1}
end
print(table.concat(y))

local x = {1}
if unknown_var then
   x = {1}
else
   print("")
end
print(table.concat(x))
      ]])
   end)

   it("handles nested control blocks", function()
      assert_warnings({
         {code = "315", line = 4, column = 9, end_column = 9, name = 'x', field = 2, set_is_nil = ''},
      }, [[
local x = {1}
if 1 then
   do
      x[2] = x[1]
   end
end
      ]])
   end)

   it("realizes that if blocks may or may not be entered", function()
      assert_warnings({
         {code = "315", line = 6, column = 6, end_column = 6, name = 't', field = 'x', set_is_nil = ''},
         {code = "325", line = 8, column = 21, end_column = 21, name = 't', field = 3},
      }, [[
local t = {}
if 1 then
   t[1] = 2
elseif 2 then
   t[2] = 2
   t.x = "x"
end
print(t[1], t[2], t[3])
      ]])
   end)

   it("realizes that a return in an if doesn't let assignments propagate out", function()
      assert_warnings({
         {code = "325", line = 10, column = 9, end_column = 9, name = 't', field = 1},
      }, [[
local t = {}
if 1 then
   t[1] = 1
   if 1 then
      return
   else
      return
   end
end
print(t[1])
      ]])
   end)

   it("accesses in returned branches do propagate out", function()
      assert_warnings({
         {code = "315", line = 6, column = 3, end_column = 3, name = 't', field = 2, set_is_nil = ''},
      }, [[
local t = {1}
if var then
   print(t[1])
   return
end
t[2] = 2

local x = {1}
if var then
   print(x[1])
   return
else
   print("Here!")
end

local z = {1}
if var then
   print(z[1])
   return
elseif var then
   print("Here!")
elseif var then
   print("Here!")
end

local y = {1, 2}
if var then
   print(y[1])
   return
else
   print(y[2])
   return
end
      ]])
   end)

   it("realizes that an else means that the branches cover all posibilities", function()
      assert_warnings({
         {code = "315", line = 1, column = 12, end_column = 12, name = 't', field = 1, set_is_nil = ''},
         {code = "325", line = 9, column = 9, end_column = 9, name = 't', field = 1},
      }, [[
local t = {1}
if var then
   t[1] = nil
elseif var then
   t[1] = nil
else
   t[1] = nil
end
print(t[1])
      ]])
   end)

   it("accounts for table leaving scope in returning branch", function()
      assert_warnings({
         {code = "315", line = 5, column = 3, end_column = 3, name = 't', field = 1, set_is_nil = ''},
      }, [[
local t = {1}
if not table.unpack(t) then
  return
end
t[1] = 1
      ]])
   end)

   it("accounts for multiple if-branch overwrites", function()
      assert_warnings({}, [[
local t = {}

if 1 then
  t[1] = "1"
end

if 2 then
  t[1] = "2"
end

return t
      ]])
   end)

   it("accounts for overwrites in one branch", function()
      assert_warnings({}, [[
local def_db_strategies = {1, 2}
if math.random(2) == 1 then
  def_db_strategies = {1}
end
return def_db_strategies
      ]])
   end)

   -- TODO: Need to figure out interaction of nil and maybe_set_keys
   -- Probably both set_keys and maybe_set_keys should simply track every set that can reach the current point?
   -- Would let us warn on more unused sets at once, and track if all are nil
end)