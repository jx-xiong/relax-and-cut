using UnitCommitment
push!(LOAD_PATH, joinpath(@__DIR__, ".", "src"))
using ucRH

using Gurobi
using JuMP
using Ipopt
using JSON

import ucRH:
    Formulation,
    KnuOstWat2018,
    MorLatRam2013,
    ShiftFactorsFormulation,
    Gar1962,
    CarArr2006

import Base.Threads: @threads


function main()
    nthreads = 1
    println("Checking args")
    parsed = Dict{String,String}()
    i = 1
    while i <= length(ARGS)
        if startswith(ARGS[i], "-")
            # this one is an argument identifier
            key = ARGS[i][2:end]  # remove the leading "-"
            # check if the next one is value
            if i + 1 <= length(ARGS) && ~startswith(ARGS[i+1], "-")
                # Next is value, this one comes with value
                parsed[key] = ARGS[i+1]
                i += 2
            else
                # Next is not, this is a bool arg
                parsed[key] = "True"
                i += 1
            end
        else
            error("Unexpected argument format: $(ARGS[i])")
        end
    end

    # obtain all keys
    if haskey(parsed, "dataset")
        dataset_name = parsed["dataset"]
        @info "Setting dataset_name to $(dataset_name)"
    else
        error("Missing critical arg: dataset")
    end

    if haskey(parsed, "threads")
        nthreads = parse(Int, parsed["threads"])
        @info "Setting nthreads to $(nthreads)"
    end
    
    println("Finished loading args")

    fstt = "matpower_subhour/$(dataset_name)/2017-01-01"
    ori_is = UnitCommitment.read_benchmark(fstt,)


    ########## constructing the model and solve using UnitCommitment.optimize!
    ori_model1 = UnitCommitment.build_model(
        instance=ori_is,
        optimizer=Gurobi.Optimizer,
    )
    @info "Time window: $(ori_model1[:instance].time)"
    JuMP.set_optimizer_attribute(ori_model1, "OutputFlag", 1)
    JuMP.set_optimizer_attribute(ori_model1, "Threads", nthreads)

    total_time = @elapsed begin 
        
        UnitCommitment.optimize!(ori_model1,
            UnitCommitment.XavQiuWanThi2019.Method(time_limit=3600.0, 
                    gap_limit=1e-2, 
                    two_phase_gap=true,
                    # max_violations_per_line=50000,
                    # max_violations_per_period=50000,
                    ))
    end

    constructive_obj = objective_value(ori_model1)
    solution_starting = UnitCommitment.solution(ori_model1)
    sol_feas1 = UnitCommitment.validate(ori_is, solution_starting)

    
    printstyled("----------UC--------------\n")
    printstyled("  First obj: $(constructive_obj)\n"; color=:red)

    K = Threads.nthreads()
    open("res_uc_threads_$(K)_nthreads_$(nthreads).txt","a") do file
        println(file,"$(dataset_name) start $(total_time) $(constructive_obj) feasible_$(sol_feas1)")
    end
end

main()