local foo = {}

function foo.bar(baz)
   for i=1, 5 do
      local q

      for a, b, c in pairs(foo) do
         print(4)
      end
   end
end

local x = 5
x = 6
x = 7; print(x)

local y = 5;
(function() print(y) end)()
y = 6

local z = 5;
(function() z = 4 end)()
z = 6

foo[foo] = 1
foo[1] = foo
foo[foo] = foo
function foo.meta()
   return function() print(foo) end
end

local t = {}
function t.func() print(t) return {val = 1} end
t[t] = t.func().val + 1

local s = {}
function s:func() print(self) return {val = 1} end
s[s] = s:func().val + 1