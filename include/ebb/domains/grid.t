-- The MIT License (MIT)
--
-- Copyright (c) 2015 Stanford University.
-- All rights reserved.
--
-- Permission is hereby granted, free of charge, to any person obtaining a
-- copy of this software and associated documentation files (the "Software"),
-- to deal in the Software without restriction, including without limitation
-- the rights to use, copy, modify, merge, publish, distribute, sublicense,
-- and/or sell copies of the Software, and to permit persons to whom the
-- Software is furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included
-- in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.

import "ebb"

local Grid = {}
package.loaded["ebb.domains.grid"] = Grid

local L    = require 'ebblib'
local M    = require "ebb.src.main"
local R    = require 'ebb.src.relations'
local UTIL = require 'ebb.src.util'

local copy_table = UTIL.copy_table

-------------------------------------------------------------------------------

local max_impl = L.Macro(function(a,b)
  return ebb `L.imax(a, b)
end)
local min_impl = L.Macro(function(a,b)
  return ebb `L.imin(a, b)
end)
local clamp_impl = L.Macro(function(x, lower, upper)
  return ebb `max_impl(lower, min_impl(upper, x))
end)
-- convert a potentially continuous signed value x to
-- an address modulo the given uint m
local wrap_idx = L.Macro(function(x, m)
  return ebb `L.uint64(L.fmod(x,m) + m) % m
end)
local clamp_idx = L.Macro(function(x, limit)
  return ebb `L.uint64(clamp_impl(x, 0.0, L.double(limit-1)))
end)

-------------------------------------------------------------------------------

local function addHelpers(cells)
  local xNum, yNum, zNum  = cells:xNum(), cells:yNum(), cells:zNum()
  local xWidth, yWidth, zWidth  = cells:xWidth(), cells:yWidth(), cells:zWidth()
  local xOrigin, yOrigin, zOrigin  = cells:xOrigin(), cells:yOrigin(), cells:zOrigin()
  local xBnum, yBnum, zBnum = cells:xBnum(), cells:yBnum(), cells:zBnum()
  local xPeriodic, yPeriodic, zPeriodic = cells:xPeriodic(), cells:yPeriodic(), cells:zPeriodic()

  -- relative offset
  cells:NewFieldMacro('__apply_macro', L.Macro(function(c,x,y,z)
      return ebb `L.Affine(cells, {{1,0,0,x},
                                   {0,1,0,y},
                                   {0,0,1,z}}, c)
  end))

  cells:NewFieldReadFunction('center', ebb(c)
    var xcw = xWidth / xNum
    var ycw = yWidth / yNum
    var zcw = zWidth / zNum
    var xro = xOrigin - xBnum * xcw
    var yro = yOrigin - yBnum * ycw
    var zro = zOrigin - zBnum * zcw
    return L.vec3d({ xro + xcw * (L.double(L.xid(c)) + 0.5),
                     yro + ycw * (L.double(L.yid(c)) + 0.5),
                     zro + zcw * (L.double(L.zid(c)) + 0.5) })
  end)

  rawset(cells, 'locate', ebb(pos)
    var xcw = xWidth / xNum
    var xro = xOrigin - xBnum * xcw
    var xpos = (pos[0] - xro) / xcw
    var xidx : L.uint64
    if xPeriodic then xidx = wrap_idx(xpos) else xidx = clamp_idx(xpos) end
    var ycw = yWidth / yNum
    var yro = yOrigin - yBnum * ycw
    var ypos = (pos[1] - yro) / ycw
    var yidx : L.uint64
    if yPeriodic then yidx = wrap_idx(ypos) else yidx = clamp_idx(ypos) end
    var zcw = zWidth / zNum
    var zro = zOrigin - zBnum * zcw
    var zpos = (pos[2] - zro) / zcw
    var zidx : L.uint64
    if zPeriodic then zidx = wrap_idx(zpos) else zidx = clamp_idx(zpos) end
    return L.UNSAFE_ROW({xidx, yidx, zidx}, cells)
  end))

  -- boundary depths
  cells:NewFieldMacro('xneg_depth', L.Macro(function(c)
    return ebb `max_impl(L.int(xBnum - L.xid(c)), 0)              end))
  cells:NewFieldMacro('xpos_depth', L.Macro(function(c)
    return ebb `max_impl(L.int(L.xid(c) - (xNum + xBnum - 1)), 0) end))
  cells:NewFieldMacro('yneg_depth', L.Macro(function(c)
    return ebb `max_impl(L.int(yBnum - L.yid(c)), 0)              end))
  cells:NewFieldMacro('ypos_depth', L.Macro(function(c)
    return ebb `max_impl(L.int(L.yid(c) - (yNum + yBnum - 1)), 0) end))
  cells:NewFieldMacro('zneg_depth', L.Macro(function(c)
    return ebb `max_impl(L.int(zBnum - L.zid(c)), 0)              end))
  cells:NewFieldMacro('zpos_depth', L.Macro(function(c)
    return ebb `max_impl(L.int(L.zid(c) - (zNum + zBnum - 1)), 0) end))

  cells:NewFieldReadFunction('in_boundary', ebb(c)
    return c.xneg_depth > 0 or c.xpos_depth > 0 or
           c.yneg_depth > 0 or c.ypos_depth > 0 or
           c.zneg_depth > 0 or c.zpos_depth > 0
  end)
  cells:NewFieldMacro('in_interior', L.Macro(function(c)
    return ebb `not c.in_boundary
  end))
end

function Grid.NewGrid(params)
  local params = copy_table(params)
  params.mode = 'GRID'
  local grid = L.NewRelation(params)
  addHelpers(grid)
  return grid
end

-------------------------------------------------------------------------------

-- R.Relation, string -> ()
function R.Relation:LinkWithCoarse(coarse, fldName)
  assert(self:isGrid() and coarse:isGrid())
  local fine = self

  M.IF(M.OR(M.NOT(M.EQ(fine.xNum:get() % coarse.xNum:get(), 0)),
       M.OR(M.NOT(M.EQ(fine.yNum:get() % coarse.yNum:get(), 0)),
            M.NOT(M.EQ(fine.zNum:get() % coarse.zNum:get(), 0)))))
    M.ERROR("Inexact coarsening factor")
  M.END()

  fine:CoarseningFields():insert(fine:NewField(fldName, coarse))
  local ebb SetCoarseningField(f : fine)
    var xFactor = [fine.xNum] / [coarse.xNum]
    var yFactor = [fine.yNum] / [coarse.yNum]
    var zFactor = [fine.zNum] / [coarse.zNum]
    if f.in_interior then
      f.[fldName] =
        L.UNSAFE_ROW({(L.xid(f) - [fine.xBnum]) / xFactor + [coarse.xBnum],
                      (L.yid(f) - [fine.yBnum]) / yFactor + [coarse.yBnum],
                      (L.zid(f) - [fine.zBnum]) / zFactor + [coarse.zBnum]},
                     coarse)
    else
      f.[fldName] = L.UNSAFE_ROW({-1,-1,-1}, coarse)
    end
  end
  fine:foreach(SetCoarseningField)
end
