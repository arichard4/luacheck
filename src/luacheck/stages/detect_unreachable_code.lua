local utils = require 'luacheck.utils'

local stage = {}

stage.warnings = {
   ["511"] = {message_format = "unreachable code", fields = {}},
   ["512"] = {message_format = "loop is executed at most once", fields = {}}
}

-- Repeat is also technically a loop, but always returning in the middle
-- results in the until evaluation being the first unreachable statement
local loop_tags = utils.array_to_set({"While", "Fornum", "Forin"})

local function noop_callback() end

local function detect_unreachable_code(chstate, line)
   local reachable_indexes = {}

   -- Mark all items reachable from the function start.
   line:walk(reachable_indexes, 1, noop_callback)

   -- All remaining items are unreachable.
   -- However, there is no point in reporting all of them.
   -- Only report those that are not reachable from any already reported ones.
   for item_index, item in ipairs(line.items) do
      if not reachable_indexes[item_index] then
         if item.node then
            if item.tag == "Noop" and item.scope_end then
               if loop_tags[item.node.tag] then
                  chstate:warn_range("512", item.node)
                  -- Mark all items reachable from the item just reported.
                  line:walk(reachable_indexes, item_index, noop_callback)
               end
            else
               chstate:warn_range("511", item.node)
               -- Mark all items reachable from the item just reported.
               line:walk(reachable_indexes, item_index, noop_callback)
            end
         end
      end
   end
end

function stage.run(chstate)
   for _, line in ipairs(chstate.lines) do
      detect_unreachable_code(chstate, line)
   end
end

return stage
