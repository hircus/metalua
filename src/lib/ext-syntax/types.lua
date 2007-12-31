-- This extension inserts type-checking code at approriate place in the code,
-- thanks to annotations based on "::" keyword:
--
-- * function declarations can be annotated with a returned type. When they
--   are, type-checking code is inserted in each of their return statements,
--   to make sure they return the expected type.
--
-- * function parameters can also be annotated. If they are, type-checking
--   code is inserted in the function body, which checks the arguments' types
--   and cause an explicit error upon incorrect calls. Moreover, if a new value
--   is assigned to the parameter in the function's body, the new value's type
--   is checked before the assignment is performed.
--
-- * Local variables can also be annotated. If they are, type-checking
--   code is inserted before any value assignment or re-assignment is
--   performed on them.
--
-- Type checking can be disabled with:
--
-- -{stat: types.enabled = false }
--
-- Code transformation is performed at the chunk level, i.e. file by
-- file.  Therefore, it the value of compile-time variable
-- [types.enabled] changes in the file, the only value that counts is
-- its value once the file is entirely parsed.
--
-- Syntax
-- ======
-- 
-- Syntax annotations consist of "::" followed by a type
-- specifier. They can appear after a function parameter name, after
-- the closing parameter parenthese of a function, or after a local
-- variable name in the declaration. See example in samples.
--
-- Type specifiers are expressions, in which identifiers are taken
-- from table types. For instance, [number] is transformed into
-- [types.number]. These [types.xxx] fields must contain functions,
-- which generate an error when they receive an argument which doesn't
-- belong to the type they represent. It is perfectly acceptible for a
-- type-checking function to return another type-checking function,
-- thus defining parametric/generic types. Parameters can be
-- identifiers (they're then considered as indexes in table [types])
-- or literals.
--
-- Design hints
-- ============
--
-- This extension uses the code walking library [walk] to globally
-- transform the chunk AST. See [chunk_transformer()] for details
-- about the walker.
--
-- During parsing, type informations are stored in string-indexed
-- fields, in the AST nodes of tags `Local and `Function. They are
-- used by the walker to generate code only if [types.enabled] is
-- true.
--
-- TODO
-- ====
--
-- It's easy to add global vars type-checking, by declaring :: as an
-- assignment operator.  It's easy to add arbitrary expr
-- type-checking, by declaring :: as an infix operator. How to make
-- both cohabit? 

--------------------------------------------------------------------------------
--
-- Function chunk_transformer()
--
--------------------------------------------------------------------------------
--
-- Takes a block annotated with extra fields, describing typing
-- constraints, and returns a normal AST where these constraints have
-- been turned into type-checking instructions.
--
-- It relies on the following annotations:
--
--  * [`Local{ }] statements may have a [types] field, which contains a
--    id name ==> type name map.
--
--  * [Function{ }] expressions may have an [param_types] field, also a
--    id name ==> type name map. They may also have a [ret_type] field
--    containing the type of the returned value.
--
-- Design hints:
-- =============
--
-- It relies on the code walking library, and two states:
--
--  * [return_types] is a stack of the expected return values types for
--    the functions currently in scope, the most deeply nested one
--    having the biggest index.
--
--  * [scopes] is a stack of id name ==> type name scopes, one per
--    currently acive variables scope.
--
-- What's performed by the walker:
--
--  * Assignments to a typed variable involve a type checking of the 
--    new value;
--
--  * Local declarations are checked for additional type declarations.
--
--  * Blocks create and destroy variable scopes in [scopes]
--
--  * Functions create an additional scope (around its body block's scope)
--    which retains its argument type associations, and stacks another
--    return type (or [false] if no type constraint is given)
--
--  * Return statements get the additional type checking statement if 
--    applicable.
--
--------------------------------------------------------------------------------

require "walk" 

module("types", package.seeall)

enabled = true

local function chunk_transformer (block)
   if not enabled then return end
   local return_types, scopes = { }, { }
   local cfg = {
      block = { };
      stat  = { pred = { "Local"; "Let"; "Return" }; down = { } };
      expr  = { pred = "Function"; up = { }; down = { } } }

   -------------------------------------------------------------
   -- Declaration of a new local variable in the current block:
   -- gather type constraints in local current scope.
   -------------------------------------------------------------
   function cfg.stat.down.Local (s)
      if s.types then

         -- Add new types in current scope
         local myscope = scopes[#scopes]
         for var, type in pairs (s.types) do 
            myscope[var] = process_type (type)
         end

         -- Type-check the rhs values
         local lhs, rhs = unpack(s)
         for i=1, max(#lhs, #rhs) do
            local type = myscope[lhs[i][1]]
            if type and rhs[i] then 
               rhs[i] = checktype_builder (type, rhs[i], 'expr') 
            end
         end
      end
   end
      
   -------------------------------------------------------------
   -- Variable assignment: add type checking to the right-hand
   -- side value, before assigning it to the left-hand side,
   -- if it is typed.
   -------------------------------------------------------------
   function cfg.stat.down.Let (s)
      local lhs, rhs = unpack (s)
      for i=1, #lhs do -- foreach lhs variable:
         
         -- Retrieve the variable type, if any:
         local type
         for j=#scopes, 1, -1 do 
            type = scopes[j][lhs[i][1]]
            if type then break end
         end
         
         -- Type constraint found, apply it:
         if type then 
            rhs[i] = checktype_builder(type, rhs[i] or `Nil, 'expr') 
         end         
      end
   end

   -------------------------------------------------------------
   -- Return statements: if there is a returned type constraint,
   -- enforce it.
   -------------------------------------------------------------
   function cfg.stat.down.Return (s)
      local rtype = return_types[#return_types]
      if rtype then s[1] = checktype_builder (rtype, s[1], 'expr') end
   end

   -------------------------------------------------------------------
   -- On expressions: the only expressions watched are functions.
   -- function parameters are to be treated like
   -- local variables. Also, if a return type constraint is given,
   -- register it.
   -------------------------------------------------------------------
   function cfg.expr.down.Function (e)
      local myscope = { }
      table.insert (scopes, myscope)
      if e.param_types then
         for var, type in pairs (e.param_types) do
            myscope[var] = process_type (type)
         end
      end
      local r = e.ret_type and process_type (e.ret_type) or false
      table.insert (return_types, r)
   end

   -------------------------------------------------------------------
   -- Unregister the returned type and the variable scope in which
   -- arguments are registered;
   -- then, adds the parameters type checking instructions at the
   -- beginning of the function, if applicable.
   -------------------------------------------------------------------
   function cfg.expr.up.Function (e) 
      -- Unregister stuff going out of scope:
      table.remove (return_types)
      table.remove (scopes)
      -- Add initial type checking:
      if e.param_types then
         for v, t in pairs(e.param_types) do
            table.insert(e[2], 1, checktype_builder(t, `Id{v}, 'stat'))
         end
      end
   end
      
   -------------------------------------------------------------------
   -- Create/delete scopes as we enter/leave blocks.
   -------------------------------------------------------------------
   function cfg.block.down (_) table.insert (scopes, { }) end
   function cfg.block.up (_)   table.remove (scopes)      end
   walk.block(cfg)(block)
end

--------------------------------------------------------------------------
-- Translate operators into their metatable entry:
-- used by [process_type] to translate operation expressions into
-- calls to the corresponding [types] entry.
--------------------------------------------------------------------------
ast2mt = { 
   Mul="__mul"; Add="__add"; Sub="__sub"; Div="__div";
   Mod="__mod"; Pow="__pow"; Len="__len"; Not="__not" }

--------------------------------------------------------------------------
-- Perform required transformations to change a raw type expression into
-- a callable function:
--
--  * identifiers are changed into indexes in [types], unless they're
--    allready indexed, or into parentheses;
--
--  * literal tables are embedded into a call to types.__table
--
-- This transformation is not performed when type checking is disabled: 
-- types are stored under their raw form in the AST; the transformation is
-- only performed when they're put in the stacks (scopes and return_types)
-- of the main walker.
--------------------------------------------------------------------------
function process_type (type)
   -- Transform the type:
   cfg = { 
      expr = { 
         pred = { "Id", "Table", "String", "Op" }; 
         cut  = { "Index", "One" };
         up   = { } } }
   function cfg.expr.up.Id (x) 
      x <- `Index{ `Id "types", `String{ x[1] } } 
   end
   function cfg.expr.up.Table (x) 
      local xcopy = table.shallow_copy(x)
      x <- `Call{ `Index{ `Id "types", `String "__table" }, xcopy }
   end
   function cfg.expr.up.String (x) 
      local xcopy = table.shallow_copy(x)
      x <- `Call{ `Index{ `Id "types", `String "__string" }, xcopy }
   end
   function cfg.expr.up.Op (x) 
      local f = "__"..x[1]
      if not f then error ("Invalid operator __"..x[1]) end
      x <- `Call{ `Index{ `Id "types", `String{ f } }, x[2], x[3] }
   end
   walk.expr(cfg)(type)
   return type
end

--------------------------------------------------------------------------
-- Insert a type-checking function call on [term] before returning
-- [term]'s value. Only legal in an expression context.
--------------------------------------------------------------------------
function checktype_builder(type, term, kind)

   -- Shove type-checking code into the term to check:
   local v = mlp.gensym()
   local non_const_tags = { Dots=1, Op=1, Index=1, Call=1, Method=1, Table=1 }
   if kind=="expr" and non_const_tags[term.tag] then
      return `Stat{ { `Local{ {v}, {term} }; `Call{ type, v } }, v }
   elseif kind=="expr" then
      return `Stat{ { `Call{ type, term } }, term }
   elseif kind=="stat" then
      return `Call{ type, term } 
   else
      error "checktype_builder must take type 'expr' or 'stat'"
   end
end

--------------------------------------------------------------------------
-- Parse the typechecking tests in a function definition, and adds the 
-- corresponding tests at the beginning of the function's body.
--------------------------------------------------------------------------
local function func_val_builder (x)
   local typed_params, ret_type, body = unpack(x)
   local e = `Function{ { }, body; param_types = { }; ret_type = ret_type }

   -- Build [untyped_params] list, and [e.param_types] dictionary.
   for i, y in ipairs (typed_params) do
      if y.tag=="Dots" then
         assert(i==#typed_params, "`...' must be the last parameter")
         break
      end
      local param, type = unpack(y)
      e[1][i] = param
      if type then e.param_types[param[1]] = type end
   end
   return e
end

--------------------------------------------------------------------------
-- Parse ":: type" annotation if next token is "::", or return false.
-- Called by function parameters parser
--------------------------------------------------------------------------
local opt_type = gg.onkeyword{ "::", mlp.expr }

--------------------------------------------------------------------------
-- Updated function definition parser, which accepts typed vars as
-- parameters.
--------------------------------------------------------------------------

-- Parameters parsing:
local id_or_dots = gg.multisequence{ { "...", builder = "Dots" }, default = mlp.id }

-- Function parsing:
mlp.func_val = gg.sequence{
   "(", gg.list{ 
      gg.sequence{ id_or_dots, opt_type }, terminators = ")", separators  = "," },
   ")",  opt_type, mlp.block, "end", 
   builder = func_val_builder }

mlp.lexer:add { "::", "newtype" }
mlp.chunk.transformers:add (chunk_transformer)

-- Local declarations parsing:
local local_decl_parser = mlp.stat:get "local" [2].default

local_decl_parser[1].primary = gg.sequence{ mlp.id, opt_type }

function local_decl_parser.builder(x)
   local lhs, rhs = unpack(x)
   local s, stypes = `Local{ { }, rhs or { } }, { } 
   for i = 1, #lhs do
      local id, type = unpack(lhs[i])
      s[1][i] = id
      if type then stypes[id[1]]=type end
   end
   if next(stypes) then s.types = stypes end
   return s   
end

function newtype_builder(x)
   local lhs, rhs = unpack(x)
   match lhs with
   | `Id{ x } -> t = process_type (rhs)
   | `Call{ `Id{ x }, ... } ->
      t = `Function{ { }, rhs }
      for i = 2, #lhs do 
         if lhs[i].tag ~= "Id" then error "Invalid newtype parameter" end 
         t[1][i-1] = lhs[i]
      end
   | _ -> error "Invalid newtype definition"
   end
   return `Let{ { `Index{ `Id "types", `String{ x } } }, { t } }
end

mlp.stat:add{ "newtype", mlp.expr, "=", mlp.expr, builder = newtype_builder }


--------------------------------------------------------------------------
-- Register as an operator
--------------------------------------------------------------------------
--mlp.expr.infix:add{ "::", prec=100, builder = |a, _, b| insert_test(a,b) }

