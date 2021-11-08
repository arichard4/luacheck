local helper = require "spec.helper"

local function assert_warnings(warnings, src)
   assert.same(warnings, helper.get_stage_warnings("check_table_fields", src))
end

describe("table field builtin function checks", function()
it("understands that builtins never have local tables as an upvalue", function()
      assert_warnings({
         {code = "315", line = 1, column = 12, end_column = 12, name = 'x', field = 1, set_is_nil = ''},
         {code = "325", line = 3, column = 10, end_column = 10, name = 'x', field = 'z'},
         {code = "315", line = 5, column = 12, end_column = 12, name = 'y', field = 1, set_is_nil = ''},
         {code = "325", line = 7, column = 10, end_column = 10, name = 'y', field = 'z'},
      }, [[
local x = {1}
print("Eh")
x[1] = x.z

local y = {1}
string.lower("AAAA")
y[1] = y.z
return x, y
      ]])
   end)

   it("understands that table.sort cannot affect which keys are set or accessed", function()
      assert_warnings({
         {code = "315", line = 1, column = 18, end_column = 18, name = 'x', field = 3, set_is_nil = ''},
         {code = "325", line = 5, column = 9, end_column = 9, name = 'x', field = 4},
      }, [[
local x = {1, 2, 3}
table.sort(x)
print(x[1])
table.sort(x[2])
print(x[4])
      ]])
   end)

   it("understands that table.concat accesses all keys", function()
      assert_warnings({
         {code = "325", line = 3, column = 7, end_column = 7, name = 'x', field = 4},
         {code = "315", line = 5, column = 12, end_column = 12, name = 'x', field = 3, set_is_nil = ''},
         {code = "315", line = 9, column = 9, end_column = 9, name = 'x', field = 2, set_is_nil = ''},
         {code = "315", line = 9, column = 12, end_column = 12, name = 'x', field = 3, set_is_nil = ''},
      }, [[
local x = {1, 2, 3}
local y = table.concat(x)
y = x[4]

x = {1, 2, 3}
y = table.concat(x[1])
y = x[2]

x = {1, 2, 3}
x[1+1] = 2
y = table.concat(x[1])
y = x[4]
x[1+1] = 2
      ]])
   end)

   it("handles table.insert correctly", function()
      assert_warnings({
         {code = "315", line = 2, column = 1, end_column = 18, name = 'x', field = 4, set_is_nil = ''},
         {code = "315", line = 3, column = 1, end_column = 18, name = 'x', field = 5, set_is_nil = ''},
         {code = "325", line = 6, column = 20, end_column = 20, name = 'x', field = 'a'},
      }, [[
local x = {1, 2, 3}
table.insert(x, 1)
table.insert(x, 1)
table.insert(x, 4, 4)
table.insert(x, "z", "z")
print(x[4], x.z, x.a, x[1], x[2], x[3])
      ]])
   end)

   it("removes from the end for table.remove", function()
      assert_warnings({
         {code = "325", line = 3, column = 21, end_column = 21, name = 'x', field = 3},
      }, [[
local x = {1, 2, 3}
table.remove(x)
print(x[1], x[2], x[3])
      ]])
   end)

   it("removes from the middle and shifts downwards for table.remove", function()
      assert_warnings({
         {code = "325", line = 3, column = 21, end_column = 21, name = 'x', field = 3},
      }, [[
local x = {1, 2, 3}
table.remove(x, 2)
print(x[1], x[2], x[3])
      ]])
   end)

   it("alerts on removing a field that's not set", function()
      assert_warnings({
         {code = "325", line = 2, column = 17, end_column = 17, name = 'x', field = 3},
         {code = "325", line = 4, column = 1, end_column = 15, name = 'x', field = 1},
      }, [[
local x = {1}
table.remove(x, 3)
table.remove(x)
table.remove(x)
      ]])
   end)

   it("ignores after unclear key sets for table.remove and table.insert", function()
      assert_warnings({}, [[
local var = 1
local x = {1, 2, 3}
x[var] = 1
table.remove(x)
table.remove(x)
print(x[3])

local y = {}
table.insert(y, var, 1)
table.insert(y, var, 1)
print(y.x)
      ]])
   end)

   it("table.remove moves nil values in the array part down", function()
      assert_warnings({
         {code = "325", line = 3, column = 15, end_column = 15, name = 'x', field = 2},
         {code = "325", line = 3, column = 27, end_column = 27, name = 'x', field = 4},
      }, [[
local x = {1, 2, nil, 4}
table.remove(x, 2)
print(x[1], x[2], x[3], x[4])
      ]])
   end)

   it("table.insert skips over gaps in array part", function()
      assert_warnings({}, [[
local x = {1, 2, nil, 4}
table.insert(x, 1)
print(x[1], x[2], x[4], x[5])
      ]])
   end)

   it("casts strings to numbers for table.remove and table.insert", function()
      assert_warnings({
         {code = "325", line = 4, column = 9, end_column = 9, name = 'x', field = 2},
         {code = "325", line = 7, column = 9, end_column = 9, name = 'x', field = 1},
      }, [[
local x = {}
table.insert(x, "1", 1)
print(x[1])
print(x[2])
table.remove(x, "1")
x.y = 1
print(x[1])
print(x.y)
      ]])
   end)

   it("handles type and next correctly", function()
      assert_warnings({
         {code = "315", line = 1, column = 12, end_column = 12, name = 'x', field = 1, set_is_nil = ''},
         {code = "315", line = 5, column = 3, end_column = 3, name = 'x', field = 1, set_is_nil = ''},
         {code = "325", line = 5, column = 10, end_column = 10, name = 'x', field = 'y'},
      }, [[
local x = {1, 2, 3}
type(x)
x[1] = 1
next(x)
x[1] = x.y
      ]])
   end)

   it("table.insert references tables used as keys or values", function()
      assert_warnings({}, [[
local x = {1}
local t = {}
table.insert(t, 1, x)

local y = {1}
local s = {}
table.insert(s, y, 1)

return s, t
      ]])
   end)
end)