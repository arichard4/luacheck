local core_utils = require "luacheck.core_utils"
local utils = require "luacheck.utils"

local stage = {}

stage.warnings = {
   ["315"] = {message_format = "value assigned to table field {name!}.{field!} is unused", fields = {"name", "field"}},
   ["325"] = {message_format = "table field {name!}.{field!} is never defined", fields = {"name", "field"}},
}

local function_call_tags = utils.array_to_set({"Call", "Invoke"})
-- Tags that delimit a control flow block; note that "Return" isn't on this list
local control_flow_tags = utils.array_to_set(
   {"Do", "While", "Repeat", "Fornum", "Forin", "If", "Label", "Goto", "Jump", "Cjump"}
)

-- Steps through the function or file scope one item at a time
-- At each point, tracking for each local table which fields have been set
local function detect_unused_table_fields(chstate, func_or_file_scope)
   local current_tables = {}

   -- Start keeping track of a local table
   -- Can be from local x = {} OR "local x; x = {}"
   local function new_local_table(table_name)
      current_tables[table_name] = {
         -- definitely_set_keys sets store a mapping from key => {table_name, node}; the node has the line/column info
         definitely_set_keys = {},
         -- A list of keys which are possibly set; since variables or function returns can be nil, we can't say for sure
         -- maybe_set_keys and accessed keys are mappings from key => true|nil
         maybe_set_keys = {},
         accessed_keys = {},
         -- For a variable key, it's impossible to reliably get the value; any given key could be set or accessed
         potentially_all_set = false,
         potentially_all_accessed = false,
         -- If this table is an upvalue reference, any field could potentially be accessed after the end of this scope
         -- A created function could be used to access the table from outside the current file-or-func scope
         -- So at the scope's end we can't check for unused keys
         upvalue_reference = false,
         -- Multiple variable names that point at the same underlying table
         -- e.g. local x = {}; local t = x
         aliases = {[table_name] = true}
      }
   end

   -- Stop trying to track a table
   -- We stop when:
   -- * the variable is overwritten entirely
   -- * there is a function call
   -- * there is a scope change (including control flow scope and return)
   local function wipe_table_data(table_name)
      local info_table = current_tables[table_name]
      for alias in pairs(info_table.aliases) do
         current_tables[alias] = nil
      end
   end

   -- Called when a table's field's value is no longer accessible
   -- Either the table is gone, or the field has been overwritten
   -- Table info can be different from the value of current_tables[table_name]
   -- In the case that the original table was removed but an alias is still relevant
   local function maybe_warn_unused(table_info, key, data)
      local table_name, ast_node = data[1], data[2]
      -- Warn if there were definitely no accesses for this value
      if not table_info.accessed_keys[key]
         and not table_info.potentially_all_accessed
      then
         chstate:warn_range("315", ast_node, {
            field = key,
            name = table_name
         })
      end
   end

   -- Called on accessing a table's field
   local function maybe_warn_undefined(table_name, key, range)
      -- Warn if the field is definitely not set
      if not current_tables[table_name].definitely_set_keys[key]
         and not current_tables[table_name].maybe_set_keys[key]
         and not current_tables[table_name].potentially_all_set
      then
         chstate:warn_range("325", range, {
            field = key,
            name = table_name
         })
      end
   end

   local function maybe_warn_undefined_var_key(table_name, var_key_name, range)
      if next(current_tables[table_name].definitely_set_keys) == nil
         and next(current_tables[table_name].maybe_set_keys) == nil
         and not current_tables[table_name].potentially_all_set
      then
         chstate:warn_range("325", range, {
            field = var_key_name,
            name = table_name
         })
      end
   end

   -- Called when setting a new key for a known local table
   local function set_key(table_name, key_node, assigned_val, in_init)
      local table_info = current_tables[table_name]
      -- Constant key
      if key_node.tag == "Number" or key_node.tag == "String" then
         local key = key_node[1]
         if key_node.tag == "Number" then
            key = tonumber(key)
         end
         -- Don't report duplicate keys in the init; other module handles that
         if table_info.definitely_set_keys[key] and not in_init then
            maybe_warn_unused(table_info, key, table_info.definitely_set_keys[key])
         end
         table_info.accessed_keys[key] = nil
         -- Variable set; variable could be nil
         if assigned_val.tag == "Id" then
            table_info.maybe_set_keys[key] = true
            table_info.definitely_set_keys[key] = nil
         elseif assigned_val.tag == "Nil" then
            table_info.definitely_set_keys[key] = nil
            table_info.maybe_set_keys[key] = nil
         else
            table_info.definitely_set_keys[key] = {table_name, key_node}
            table_info.maybe_set_keys[key] = nil
         end
      else
         -- variable key
         table_info.potentially_all_set = true
      end
   end

   -- Called when indexing into a known local table
   local function access_key(table_name, key_node)
      if key_node.tag == "Number" or key_node.tag == "String" then
         local key = key_node[1]
         if key_node.tag == "Number" then
            key = tonumber(key)
         end
         maybe_warn_undefined(table_name, key, key_node)
         current_tables[table_name].accessed_keys[key] = true
      else
         -- variable key
         local var_key_name = key_node.var and key_node.var.name or "[Non-atomic key]"
         maybe_warn_undefined_var_key(table_name, var_key_name, key_node)
         current_tables[table_name].potentially_all_accessed = true
      end
   end

   -- Called when a table variable is no longer accessible
   -- i.e. the scope has ended or the variable has been overwritten
   local function end_table_variable(table_name)
      local table_info = current_tables[table_name]
      table_info.aliases[table_name] = nil

      if next(table_info.aliases) == nil then
         for key, value in pairs(table_info.definitely_set_keys) do
            maybe_warn_unused(table_info, key, value)
         end
      end

      current_tables[table_name] = nil
   end

   -- Called on a new scope or function call
   -- Unlike end_table_variable, this assumes that any and all existing tables values
   -- Can potentially be accessed later on, and so doesn't warn about unused values
   local function stop_tracking_tables()
      for table_name in pairs(current_tables) do
         wipe_table_data(table_name)
      end
   end

   local function on_scope_end()
      -- Function definition; need to account for upval references
      -- from functions defined inside current func-or-file scope
      -- Can only do at file-or-func end, since otherwise we don't know
      -- what variables will be under consideration at the end
      for _,item in ipairs(func_or_file_scope.items) do
         if item.lines then
            for _,new_func_scope in ipairs(item.lines) do
               for var in pairs(new_func_scope.accessed_upvalues) do
                  if current_tables[var.name] then
                     current_tables[var.name].upvalue_reference = true
                  end
               end
            end
         end
      end

      -- Upvalue from outside current scope
      for var in pairs(func_or_file_scope.set_upvalues) do
         if current_tables[var.name] then
            current_tables[var.name].upvalue_reference = true
         end
      end

      for table_name, table_info in pairs(current_tables) do
         if not table_info.upvalue_reference then
            end_table_variable(table_name)
         end
      end
   end

   -- Records accesses to a specific key in a table
   local function record_field_accesses(node)
      if node.tag ~= "Function" then
         for index, sub_node in ipairs(node) do
            if type(sub_node) == "table" then
               if sub_node.var and current_tables[sub_node.var.name] then
                  -- Either we are accessing an index into the table, in which case we record the access
                  -- Or we are accessing the whole table, in which case we stop tracking it
                  if node.tag == "Index" and index == 1 then
                     access_key(sub_node.var.name, node[2])
                  end
               end
               record_field_accesses(sub_node)
            end
         end
      end
   end

   -- Records accesses to the table as a whole, i.e. for table x, either t[x] = val or x = t
   -- For the former, we stop tracking the table; for the latter, we mark x and t down as aliases if x is a local
   -- For existing table t, in "local x = t", x is passed in as the aliased node
   local function record_table_accesses(node, aliased_node)
      -- t[x or y] = val; x = t1 or t2
      if node[1] == "and" or node[1] == "or" then
         for _, sub_node in ipairs(node) do
            if type(sub_node) == "table" then
               record_table_accesses(sub_node)
            end
         end
      end

      -- t[{x}] = val; t = {x}; t = {[x] = val}; all keep x alive
      if node.tag == "Table" then
         for _, sub_node in ipairs(node) do
            if sub_node.tag == "Pair" then
               local key_node, val_node = sub_node[1], sub_node[2]
               record_table_accesses(key_node)
               record_table_accesses(val_node)
            elseif sub_node.tag ~= "Nil" then
               record_table_accesses(sub_node)
            end
         end
      end

      if node.var and current_tables[node.var.name] then
         if aliased_node and aliased_node.var then
            current_tables[aliased_node.var.name] = current_tables[node.var.name]
            current_tables[aliased_node.var.name].aliases[aliased_node.var.name] = true
         else
            wipe_table_data(node.var.name)
         end
      end
   end

   for _,item in ipairs(func_or_file_scope.items) do
      -- New control flow scope
      -- TODO: Ideally, this would check inside the child blocks using the current set of set/accessed keys
      -- Then pass out modifications/accessed as *potential* modifications/accesses

      -- Of note here: the control_flow_tags contain some duplicates, this is done deliberately
      -- for scope safety reasons. e.g. an "if" generates the initial "If", plus a closing "Jump";
      -- we wipe the scope both times, because if a local declared outside the if scope got assigned
      -- a table inside the if scope, we want to check the consequences of that assignment
      -- inside, but not assume outside the if that the table has the keys from inside
      if (item.tag == "Noop" and item.node and control_flow_tags[item.node.tag])
         or control_flow_tags[item.tag]
      then
         stop_tracking_tables()

      -- Function call
      -- TODO: ideally, this would attempt to check the function in question:
      -- For Invoke, check if self is accessed/modified (V1: boolean for all keys, V2: check specific keys)
      -- For Call, check if the table is an upvalue that is accessed/modified, as above
      -- For both, if the table is passed as a parameter
      elseif core_utils.contains_call(item.node) then
         stop_tracking_tables()

      -- Return
      elseif item.tag == "Noop" and item.node and item.node.tag == "Return" then
         record_field_accesses(item.node)
         for _, node in ipairs(item.node) do
            record_table_accesses(node)
         end

         -- Recall that we stop processing entirely if a control block is hit
         -- So returning, if there are any current tables, means that the function is over

         -- We need to explicitly check here, rather than going through to the fallback for
         -- the implicit return below, because an explicit "return" generates a "Jump" item
         -- See LinState:emit_stmt_Return
         -- And so causes us to stop tracking all tables due to changing control flow
         on_scope_end()

      -- Table modification, access, or creation
      elseif item.tag == "Local" or item.tag == "Set" then
         if item.rhs then
            record_field_accesses(item.rhs)
         end

         -- For imbalanced assignment with possible multiple return function
         local last_rhs_node = false
         for index, lhs_node in ipairs(item.lhs) do
            local rhs_node = item.rhs and item.rhs[index]
            if not rhs_node then
               if last_rhs_node and function_call_tags[last_rhs_node.tag] then
                  rhs_node = last_rhs_node
               else
                  -- Duck typing seems bad?
                  rhs_node = {
                     tag = "Nil"
                  }
               end
            else
               last_rhs_node = rhs_node
            end

            -- Case: $existing_table[key] = value
            if lhs_node.tag == "Index" then
               local base_node, key_node = lhs_node[1], lhs_node[2]
               -- Deliberately don't continue down indexes- $table[key1][key2] isn't a new set of key1
               if base_node.tag == "Id" then
                  -- Might not have a var if it's a global
                  local lhs_table_name = base_node.var and base_node.var.name
                  if current_tables[lhs_table_name] then
                     set_key(lhs_table_name, key_node, rhs_node)
                  end
               end

               -- Case: $var[$existing_table[key]] = value
               -- Need to pass in a new array rather than using lhs_node, because that would
               -- mark the base *set* as also being an access
               record_field_accesses({key_node})
               record_table_accesses(key_node)
            end

            -- Case: $existing_table = new_value
            -- Complete overwrite of previous value
            if item.tag == "Set" and lhs_node.var and current_tables[lhs_node.var.name] then
               end_table_variable(lhs_node.var.name)
            end

            record_table_accesses(rhs_node, lhs_node)

            -- Case: local $table = {} or local $table; $table = {}
            -- New table assignment
            if lhs_node.var and rhs_node.tag == "Table" then
               local table_var = lhs_node.var
               new_local_table(table_var.name)
               for initialization_index, node in ipairs(rhs_node) do
                  if node.tag == "Pair" then
                     local key_node, val_node = node[1], node[2]
                     set_key(table_var.name, key_node, val_node, true)
                  elseif node.tag ~= "Nil" then
                     -- Duck typing, meh
                     local key_node = {
                        [1] = initialization_index,
                        tag = "Number",
                        line = node.line,
                        offset = node.offset,
                        end_offset = node.end_offset
                     }
                     set_key(table_var.name, key_node, node, true)
                  end
               end
            end
         end

      end
   end

   -- Implicit return
   on_scope_end()
end

-- Warns about table fields that are never accessed
-- VERY high false-negative rate, deliberately in order to minimize the false-positive rate
function stage.run(chstate)
   for _, line in ipairs(chstate.lines) do
      detect_unused_table_fields(chstate, line)
   end
end

return stage
