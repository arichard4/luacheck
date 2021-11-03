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

   it("stops checking referenced upvalues if function call is known to not have table as an upvalue", function()
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

   it("can't identify complicated function calls", function()
      assert_warnings({}, [[
local x = {}
x[1] = {}
x[2] = 1
x[1][1] = function() x[2] = 2 end
x[1][2] = function() return 1 end
x[1][2]()
x[2] = 1 -- overwrite without access
      ]])
   end)

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

   it("assumes that all non-atomic values in initializers can be arbitrary", function()
      assert_warnings({
         {line = 5, column = 3, name = 'x', end_column = 3, field = 1, code = '315', },
         {line = 6, column = 3, name = 'x', end_column = 3, field = 1, code = '315', }
      }, [[
local var = 1
local x = {[1+1] = 1, [var] = 1}
print(x[2])
print(x[1])
x[1] = 1
x[1] = 1
      ]])
   end)

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