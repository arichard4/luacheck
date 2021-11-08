local helper = require "spec.helper"

local function assert_warnings(warnings, src)
   assert.same(warnings, helper.get_stage_warnings("check_table_fields", src))
end

describe("table field todo tests", function()
   it("detects unused and undefined table fields inside control blocks", function()
      assert_warnings({
         {line = 3, column = 6, name = 'x', end_column = 6, field = 1, code = '315', },
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
         {line = 2, column = 3, name = 'x', end_column = 3, field = 1, code = '315', },
         {line = 6, column = 6, name = 'x', end_column = 6, field = 2, code = '315', },
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
         {line = 2, column = 3, name = 'x', end_column = 3, field = 1, code = '315', },
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
         {line = 6, column = 6, name = 'x', end_column = 6, field = 1, code = '315', },
         {line = 7, column = 6, name = 'x', end_column = 6, field = 2, code = '315', },
         {line = 10, column = 15, name = 'x', end_column = 15, field = 2, code = '325', },
      }, [[
local x = {}
x[1] = 1

do
   local x = {}
   x[1] = 1
   x[2] = 1
end

print(x[1], x[2])
      ]])
   end)
end)