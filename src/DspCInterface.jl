module DspCInterface
using Compat, Pkg
using SparseArrays
import ..Dsp
import Compat: String, unsafe_wrap
import JuMP

if isless(VERSION,v"1.0.0")
	if Pkg.installed("MPI") == nothing
		using MPI
	end
else
	if "MPI" in keys(Pkg.installed())
		using MPI
	end
end

export DspModel

###############################################################################
# Help functions
###############################################################################

macro dsp_ccall(func, args...)
    @static if Compat.Sys.isunix()
        return esc(quote
            ccall(($func, "libDsp"), $(args...))
        end)
    end
    @static if Compat.Sys.iswindows()
        return esc(quote
            ccall(($func, "libDsp"), stdcall, $(args...))
        end)
    end
end

mutable struct DspModel
    p::Ptr{Cvoid}

    # Number of blocks
    nblocks::Int

    # solve_type should be one of these:
    # :Dual
    # :Benders
    # :Extensive
    solve_type

    numRows::Int
    numCols::Int
    primVal
    dualVal
    colVal::Vector{Float64}
    rowVal::Vector{Float64}

    # MPI settings
    comm
    comm_size::Int
    comm_rank::Int

    # Array of block ids:
    # The size of array is not necessarily same as nblocks,
    # as block ids may be distributed to multiple processors.
    block_ids::Vector{Integer}

    function DspModel()
        # assign Dsp pointer
        p = @dsp_ccall("createEnv", Ptr{Cvoid}, ())
        # initialize variables
        nblocks = 0
        solve_type = :Dual
        numRows = 0
        numCols = 0
        primVal = NaN
        dualVal = NaN
        colVal = Vector{Float64}()
        rowVal = Vector{Float64}()
        comm = nothing
        comm_size = 1
        comm_rank = 0
        block_ids = Vector{Integer}()
        # create DspModel
        dsp = new(p, nblocks, solve_type, numRows, numCols, primVal, dualVal, colVal, rowVal, comm, comm_size, comm_rank, block_ids)
        # with finalizer
        finalizer(freeDSP, dsp)
        # return DspModel
        return dsp
    end
end

function freeDSP(dsp::DspModel)
    if dsp.p == C_NULL
        return
    else
        @dsp_ccall("freeEnv", Cvoid, (Ptr{Cvoid},), dsp.p)
        dsp.p = C_NULL
    end
    dsp.nblocks = 0
    dsp.solve_type = nothing
    dsp.numRows = 0
    dsp.numCols = 0
    dsp.primVal = NaN
    dsp.dualVal = NaN
    dsp.colVal = Vector{Float64}()
    dsp.rowVal = Vector{Float64}()
    return
end

function freeModel(dsp::DspModel)
    check_problem(dsp)
    @dsp_ccall("freeModel", Cvoid, (Ptr{Cvoid},), dsp.p)
    dsp.nblocks = 0
    dsp.numRows = 0
    dsp.numCols = 0
    dsp.primVal = NaN
    dsp.dualVal = NaN
    dsp.colVal = Vector{Float64}()
    dsp.rowVal = Vector{Float64}()
end

function check_problem(dsp::DspModel)
    if dsp.p == C_NULL
        error("Invalid DspModel")
    end
end

function readParamFile(dsp::DspModel, param_file::AbstractString)
    check_problem(dsp)
    @dsp_ccall("readParamFile", Cvoid, (Ptr{Cvoid}, Ptr{UInt8}), dsp.p, param_file);
end

function prepConstrMatrix(m::JuMP.Model)
    if !haskey(m.ext, :DspBlocks)
        return JuMP.prepConstrMatrix(m)
    end

    blocks = m.ext[:DspBlocks]
    if blocks.parent == nothing
        return JuMP.prepConstrMatrix(m)
    else
        rind = Int[]
        cind = Int[]
        value = Float64[]
        linconstr = deepcopy(m.linconstr)
        for (nrow,con) in enumerate(linconstr)
            aff = con.terms
            for (var,id) in zip(reverse(aff.vars), length(aff.vars):-1:1)
                push!(rind, nrow)
                if m.linconstr[nrow].terms.vars[id].m == blocks.parent
                    push!(cind, var.col)
                elseif m.linconstr[nrow].terms.vars[id].m == m
                    push!(cind, blocks.parent.numCols + var.col)
                end
                push!(value, aff.coeffs[id])
                splice!(aff.vars, id)
                splice!(aff.coeffs, id)
            end
        end
    end
    return sparse(rind, cind, value, length(m.linconstr), blocks.parent.numCols + m.numCols)
end

###############################################################################
# Block IDs
###############################################################################

function setBlockIds(dsp::DspModel, nblocks::Integer, master_has_subblocks::Bool = false)
    check_problem(dsp)
    # set number of blocks
    dsp.nblocks = nblocks
    # set MPI settings
    if @isdefined(MPI) && MPI.Initialized()
        dsp.comm = MPI.COMM_WORLD
        dsp.comm_size = MPI.Comm_size(dsp.comm)
        dsp.comm_rank = MPI.Comm_rank(dsp.comm)
    end
    #@show dsp.nblocks
    #@show dsp.comm
    #@show dsp.comm_size
    #@show dsp.comm_rank
    # get block ids with MPI settings
    dsp.block_ids = getBlockIds(dsp, master_has_subblocks)
    #@show dsp.block_ids
    # send the block ids to Dsp
    @dsp_ccall("setIntPtrParam", Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Cint, Ptr{Cint}),
        dsp.p, "ARR_PROC_IDX", convert(Cint, length(dsp.block_ids)), convert(Vector{Cint}, dsp.block_ids .- 1))
end

function getBlockIds(dsp::DspModel, master_has_subblocks::Bool = false)
    check_problem(dsp)
    # processor info
    mysize = dsp.comm_size
    myrank = dsp.comm_rank
    # empty block ids
    proc_idx_set = Int[]
    # DSP is further parallelized with mysize > dsp.nblocks.
    modrank = myrank % dsp.nblocks
    # If we have more than one processor,
    # do not assign a sub-block to the master.
    if master_has_subblocks
        # assign sub-blocks in round-robin fashion
        for s = modrank:mysize:(dsp.nblocks-1)
            push!(proc_idx_set, s+1)
        end
    else
        if mysize > 1
            if myrank == 0
                return proc_idx_set
            end
            # exclude master
            mysize -= 1;
            modrank = (myrank-1) % dsp.nblocks
        end
        # assign sub-blocks in round-robin fashion
        for s = modrank:mysize:(dsp.nblocks-1)
            push!(proc_idx_set, s+1)
        end
    end
    # return assigned block ids
    return proc_idx_set
end

function getNumBlockCols(dsp::DspModel, m::JuMP.Model)
    check_problem(dsp)
    # subblocks
    blocks = m.ext[:DspBlocks].children
    # get number of block columns
    numBlockCols = Dict{Int,Int}()
    if dsp.comm_size > 1
        num_proc_blocks = convert(Vector{Cint}, MPI.Allgather(length(blocks), dsp.comm))
        #@show num_proc_blocks
        #@show collect(keys(blocks))
        block_ids = MPI.Allgatherv(collect(keys(blocks)), num_proc_blocks, dsp.comm)
        #@show block_ids
        ncols_to_send = Int[blocks[i].numCols for i in keys(blocks)]
        #@show ncols_to_send
        ncols = MPI.Allgatherv(ncols_to_send, num_proc_blocks, dsp.comm)
        #@show ncols
        for i in 1:dsp.nblocks
            setindex!(numBlockCols, ncols[i], block_ids[i])
        end
    else
        for b in blocks
            setindex!(numBlockCols, b.second.numCols, b.first)
        end
    end
    return numBlockCols
end

###############################################################################
# Load problems
###############################################################################

function readSmps(dsp::DspModel, filename::AbstractString, master_has_subblocks::Bool = false)
    # Check pointer to TssModel
    check_problem(dsp)
    # read smps files
    @dsp_ccall("readSmps", Cvoid, (Ptr{Cvoid}, Ptr{UInt8}), dsp.p, convert(Vector{UInt8}, filename))
    # set block Ids
    setBlockIds(dsp, getNumScenarios(dsp), master_has_subblocks)
end

function loadProblem(dsp::DspModel, model::JuMP.Model)
    check_problem(dsp)
    if haskey(model.ext, :DspBlocks)
        if dsp.solve_type in [:Dual, :Benders, :Extensive]
            loadStochasticProblem(dsp, model)
        elseif dsp.solve_type in [:BB]
            loadStructuredProblem(dsp, model)
        end
    else
        error("No block is defined.")
    end
end

function loadStochasticProblem(dsp::DspModel, model::JuMP.Model)
    # get DspBlocks
    blocks = model.ext[:DspBlocks]

    nscen  = dsp.nblocks
    ncols1 = model.numCols
    nrows1 = length(model.linconstr)
    ncols2 = 0
    nrows2 = 0
    for s in values(blocks.children)
        ncols2 = s.numCols
        nrows2 = length(s.linconstr)
        break
    end

    # set scenario indices for each MPI processor
    if dsp.comm_size > 1
        ncols2 = MPI.allreduce([ncols2], MPI.MAX, dsp.comm)[1]
        nrows2 = MPI.allreduce([nrows2], MPI.MAX, dsp.comm)[1]
    end

    @dsp_ccall("setNumberOfScenarios", Cvoid, (Ptr{Cvoid}, Cint), dsp.p, convert(Cint, nscen))
    @dsp_ccall("setDimensions", Cvoid,
        (Ptr{Cvoid}, Cint, Cint, Cint, Cint),
        dsp.p, convert(Cint, ncols1), convert(Cint, nrows1), convert(Cint, ncols2), convert(Cint, nrows2))

    # get problem data
    start, index, value, clbd, cubd, ctype, obj, rlbd, rubd = getDataFormat(model)

    @dsp_ccall("loadFirstStage", Cvoid,
        (Ptr{Cvoid}, Ptr{Cint}, Ptr{Cint}, Ptr{Cdouble}, Ptr{Cdouble},
            Ptr{Cdouble}, Ptr{UInt8}, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cdouble}),
            dsp.p, start, index, value, clbd, cubd, ctype, obj, rlbd, rubd)

    for id in dsp.block_ids
        # model and probability
        blk = blocks.children[id]
        probability = blocks.weight[id]
        # get model data
        start, index, value, clbd, cubd, ctype, obj, rlbd, rubd = getDataFormat(blk)
        @dsp_ccall("loadSecondStage", Cvoid,
            (Ptr{Cvoid}, Cint, Cdouble, Ptr{Cint}, Ptr{Cint}, Ptr{Cdouble}, Ptr{Cdouble},
                Ptr{Cdouble}, Ptr{UInt8}, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cdouble}),
            dsp.p, id-1, probability, start, index, value, clbd, cubd, ctype, obj, rlbd, rubd)
    end
end

function loadStructuredProblem(dsp::DspModel, model::JuMP.Model)

    ncols_master = model.numCols
    nrows_master = length(model.linconstr)
    # @show ncols_master
    # @show nrows_master

    # TODO: do something for MPI
    
    # load master
    start, index, value, clbd_master, cubd_master, ctype_master, obj_master, rlbd, rubd = getDataFormat(model)
    @dsp_ccall("loadBlockProblem", Cvoid, (
        Ptr{Cvoid},    # env
        Cint,         # id
        Cint,         # ncols
        Cint,         # nrows
        Cint,         # numels
        Ptr{Cint},    # start
        Ptr{Cint},    # index
        Ptr{Cdouble}, # value
        Ptr{Cdouble}, # clbd
        Ptr{Cdouble}, # cubd
        Ptr{UInt8},   # ctype
        Ptr{Cdouble}, # obj
        Ptr{Cdouble}, # rlbd
        Ptr{Cdouble}  # rubd
        ),
        dsp.p, 0, ncols_master, nrows_master, start[nrows_master+1],
        start, index, value, clbd_master, cubd_master, ctype_master, obj_master, rlbd, rubd)

    # going over blocks
    blocks = model.ext[:DspBlocks]
    for id in dsp.block_ids
        child = blocks.children[id]
        weight = blocks.weight[id]
        ncols_block = child.numCols # number of columns not coupled with the master
        nrows_block = length(child.linconstr)
        # @show id
        # @show ncols_block
        # @show nrows_block
        # load blocks
        start, index, value, clbd, cubd, ctype, obj, rlbd, rubd = getDataFormat(child)
        # @show start
        # @show index
        # @show value
        @dsp_ccall("loadBlockProblem", Cvoid, (
            Ptr{Cvoid},    # env
            Cint,         # id
            Cint,         # ncols
            Cint,         # nrows
            Cint,         # numels
            Ptr{Cint},    # start
            Ptr{Cint},    # index
            Ptr{Cdouble}, # value
            Ptr{Cdouble}, # clbd
            Ptr{Cdouble}, # cubd
            Ptr{UInt8},   # ctype
            Ptr{Cdouble}, # obj
            Ptr{Cdouble}, # rlbd
            Ptr{Cdouble}  # rubd
            ),
            dsp.p, id, ncols_master + ncols_block, nrows_block, start[nrows_block+1], 
            start, index, value, [clbd_master;clbd], [cubd_master;cubd], [ctype_master;ctype], 
            [obj_master;obj], rlbd, rubd)
    end

    # Finalize loading blocks
    @dsp_ccall("updateBlocks", Cvoid, (Ptr{Cvoid},), dsp.p)
end

function loadDeterministicProblem(dsp::DspModel, model::JuMP.Model)
    ncols = convert(Cint, model.numCols)
    nrows = convert(Cint, length(model.linconstr))
    start, index, value, clbd, cubd, ctype, obj, rlbd, rubd = getDataFormat(model)
    numels = length(index)
    @dsp_ccall("loadDeterministic", Cvoid,
        (Ptr{Cvoid}, Ptr{Cint}, Ptr{Cint}, Ptr{Cdouble}, Cint, Cint, Cint,
            Ptr{Cdouble}, Ptr{Cdouble}, Ptr{UInt8}, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cdouble}),
            dsp.p, start, index, value, numels, ncols, nrows, clbd, cubd, ctype, obj, rlbd, rubd)
end


###############################################################################
# Get functions
###############################################################################

for func in [:freeSolver, 
             :solveDe, 
             :solveBd, 
             :solveDd, 
             :solveDw]
    strfunc = string(func)
    @eval begin
        function $func(dsp::DspModel)
            return @dsp_ccall($strfunc, Cvoid, (Ptr{Cvoid},), dsp.p)
        end
    end
end

for func in [:solveBdMpi, :solveDdMpi, :solveDwMpi]
    strfunc = string(func)
    @eval begin
        function $func(dsp::DspModel, comm)
            return @dsp_ccall($strfunc, Cvoid, (Ptr{Cvoid}, MPI.CComm), dsp.p, convert(MPI.CComm, comm))
        end
    end
end

function solve(dsp::DspModel)
    check_problem(dsp)
    if dsp.comm_size == 1
        if dsp.solve_type == :Dual
            solveDd(dsp);
        elseif dsp.solve_type == :Benders
            solveBd(dsp);
        elseif dsp.solve_type == :Extensive
            solveDe(dsp);
        elseif dsp.solve_type == :BB
            solveDw(dsp);
        end
    elseif dsp.comm_size > 1
        if dsp.solve_type == :Dual
            solveDdMpi(dsp, dsp.comm);
        elseif dsp.solve_type == :Benders
            solveBdMpi(dsp, dsp.comm);
        elseif dsp.solve_type == :BB
            solveDwMpi(dsp, dsp.comm);
        elseif dsp.solve_type == :Extensive
            solveDe(dsp);
        end
    end
end

###############################################################################
# Get functions
###############################################################################

function getDataFormat(model::JuMP.Model)
    # Get a column-wise sparse matrix
    mat = prepConstrMatrix(model)

    # Tranpose; now I have row-wise sparse matrix
    mat = permutedims(mat)

    # sparse description
    start = convert(Vector{Cint}, mat.colptr .- 1)
    index = convert(Vector{Cint}, mat.rowval .- 1)
    value = mat.nzval

    # column type
    ctype = ""
    for i = 1:length(model.colCat)
        if model.colCat[i] == :Int
            ctype = ctype * "I";
        elseif model.colCat[i] == :Bin
            ctype = ctype * "B";
        else
            ctype = ctype * "C";
        end
    end
	ctype = Vector{UInt8}(ctype)

    # objective coefficients
    obj = JuMP.prepAffObjective(model)
    rlbd, rubd = JuMP.prepConstrBounds(model)

    # set objective sense
    if model.objSense == :Max
        obj *= -1
    end

    return start, index, value, model.colLower, model.colUpper, ctype, obj, rlbd, rubd
end

for (func,rtn) in [(:getNumScenarios, Cint), 
                   (:getTotalNumRows, Cint), 
                   (:getTotalNumCols, Cint), 
                   (:getStatus, Cint), 
                   (:getNumIterations, Cint), 
                   (:getNumNodes, Cint), 
                   (:getWallTime, Cdouble), 
                   (:getPrimalBound, Cdouble), 
                   (:getDualBound, Cdouble),
                   (:getNumCouplingRows, Cint)]
    strfunc = string(func)
    @eval begin
        function $func(dsp::DspModel)
            check_problem(dsp)
            return @dsp_ccall($strfunc, $rtn, (Ptr{Cvoid},), dsp.p)
        end
    end
end

function getSolution(dsp::DspModel, num::Integer)
    #@compat sol = Array{Cdouble}(num)
	sol = zeros(num)
    @dsp_ccall("getPrimalSolution", Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cdouble}), dsp.p, num, sol)
    return sol
end
getSolution(dsp::DspModel) = getSolution(dsp, getTotalNumCols(dsp))

function getDualSolution(dsp::DspModel, num::Integer)
    #@compat sol = Array{Cdouble}(num)
	sol = zeros(num)
    @dsp_ccall("getDualSolution", Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cdouble}), dsp.p, num, sol)
    return sol
end
getDualSolution(dsp::DspModel) = getDualSolution(dsp, getNumCouplingRows(dsp))

###############################################################################
# Set functions
###############################################################################

function setSolverType(dsp::DspModel, solver)
    check_problem(dsp)
    solver_types = [:DualDecomp, :Benders, :ExtensiveForm]
    if solver in solver_types
        dsp.solver = solver
    else
        warn("Solver type $solver is invalid.")
    end
end

end # end of module
