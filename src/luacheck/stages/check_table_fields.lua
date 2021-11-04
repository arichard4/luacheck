local utils = require "luacheck.utils"
local builtin_standards = require 'luacheck.builtin_standards'

local stage = {}

stage.warnings = {
   ["315"] = {message_format = "value assigned to table field {name!}.{field!} is unused", fields = {"name", "field"}},
   ["325"] = {message_format = "table field {name!}.{field!} is not defined", fields = {"name", "field"}},
}

local function_call_tags = utils.array_to_set({"Call", "Invoke"})
-- Tags that delimit a control flow block; note that "Return" isn't on this list
local control_flow_tags = utils.array_to_set(
   {"Do", "While", "Repeat", "Fornum", "Forin", "If", "Label", "Goto", "Jump", "Cjump"}
)

-- Steps through the function or file scope one item at a time
-- At each point, tracking for each local table which fields have been set
local function detect_unused_table_fields(chstate, func_or_file_scope)
   -- A list of all local variables that are assigned tables
   local current_tables = {}
   -- A list of all local variables that are (1) upvalues from created functions,
   -- or (2) upvalues from outside the current scope
   local external_references = {}

   -- Start keeping track of a local table
   -- Can be from local x = {} OR "local x; x = {}"
   local function new_local_table(table_name)
      current_tables[table_name] = {
         -- set_keys sets store a mapping from key => {table_name, key_node, value_node}; the node has the line/column info
         set_keys = {},
         -- accessed keys is a mappings from key => true|nil
         accessed_keys = {},
         -- For a variable key, it's impossible to reliably get the value; any given key could be set or accessed
         potentially_all_set = false,
         potentially_all_accessed = false,
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
      if (not current_tables[table_name].set_keys[key]
            or current_tables[table_name].set_keys[key][3].tag == "Nil")
         and not current_tables[table_name].potentially_all_set
      then
         chstate:warn_range("325", range, {
            field = key,
            name = table_name
         })
      end
   end

   -- Called on accessing a table's field with a variable
   -- Can only warn if the table is known to be empty
   local function maybe_warn_undefined_var_key(table_name, var_key_name, range)
      if next(current_tables[table_name].set_keys) == nil
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
         if table_info.set_keys[key] and not in_init then
            maybe_warn_unused(table_info, key, table_info.set_keys[key])
         end
         table_info.accessed_keys[key] = nil
         -- Do note: just because a table's key has a value in set_keys doesn't
         -- mean that it's not nil! variables, function returns, table indexes,
         -- nil itself, and complex boolean conditions can return nil
         -- set_keys tracks *specifically* the set itself, not whether the table's
         -- field is non-nil
         table_info.set_keys[key] = {table_name, key_node, assigned_val}
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
         for key, value in pairs(table_info.set_keys) do
            maybe_warn_unused(table_info, key, value)
         end
      end

      current_tables[table_name] = nil
   end

   -- Called on a new control block scope
   -- Unlike end_table_variable, this assumes that any and all existing tables values
   -- Can potentially be accessed later on, and so doesn't warn about unused values
   local function stop_tracking_tables()
      for table_name in pairs(current_tables) do
         wipe_table_data(table_name)
      end
   end

   -- Called on a function call
   -- All tables which are potentially externally referenced can receive arbitrary modifications
   -- Two cases for external access:
   -- * Upvalue from outside the current scope
   -- * Upvalue to a function created in the current scope
   local function stop_tracking_externally_referenced_tables()
      for table_name in pairs(current_tables) do
         if external_references[table_name] then
            wipe_table_data(table_name)
         end
      end
   end

   local function on_scope_end()
      for table_name, table_info in pairs(current_tables) do
         local has_external_references = false
         for alias in pairs(table_info.aliases) do
            if external_references[alias] then
               has_external_references = true
            end
         end
         if has_external_references then
            wipe_table_data(table_name)
         else
            end_table_variable(table_name)
         end
      end
   end

   -- Functions which are known to not lead to touching any declared tables
   local function is_builtin_function(node)
      local call_node = node[1]
      local called_name = call_node[1]
      if builtin_standards.max[called_name] then
         if call_node.tag == "Index" then
            local key = call_node[2][1]
            if key.tag =="String" and builtin_standards.max[called_name][key] then
               -- Debug does weird stuff; invalidate everything
               return called_name ~= "debug" or key ~= "traceback"
            end
         else
            return true
         end
      end
   end

   local function check_for_function_calls(node)
      if function_call_tags[node.tag] then
         if not is_builtin_function(node) then
            stop_tracking_externally_referenced_tables()
         end
      end

      if node.tag ~= "Function" then
         for _, sub_node in ipairs(node) do
            if type(sub_node) == 'table' then
               check_for_function_calls(sub_node)
            end
         end
      end
   end

   -- Records accesses to a specific key in a table
   local function record_field_accesses(node)
      if node.tag ~= "Function" then
         for index, sub_node in ipairs(node) do
            if type(sub_node) == "table" then
               if sub_node.var and current_tables[sub_node.var.name] then
                  if node.tag == "Index" and index == 1 then
                     access_key(sub_node.var.name, node[2])
                  end
               end
               record_field_accesses(sub_node)
            end
         end
      end
   end

   local record_table_accesses

   -- More complicated than record_table_accesses below
   -- Because invocation can cause accesses to a table at an arbitrary point in logic:
   -- = t[x][y:func()] causes a reference to y (passed to func)
   local function record_table_invocations(node)
      if node.tag == "Invoke" then
         local self_node = node[1]
         if self_node.var and current_tables[self_node.var.name] then
            wipe_table_data(self_node.var.name)
         end
      end

      if function_call_tags[node.tag] then
         for _, sub_node in ipairs(node) do
            if type(sub_node) == 'table' then
               record_table_accesses(sub_node)
            end
         end
      elseif node.tag ~= "Function" then
         for _, sub_node in ipairs(node) do
            if type(sub_node) == 'table' then
               record_table_invocations(sub_node)
            end
         end
      end
   end

   -- Records accesses to the table as a whole, i.e. for table x, either t[x] = val or x = t
   -- For the former, we stop tracking the table; for the latter, we mark x and t down as aliases if x is a local
   -- For existing table t, in "local x = t", x is passed in as the aliased node
   function record_table_accesses(node, aliased_node)
      local alias_info = nil
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
            alias_info = {aliased_node.var.name, node.var.name}
         else
            wipe_table_data(node.var.name)
         end
      end

      record_table_invocations(node)
      return alias_info
   end

   -- Upvalue from outside current scope
   for var in pairs(func_or_file_scope.set_upvalues) do
      external_references[var.name] = true
   end

   for item_index ,item in ipairs(func_or_file_scope.items) do
      -- Add that this item potentially adds upvalue references to local variables
      if item.lines then
         for _,func_scope in ipairs(item.lines) do
            for var in pairs(func_scope.accessed_upvalues) do
               external_references[var.name] = true
            end
            for var in pairs(func_scope.set_upvalues) do
               external_references[var.name] = true
            end
            for var in pairs(func_scope.mutated_upvalues) do
               external_references[var.name] = true
            end
         end
      end

      if item.node then
         check_for_function_calls(item.node)
      end

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

      -- Return
      elseif item.tag == "Noop" and item.node and item.node.tag == "Return" then
         record_field_accesses(item.node)
         for _, node in ipairs(item.node) do
            record_table_accesses(node)
         end

         -- Need to jump ahead slightly and record any upvalues in returned functions
         for return_index in ipairs(item.node) do
            local ret_item = func_or_file_scope.items[item_index + return_index]
            if ret_item and ret_item.lines then
               for _,new_func_scope in ipairs(ret_item.lines) do
                  for var in pairs(new_func_scope.accessed_upvalues) do
                     external_references[var.name] = true
                  end
               end
            end
         end

         -- Recall that we stop processing entirely if a control block is hit
         -- So returning, if there are any current tables, means that the function is over

         -- We need to explicitly check here, rather than going through to the fallback for
         -- the implicit return below, because an explicit "return" generates a "Jump" item
         -- See LinState:emit_stmt_Return
         -- And so causes us to stop tracking all tables due to changing control flow
         on_scope_end()

      elseif item.tag == "Eval" then
         record_field_accesses(item.node)
         for _, node in ipairs(item.node) do
            record_table_accesses(node)
         end

      -- Table modification, access, or creation
      elseif item.tag == "Local" or item.tag == "Set" then
         -- Process RHS first, then LHS
         -- When creating an alias, i.e. $new_var = $existing_var, need to store that info
         -- and record it during LHS processing
         local alias_info = {}
         if item.rhs then
            record_field_accesses(item.rhs)
            for node_index, rhs_node in ipairs(item.rhs) do
               -- lhs here can be nil
               alias_info[node_index] = record_table_accesses(rhs_node, item.lhs[node_index])
            end
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

               -- Case: $var[$existing_table[key]] = value
               -- Need to pass in a new array rather than using lhs_node, because that would
               -- mark the base *set* as also being an access
               record_field_accesses({key_node})
               record_table_accesses(key_node)

               -- Deliberately don't continue down indexes- $table[key1][key2] isn't a new set of key1
               if base_node.tag == "Id" then
                  -- Might not have a var if it's a global
                  local lhs_table_name = base_node.var and base_node.var.name
                  if current_tables[lhs_table_name] then
                     set_key(lhs_table_name, key_node, rhs_node, false)
                  end
               end
            end

            -- Case: $existing_table = new_value
            -- Complete overwrite of previous value
            if item.tag == "Set" and lhs_node.var and current_tables[lhs_node.var.name] then
               end_table_variable(lhs_node.var.name)
            end

            if alias_info[index] then
               local new_var_name, existing_var_name = alias_info[index][1], alias_info[index][2]
               current_tables[new_var_name] = current_tables[existing_var_name]
               current_tables[new_var_name].aliases[new_var_name] = true
            end

            -- Case: local $table = {} or local $table; $table = {}
            -- New table assignment
            if lhs_node.var and rhs_node.tag == "Table" then
               local table_var = lhs_node.var
               new_local_table(table_var.name)
               for initialization_index, node in ipairs(rhs_node) do
                  if node.tag == "Pair" then
                     local key_node, val_node = node[1], node[2]
                     set_key(table_var.name, key_node, val_node, true)
                  elseif node.tag == "Dots" or node.tag == "Call" then
                     -- Vararg can expand to arbitrary size;
                     -- Function calls can return multiple values
                     current_tables[table_var.name].potentially_all_set = true
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
