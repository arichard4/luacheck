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
local loop_types = utils.array_to_set({"While", "Fornum", "Forin", "Repeat"})
local branching_scope_types = utils.array_to_set({"If", "While", "Fornum", "Forin"})

local function noop() end

local chstate

-- A list of all local variables that are assigned tables
local current_tables

-- Stores auxiliary information about the current scope
local current_scope

-- When set to true, concludes that the file can't be understand and gives up
local give_up_processing = false

local previous_scopes = {}

-- Map from item index to {has_else = true|false, array of scopes}
local scopes_to_merge_at_index = {}

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
      -- Like set_keys, but for sets than only occur in some, not all, branches
      maybe_set_keys = {},
      -- accessed keys is a mappings from key => key_node
      accessed_keys = {},
      -- For a variable key, it's impossible to reliably get the value; any given key could be set or accessed
      -- Set to the node responsible when truthy
      potentially_all_set = nil,
      potentially_all_accessed = nil,
      -- Multiple variable names that point at the same underlying table
      -- e.g. local x = {}; local t = x
      aliases = {[table_name] = true},
      shadowed_aliases = {},
   }
end

local function enter_new_scope(scope_node, scope_type)
   if current_tables then
      table.insert(previous_scopes, current_scope)
      current_tables = utils.deepcopy(current_tables)
   else
      current_tables = {}
   end
   current_scope = {
      -- An array of local names; each new scope *doesn't* inherit the previous scopes' locals here
      -- Stored in order, i.e. the first declared local is first
      -- Also includes the information about the overwritten variable, if any
      -- i.e. local x = {}; do x[1] = 1; x = {} end; we need to store that the outer scope var had changes
      locals = {},
      scope_definitely_returns = false,
      -- At the end of the current scope, where do we jump to?
      -- Overwritten on each jump, we only care about the final one
      -- e.g. in the case of If...end, if there's an elseif/else
      -- we only care about the end
      index_current_scope_jumps_to = nil,
      current_tables = current_tables,
      scope_node = scope_node,
      scope_type = scope_type
   }
end

local function scope_has_local(scope, local_name)
   for _, var_info in pairs(scope.locals) do
      if var_info.name == local_name then
         return true
      end
   end
   return false
end

-- Detects the following case:
-- local t = {}; for i=1,10 do table.insert(t, 1) end
local function is_table_from_outside_loop(table_name)
   if scope_has_local(current_scope, table_name) then
      return false
   end
   local has_encountered_loop_scope = loop_types[current_scope.scope_type] or false
   for _, scope in utils.ripairs(previous_scopes) do
      if scope_has_local(scope, table_name) then
         break
      end
      if loop_types[scope.scope_type] then
         has_encountered_loop_scope = true
      end
   end
   return has_encountered_loop_scope
end

local function register_new_local(local_name)
   if not scope_has_local(current_scope, local_name) then
      local local_info = {name = local_name}
      if current_tables[local_name] then
         local table_info = current_tables[local_name]
         local_info.overwritten_table_info = table_info
         current_tables[local_name] = nil
         table_info.aliases[local_name] = nil
         table_info.shadowed_aliases[local_info] = true
      end
      table.insert(current_scope.locals, local_info)
   end
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
local function maybe_warn_unused(table_info, key, set_data)
   local set_table_name, set_node, assigned_val = set_data.table_name, set_data.key_node, set_data.assigned_node
   local access_node = table_info.accessed_keys[key]
   local all_access_node = table_info.potentially_all_accessed
   -- Warn if there were definitely no accesses for this value
   if (not access_node or access_node.line < set_node.line)
      and (not all_access_node or all_access_node.line < set_node.line)
   then
      -- if it's from a branching previous scope, don't report here
      -- i.e. an overwrite in one "if" or in a branch shouldn't produce a warning
      local has_encountered_branching_scope = branching_scope_types[current_scope.scope_type]
      for scope_index = #previous_scopes, 1, -1 do
         local outer_scope = previous_scopes[scope_index]
         if outer_scope.current_tables[set_table_name]
            and ((outer_scope.current_tables[set_table_name].set_keys[key]
               and outer_scope.current_tables[set_table_name].set_keys[key].key_node.line == set_node.line)
            or (outer_scope.current_tables[set_table_name].maybe_set_keys[key]
               and outer_scope.current_tables[set_table_name].maybe_set_keys[key].key_node.line == set_node.line))
         then
            -- Between the new set and the earliest accessible set, is there an "If" scope?
            if has_encountered_branching_scope then
               return
            end
         else
            break
         end
         has_encountered_branching_scope = has_encountered_branching_scope
            or branching_scope_types[outer_scope.scope_type]
      end

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
   -- Loops can produce a different starting value for tables than expected
   -- Don't attempt to handle this case for now
   if is_table_from_outside_loop(table_name) then
      return
   end
   local table_info = current_tables[table_name]
   -- Warn if the field is definitely not set
   local set_data = table_info.set_keys[key] or table_info.maybe_set_keys[key]
   local set_node, set_val
   if set_data then
      set_node, set_val = set_data.key_node, set_data.assigned_node
   end
   local all_set = table_info.potentially_all_set
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
   -- Loops can produce a different starting value for tables than expected
   -- Don't attempt to handle this case for now
   if is_table_from_outside_loop(table_name) then
      return
   end
   -- Are there any non-nil keys at all?
   if current_tables[table_name].potentially_all_set then
      return
   end
   for _, set_data in pairs(current_tables[table_name].set_keys) do
      if set_data.assigned_node.tag ~= "Nil" then
         return
      end
   end
   for _, set_data in pairs(current_tables[table_name].maybe_set_keys) do
      if set_data.assigned_node.tag ~= "Nil" then
         return
      end
   end
   chstate:warn_range("325", range, {
      name = table_name,
      field = var_key_name
   })
end

-- Called when setting a new key for a known local table
local function set_key(table_name, key_node, assigned_val, in_init)
   local table_info = current_tables[table_name]
   -- Constant key
   if key_node.tag == "Number" or key_node.tag == "String" then
      -- Don't warn about unused nil initializations
      -- Fairly common to declare that a table should end up with fields set
      -- by setting them to nil in the constructor
      if in_init and assigned_val.tag == "Nil" then
         return
      end
      local key = key_node[1]
      if key_node.tag == "Number" then
         key = tonumber(key)
      end
      -- Don't report duplicate keys in the init; other module handles that
      if table_info.set_keys[key] and not in_init then
         maybe_warn_unused(table_info, key, table_info.set_keys[key])
      end
      if table_info.maybe_set_keys[key] then
         maybe_warn_unused(table_info, key, table_info.maybe_set_keys[key])
      end
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
      table_info.maybe_set_keys[key] = nil
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
      if next(table_info.shadowed_aliases) == nil then
         for key, set_data in pairs(table_info.set_keys) do
            maybe_warn_unused(table_info, key, set_data)
         end
         for key, set_data in pairs(table_info.maybe_set_keys) do
            maybe_warn_unused(table_info, key, set_data)
         end
      end
   end

   current_tables[table_name] = nil
end

local function on_scope_end_for_var(table_name)
   local table_info = current_tables[table_name]
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
   for table_name in pairs(current_tables) do
      on_scope_end_for_var(table_name)
   end
end

-- Called on a function call
-- All tables which are potentially externally referenced can receive arbitrary modifications
-- Two cases for external access:
-- * Upvalue from outside the current scope
-- * Upvalue to a function created in the current scope
local function enter_unknown_scope(node)
   for table_name in pairs(current_tables) do
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
      -- The variable could be overwritten with another table that has different keys set
      if external_references_set[table_name] then
         current_tables[table_name].potentially_all_set = node
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
   return false
end

-- A function call leaves the current scope, and does potentially arbitrary modifications
-- To any externally referencable tables: either upvalues to other functions
-- Or parameters
local function check_for_function_calls(node)
   if node.tag ~= "Function" then
      if function_call_tags[node.tag] and not is_builtin_function(node) then
         enter_unknown_scope(node)
         return
      end

      for _, sub_node in ipairs(node) do
         if type(sub_node) == "table" then
            check_for_function_calls(sub_node)
         end
      end
   end
end

-- Records accesses to a specific key in a table
local function record_field_accesses(node)
   if node.tag ~= "Function" then
      if node.tag == "Index" and node[1] then
         local sub_node = node[1]
         if sub_node.var and current_tables[sub_node.var.name] then
            access_key(sub_node.var.name, node[2])
         end
      end
      for _, sub_node in ipairs(node) do
         if type(sub_node) == "table" then
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
   -- t[$existing_table] = val
   if node[3] then
      record_table_accesses(node[3])
   end
   -- t[key] = $existing_table
   if node[4] then
      record_table_accesses(node[4])
   end

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
         if table_info.potentially_all_set
            or next(table_info.maybe_set_keys) ~= nil
            or is_table_from_outside_loop(table_param.var.name)
         then
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

      if table_info.potentially_all_set
         or is_table_from_outside_loop(table_name)
         or next(table_info.maybe_set_keys) ~= nil
      then
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
      if table_info.potentially_all_set
         or is_table_from_outside_loop(table_param.var.name)
      then
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
         for key in pairs(table_info.maybe_set_keys) do
            -- Assume that ipairs accesses all numeric keys
            if iterator == pairs or type(key) == "number" then
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
   if function_call_tags[node.tag] then
      if node.tag == "Invoke" then
         local self_node = node[1]
         if self_node.var and current_tables[self_node.var.name] then
            current_tables[self_node.var.name].potentially_all_accessed = node
            current_tables[self_node.var.name].potentially_all_set = node
         end
      end

      local call_node = node[1]
      -- Possibly a builtin table function
      -- Custom handling for insert/remove/sort/concat/pairs/ipairs/type/next
      if call_node.tag == "Index"
         and builtin_funcs[call_node[1][1]]
         and builtin_funcs[call_node[1][1]][call_node[2][1]]
      then
         builtin_funcs[call_node[1][1]][call_node[2][1]](node)
      elseif call_node.tag == "Id"
         and call_node[1] ~= "table"
         and builtin_funcs[call_node[1]]
      then
         builtin_funcs[call_node[1]](node)
      else
         for _, sub_node in ipairs(node) do
            record_table_accesses(sub_node)
         end
      end
   elseif node.tag ~= "Function" then
      for _, sub_node in ipairs(node) do
         if type(sub_node) == "table" then
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

   local alias_info = nil
   if node.var and current_tables[node.var.name] then
      -- $lhs = $tracked_table
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
   for node_index, node in ipairs(sub_nodes) do
      record_field_accesses(node)
      alias_info[node_index] = record_table_accesses(node, potential_aliases and potential_aliases[node_index])
   end
   return alias_info
end

local function clear_locals_on_scope_end()
   for _,var_info in utils.ripairs(current_scope.locals) do
      local var_name, table_info = var_info.name, var_info.overwritten_table_info
      if current_tables[var_name] then
         on_scope_end_for_var(var_name)
      end
      if table_info then
         for alias in pairs(table_info.aliases) do
            if current_tables[alias] then
               table_info = current_tables[alias]
               break
            end
         end
         current_tables[var_name] = table_info
         table_info.aliases[var_name] = true
         table_info.shadowed_aliases[var_info] = nil
      end
   end
end

local function handle_control_flow_item(item)
   if item.node and item.control_block_type == "Return" then
      -- Do nothing here
      -- Recall that we assume we only handle a single control block at a time
      -- So we can fall through to the end-of-scope check
      -- Unless there's unreachable code, but that's reported separately
      current_scope.scope_definitely_returns = true
      return
   elseif item.control_block_type == "Goto" or item.control_block_type == "Label" then
      -- Will never support Goto/Label, they're too weird
      give_up_processing = true
   elseif not item.scope_end then
      enter_new_scope(item.node, item.control_block_type)
   elseif item.control_block_type == "Do" then
      -- Simplest case: do doesn't lead to branching scope
      clear_locals_on_scope_end()
      local has_return = current_scope.scope_definitely_returns
      current_scope = table.remove(previous_scopes)
      current_scope.scope_definitely_returns = has_return
      current_scope.current_tables = current_tables
   elseif item.control_block_type == "If" then
      clear_locals_on_scope_end()
      local has_return = current_scope.scope_definitely_returns
      local dest_index = current_scope.index_current_scope_jumps_to
      if not scopes_to_merge_at_index[dest_index] then
         scopes_to_merge_at_index[dest_index] = {
            has_else = false,
            always_returning_scopes = {}
         }
      end
      if has_return then
         table.insert(scopes_to_merge_at_index[dest_index].always_returning_scopes, current_scope)
      else
         table.insert(scopes_to_merge_at_index[dest_index], current_scope)
      end
      if item.is_else then
         scopes_to_merge_at_index[dest_index].has_else = true
      end
      current_scope = table.remove(previous_scopes)
      current_tables = current_scope.current_tables
   elseif loop_types[item.control_block_type] then
      -- Loops are tremendously difficult to support
      -- Because they can have an initial state that differs from the state from the block before the loop
      -- And because they can execute multiple times
      -- Ideally, this would track assignments through to the end, then re-analyze
      -- TODO
      -- Too complicated for now, so instead I'll do the dumbest way to handle it: ignore accesses
      -- to non-locals in loops, assume that table.remove can access anything and table.insert can
      -- insert anything
      -- Another simplification: *in theory*, a loop could not be entered.
      -- *In practice*, that doesn't matter here: any logic done inside a loop can't produce false positives
      current_scope = table.remove(previous_scopes)
      current_scope.current_tables = current_tables
   end
end

local function handle_local_or_set_item(item)
   check_for_function_calls(item.node)

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
         detect_accesses({key_node})

         -- Deliberately don't continue down indexes- $table[key1][key2] isn't a new set of key1
         if base_node.tag == "Id" then
            -- Might not have a var if it's a global
            local lhs_table_name = base_node.var and base_node.var.name
            if current_tables[lhs_table_name] then
               set_key(lhs_table_name, key_node, rhs_node, false)
            end
         end
      end

      -- Also handles backing up shadowed values
      if item.tag == "Local" then
         if lhs_node.tag == "Id" then
            register_new_local(lhs_node.var.name)
         end
      end

      if alias_info[index] then
         local new_var_name, existing_var_name = alias_info[index][1], alias_info[index][2]
         current_tables[new_var_name] = current_tables[existing_var_name]
         current_tables[new_var_name].aliases[new_var_name] = true
      end

      -- Case: $existing_table = new_value
      -- Complete overwrite of previous value
      if lhs_node.var and current_tables[lhs_node.var.name] then
         -- $existing_table = $existing_table should do nothing
         if not (rhs_node.var 
            and current_tables[rhs_node.var.name] == current_tables[lhs_node.var.name])
         then
            end_table_variable(lhs_node.var.name)
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
               break
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
   check_for_function_calls(item.node)
   detect_accesses({item.node})
end

local function update_cur_scope_jumps(item)
   current_scope.index_current_scope_jumps_to = item.to
end

local item_callbacks = {
   Noop = handle_control_flow_item,
   Jump = update_cur_scope_jumps,
   Cjump = update_cur_scope_jumps,
   Eval = handle_eval,
   Local = handle_local_or_set_item,
   Set = handle_local_or_set_item
}

local function merge_in_scope_accesses(always_returning_scopes)
   for table_name, table_info in pairs(current_tables) do
      for _,scope in ipairs(always_returning_scopes) do
         local scope_table_info = scope.current_tables[table_name]
         if scope_table_info then
            if not table_info.potentially_all_accessed
               or (scope_table_info.potentially_all_accessed
                  and scope_table_info.potentially_all_accessed.line > table_info.potentially_all_accessed.line)
            then
               table_info.potentially_all_accessed = scope_table_info.potentially_all_accessed
            end
            for key, access_info in pairs(scope_table_info.accessed_keys) do
               if not table_info.accessed_keys[key]
                  or access_info.line > table_info.accessed_keys[key].line
               then
                  table_info.accessed_keys[key] = access_info
               end
            end
         else
            -- If the table went out of scope in a returned scope, don't wipe it, but mark all fields as
            -- potentially accessed
            table_info.potentially_all_accessed = scope.scope_node
         end
      end
   end
end

-- local x = {1}; if 1 then x[1] = 2 else x[1] = 3 end
-- Need to check at branch scope end for keys overwritten on all branches
local function check_for_overwritten_keys(prev_tables)
   for table_name, prev_table_info in pairs(prev_tables) do
      if current_tables[table_name] then
         for key, set_info in pairs(prev_table_info.set_keys) do
            local new_set_info = current_tables[table_name].set_keys[key]
               or current_tables[table_name].maybe_set_keys[key]
            if not new_set_info or new_set_info.key_node.line > set_info.key_node.line then
               maybe_warn_unused(current_tables[table_name], key, set_info)
            end
         end
      end
   end
end

local function merge_scopes_at_index(index)
   local scopes = scopes_to_merge_at_index[index]
   if not scopes then return end
   if #scopes == 0 then
      if scopes.has_else then
         current_scope.scope_definitely_returns = true
      end
      merge_in_scope_accesses(scopes.always_returning_scopes)
      return
   end

   if #scopes == 1 and scopes.has_else then
      local prev_tables = current_tables
      current_tables = scopes[1].current_tables
      current_scope.current_tables = current_tables
      merge_in_scope_accesses(scopes.always_returning_scopes)
      check_for_overwritten_keys(prev_tables)
      return
   end

   if not scopes.has_else then
      table.insert(scopes, 1, current_scope)
   end

   -- Get variables that are tables in all merged scopes
   local table_names = {}
   for table_name in pairs(scopes[1].current_tables) do
      table_names[table_name] = true
   end
   for scope_index = 2, #scopes do
      local tables = scopes[scope_index].current_tables
      for table_name in pairs(table_names) do
         if not tables[table_name] then
            table_names[table_name] = nil
         end
      end
   end

   -- For those variables, make set_keys the intersection of the various scopes' set_keys
   -- Add maybe_set_keys for keys only set in some scopes
   -- Make potentially_all_set and potentially_all_accessed the 'or' of the various values
   -- Makes accessed_keys the union of the various values
   -- If the aliases aren't identical, wipe the table data for all aliases (unanalyzable)
   local prev_tables = current_tables
   current_tables = {}
   local unanalyzable_tables = {}
   for table_name in pairs(table_names) do
      new_local_table(table_name)
      local table_info = current_tables[table_name]
      table_info.aliases = scopes[1].current_tables[table_name].aliases
      -- Track how many branches each key is set in
      local maybe_set_keys = {}
      local set_keys = {}
      for _,scope in utils.ripairs(scopes) do
         local scope_table_info = scope.current_tables[table_name]
         -- Order matters, due to line number checks later values should always overwrite earlier ones
         for key, set_info in pairs(scope_table_info.set_keys) do
            local prev_count = set_keys[key] and set_keys[key][1] or 0
            -- Prefer non-nil set_info even if earlier
            set_info = (set_keys[key] and set_keys[key][2].assigned_node.line < set_info.assigned_node.line)
               and set_keys[key][2]
               or set_info
            set_keys[key] = {prev_count + 1, set_info}
         end
         for key, set_info in pairs(scope_table_info.maybe_set_keys) do
            if not maybe_set_keys[key] or set_info.assigned_node.tag ~= "Nil" then
               maybe_set_keys[key] = set_info
            end
         end
         table_info.potentially_all_set = scope_table_info.potentially_all_set or table_info.potentially_all_set
         table_info.potentially_all_accessed = table_info.potentially_all_accessed
            or scope_table_info.potentially_all_accessed
         for key, access_info in pairs(scope_table_info.accessed_keys) do
            table_info.accessed_keys[key] = access_info
         end
         for alias in pairs(scope_table_info.aliases) do
            if not table_info.aliases[alias] then
               unanalyzable_tables[table_name] = true
               table_info.aliases[alias] = true
            end
         end
      end

      merge_in_scope_accesses(scopes.always_returning_scopes)

      for key, set_data in pairs(set_keys) do
         local set_branch_count, set_info = set_data[1], set_data[2]
         if set_branch_count == #scopes then
            table_info.set_keys[key] = set_info
         else
            table_info.maybe_set_keys[key] = set_info
         end
      end

      for key, set_data in pairs(maybe_set_keys) do
         if table_info.maybe_set_keys[key] then
            local other_set = table_info.maybe_set_keys[key]
            if other_set.assigned_node.tag ~= "Nil" then
               if set_data.assigned_node.tag == "Nil"
                  or other_set.key_node.line > set_data.key_node.line
               then
                  set_data = other_set
               end
            end
         end

         table_info.maybe_set_keys[key] = set_data
      end
   end

   for table_name in pairs(unanalyzable_tables) do
      if current_tables[table_name] then
         wipe_table_data(table_name)
      end
   end
   current_scope.current_tables = current_tables
   check_for_overwritten_keys(prev_tables)
end

-- Steps through the function or file scope one item at a time
-- At each point, tracking for each local table which fields have been set
local function detect_unused_table_fields(func_or_file_scope)
   enter_new_scope(func_or_file_scope.node, "func_or_file_scope")

   external_references_set, external_references_accessed, external_references_mutated = {}, {}, {}
   local args = func_or_file_scope.node[1]
   for _, parameter in ipairs(args) do
      register_new_local(parameter.var.name)
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

      item_callbacks[item.tag](item)

      if give_up_processing then
         break
      end

      -- If it ends on an if...end, the jump will go to the last index + 1
      merge_scopes_at_index(item_index + 1)
   end

   if not give_up_processing then
      -- Handle implicit return
      on_scope_end()
   end

   current_scope = nil
   current_tables = nil
   external_references_accessed = nil
   external_references_mutated = nil
   external_references_set = nil
   previous_scopes = {}
   scopes_to_merge_at_index = {}
   give_up_processing = false
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
