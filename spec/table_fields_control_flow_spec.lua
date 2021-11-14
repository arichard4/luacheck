local helper = require "spec.helper"

local function assert_warnings(warnings, src)
   assert.same(warnings, helper.get_stage_warnings("check_table_fields", src))
end

describe("table field control flow", function()
   it("detects unused and undefined table fields inside control blocks", function()
      assert_warnings({
         {line = 3, column = 6, name = 'x', end_column = 6, field = 1, code = '315', set_is_nil = ''},
         {line = 3, column = 13, name = 'x', end_column = 13, field = 'z', code = '325', },
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

if true then
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
end)