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
    # debug args
    fix_pow = false
    solve_ori = false
    write_ori = false
    test_sub = false
    full_cb = false
    decom_no_cb = false

    # parameters
    nCont = 24
    nInt = 24
    stepsize = 16
    type_imp = 0
    dataset_name = "case89pegase"

    # model parameters
    gap = 1e-3
    sub_gap = 1e-2
    nthreads = 1 # nthreads: for Gurobi, threads for julia
    time_limit = 3600

    # parsing arguments
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
    if haskey(parsed, "full_cb")
        full_cb = true
        @info "Setting gap to $(gap)"
    end

    if haskey(parsed, "decom_no_cb")
        decom_no_cb = true
        @info "Setting decom_no_cb to $(decom_no_cb)"
    end

    if haskey(parsed, "nInt")
        nInt = parse(Int, parsed["nInt"])
        @info "Setting nInt to $(nInt)"
    elseif ~full_cb
        error("Missing critical arg: nInt")
    end
    if haskey(parsed, "nCont")
        nCont = parse(Int, parsed["nCont"])
        @info "Setting nCont to $(nCont)"
    elseif ~full_cb
        error("Missing critical arg: nCont")
    end
    if haskey(parsed, "dataset")
        dataset_name = parsed["dataset"]
        @info "Setting dataset_name to $(dataset_name)"
    else
        error("Missing critical arg: dataset")
    end
    stepsize = nInt
    if haskey(parsed, "stepsize")
        stepsize = parse(Int, parsed["stepsize"])
        @info "Setting stepsize to $(stepsize)"
    end
    if haskey(parsed, "ori")
        solve_ori = true
        @info "Setting solve_ori to $(solve_ori)"
    end
    if haskey(parsed, "pow")
        fix_pow = true
        @info "Setting fix_pow to $(fix_pow)"
    end
    if haskey(parsed, "type_imp")
        type_imp = parse(Int, parsed["type_imp"])
        @info "Setting type_imp to $(type_imp)"
    end
    if haskey(parsed, "threads")
        nthreads = parse(Int, parsed["threads"])
        @info "Setting threads to $(nthreads)"
    end



    println("Finished loading args")

    fstt = "matpower/$(dataset_name)/2017-01-01"
    ori_is = UnitCommitment.read_benchmark(fstt,)
    run(`python dataset_transformer.py --dataset $(dataset_name)`, wait=true)
    fstt = "matpower_subhour/$(dataset_name)/2017-01-01"
    instance = ucRH.read_dir(fstt,)
    instance1 = ucRH.read_dir(fstt, )
    @info "Finished loading instance"


    # # check number of category
    # S = 0
    # delay_max = 0
    # for g in instance.scenarios[1].thermal_units
    #     S = max(S, length(g.startup_categories))
    #     for s in g.startup_categories
    #         delay_max = max(delay_max, s.delay)
    #     end
    # end

    # open("startup_categories.txt", "a") do file
    #     println(file, "$(dataset_name) category_$(S) delay_$(delay_max)")
    # end
    # return

    if solve_ori
        ori_model2 = UnitCommitment.build_model(
            instance=ori_is,
            optimizer=Gurobi.Optimizer,
            formulation=UnitCommitment.Formulation(pwl_costs=UnitCommitment.Gar1962.PwlCosts()),
            variable_names=true,
        )
        # write instance to json file
        if write_ori
            open("intance_$(dataset_name)_ori.json", "w") do f
                JSON.print(f, ori_is)
            end
        end 
        if test_sub
            sub_instance = UnitCommitment.slice(ori_is, 1:2)
            # build and optimize the model 
            sub_model = UnitCommitment.build_model(
                instance = sub_instance,
                optimizer = Gurobi.Optimizer,
                variable_names=true
            )
            UnitCommitment.optimize!(sub_model)
            # get the solution
            solution_sub = UnitCommitment.solution(sub_model)
            JuMP.write_to_file(sub_model, "$(dataset_name)_sub.lp")
            UnitCommitment.write("sol_sub_$(dataset_name).json", solution_sub)
            printstyled("!!!!!!!!!!FINISHED WRITING MPS\n"; color=:red)
        end

        if write_ori
            JuMP.write_to_file(ori_model2, "$(dataset_name)_ori.lp")
            printstyled("!!!!!!!!!!FINISHED WRITING MPS\n"; color=:red)
            JuMP.set_optimizer_attribute(ori_model2, "Threads", nthreads)
            JuMP.set_optimizer_attribute(ori_model2, "MIPGap", gap)
            JuMP.set_time_limit_sec(ori_model2, time_limit)
            @info "original model created using UnitCommitment"
            total_time_jl = @elapsed begin
                UnitCommitment.optimize!(ori_model2)
            end
            ori_obj = objective_value(ori_model2)
            solution_orig = UnitCommitment.solution(ori_model2)
            sol_feas_orig = UnitCommitment.validate(ori_is, solution_orig)
            UnitCommitment.write("sol_orig_$(dataset_name).json", solution_orig)
            open("res_an.txt", "a") do file
                println(file, "$(dataset_name) ori $(total_time_jl) $(ori_obj) feasibility_$(sol_feas_orig)")
            end
        end
        return
    end

    # constructing the ori_model, spanning the whole time window, used for improvement stage
    net_tw_ori = instance.time 
    ori_model = ucRH.build_model(
        instance=instance1,
        optimizer=Gurobi.Optimizer,
        nCont=0,
        nInt=net_tw_ori,
        # formulation=Formulation(pwl_costs=Gar1962.PwlCosts()),
    )
    not_unfix_is_on, not_unfix_switch_on, not_unfix_switch_off = ucRH.update_model(instance1, ori_model, 0)


    function my_callback_function_ori(cb_data)
        status = callback_node_status(cb_data, ori_model)
        if status == MOI.CALLBACK_NODE_STATUS_FRACTIONAL
            return
        elseif status == MOI.CALLBACK_NODE_STATUS_INTEGER
            println("Found Integer Solution... callback")
        else
            println("Unknown status")
            return
        end
        # check violation and add cuts

        violations = []
        find_time = @elapsed begin
            for sc in ori_model[:instance].scenarios
                push!(
                    violations,
                    ucRH._find_violations_callback(
                        ori_model,
                        sc,
                        max_per_line=1,
                        max_per_period=5,
                        nStart=1,
                        nEnd=net_tw_ori,
                        cb_data=cb_data
                    ),
                )
            end
        end

        violations_found = false
        for v in violations
            if !isempty(v)
                violations_found = true
            end
        end

        enfor_time = @elapsed begin
            if violations_found
                time_screening = @elapsed begin
                    for (i, v) in enumerate(violations)
                        ucRH._enforce_transmission_callback(ori_model, v, ori_model[:instance].scenarios[i], cb_data)
                    end
                end
                println("Enforced transmission limits in $(time_screening) seconds")
            else
                @info "No violations found"
            end
        end

        println("Finished one enforce::: find time:$(find_time), enforce time:$(enfor_time)")
    end

    
    if decom_no_cb
        println("Decomposing without callback")
    else
        set_attribute(ori_model, MOI.LazyConstraintCallback(), my_callback_function_ori)
    end
    JuMP.set_optimizer_attribute(ori_model, "Threads", nthreads)
    JuMP.set_optimizer_attribute(ori_model, "MIPGap", gap)
    JuMP.set_time_limit_sec(ori_model, time_limit)
    JuMP.set_optimizer_attribute(ori_model, "OutputFlag", 1)

    if full_cb
        total_time = @elapsed begin
            JuMP.optimize!(ori_model)
        end
        constructive_obj = objective_value(ori_model)
        println("Objective value: ", constructive_obj)
        solution_orig = ucRH.solution(ori_model)
        sol_feas1 = ucRH.validate(instance1, solution_orig)
        println("Feasibility of the starting solution: $(sol_feas1)")
        K = Threads.nthreads()
        open("res_full_cb_threads_$(K)_nthreads_$(nthreads).txt","a") do file
            println(file,"$(dataset_name) full_cb $(total_time) $(constructive_obj) feasible_$(sol_feas1)")
        end
        return
    end

    # JuMP.optimize!(ori_model)
    # println("Objective value: ", objective_value(ori_model))
    # solution_orig = ucRH.solution(ori_model)
    # sol_feas_orig = ucRH.validate(instance1, solution_orig)
    # println("Feasibility of the starting solution: $(sol_feas_orig)")
    # return 

    # Construct model (using state-of-the-art defaults)
    model = ucRH.build_model(
        instance=instance,
        optimizer=Gurobi.Optimizer,
        nCont=nCont,
        nInt=nInt,
        formulation=Formulation(pwl_costs=Gar1962.PwlCosts()) # use simple pwl_costs
    )

    function my_callback_function(cb_data)
        status = callback_node_status(cb_data, model)
        if status == MOI.CALLBACK_NODE_STATUS_FRACTIONAL
            return
        elseif status == MOI.CALLBACK_NODE_STATUS_INTEGER
            println("Found Integer Solution... callback")
        else
            println("Unknown status")
            return
        end
        # check violation and add cuts

        violations = []
        find_time = @elapsed begin
            for sc in model[:instance].scenarios
                push!(
                    violations,
                    ucRH._find_violations_callback(
                        model,
                        sc,
                        max_per_line=1,
                        max_per_period=5,
                        nStart=1,
                        nEnd=model[:nsize],
                        cb_data=cb_data
                    ),
                )
            end
        end

        violations_found = false
        for v in violations
            if !isempty(v)
                violations_found = true
            end
        end

        enfor_time = @elapsed begin
            if violations_found
                time_screening = @elapsed begin
                    for (i, v) in enumerate(violations)
                        ucRH._enforce_transmission_callback(model, v, model[:instance].scenarios[i], cb_data)
                    end
                end
                println("Enforced transmission limits in $(time_screening) seconds")
            else
                @info "No violations found"
            end
        end

        println("Finished one enforce::: find time:$(find_time), enforce time:$(enfor_time)")
    end

    if decom_no_cb
        println("Decomposing without callback")
        model[:rh] = false
    else
        set_attribute(model, MOI.LazyConstraintCallback(), my_callback_function)
        model[:rh] = true  
    end

    JuMP.set_time_limit_sec(model, time_limit)
    JuMP.set_optimizer_attribute(model, "Threads", nthreads)
    JuMP.set_optimizer_attribute(model, "OutputFlag", 0)
    JuMP.set_optimizer_attribute(model, "MIPGap", sub_gap)
    println("RH Model Created")
    @info "RH model created"


    net_tw = instance.time
    offset = 0
    iteration = 0
    update_time = 0
    total_time = @elapsed begin
        while offset + nInt + nCont < net_tw # will solve the model with all integer in the end, 
            printstyled("Current dealing with time window: $(offset+1) ~ $(offset+nInt)I + $(offset+nInt+1)~$(offset+nInt+nCont)C / $(net_tw)", "\n"; color=:blue)
            @info "Current dealing with time window: $(offset+1) ~ $(offset+nInt)I + $(offset+nInt+1)~$(offset+nInt+nCont)C / $(net_tw)"
            update_time += @elapsed begin 
                ucRH.update_model(instance, model, offset)
            end

            milp_time = @elapsed begin
                try 
                    ucRH.run_rh_cb!(model, nInt, nCont, stepsize, offset)
                catch e
                    println("Error: $(e)")
                    K = Threads.nthreads()
                    if ~decom_no_cb
                        res_file_name = "res_an_threads_$(K)_nthreads_$(nthreads).txt"
                    else
                        res_file_name = "res_an_no_cb_threads_$(K)_nthreads_$(nthreads).txt"
                    end
                    open(res_file_name,"a") do file
                        println(file,"$(dataset_name) start_$(nInt)_$(stepsize) 0 0 feasible_false")
                        println(file,"$(dataset_name) improve_$(nInt)_$(type_imp)_$(stepsize) 0 0 feasible_false")
                        println(file,"$(dataset_name) rh_$(nInt)_$(type_imp)_$(stepsize) 0 0 feasible_false")
                    end
                    return
                end
            end
            iteration += 1
            

            update_time += @elapsed begin
                if offset + nInt + nCont >= net_tw
                    break
                end
                ucRH.clean_model(instance, model, offset)
            end
            @info "Finished iteration $(iteration), \n time window:  $(offset+1) ~ $(offset+nInt)I + $(offset+nInt+1)~$(offset+nInt+nCont)C / $(net_tw)"
            offset += stepsize
        end

        printstyled("Finished most of construction, need to finish last tw\n"; color=:blue)
        # need to solve for the last window
        #  we can first fix all, then directly sovle
        is_on_ts = model[:is_on_ts]
        switch_on_ts = model[:switch_on_ts]
        switch_off_ts = model[:switch_off_ts]
        
        # save is_on_ts to file
        for g in instance.scenarios[1].thermal_units
            for t in 1:iteration*stepsize
                JuMP.fix(ori_model[:is_on][g.name, t], is_on_ts[g.name, t], force=true)
                JuMP.fix(ori_model[:switch_on][g.name, t], switch_on_ts[g.name, t], force=true)
                JuMP.fix(ori_model[:switch_off][g.name, t], switch_off_ts[g.name, t], force=true)
            end

            # fixing power: TODO
        end


        milp_time = @elapsed begin
            if decom_no_cb
                ucRH.optimize!(ori_model, nStart=1, nEnd=net_tw_ori)
            else
                JuMP.optimize!(ori_model)
            end
        end

        sol_que_time = @elapsed begin
            solution_starting = ucRH.solution(ori_model)
        end
        new_obj = objective_value(ori_model)

        for g in instance.scenarios[1].thermal_units
            for t in iteration*stepsize+1:instance.time
                is_on_ts[g.name, t] = value(ori_model[:is_on][g.name, t])
                switch_on_ts[g.name, t] = value(ori_model[:switch_on][g.name, t])
                switch_off_ts[g.name, t] = value(ori_model[:switch_off][g.name, t])
            end
        end


        for g in instance.scenarios[1].thermal_units
            for t in 1:instance.time
                JuMP.fix(ori_model[:is_on][g.name, t], is_on_ts[g.name, t], force=true)
                JuMP.fix(ori_model[:switch_on][g.name, t], switch_on_ts[g.name, t], force=true)
                JuMP.fix(ori_model[:switch_off][g.name, t], switch_off_ts[g.name, t], force=true)
            end

            # fixing power: TODO
        end


        # write the model to lp
        # JuMP.write_to_file(ori_model, "$(dataset_name)_last.lp")
        println("Finished milp at last window :::  time:$(milp_time)")        
    end
    
    printstyled("Finished construction RH, Start improving\n"; color=:red)
    sol_feas1 = ucRH.validate(instance1, solution_starting)
    # constructive_obj = new_obj
    # println(sol_feas1)
    # open("res_an.txt","a") do file
    #     println(file,"$(dataset_name) start_$(nInt)_$(stepsize) $(total_time) $(constructive_obj) feasible_$(sol_feas1)")
    # end
    # return

    # ############################# Start Improving ####################################

    constructive_obj = new_obj

    tws=[
        [1,12],
        [9,20],
        [17,28],
        [25,36],
    ]
    if type_imp == 1
        tws=[
            [1,8],
            [5,12],
            [9,16],
            [13,20],
            [17,24],
            [21,28],
            [25,32],
            [29,36],
        ]
    elseif type_imp == 2
        tws=[
            [3,6],
            [7,10],
            [9,14],
            [15,18],
            [19,22],
            [23,26],
            [27,30],
            [33,36],
        ]
    elseif type_imp == 3
        tws=[]
        tw1_pos = 1
        for t in 1:max_it
            bw1 = t*nInt-3+1
            bw2 = t*nInt+3
            if bw1>net_tw_ori
                break
            end

            if bw2>net_tw_ori
                bw2 = net_tw_ori
            end
            if bw1==bw2
                break
            end
            push!(tws, [bw1, bw2])
            if bw2 == net_tw_ori
                break
            end
        end
    end

    t_f_ison = []
    t_f_switch_on = []
    t_f_switch_off = []
    for i in 1:net_tw
        push!(t_f_ison, [])
        push!(t_f_switch_on, [])
        push!(t_f_switch_off, [])
    end

    sol_q_time = 0.0
    sol_feas2 = false
    imp_objs=[]
    improve_time = @elapsed begin
        # iterate through time windows
        for tw in tws
            for t in tw[1]:tw[2]
                for g in instance1.scenarios[1].thermal_units
                    if !((g.name, t) in not_unfix_is_on) && is_fixed(ori_model[:is_on][g.name, t])
                        JuMP.unfix(ori_model[:is_on][g.name, t])
                    end
                    if !((g.name, t) in not_unfix_switch_on) && is_fixed(ori_model[:switch_on][g.name, t])
                        JuMP.unfix(ori_model[:switch_on][g.name, t])
                    end
                    if !((g.name, t) in not_unfix_switch_off) && is_fixed(ori_model[:switch_off][g.name, t])
                        JuMP.unfix(ori_model[:switch_off][g.name, t])
                    end
                end
            end
            
            if decom_no_cb
                ucRH.optimize!(ori_model, nStart=1, nEnd=net_tw_ori)
            else
                JuMP.optimize!(ori_model)
            end

            sqt = @elapsed begin
                solution_improving = ucRH.solution(ori_model)
                sol_feas2 = ucRH.validate(instance1, solution_improving)
            end
            sol_q_time = sol_q_time+sqt

            new_obj = objective_value(ori_model)
            push!(imp_objs, new_obj)
            # fix current set of times by result
            for t in tw[1]:tw[2]
                t_f_ison[t]=[]
                t_f_switch_on[t]=[]
                t_f_switch_off[t]=[]
                for g in instance.scenarios[1].thermal_units
                    push!(t_f_ison[t], [g.name, value(ori_model[:is_on][g.name, t])])
                    push!(t_f_switch_on[t], [g.name, value(ori_model[:switch_on][g.name, t])])
                    push!(t_f_switch_off[t], [g.name, value(ori_model[:switch_off][g.name, t])])
                end
            end

            for t in tw[1]:tw[2]
                for i in 1:length(t_f_ison[t])
                    JuMP.fix(ori_model[:is_on][t_f_ison[t][i][1], t], t_f_ison[t][i][2], force=true)
                    JuMP.fix(ori_model[:switch_on][t_f_switch_on[t][i][1], t], t_f_switch_on[t][i][2], force=true)
                    JuMP.fix(ori_model[:switch_off][t_f_switch_off[t][i][1], t], t_f_switch_off[t][i][2], force=true)
                end
            end
            printstyled("Finsihed update solution for TW: [$(tw[1])~$(tw[2])]\n    new obj: $(new_obj)\n"; color=:red)

        end
    end


    total_time = total_time - sol_que_time
    improve_time = improve_time - sol_q_time

    printstyled("----------RH--------------\n")
    printstyled("Total Time $(total_time+improve_time)\n"; color=:red)
    # printstyled("Total update Time $(update_time)\n"; color=:red)
    printstyled("Total start RH Time $(total_time)\n"; color=:red)
    # printstyled("Total Restore Time $(restore_time)\n"; color=:red)
    printstyled("Total improve RH Time $(improve_time)\n"; color=:red)
    printstyled("   First obj: $(constructive_obj)\n"; color=:red)
    printstyled("  Final objs:\n"; color=:red)
    final_obj = 0
    for o in imp_objs
        printstyled("             $(o)\n"; color=:red)
        final_obj = o
    end
    
    K = Threads.nthreads()
    if ~decom_no_cb
        res_file_name = "res_an_threads_$(K)_nthreads_$(nthreads).txt"
    else
        res_file_name = "res_an_no_cb_threads_$(K)_nthreads_$(nthreads).txt"
    end
    open(res_file_name,"a") do file
        println(file,"$(dataset_name) start_$(nInt)_$(stepsize) $(total_time) $(constructive_obj) feasible_$(sol_feas1)")
        println(file,"$(dataset_name) improve_$(nInt)_$(type_imp)_$(stepsize) $(improve_time) $(final_obj) feasible_$(sol_feas2)")
        println(file,"$(dataset_name) rh_$(nInt)_$(type_imp)_$(stepsize) $(improve_time+total_time) $(final_obj) feasible_$(sol_feas2)")
    end
end

main()