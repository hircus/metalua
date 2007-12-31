require "walk"

----------------------------------------------------------------------
-- * [loop_tags] are the tags of statements which support continue.
-- * [loop_keywords] are the initial keywords which trigger the parsing
--   of these statements: they're indeed indexed by keyword in [mlp.stat].
----------------------------------------------------------------------

local loop_tags     = { "Forin", "Fornum", "While", "Repeat" }
local loop_keywords = { "for", "while", "repeat" }

----------------------------------------------------------------------
-- This function takes the AST of a continue-enabled loop, parse
-- its body to find all instances of [`Continue]. If any of them
-- is found ([label~=nil]), they're transformed in [`Goto{...}], and
-- the corresponding label is added at the end of the loop's body.
--
-- Caveat: if a [continue] appears in the non-body part of a loop
-- (and therefore is relative to some enclosing loop), it isn't
-- handled, and therefore causes a compilation error. This could
-- only happen due in a [`Stat{ }], however, since [`Function{ }]
-- cuts the search for [`Continue].
----------------------------------------------------------------------
local function loop_transformer (ast)
   local label = nil
   local cfg = { 
      stat = { cut  = loop_tags; pred = "Continue" } ;
      expr = { cut = "Function" } }

   --------------------------------------------------------------
   -- This function will be called on every "Continue" in the loop
   -- body which isn't into a Forin/Fornum/While/Repeat/Function:
   --------------------------------------------------------------
   function cfg.stat.map_down (x)
      if not label then label = mlp.gensym() end
      x <- `Goto{ label }
   end

   --------------------------------------------------------------
   -- walk [cfg.stat.map_down()] through the loop's body:
   --------------------------------------------------------------
   local body = ast.tag=="Repeat" and ast[1] or ast[#ast]
   walk.block (cfg) (body)
   if label then table.insert (body, `Label{ label }) end
   return ast
end

----------------------------------------------------------------------
-- Register the transformer for each kind of loop:
----------------------------------------------------------------------
for keyword in values (loop_keywords) do 
   mlp.stat:get(keyword).transformers:add (loop_transformer)
end

mlp.lexer:add "continue"
mlp.stat:add{ "continue", builder = ||`Continue }


