# Copyright 2016 Martin Holters
# See accompanying license file.

type ParametricNonLinEq
    func::Function
    res::Vector{Float64}
    Jp::Matrix{Float64}
    J::Matrix{Float64}
    function ParametricNonLinEq(func::Function, nn::Integer, np::Integer)
        res = zeros(nn)
        Jp = zeros(nn, np)
        J = zeros(nn, nn)
        return new(func, res, Jp, J)
    end
end

nn(nleq::ParametricNonLinEq) = length(nleq.res)
np(nleq::ParametricNonLinEq) = size(nleq.Jp, 2)

evaluate!(nleq::ParametricNonLinEq, p, z) =
    nleq.func(nleq.res, nleq.J, nleq.Jp, p, z)


type SimpleSolver
    nleq::ParametricNonLinEq
    z::Vector{Float64}
    last_z::Vector{Float64}
    last_p::Vector{Float64}
    last_Jp::Matrix{Float64}
    JLU::Base.LU{Float64,Matrix{Float64}}
    iters::Int
    tol::Float64
    function SimpleSolver(nleq::ParametricNonLinEq, initial_p::Vector{Float64},
                          initial_z::Vector{Float64})
        z = zeros(nn(nleq))
        last_z = zeros(nn(nleq))
        last_p = zeros(np(nleq))
        last_Jp = zeros(nn(nleq), np(nleq))
        JLU = lufact(eye(nn(nleq)))
        solver = new(nleq, z, last_z, last_p, last_Jp, JLU, 0, 1e-20)
        set_extrapolation_origin(solver, initial_p, initial_z)
        return solver
    end
end

set_resabs2tol!(solver::SimpleSolver, tol) = solver.tol = tol

function set_extrapolation_origin(solver::SimpleSolver, p, z)
    evaluate!(solver.nleq, p, z)
    JLU = lufact(solver.nleq.J)
    set_extrapolation_origin(solver, p, z, solver.nleq.Jp, JLU)
end

function set_extrapolation_origin(solver::SimpleSolver, p, z, Jp, JLU)
    solver.JLU = JLU
    copy!(solver.last_Jp, Jp)
    copy!(solver.last_p, p)
    copy!(solver.last_z, z)
end

get_extrapolation_origin(solver::SimpleSolver) = solver.last_p, solver.last_z

function hasconverged(solver::SimpleSolver)
    return sumabs2(solver.nleq.res) < solver.tol
end

needediterations(solver::SimpleSolver) = solver.iters

function solve(solver::SimpleSolver, p::AbstractVector{Float64}, maxiter=500)
    copy!(solver.z, solver.last_z - solver.JLU\(solver.last_Jp * (p - solver.last_p)))
    local JLU
    for solver.iters=1:maxiter
        evaluate!(solver.nleq, p, solver.z)
        if ~all(isfinite(solver.nleq.res)) || ~all(isfinite(solver.nleq.J))
            return solver.z
        end
        JLU = lufact(solver.nleq.J)
        if JLU.info > 0 # J was singular
            return solver.z
        end
        hasconverged(solver) && break
        solver.z -= JLU\solver.nleq.res
    end
    if hasconverged(solver)
        set_extrapolation_origin(solver, p, solver.z, solver.nleq.Jp, JLU)
    end
    return solver.z
end


type HomotopySolver{BaseSolver}
    basesolver::BaseSolver
    start_p::Vector{Float64}
    iters::Int
    function HomotopySolver(nleq::ParametricNonLinEq,
                            initial_p::Vector{Float64},
                            initial_z::Vector{Float64})
        basesolver = BaseSolver(nleq, initial_p, initial_z)
        return new(basesolver, zeros(np(nleq)), 0)
    end
end

set_resabs2tol!(solver::HomotopySolver, tol) =
    set_resabs2tol!(solver.basesolver, tol)

set_extrapolation_origin(solver::HomotopySolver, p, z) =
    set_extrapolation_origin(solver.basesolver, p, z)

function solve(solver::HomotopySolver, p)
    z = solve(solver.basesolver, p)
    solver.iters = needediterations(solver.basesolver)
    if ~hasconverged(solver)
        a = 0.5
        best_a = 0.0
        copy!(solver.start_p, get_extrapolation_origin(solver.basesolver)[1])
        while best_a < 1 && a > 0
            pa = (1-a) * solver.start_p + a * p
            z = solve(solver.basesolver, pa)
            if hasconverged(solver)
                best_a = a
                a = 1.0
            else
                a = (a + best_a) / 2
            end
        end
    end
    return z
end

hasconverged(solver::HomotopySolver) = hasconverged(solver.basesolver)
needediterations(solver::HomotopySolver) = solver.iters


type CachingSolver{BaseSolver}
    basesolver::BaseSolver
    ps_tree::KDTree{Vector{Float64}, Matrix{Float64}}
    zs::Matrix{Float64}
    new_count::Int
    new_count_limit::Int
    function CachingSolver(nleq::ParametricNonLinEq, initial_p::Vector{Float64},
                          initial_z::Vector{Float64})
        basesolver = BaseSolver(nleq, initial_p, initial_z)
        ps_tree = KDTree(reshape(copy(initial_p), np(nleq), 1))
        zs = reshape(copy(initial_z), nn(nleq), 1)
        return new(basesolver, ps_tree, zs, 0, 2)
    end
end

set_resabs2tol!(solver::CachingSolver, tol) =
    set_resabs2tol!(solver.basesolver, tol)

hasconverged(solver::CachingSolver) = hasconverged(solver.basesolver)
needediterations(solver::CachingSolver) = needediterations(solver.basesolver)

function solve(solver::CachingSolver, p)
    best_diff = sumabs2(p - get_extrapolation_origin(solver.basesolver)[1])
    idx = 0
    num_ps = size(solver.ps_tree.ps, 2)
    for i in (num_ps-solver.new_count+1):num_ps
        diff = 0.
        for j in 1:size(solver.ps_tree.ps, 1)
            diff += abs2(solver.ps_tree.ps[j,i] - p[j])
        end
        if diff < best_diff
            best_diff = diff
            idx = i
        end
    end

    idx = indnearest(solver.ps_tree, p,
                     Alts([AltEntry(1, zeros(p), 0.0)], best_diff, idx))[1]

    if idx ≠ 0
        set_extrapolation_origin(solver.basesolver,
                                 solver.ps_tree.ps[:,idx], solver.zs[:,idx])
    end

    z = solve(solver.basesolver, p)
    if needediterations(solver.basesolver) > 5 && hasconverged(solver.basesolver)
        solver.ps_tree.ps = [solver.ps_tree.ps p]
        solver.zs = [solver.zs z]
        solver.new_count += 1
    end
    if solver.new_count > 0
        solver.new_count_limit -= 1
    end
    if solver.new_count > solver.new_count_limit
        solver.ps_tree = KDTree(solver.ps_tree.ps)
        solver.new_count = 0
        solver.new_count_limit = 2size(solver.ps_tree.ps, 2)
    end
    return z
end

get_extrapolation_origin(solver::CachingSolver) =
    get_extrapolation_origin(solver.basesolver)
