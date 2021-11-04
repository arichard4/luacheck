local helper = require "spec.helper"

local function assert_warnings(warnings, src)
   assert.same(warnings, helper.get_stage_warnings("check_table_fields", src))
end

describe("table field todo tests", function()
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

   it("does nothing for nested tables", function()
      assert_warnings({}, [[
local x = {}
x[1] = {}
x[1][1] = 1
x[1][1] = x[1][2]
return x
      ]])
   end)

   -- Because of possible multiple return (TODO is to try to examine the function for multiple return)
   it("assumes tables initialized from function can have arbitrary keys set", function()
      assert_warnings({
         {code = "315", line = 3, column = 3, end_column = 3, name = 'x', field = 'y'},
      }, [[
local function func() return 1 end
local x = {func()}
x.y = x[2]
      ]])
   end)

   it("stops checking referenced upvalues even if function call is known to not have table as an upvalue", function()
      assert_warnings({}, [[
local x = {}
x[1] = 1
local function printx() x = 1 end
local function ret2() return 2 end
ret2()
x[1] = 1

local y = {}
y[1] = 1
function y.printx() y = 1 end
function y.ret2() return 2 end
y.ret2()
y[1] = 1
      ]])
   end)

   it("does nothing for table parameters that aren't declared in scope", function()
      assert_warnings({}, [[
function func(x)
   x[1] = x.z
   x[1] = 1
end
      ]])
   end)

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