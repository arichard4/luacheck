local utils = require "luacheck.utils"
local builtin_standards = require 'luacheck.builtin_standards'

local stage = {}

stage.warnings = {
   ["315"] = {
      message_format = "{set_is_nil}value assigned to table field {name!}.{field!} is unused",
      fields = {"set_is_nil", "name", "field"}
   },
   ["325"] = {message_format = "table field {name!}.{field!} is not defined", fields = {"name", "field"}},
}

local function_call_tags = utils.array_to_set({"Call", "Invoke"})

local function noop() end

local chstate

-- A list of all local variables that are assigned tables
local current_tables

-- When entering a new control flow block, we save the previous state of current_tables
local current_tables_from_outer_scopes = {}

-- An array of {local_name => true}; each new scope *doesn't* inherit the previous scopes' locals here
local local_variables_per_scope = {}

-- A list of all local variables that are (1) upvalues from created functions,
-- or (2) upvalues from outside the current scope, or (3) parameters passed in
local external_references_set -- variable value is potentially overwritten externally
local external_references_accessed -- variable fields are potentially all accessed externally
local external_references_mutated -- variable fields are potentially all mutated externally

-- Start keeping track of a local table
-- Can be from local x = {} OR "local x; x = {}"
local function new_local_table(table_name)
   current_tables[table_name] = {
      -- set_keys sets store a mapping from key => {table_name, key_node, value_node}
      -- the nodes store the line/column info
      set_keys = {},
      -- accessed keys is a mappings from key => key_node
      accessed_keys = {},
      -- For a variable key, it's impossible to reliably get the value; any given key could be set or accessed
      -- Set to the node responsible when truthy
      potentially_all_set = nil,
      potentially_all_accessed = nil,
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
local function maybe_warn_unused(table_info, key)
   local set_data = table_info.set_keys[key]
   local set_table_name, set_node, assigned_val = set_data.table_name, set_data.key_node, set_data.assigned_node
   local access_node = table_info.accessed_keys[key]
   local all_access_node = table_info.potentially_all_accessed
   -- Warn if there were definitely no accesses for this value
   if (not access_node or access_node.line < set_node.line)
      and (not all_access_node or all_access_node.line < set_node.line)
   then
      -- table.insert/table.remove can push around keys internally, so use the set_node's key
      local original_key = set_node.tag == "Number" and tonumber(set_node[1]) or set_node[1]
      chstate:warn_range("315", set_node, {
         name = set_table_name,
         field = original_key,
         set_is_nil = assigned_val.tag == "Nil" and "nil " or ""
      })
   end
end

-- Called on accessing a table's field
local function maybe_warn_undefined(table_name, key, range)
   -- Warn if the field is definitely not set
   local set_data = current_tables[table_name].set_keys[key]
   local set_node, set_val
   if set_data then
      set_node, set_val = set_data.key_node, set_data.assigned_node
   end
   local all_set = current_tables[table_name].potentially_all_set
   if (not set_data and not all_set)
      or (set_data and set_val.tag == "Nil" and (not all_set or set_node.line > all_set.line))
   then
      chstate:warn_range("325", range, {
         name = table_name,
         field = key
      })
   end
end

-- Called on accessing a table's field with an unknown key
-- Can only warn if the table is known to be empty
local function maybe_warn_undefined_var_key(table_name, var_key_name, range)
   -- Are there any non-nil keys at all?
   local potentially_set = not not current_tables[table_name].potentially_all_set
   for _, set_data in pairs(current_tables[table_name].set_keys) do
      if set_data.assigned_node.tag ~= "Nil" then
         potentially_set = true
      end
   end
   if not potentially_set then
      chstate:warn_range("325", range, {
         name = table_name,
         field = var_key_name
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
         maybe_warn_unused(table_info, key)
      end
      table_info.accessed_keys[key] = nil
      -- Do note: just because a table's key has a value in set_keys doesn't
      -- mean that it's not nil! variables, function returns, table indexes,
      -- nil itself, and complex boolean conditions can return nil
      -- set_keys tracks *specifically* the set itself, not whether the table's
      -- field is non-nil
      table_info.set_keys[key] = {
         table_name = table_name,
         key_node = key_node,
         assigned_node = assigned_val
      }
   else
      -- variable key
      if assigned_val.tag ~= "Nil" then
         table_info.potentially_all_set = key_node
      end
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
      current_tables[table_name].accessed_keys[key] = key_node
   else
      -- variable key
      local var_key_name = key_node.var and key_node.var.name or "[Non-atomic key]"
      maybe_warn_undefined_var_key(table_name, var_key_name, key_node)
      current_tables[table_name].potentially_all_accessed = key_node
   end
end

-- Called when a table variable is no longer accessible
-- i.e. the scope has ended or the variable has been overwritten
local function end_table_variable(table_name)
   local table_info = current_tables[table_name]
   table_info.aliases[table_name] = nil

   if next(table_info.aliases) == nil then
      for key in pairs(table_info.set_keys) do
         maybe_warn_unused(table_info, key)
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

local function on_scope_end_for_var(table_name, table_info)
   local has_external_references = false
   for alias in pairs(table_info.aliases) do
      if external_references_accessed[alias] then
         has_external_references = true
      end
   end
   if has_external_references then
      wipe_table_data(table_name)
   else
      end_table_variable(table_name)
   end
end

local function on_scope_end()
   for table_name, table_info in pairs(current_tables) do
      on_scope_end_for_var(table_name, table_info)
   end
end

-- Called on a function call
-- All tables which are potentially externally referenced can receive arbitrary modifications
-- Two cases for external access:
-- * Upvalue from outside the current scope
-- * Upvalue to a function created in the current scope
local function enter_unknown_scope(node)
   for table_name in pairs(current_tables) do
      if external_references_set[table_name] then
         wipe_table_data(table_name)
      else
         if external_references_accessed[table_name] then
            current_tables[table_name].potentially_all_accessed = node
            -- Unfortunately mutate vs. access only checks in-line
            -- So an access can pass the table elsewhere that then mutates
            -- e.g. function() table.insert(t, 1) end is an access that
            -- causes a mutation
            current_tables[table_name].potentially_all_set = node
         end
         if external_references_mutated[table_name] then
            current_tables[table_name].potentially_all_set = node
         end
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
         if key.tag == "String" and builtin_standards.max[called_name][key] then
            -- Debug does weird stuff; invalidate everything
            return called_name ~= "debug" or key ~= "traceback"
         end
      else
         return true
      end
   end
end

-- A function call leaves the current scope, and does potentially arbitrary modifications
-- To any externally referencable tables: either upvalues to other functions
-- Or parameters
local function check_for_function_calls(node)
   if function_call_tags[node.tag] then
      if not is_builtin_function(node) then
         enter_unknown_scope(node)
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

-- Like #, but excludes known nil values
local function get_table_length(set_keys)
   local temp_table = {}
   for key, set_info in pairs(set_keys) do
      if set_info.assigned_node.tag ~= "Nil" then
         temp_table[key] = true
      end
   end
   return #temp_table
end

local function process_table_insert(node)
   local table_param = node[2]
   if table_param
      and table_param.var
      and current_tables[table_param.var.name]
   then
      local insert_key, inserted_val
      if node[4] then
         insert_key = node[3]
         if insert_key.tag == "String" and tonumber(insert_key[1]) then
            insert_key = utils.deepcopy(insert_key)
            insert_key.tag = "Number"
            insert_key[1] = tonumber(insert_key[1])
         end
         inserted_val = node[4]
      else
         inserted_val = node[3]
      end
      if not insert_key then
         local table_info = current_tables[table_param.var.name]
         if table_info.potentially_all_set then
            table_info.potentially_all_set = node
            return
         else
            -- table.insert skips over gaps in the array part
            local max_int_key = get_table_length(table_info.set_keys)
            insert_key = {
               [1] = max_int_key + 1,
               tag = "Number",
               line = node.line,
               offset = node.offset,
               end_offset = node.end_offset
            }

         end
      end
      set_key(table_param.var.name, insert_key, inserted_val, false)
   end

   -- t[$existing_table] = val
   if node[3] then
      record_table_accesses(node[3])
   end
   -- t[key] = $existing_table
   if node[4] then
      record_table_accesses(node[4])
   end
end

local function process_table_remove(node)
   local table_param = node[2]
   if table_param
      and table_param.var
      and current_tables[table_param.var.name]
   then
      local table_name = table_param.var.name
      local table_info = current_tables[table_name]

      local removal_key = node[3]
      if removal_key and removal_key.tag ~= "Number" then
         if removal_key.tag == "String" and tonumber(removal_key[1]) then
            removal_key = utils.deepcopy(removal_key)
            removal_key.tag = "Number"
            removal_key[1] = tonumber(removal_key[1])
         else
            table_info.potentially_all_set = node
            table_info.potentially_all_accessed = node
            return
         end
      end

      if table_info.potentially_all_set then
         table_info.potentially_all_set = node
         if removal_key then
            access_key(table_name, removal_key)
         else
            table_info.potentially_all_accessed = node
         end
         return
      end

      local max_int_key = get_table_length(table_info.set_keys)
      if not removal_key then
         removal_key = {
            [1] = max_int_key > 0 and max_int_key or 1,
            tag = "Number",
            line = node.line,
            offset = node.offset,
            end_offset = node.end_offset
         }
      end

      if max_int_key == 0 or tonumber(removal_key[1]) > max_int_key then
         access_key(table_name, removal_key)
         return
      end

      access_key(table_name, removal_key)
      local nil_insert_val = {
         tag = "Nil",
         line = node.line,
         offset = node.offset,
         end_offset = node.end_offset
      }
      for index = tonumber(removal_key[1]), max_int_key - 1 do
         local replaced_key
         if table_info.set_keys[index] then
            replaced_key = utils.deepcopy(table_info.set_keys[index].key_node)
            replaced_key[1] = index
         else
            replaced_key = {
               index,
               line = node.line,
               offset = node.offset,
               end_offset = node.end_offset,
               tag = "Number"
            }
         end
         
         local replacing_val 
         if table_info.set_keys[index + 1] then
            replacing_val = table_info.set_keys[index + 1].assigned_node
         else
            replacing_val = utils.deepcopy(nil_insert_val)
         end
         set_key(table_name, replaced_key, replacing_val, false)
         if table_info.set_keys[index + 1] then
            removal_key = utils.deepcopy(removal_key)
            removal_key[1] = index + 1
            access_key(table_name, removal_key)
         end
      end
      removal_key = utils.deepcopy(removal_key)
      removal_key[1] = max_int_key
      set_key(table_name, removal_key, nil_insert_val, false)
   end
end

-- iterator is pairs or ipairs
local function access_all_fields(node, iterator)
   local table_param = node[2]
   if table_param
      and table_param.var
      and current_tables[table_param.var.name]
   then
      local table_info = current_tables[table_param.var.name]
      if table_info.potentially_all_set then
         table_info.potentially_all_accessed = table_param
      else
         for key, set_info in iterator(table_info.set_keys) do
            if set_info and set_info.assigned_node.tag ~= "Nil" then
               access_key(
                  table_param.var.name,
                  {
                     [1] = key,
                     tag = node.tag,
                     line = node.line,
                     offset = node.offset,
                     end_offset = node.end_offset
                  }
               )
            end
         end
      end
   end
end

local function process_next(node)
   local table_param = node[2]
   if table_param
      and table_param.var
      and current_tables[table_param.var.name]
   then
      local table_info = current_tables[table_param.var.name]
      table_info.potentially_all_accessed = node
   end
end

-- Note: table sort will fail on gaps in the array part of the table
-- So it's a noop in terms of which keys are defined
local builtin_funcs = {
   table = {
      insert = process_table_insert,
      remove = process_table_remove,
      sort = noop,
      concat = function(node) access_all_fields(node, ipairs) end
   },
   type = noop,
   pairs = function(node) access_all_fields(node, pairs) end,
   ipairs = function(node) access_all_fields(node, ipairs) end,
   next = process_next
}

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
      local call_node = node[1]
      -- Possibly a builtin table function
      -- Custom handling for insert/remove/sort/concat/pairs/ipairs/type/next
      if call_node.tag == "Index"
         and builtin_funcs[call_node[1][1]]
         and builtin_funcs[call_node[1][1]][call_node[2][1]]
      then
         builtin_funcs[call_node[1][1]][call_node[2][1]](node)
      elseif call_node.tag == "Id"
         and builtin_funcs[call_node[1]]
      then
         builtin_funcs[call_node[1]](node)
      else
         for _, sub_node in ipairs(node) do
            if type(sub_node) == 'table' then
               record_table_accesses(sub_node)
            end
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
   record_table_invocations(node)

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

   return alias_info
end

-- Detects accesses to tables and table fields in item
-- For the case local $var = $existing table, returns a table
-- of multiple assignment index => {newly_set_var_name, existing_table_name}
local function detect_accesses(sub_nodes, potential_aliases)
   local alias_info = {}
   record_field_accesses(sub_nodes)
   for node_index, node in ipairs(sub_nodes) do
      alias_info[node_index] = record_table_accesses(node, potential_aliases and potential_aliases[node_index])
   end
   return alias_info
end

local function handle_control_flow_item(item)
   if item.node and item.node.tag == "Return" then
      -- Do nothing here
      -- Recall that we assume we only handle a single control block at a time
      -- So we can fall through to the end-of-scope check
      -- Unless there's unreachable code, but that's reported separately
      return
   else
      if item.node and item.node.tag == "Do" then
         -- Simplest case: do doesn't lead to branching scope
         if item.scope_end then
            local outer_scope_current_tables = table.remove(current_tables_from_outer_scopes)
            local ended_scope_new_locals = table.remove(local_variables_per_scope)
            for table_name, table_info in pairs(current_tables) do
               if ended_scope_new_locals[table_name] then
                  on_scope_end_for_var(table_name, table_info)
               else
                  outer_scope_current_tables[table_name] = table_info
               end
            end
            current_tables = outer_scope_current_tables
         else
            table.insert(local_variables_per_scope, {})
            table.insert(current_tables_from_outer_scopes, current_tables)
            current_tables = utils.deepcopy(current_tables)
         end
      -- TODO: Support if/elseif/else
      -- elseif item.node and item.node.tag == "If" then
      else
         -- Will never support Goto/Label, they're too weird
         -- Doesn't currently support loops; they're complicated because the end state could end up
         -- Being the start state, i.e. they're non-linear
         stop_tracking_tables()
      end
   end
end

local function handle_local_or_set_item(item)
   -- Process RHS first, then LHS
   -- When creating an alias, i.e. $new_var = $existing_var, need to store that info
   -- and record it during LHS processing
   local alias_info = {}
   if item.rhs then
      alias_info = detect_accesses(item.rhs, item.lhs)
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

      if item.tag == "Local" then
         if lhs_node.tag == "Id" then
            local_variables_per_scope[#local_variables_per_scope][lhs_node.var.name] = true
         end
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
               current_tables[table_var.name].potentially_all_set = node
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

local function handle_eval(item)
   detect_accesses({item.node})
end

local item_callbacks = {
   Noop = handle_control_flow_item,
   Jump = noop,
   Cjump = noop,
   Eval = handle_eval,
   Local = handle_local_or_set_item,
   Set = handle_local_or_set_item
}

-- Steps through the function or file scope one item at a time
-- At each point, tracking for each local table which fields have been set
local function detect_unused_table_fields(func_or_file_scope)
   current_tables = {}
   table.insert(local_variables_per_scope, {})

   external_references_set, external_references_accessed, external_references_mutated = {}, {}, {}
   local args = func_or_file_scope.node[1]
   for _, parameter in ipairs(args) do
      local_variables_per_scope[#local_variables_per_scope][parameter.var.name] = true
      external_references_accessed[parameter.var.name] = true
      external_references_mutated[parameter.var.name] = true
   end

   -- Upvalues from outside current scope
   -- Only need to check set_upvalues because we only track newly set tables
   -- Inside the current scope
   for var in pairs(func_or_file_scope.set_upvalues) do
      external_references_set[var.name] = true
      external_references_accessed[var.name] = true
      external_references_mutated[var.name] = true
   end

   for item_index = 1, #func_or_file_scope.items do
      local item = func_or_file_scope.items[item_index]
      -- Add that this item potentially adds upvalue references to local variables
      -- If it contains a new function declaration
      if item.lines then
         for _,func_scope in ipairs(item.lines) do
            for var in pairs(func_scope.accessed_upvalues) do
               external_references_accessed[var.name] = true
            end
            for var in pairs(func_scope.set_upvalues) do
               external_references_set[var.name] = true
            end
            for var in pairs(func_scope.mutated_upvalues) do
               external_references_mutated[var.name] = true
            end
         end
      end

      if item.tag ~= "Noop" and item.node then
         check_for_function_calls(item.node)
      end

      item_callbacks[item.tag](item)
   end

   -- Handle implicit return
   on_scope_end()
end

-- Warns about table fields that are never accessed
-- VERY high false-negative rate, deliberately in order to minimize the false-positive rate
function stage.run(check_state)
   chstate = check_state
   for _, line in ipairs(chstate.lines) do
      detect_unused_table_fields(line)
   end
end

return stage
