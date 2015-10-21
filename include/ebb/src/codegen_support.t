
local Support = {}
package.loaded["ebb.src.codegen_support"] = Support

--local ast = require "ebb.src.ast"

local C = require 'ebb.src.c'
local G = require 'ebb.src.gpu_util'


-- **** ******** ******** ******** ******** ****
-- NOTE:
--[[
      This file needs to be cleaned up a bit.
      The code should be fine, but just needs some more useful
        comments and better names / organization
  
    Q: When does code go in Codegen_Support vs. the main Codegen
        File?
    A: Codegen_Support should not have to know about the AST.
        So code related to generating vector/matrix expressions
        is a natural choice for this file.
        We might also be able to move some of the GPU reduction
        code into here, but haven't bothered doing so yet.
]]



--[[--------------------------------------------------------------------]]--
--[[                         Utility Functions                          ]]--
--[[--------------------------------------------------------------------]]--


local function vec_mapgen(typ,func)
  local arr = {}
  for i=1,typ.N do arr[i] = func(i-1) end
  return `[typ:terraType()]({ array([arr]) })
end
local function mat_mapgen(typ,func)
  local rows = {}
  for i=1,typ.Nrow do
    local r = {}
    for j=1,typ.Ncol do r[j] = func(i-1,j-1) end
    rows[i] = `array([r])
  end
  return `[typ:terraType()]({ array([rows]) })
end

local function vec_foldgen(N, init, binf)
  local acc = init
  for ii = 1, N do local i = N - ii -- count down to 0
    acc = binf(i, acc) end
  return acc
end
local function mat_foldgen(N,M, init, binf)
  local acc = init
  for ii = 1, N do local i = N - ii -- count down to 0
    for jj = 1, M do local j = M - jj -- count down to 0
      acc = binf(i,j, acc) end end
  return acc
end

Support.vec_mapgen  = vec_mapgen
Support.mat_mapgen  = mat_mapgen
Support.vec_foldgen = vec_foldgen
Support.mat_foldgen = mat_foldgen





--[[--------------------------------------------------------------------]]--
--[[                         Utility Functions                          ]]--
--[[--------------------------------------------------------------------]]--


-- ONLY ONE PLACE...
local function let_vec_binding(typ, N, exp)
  local val = symbol(typ:terraType())
  local let_binding = quote var [val] = [exp] end

  local coords = {}
  if typ:isVector() then
    for i=1, N do coords[i] = `val.d[i-1] end
  else
    for i=1, N do coords[i] = `val end
  end

  return let_binding, coords
end

local function let_mat_binding(typ, N, M, exp)
  local val = symbol(typ:terraType())
  local let_binding = quote var [val] = [exp] end

  local coords = {}
  for i = 1, N do
    coords[i] = {}
    for j = 1, M do
      if typ:isMatrix() then
        coords[i][j] = `val.d[i-1][j-1]
      else
        coords[i][j] = `val
      end
    end
  end
  return let_binding, coords
end

local function symgen_bind(typ, exp, f)
  local s = symbol(typ:terraType())
  return quote var s = exp in [f(s)] end
end
local function symgen_bind2(typ1, typ2, exp1, exp2, f)
  local s1 = symbol(typ1:terraType())
  local s2 = symbol(typ2:terraType())
  return quote
    var s1 = exp1
    var s2 = exp2
  in [f(s1,s2)] end
end








--[[--------------------------------------------------------------------]]--
--[[                         Utility Functions                          ]]--
--[[--------------------------------------------------------------------]]--

local minexp = macro(function(lhe,rhe)
    if lhe:gettype() == double and L.default_processor == L.GPU then
        return `G.fmin(lhe,rhe)
    else 
      return quote
        var a = [lhe]
        var b = [rhe]
        var result = a
        if result > b then result = b end
      in
        result
      end
    end
end)

local maxexp = macro(function(lhe,rhe)
    if lhe:gettype() == double and L.default_processor == L.GPU then
        return `G.fmax(lhe,rhe)
    else 
      return quote
        var a = [lhe]
        var b = [rhe]
        var result = a
        if result < b then result = b end
      in
        result
      end
    end
end)






--[[--------------------------------------------------------------------]]--
--[[                         Utility Functions                          ]]--
--[[--------------------------------------------------------------------]]--



local function prim_bin_exp (op, lhe, rhe)
  if     op == '+'   then return `[lhe] +   [rhe]
  elseif op == '-'   then return `[lhe] -   [rhe]
  elseif op == '/'   then return `[lhe] /   [rhe]
  elseif op == '*'   then return `[lhe] *   [rhe]
  elseif op == '%'   then return `[lhe] %   [rhe]
  elseif op == '^'   then return `[lhe] ^   [rhe]
  elseif op == 'or'  then return `[lhe] or  [rhe]
  elseif op == 'and' then return `[lhe] and [rhe]
  elseif op == '<'   then return `[lhe] <   [rhe]
  elseif op == '>'   then return `[lhe] >   [rhe]
  elseif op == '<='  then return `[lhe] <=  [rhe]
  elseif op == '>='  then return `[lhe] >=  [rhe]
  elseif op == '=='  then return `[lhe] ==  [rhe]
  elseif op == '~='  then return `[lhe] ~=  [rhe]
  elseif op == 'max' then return `maxexp(lhe, rhe)
  elseif op == 'min' then return `minexp(lhe, rhe)
  end
end


local function atomic_gpu_red_exp (op, typ, lvalptr, update)
  local internal_error = 'unsupported reduction, internal error; '..
                         'this should be guarded against in the typechecker'
  if typ == L.float then
    if     op == '+'   then return `G.atomic_add_float(lvalptr,  update)
    --elseif op == '-'   then return `G.atomic_add_float(lvalptr, -update)
    elseif op == '*'   then return `G.atomic_mul_float_SLOW(lvalptr, update)
    --elseif op == '/'   then return `G.atomic_div_float_SLOW(lvalptr, update)
    elseif op == 'min' then return `G.atomic_min_float_SLOW(lvalptr, update)
    elseif op == 'max' then return `G.atomic_max_float_SLOW(lvalptr, update)
    end

  elseif typ == L.double then
    if     op == '+'   then return `G.atomic_add_double_SLOW(lvalptr,  update)
    --elseif op == '-'   then return `G.atomic_add_double_SLOW(lvalptr,-update)
    elseif op == '*'   then return `G.atomic_mul_double_SLOW(lvalptr, update)
    --elseif op == '/'   then return `G.atomic_div_double_SLOW(lvalptr, update)
    elseif op == 'min' then return `G.atomic_min_double_SLOW(lvalptr, update)
    elseif op == 'max' then return `G.atomic_max_double_SLOW(lvalptr, update)
    end

  elseif typ == L.int then
    if     op == '+'   then return `G.reduce_add_int32(lvalptr,  update)
    --elseif op == '-'   then return `G.reduce_add_int32(lvalptr, -update)
    elseif op == '*'   then return `G.atomic_mul_int32_SLOW(lvalptr, update)
    elseif op == 'max' then return `G.reduce_max_int32(lvalptr, update)
    elseif op == 'min' then return `G.reduce_min_int32(lvalptr, update)
    end

  elseif typ == L.bool then
    if     op == 'and' then return `G.reduce_and_b32(lvalptr, update)
    elseif op == 'or'  then return `G.reduce_or_b32(lvalptr, update)
    end
  end
  error(internal_error)
end


local function atomic_gpu_mat_red_exp(op, result_typ, lval, rhe, rhtyp)
  if result_typ:isScalar() then
    return atomic_gpu_red_exp(op, result_typ, `&lval, rhe)
  elseif result_typ:isVector() then

    local N = result_typ.N
    local rhbind, rhcoords = let_vec_binding(rhtyp, N, rhe)

    local v = symbol() -- pointer to vector location of reduction result

    local result = quote end
    for i = 0, N-1 do
      result = quote
        [result]
        [atomic_gpu_red_exp(op, result_typ:baseType(), `v+i, rhcoords[i+1])]
      end
    end
    return quote
      var [v] : &result_typ:terraBaseType() = [&result_typ:terraBaseType()](&[lval])
      [rhbind]
    in
      [result]
    end
  else -- small matrix

    local N = result_typ.Nrow
    local M = result_typ.Ncol
    local rhbind, rhcoords = let_mat_binding(rhtyp, N, M, rhe)

    local m = symbol()

    local result = quote end
    for i = 0, N-1 do
      for j = 0, M-1 do
        result = quote
          [result]
          [atomic_gpu_red_exp(op, result_typ:baseType(), `&([m].d[i][j]), rhcoords[i+1][j+1])]
        end
      end
    end
    return quote
      var [m] : &result_typ:terraType() = [&result_typ:terraType()](&[lval])
      [rhbind]
      in
      [result]
    end
  end
end






--[[--------------------------------------------------------------------]]--
--[[                         Utility Functions                          ]]--
--[[--------------------------------------------------------------------]]--



local function mat_bin_exp(op, result_typ, lhe, rhe, lhtyp, rhtyp)
  if lhtyp:isPrimitive() and rhtyp:isPrimitive() then
    return prim_bin_exp(op, lhe, rhe)
  end

  -- handles equality and inequality of keys
  if lhtyp:isKey() and rhtyp:isKey() then
    return prim_bin_exp(op, lhe, rhe)
  end

  -- ALL THE CASES

  -- OP: Ord (scalars only)
  -- OP: Mod (scalars only)
  -- BOTH HANDLED ABOVE

  -- OP: Eq (=> DIM: == , BASETYPE: == )
    -- pairwise comparisons, and/or collapse
  local eqinitval = { ['=='] = `true, ['~='] = `false }
  if op == '==' or op == '~=' then
    if lhtyp:isVector() then -- rhtyp:isVector()
      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(lvec,rvec)
        return vec_foldgen(lhtyp.N, eqinitval[op], function(i, acc)
          if op == '==' then return `acc and lvec.d[i] == rvec.d[i]
                        else return `acc or  lvec.d[i] ~= rvec.d[i] end
        end) end)

    elseif lhtyp:isMatrix() then -- rhtyp:isMatrix()
      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(lmat,rmat)
        return mat_foldgen(lhtyp.Nrow, lhtyp.Ncol, eqinitval[op],
          function(i,j, acc)
            if op == '==' then return `acc and lmat.d[i][j] == rmat.d[i][j]
                          else return `acc or  lmat.d[i][j] ~= rmat.d[i][j] end
          end) end)

    end
  end

  -- OP: Logical (and or)
    -- map the OP
  -- OP: + - min max
    -- map the OP
  if op == 'and'  or op == 'or' or
     op == '+'    or op == '-'  or
     op == 'min'  or op == 'max'
  then
    if lhtyp:isVector() then -- rhtyp:isVector()
      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(lvec,rvec)
        return vec_mapgen(result_typ, function(i)
          return prim_bin_exp( op, `(lvec.d[i]), `(rvec.d[i]) ) end) end)

    elseif lhtyp:isMatrix() then
      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(lmat,rmat)
        return mat_mapgen(result_typ, function(i,j)
          return prim_bin_exp( op, (`lmat.d[i][j]), `(rmat.d[i][j]) ) end) end)

    end
  end

  -- OP: *
    -- DIM: Scalar _
    -- DIM: _ Scalar
      -- map the OP with expanding one side
  -- OP: /
    -- DIM: _ Scalar
      -- map the OP with expanding one side
  if op == '/' or
    (op == '*' and lhtyp:isPrimitive() or rhtyp:isPrimitive())
  then
    if lhtyp:isVector() then -- rhtyp:isPrimitive()
      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(lvec,r)
        return vec_mapgen(result_typ, function(i)
          return prim_bin_exp( op, (`lvec.d[i]), r ) end) end)

    elseif rhtyp:isVector() then -- lhtyp:isPrimitive()
      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(l,rvec)
        return vec_mapgen(result_typ, function(i)
          return prim_bin_exp( op, l, `(rvec.d[i]) ) end) end)

    elseif lhtyp:isMatrix() then -- rhtyp:isPrimitive()
      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(lmat,r)
        return mat_mapgen(result_typ, function(i,j)
          return prim_bin_exp( op, (`lmat.d[i][j]), r ) end) end)

    elseif rhtyp:isMatrix() then -- rhtyp:isPrimitive()
      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(l,rmat)
        return mat_mapgen(result_typ, function(i,j)
          return prim_bin_exp( op, l, `(rmat.d[i][j]) ) end) end)

    end
  end

  -- OP: *
    -- DIM: Vector(n) Matrix(n,_)
    -- DIM: Matrix(_,m) Vector(m)
    -- DIM: Matrix(_,m) Matrix(m,_)
      -- vector-matrix, matrix-vector, or matrix-matrix products
--  if op == '*' then
--    if lhtyp:isVector() and rhtyp:isMatrix() then
--      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(lvec,rmat)
--        return vec_mapgen(result_typ, function(j)
--          return vec_foldgen(rmat.Ncol, `0, function(i, acc)
--            return `acc + lvec.d[i] * rmat.d[i][j] end) end) end)
--
--    elseif lhtyp:isMatrix() and rhtyp:isVector() then
--      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(lmat,rvec)
--        return vec_mapgen(result_typ, function(i)
--          return vec_foldgen(lmat.Nrow, `0, function(j, acc)
--            return `acc + lmat.d[i][j] * rvec.d[j] end) end) end)
--
--    elseif lhtyp:isMatrix() and rhtyp:isMatrix() then
--      return symgen_bind2(lhtyp, rhtyp, lhe, rhe, function(lmat,rmat)
--        return mat_mapgen(result_typ, function(i,j)
--          return vec_foldgen(rmat.Ncol, `0, function(k, acc)
--            return `acc + lmat.d[i][k] * rmat.d[k][j] end) end) end)
--
--    end
--  end

  -- If we fell through to here we've run into an unhandled branch
  error('Internal Error: Could not find any code to generate for '..
        'binary operator '..op..' with opeands of type '..lhtyp:toString()..
        ' and '..rhtyp:toString())
end



local function unary_exp(op, typ, expr)

  if typ:isPrimitive() then
    if     op == '-'   then return `-[expr]
    elseif op == 'not' then return `not [expr] end

  elseif typ:isVector() then
    local vec = symbol(typ:terraType())

    if op == '-' then
      return quote var [vec] = expr in
        [ Support.vec_mapgen(typ, function(i)
            return `-vec.d[i]
        end) ] end
    elseif op == 'not' then
      return quote var [vec] = expr in
        [ Support.vec_mapgen(typ, function(i)
            return `not vec.d[i]
        end) ] end
    end

  elseif typ:isMatrix() then
    local mat = symbol(typ:terraType())

    if op == '-' then
      return quote var [mat] = expr in
        [ Support.mat_mapgen(typ, function(i,j)
            return `-mat.d[i][j]
        end) ] end
    elseif op == 'not' then
      return quote var [mat] = expr in
        [ Support.mat_mapgen(typ, function(i,j)
            return `not mat.d[i][j]
        end) ] end
    end

  else
    error("Internal Error: Type unrecognized "..typ:toString())
  end

  error("Internal Error: Operation unrecognized "..op)
end



local function scalar_reduce_identity (ltype, reduceop)
  if ltype == L.int then
    if reduceop == '+' or reduceop == '-' then
      return `0
    elseif reduceop == '*' or reduceop == '/' then
      return `1
    elseif reduceop == 'min' then
      return `[C.INT_MAX]
    elseif reduceop == 'max' then
      return `[C.INT_MIN]
    end
  elseif ltype == L.uint64 then
    if reduceop == '+' or reduceop == '-' then
      return `0
    elseif reduceop == '*' or reduceop == '/' then
      return `1
    elseif reduceop == 'min' then
      return `[C.ULONG_MAX]
    elseif reduceop == 'max' then
      return `0
    end
  elseif ltype == L.float then
    if reduceop == '+' or reduceop == '-' then
      return `0.0f
    elseif reduceop == '*' or reduceop == '/' then
      return `1.0f
    elseif reduceop == 'min' then
      return `[C.FLT_MAX]
    elseif reduceop == 'max' then
      return `[C.FLT_MIN]
    end
  elseif ltype == L.double then
    if reduceop == '+' or reduceop == '-' then
      return `0.0
    elseif reduceop == '*' or reduceop == '/' then
      return `1.0
    elseif reduceop == 'min' then
      return `[C.DBL_MAX]
    elseif reduceop == 'max' then
      return `[C.DBL_MIN]
    end
  elseif ltype == L.bool then
    if reduceop == 'and' then
      return `true
    elseif reduceop == 'or' then
      return `false
    end
  end
  -- we should never reach this
  error("scalar identity for reduction operator " .. reduceop .. 'on type '
        .. tostring(ltype) ' not implemented')
end

function Support.reduction_identity(lz_type, reduceop)
  if not lz_type:isVector() then
    return scalar_reduce_identity(lz_type, reduceop)
  end
  local scalar_id = scalar_reduce_identity(lz_type:baseType(), reduceop)
  return quote
    var rid : lz_type:terraType()
    var tmp : &lz_type:terraBaseType() = [&lz_type:terraBaseType()](&rid)
    for i = 0, [lz_type.N] do
      tmp[i] = [scalar_id]
    end
  in
    [rid]
  end
end

-- expose useful snippet of codegeneration to module-external code
function Support.reduction_binop(lz_type, op, lhe, rhe)
  return mat_bin_exp(op, lz_type, lhe, rhe, lz_type, lz_type)
end











Support.bin_exp = mat_bin_exp
Support.gpu_atomic_exp = atomic_gpu_mat_red_exp
Support.unary_exp = unary_exp

















