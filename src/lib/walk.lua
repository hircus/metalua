--------------------------------------------------------------------------------
-- Code walkers generator
--      "Make everything as simple as possible, but not simpler" (Einstein)
--
-- This library offers a generic way to write AST transforming
-- functions. Macros can take bits of AST as parameters and generate a
-- more complex AST with them; but modifying an AST a posteriori is
-- much more difficult; typical tasks requiring code walking are
-- transformation such as lazy evaluation or Continuation Passing
-- Style.
--
--  The API is not extremely easy to handle, but I can't think of a
-- better one. It might change if I get more inspired.
--
-- We deal here with 3 important kinds of AST: statements, expressions
-- and blocks. Code walkers for these three kinds for AST are
-- generated by [walk.stat (cfg)], [walk.expr (cfg)] and [walk.block
-- (cfg)] respectively: each of these generate a function transforming
-- an AST of the corresponding type. The nature of this transformation
-- is determined by [cfg], or more accurately [cfg.stat], [cfg.expr]
-- and [cfg.block].
--
-- [cfg.stat] is a table which migh have any of these fields:
--
-- * [cfg.stat.down()] is a function taking a statement AST and
--   returning [nil] or ["break"]. It will be applied to some
--   statements in the transformed term, depending on
--   [cfg.stat.pred]. This is applied top-bottom, i.e. from the AST
--   root to its leaves.
--
--   If it returns ["break"], the walking stops at this level, and no
--   sub-node of this will be visited.
--
--   [New in 0.3.1]
--   It can also be a table of functions indexed by strings. In this 
--   case, the function whose index matches the visited term's tag
--   is selected.
--
-- * [cfg.stat.up()] is similar, except that it is applied bottom-up,
--   from leaves to the root. On a given node, [down()] is always
--   applied before [up()]. Moreover, if [down()] returns ["break"],
--   [up()] is never called. The value returned by [up()] is irrelevant.
--
-- * [cfg.stat.pred] is a predicate, i.e. it can contain:
--   + a function taking a statement AST and returning [true] or [false]
--   + or a boolean, which is equivalent to the function [||true] or [||false]
--   + or a string [s],  which is equivalent to the function [|ast| ast.tag==s]
--   + or a table of predicates, which is equivalent to a predicate returning
--     [true] whenever on of the sub-predicates returns true.
--
--   Actions [cfg.stat.down()] and [cfg.stat.up()] are only applied on
--   a statement AST if this predicate returns true, or if there is no
--   [pred] field.
--
-- * [cfg.stat.cut()] DEPRECATED(?) if present and returning true, this
--   predicate stops traversal between [up()] and [down()].
--
-- Notice that this [cfg.stat] fields is meaningful in every walker
-- generator, not only [walk.stat()], as expressions and blocks can
-- contain ASTs.
--
-- [cfg.expr] and [cfg.block] are similar to [cfg.stat], except that
-- they work on expressions and blocks respectively. Both of them can
-- also appear in all three walker generators.
--
--------------------------------------------------------------------------------

-- FIXME: maintenant qu'up et down peuvent etre des tables, peut-etre que
--        pred ne sert plus a rien ? Ou au moins, s'il n'y a pas de pred,
--        on peut peut-etre l'inferer des tables up/down ?

-{ extension "match" }

walk = { traverse = { } }

--------------------------------------------------------------------------------
-- These [traverse.xxx()] functions are in charge of actually going through
-- ASTs. At each node, they make sure to call the appropriate walker.
--------------------------------------------------------------------------------
local traverse = walk.traverse

-- In `Call{ } and `Method{ } as statements, each strict subexpression 
-- is treated as an expression, but the whole AST is *not* treated
-- as en expr. This allows to target calls-as-statements without
-- targetting calls-as-real-expr.
function traverse.stat (cfg, x)
   local B  = walk.block(cfg)
   local S  = walk.stat(cfg)
   local E  = walk.expr(cfg)
   local EL = walk.expr_list(cfg)
   match x with
   | `Do{...}              -> B(x)
   | {...} if x.tag == nil -> B(x)
   | `Let{ lhs, rhs }      -> EL(lhs); EL(rhs)
   | `While{ cond, body }  -> E(cond); B(body)
   | `Repeat{ body, cond } -> B(body); E(cond)
   | `Local{ _, rhs } | `Localrec{ _, rhs }   -> EL(rhs)
   | `Call{...} | `Method{...} | `Return{...} -> EL(x)
   | `Fornum{ _, a, b, body } 
   | `Fornum{ _, a, b, c, body } -> E(a); E(b); if #x==5 then E(c) end; B(body)
   | `Forin{ _, rhs, body }      -> EL(rhs); B(body)
   | `If{...}                    -> for i=1, #x-1, 2 do E(x[i]); B(x[i+1]) end
                                    if #x%2 == 1 then B(x[#x]) end
   | `Break | `Goto{ _ } | `Label{ _ } -> -- nothing
   | {...} -> print("Warning: unknown stat node `"..x.tag)
   | _     -> print("Warning: unexpected stat node of type "..type(x))
   end
end

function traverse.expr (cfg, x)
   local B  = walk.block(cfg)
   local S  = walk.stat(cfg)
   local E  = walk.expr(cfg)
   local EL = walk.expr_list(cfg)
   match x with
   | `One{ e }                 -> E(e)
   | `Call{...} | `Method{...} -> EL(x)
   | `Index{ a, b }            -> E(a); E(b)
   | `Op{ opid, ... }          -> E(x[2]); if #x==3 then E(x[3]) end
   | `Function{ params, body } -> B(body)
   | `Stat{ b, e }             -> B(b); E(e)
   | `Table{ ... }             ->
      for i = 1, #x do match x[i] with
         | `Key{ k, v } -> E(k); E(v)
         | v            -> E(v)
      end end
   |`Nil|`Dots|`True|`False|`Number{_}|`String{_}|`Id{_} -> -- nothing 
   | {...} -> printf("Warning: unknown expr node %s", table.tostring(x))
   | _     -> print("Warning: unexpected expr node of type "..type(x))
   end
end

function traverse.block (cfg, x)
   table.iforeach(walk.stat(cfg), x)
end

function traverse.expr_list (cfg, x)
   table.iforeach(walk.expr(cfg), x)
end

----------------------------------------------------------------------
-- Generic walker generator
----------------------------------------------------------------------
local walker_builder = |cfg_field, traverse| |cfg| function (x)
   local function pred_builder (pred)
      match type(pred) with
      | "boolean"  -> return (|| pred)
      | "nil"      -> return nil
      | "function" -> return pred
      | "string"   -> return (|x| x.tag==pred)
      | "table"    -> 
         local preds = table.imap (pred_builder, pred)
         return function(x)
                   for p in values(preds) do
                      if p(x) then return true end
                   end
                   return false
                end                      
         --return (|x| table.iany((|p| p(x)), preds))
      | _ -> error "Invalid predicate"
      end
   end
   local subcfg   = cfg[cfg_field] or { }
   local map_pred = pred_builder (subcfg.pred)
   local broken   = false
   local function map(f)
      if f and (not map_pred or map_pred(x)) then 
         if type(f) == "table" then 
            local maptable = f
            f = |x| maptable[x.tag](x) 
         end
         local r=f(x)
         if r=="break" then broken=true 
         else assert(not r, "Map functions must return 'break' or nil") end
      end
   end
   --printf("\n--> walk.%s (cfg) (\n%s)", cfg_field, table.tostring(x,"nohash",60))
   map (subcfg.down)
   --printf("\n--- walk.%s (cfg) (\n%s)", cfg_field, table.tostring(x,"nohash",60))
   local cut_pred = pred_builder(subcfg.cut)
   if not broken and (not cut_pred or not cut_pred(x)) then 
      traverse(cfg, x) 
   end
   map (subcfg.up)
   --printf("\n<-- walk.%s (cfg) (\n%s)", cfg_field, table.tostring(x,"nohash",60))
end

-- Declare [walk.stat], [walk.expr], [walk.block] and [walk.expr_list]
for w in values{ "stat", "expr", "block", "expr_list" } do
   walk[w] = walker_builder (w, traverse[w])
end

--------------------------------------------------------------------------------
-- Useful example of a non-trivial usage: this generates a walker
-- which applies [f] on every occurence of an identifier whose name is
-- [id_name], but takes care of variable capture: if a [local]
-- statement or a function parameter with the same name shadows it,
-- [f] is not applied to the homonymous id occurences.
--------------------------------------------------------------------------------
function walk.alpha_id (f, id_name)
   local cfg = { expr  = { pred = { "Function", "Id" } },
                 block = { cut  = true } }
      
   -----------------------------------------------------------------------------
   -- Apply [f] on id, make sure that function parameters don't capture id.
   -----------------------------------------------------------------------------
   function cfg.expr.down(x)
      match x with
      | `Id{ name } if name==id_name -> f(x)
      | `Function{ params, _ } if table.iforeach (|p| p[1]==id_name, params) -> 
         return "break"
      end
   end

   -----------------------------------------------------------------------------
   -- Blocks must be traversed in a custom way, in order to stop as soon as
   -- a local declaration captures the id.
   -----------------------------------------------------------------------------
   function cfg.block.down(b)
      assert(b, "Null block in alpha conversion")
      for s in values(b) do
         if (s.tag=="Local" or s.tag=="Localrec") and
            table.iforeach (|p| p[1]==id_name, s[1]) then
            --------------------------------------------------------------------
            -- Local declaration captures Id: stop traversing this block.  
            -- However, for `Local{lhs, rhs} stats, the rhs is out of scope
            -- and must be traversed.
            --------------------------------------------------------------------
            if s.tag=="Local" then walk.expr_list(cfg)(s[2]) end
            return "break" 
         end
         -- No capture occured --> traverse and go on.
         walk.stat(cfg)(s)
      end
   end

   return cfg
end

