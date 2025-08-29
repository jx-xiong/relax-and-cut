using UnitCommitment

push!(LOAD_PATH, joinpath(@__DIR__, ".", "src"))
using ucRH
using Gurobi
using JuMP

import UnitCommitment:
    TimeDecomposition,
    ConventionalLMP,
    XavQiuWanThi2019,
    Formulation,
    Gar1962

import Base.Threads: @threads

function main()
# dataset_name = "case89pegase"
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

println(fstt)
# assume the instance is given as a 120h problem
instance = UnitCommitment.read_benchmark(fstt)
instance_rh = ucRH.read_dir(fstt,)
lmps = []

function after_build(model, instance)
    JuMP.set_optimizer_attribute(model, "Threads", nthreads)
end

function after_optimize(solution, model, instance)
    final_obj = objective_value(model)
    return push!(lmps, final_obj)
end
solution = nothing
K = Threads.nthreads()
println("number of threads $(K))")
total_time = @elapsed begin
    try 
        solution = UnitCommitment.optimize!(
        instance,
        TimeDecomposition(
            time_window = 6, 
            time_increment = 6,  
            inner_method = UnitCommitment.XavQiuWanThi2019.Method(time_limit=3600.0, 
                                                                gap_limit=1e-3, 
                                                                two_phase_gap=true,),
            formulation = Formulation(pwl_costs=Gar1962.PwlCosts()),
        ),
        optimizer = Gurobi.Optimizer,
        after_optimize = after_optimize,
        after_build = after_build,
        )
    catch e
        println("Error: $(e)")
        open("res_td_threads_$(K)_nthreads_$(nthreads).txt","a") do file
            println(file,"$(dataset_name) baseline_time_decompos $(0.0) $(0.0) feasibility_false")
        end
    end
end
fobj= sum(lmps)
sol_feas = ucRH.validate(instance_rh, solution)


open("res_td_threads_$(K)_nthreads_$(nthreads).txt","a") do file
    println(file,"$(dataset_name) baseline_time_decompos $(total_time) $(fobj) feasibility_$(sol_feas)")
end

end

main()