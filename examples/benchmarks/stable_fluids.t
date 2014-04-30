import "compiler.liszt"

local Grid  = L.require 'domains.grid'
local cmath = terralib.includecstring [[
#include <math.h>
#include <stdlib.h>
#include <time.h>



float rand_float()
{
      float r = (float)rand() / (float)RAND_MAX;
      return r;
}
]]
cmath.srand(cmath.time(nil));
local vdb   = L.require 'lib.vdb'

local N = 150
local grid = Grid.New2dUniformGrid{
    size   = {N, N},
    origin = {-N/2.0, -1.0},
    width  = N,
    height = N,
}

local viscosity     = 0.08
local dt            = L.NewGlobal(L.float, 0.01)


grid.cells:NewField('velocity', L.vec2f)
grid.cells.velocity:LoadConstant(L.NewVector(L.float, {0,0}))

grid.cells:NewField('velocity_prev', L.vec2f)
grid.cells.velocity_prev:LoadConstant(L.NewVector(L.float, {0,0}))





-----------------------------------------------------------------------------
--[[                             UPDATES                                 ]]--
-----------------------------------------------------------------------------

grid.cells:NewField('vel_shadow', L.vec2f):Load({0,0})
local neumann_shadow_update = liszt kernel (c : grid.cells)
    if c.is_left_bnd then
        var v = c.right.velocity
        c.vel_shadow = { -v[0],  v[1] }
    elseif c.is_right_bnd then
        var v = c.left.velocity
        c.vel_shadow = { -v[0],  v[1] }
    elseif c.is_up_bnd then
        var v = c.down.velocity
        c.vel_shadow = {  v[0], -v[1] }
    elseif c.is_down_bnd then
        var v = c.up.velocity
        c.vel_shadow = {  v[0], -v[1] }
    end
end
local neumann_cpy_update = liszt kernel (c : grid.cells)
    c.velocity = c.vel_shadow
end
local function vel_neumann_bnd(cells)
    neumann_shadow_update(cells.boundary)
    neumann_cpy_update(cells.boundary)
end

-----------------------------------------------------------------------------
--[[                             VELSTEP                                 ]]--
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
--[[                             DIFFUSE                                 ]]--
-----------------------------------------------------------------------------

local diffuse_diagonal = L.NewGlobal(L.float, 0.0)
local diffuse_edge     = L.NewGlobal(L.float, 0.0)

-- One Jacobi-Iteration
local diffuse_lin_solve_jacobi_step = liszt kernel (c : grid.cells)
    if not c.is_bnd then
        var edge_sum = diffuse_edge * (
            c.left.velocity + c.right.velocity +
            c.up.velocity + c.down.velocity
        )
        c.vel_shadow = (c.velocity_prev - edge_sum) / diffuse_diagonal
    end
end

-- Should be called with velocity and velocity_prev both set to
-- the previous velocity field value...
local function diffuse_lin_solve(edge, diagonal)
    diffuse_diagonal:set(diagonal)
    diffuse_edge:set(edge)

    -- do 20 Jacobi iterations
    for i=1,20 do
        diffuse_lin_solve_jacobi_step(grid.cells)
        grid.cells:Swap('velocity','vel_shadow')
        vel_neumann_bnd(grid.cells)
    end
end

local function diffuse_velocity(grid)
    -- Why the N*N term?  I don't get that...
    local laplacian_weight  = dt:get() * viscosity * N * N
    local diagonal          = 1.0 + 4.0 * laplacian_weight
    local edge              = -laplacian_weight

    grid.cells:Copy{from='velocity',to='velocity_prev'}
    diffuse_lin_solve(edge, diagonal)
end

-----------------------------------------------------------------------------
--[[                             ADVECT                                  ]]--
-----------------------------------------------------------------------------

local cell_w = grid:cellWidth()
local cell_h = grid:cellHeight()

local advect_dt = L.NewGlobal(L.float, 0.0)
grid.cells:NewField('lookup_pos', L.vec2f):Load(L.NewVector(L.float, {0,0}))
grid.cells:NewField('lookup_from', grid.dual_cells):Load(0)

local advect_where_from = liszt kernel(c : grid.cells)
    var offset      = - c.velocity_prev
    -- Make sure all our lookups are appropriately confined
    c.lookup_pos    = grid.snap_to_grid(c.center + advect_dt * offset)
end

local advect_point_locate = liszt kernel(c : grid.cells)
    c.lookup_from   = grid.dual_locate(c.lookup_pos)
end

local advect_interpolate_velocity = liszt kernel(c : grid.cells)
    if not c.is_bnd then
        var dc      = c.lookup_from
        var frac    = c.lookup_pos - dc.center
        -- figure out fractional position in the dual cell in range [0.0, 1.0]
        var xfrac   = frac[0] / cell_w + 0.5 
        var yfrac   = frac[1] / cell_h + 0.5

        -- interpolation constants
        var x1      = L.float(xfrac)
        var y1      = L.float(yfrac)
        var x0      = L.float(1.0 - xfrac)
        var y0      = L.float(1.0 - yfrac)

        c.velocity  = x0 * y0 * dc.upleft.velocity_prev
                    + x1 * y0 * dc.upright.velocity_prev
                    + x0 * y1 * dc.downleft.velocity_prev
                    + x1 * y1 * dc.downright.velocity_prev
    end
end

local function advect_velocity(grid)
    -- Why N?
    advect_dt:set(dt:get() * N)

    grid.cells:Swap('velocity','velocity_prev')
    advect_where_from(grid.cells)
    advect_point_locate(grid.cells)
    advect_interpolate_velocity(grid.cells)

    vel_neumann_bnd(grid.cells)
end

-----------------------------------------------------------------------------
--[[                             PROJECT                                 ]]--
-----------------------------------------------------------------------------

local project_diagonal = L.NewGlobal(L.float, 0.0)
local project_edge     = L.NewGlobal(L.float, 0.0)
grid.cells:NewField('divergence', L.float):Load(0)
grid.cells:NewField('p', L.float):Load(0)
grid.cells:NewField('p_temp', L.float):Load(0)

local project_lin_solve_jacobi_step = liszt kernel (c : grid.cells)
    if not c.is_bnd then
        var edge_sum = project_edge * ( c.left.p + c.right.p +
                                        c.up.p + c.down.p )
        c.p_temp = (c.divergence - edge_sum) / project_diagonal
    end
end

-- Neumann condition
local pressure_shadow_update = liszt kernel (c : grid.cells)
    if c.is_left_bnd then
        c.p_temp = c.right.p
    elseif c.is_right_bnd then
        c.p_temp = c.left.p
    elseif c.is_up_bnd then
        c.p_temp = c.down.p
    elseif c.is_down_bnd then
        c.p_temp = c.up.p
    end
end
local pressure_cpy_update = liszt kernel (c : grid.cells)
    c.p = c.p_temp
end
local function pressure_neumann_bnd(cells)
    pressure_shadow_update(cells.boundary)
    pressure_cpy_update(cells.boundary)
end


-- Should be called with velocity and velocity_prev both set to
-- the previous velocity field value...
local function project_lin_solve(edge, diagonal)
    project_diagonal:set(diagonal)
    project_edge:set(edge)

    -- do 20 Jacobi iterations
    for i=1,20 do
        project_lin_solve_jacobi_step(grid.cells)
        grid.cells:Swap('p','p_temp')
        pressure_neumann_bnd(grid.cells)
    end
end

local compute_divergence = liszt kernel (c : grid.cells)
    if c.is_bnd then
        c.divergence = 0
    else
        -- why the factor of N?
        var vx_dx = c.right.velocity[0] - c.left.velocity[0]
        var vy_dy = c.up.velocity[1]   - c.down.velocity[1]
        c.divergence = L.float(-(0.5/N)*(vx_dx + vy_dy))
    end
end

local compute_projection = liszt kernel (c : grid.cells)
    if not c.is_bnd then
        var grad = L.vec2f(0.5 * N * { c.right.p - c.left.p,
                                       c.up.p   - c.down.p })
        c.velocity = c.velocity_prev - grad
    end
end

local function project_velocity(grid)
    local diagonal          =  4.0
    local edge              = -1.0

    compute_divergence(grid.cells)
    grid.cells:Swap('divergence','p') -- move divergence into p to do bnd
    pressure_neumann_bnd(grid.cells)
    grid.cells:Copy{from='p',to='divergence'} -- then copy it back

    project_lin_solve(edge, diagonal)

    grid.cells:Swap('velocity','velocity_prev')
    compute_projection(grid.cells)

    vel_neumann_bnd(grid.cells)
end



local N_particles = (N-1)*(N-1)
local particles = L.NewRelation(N_particles, 'particles')

particles:NewField('dual_cell', grid.dual_cells)
    :Load(function(i) return i end)

particles:NewField('next_pos', L.vec2f):Load(L.NewVector(L.float, {0,0}))
particles:NewField('pos', L.vec2f):Load(L.NewVector(L.float, {0,0}))
(liszt kernel (p : particles) -- init...
    p.pos = p.dual_cell.center
end)(particles)

local locate_particles = liszt kernel (p : particles)
    p.dual_cell = grid.dual_locate(p.pos)
end

local compute_particle_velocity = liszt kernel (p : particles)
    var dc      = p.dual_cell
    var frac    = p.pos - dc.center
    -- figure out fractional position in the dual cell in range [0.0, 1.0]
    var xfrac   = frac[0] / cell_w + 0.5 
    var yfrac   = frac[1] / cell_h + 0.5

    -- interpolation constants
    var x1      = L.float(xfrac)
    var y1      = L.float(yfrac)
    var x0      = L.float(1.0 - xfrac)
    var y0      = L.float(1.0 - yfrac)

    p.next_pos  = p.pos + N *
        ( x0 * y0 * dc.downleft.velocity
        + x1 * y0 * dc.downright.velocity
        + x0 * y1 * dc.upleft.velocity
        + x1 * y1 * dc.upright.velocity )
end

local update_particle_pos = liszt kernel (p : particles)
    var r = L.vec2f({ cmath.rand_float() - 0.5, cmath.rand_float() - 0.5 })
    var pos = p.next_pos + dt * r
    p.pos = grid.snap_to_grid(pos)
end


-----------------------------------------------------------------------------
--[[                             MAIN LOOP                               ]]--
-----------------------------------------------------------------------------

--grid.cells:print()

local source_strength = 100.0
local source_velocity = liszt kernel (c : grid.cells)
    if cmath.fabs(c.center[0]) < 1.75 and
       cmath.fabs(c.center[1]) < 1.75
    then
        if not c.is_bnd then
            c.velocity += dt * source_strength * { 0.0, 1.0 }
        else
            c.velocity += dt * source_strength * { 0.0, -1.0 }
        end
    end
end

local draw_grid = liszt kernel (c : grid.cells)
    var color = {1.0, 1.0, 1.0}
    vdb.color(color)
    var p : L.vec3f = { c.center[0],   c.center[1],   0.0 }
    var vel = c.velocity
    var v = L.vec3f({ vel[0], vel[1], 0.0 })
    --if not c.is_bnd then
    vdb.line(p, p+v*N)
end

local draw_particles = liszt kernel (p : particles)
    var color = {1.0,1.0,0.0}
    vdb.color(color)
    var pos : L.vec3f = { p.pos[0], p.pos[1], 0.0 }
    vdb.point(pos)
end

for i = 1, 500 do
    if math.floor(i / 70) % 2 == 0 then
        source_velocity(grid.cells)
    end

    diffuse_velocity(grid)
    project_velocity(grid)
    --grid.cells:print()
    --io.read()

    advect_velocity(grid)
    project_velocity(grid)

    compute_particle_velocity(particles)
    update_particle_pos(particles)
    locate_particles(particles)

    if i % 5 == 0 then
        vdb.vbegin()
            vdb.frame()
            --draw_grid(grid.cells)
            draw_particles(particles)
        vdb.vend()
    end
end

--grid.cells:print()
