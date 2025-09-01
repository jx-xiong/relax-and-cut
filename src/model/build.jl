# ucRH.jl: Optimization Package for Security-Constrained Unit Commitment
# Copyright (C) 2020, UChicago Argonne, LLC. All rights reserved.
# Released under the modified BSD license. See COPYING.md for more details.

using JuMP, MathOptInterface, DataStructures
import JuMP: value, fix, set_name

"""
    function build_model(;
        instance::ucRHInstance,
        optimizer = nothing,
        formulation = Formulation(),
        variable_names::Bool = false,
    )::JuMP.Model

Build the JuMP model corresponding to the given unit commitment instance.

Arguments
---------

- `instance`:
    the instance.
- `optimizer`:
    the optimizer factory that should be attached to this model (e.g. Cbc.Optimizer).
    If not provided, no optimizer will be attached.
- `formulation`:
    the MIP formulation to use. By default, uses a formulation that combines
    modeling components from different publications that provides good
    performance across a wide variety of instances. An alternative formulation
    may also be provided.
- `variable_names`: 
    if true, set variable and constraint names. Important if the model is going
    to be exported to an MPS file. For large models, this can take significant
    time, so it's disabled by default.

Examples
--------

```julia
# Read benchmark instance
instance = ucRH.read_benchmark("matpower/case118/2017-02-01")

# Construct model (using state-of-the-art defaults)
model = ucRH.build_model(
    instance = instance,
    optimizer = Cbc.Optimizer,
)

# Construct model (using customized formulation)
model = ucRH.build_model(
    instance = instance,
    optimizer = Cbc.Optimizer,
    formulation = Formulation(
        pwl_costs = KnuOstWat2018.PwlCosts(),
        ramping = MorLatRam2013.Ramping(),
        startup_costs = MorLatRam2013.StartupCosts(),
        transmission = ShiftFactorsFormulation(
            isf_cutoff = 0.005,
            lodf_cutoff = 0.001,
        ),
    ),
)
```

"""
function build_model(;
    instance::ucRHInstance,
    optimizer = nothing,
    formulation = Formulation(),
    variable_names::Bool = false,
    nCont::Int,
    nInt::Int
)::JuMP.Model
    @info "Building model..."
    time_model = @elapsed begin
        model = Model()
        model[:nsize]=nCont+nInt
        if optimizer !== nothing
            set_optimizer(model, optimizer)
        end
        model[:obj] = AffExpr()
        model[:instance] = instance

        _init(model, :currentPos0)
        _init(model, :currentPos1)

        # initialize ts for all past periods. update at each rolling step
        _init(model, :is_on_ts)
        _init(model, :switch_on_ts)
        _init(model, :switch_off_ts)
        _init(model, :startup_ts)
        _init(model, :prod_above_ts)

        _init(model, :initial_total_reserve)
        _init(model, :true_initial_status)
        _init(model, :offset)
        
        _init(model, :bus_load)
        # Actual model set up starts here
        nthermal = 0
        for g in instance.scenarios[1].thermal_units
            # DONE
            _add_unit_commitment!(model, g, formulation, nCont, nInt)
            model[:true_initial_status][g.name] = g.initial_status
            nthermal+=1
        end
        @info "Finished processing $(nthermal) thermal units"
        for sc in instance.scenarios
            @info "Building scenario $(sc.name) with " *
                  "probability $(sc.probability)"
            # DONE:: not time related
            _setup_transmission(formulation.transmission, sc)
            for l in sc.lines
                # DONE
                _add_transmission_line!(model, l, formulation.transmission, sc, nCont, nInt)
            end
            for b in sc.buses
                # DONE
                _add_bus!(model, b, sc, nCont, nInt)
            end
            for ps in sc.price_sensitive_loads
                # DONE, not involved
                println("adding price sensitive load $(ps.name)")
                _add_price_sensitive_load!(model, ps, sc, nCont, nInt)
            end
            for g in sc.thermal_units
                # DONE
                _add_unit_dispatch!(model, g, formulation, sc, nCont, nInt)
            end
            for pu in sc.profiled_units
                # DONE, not involved
                println("adding profiled unit $(pu.name)")
                _add_profiled_unit!(model, pu, sc, nCont, nInt)
            end
            for su in sc.storage_units
                # TODO::change to rh time window form, not involved
                println("adding storage unit $(su.name)")
                _add_storage_unit!(model, su, sc, nCont, nInt)
            end
            # DONE
            _add_system_wide_eqs!(model, sc, nCont, nInt)
        end
        
        # DONE
        @objective(model, Min, model[:obj])
    end
    @info @sprintf("Built model in %.2f seconds", time_model)
    if variable_names
        # TODO::change to rh time window form
        _set_names!(model)
    end
    return model
end

_is_initially_on(g::ThermalUnit)::Float64 = (g.initial_status > 0 ? 1.0 : 0.0)

function update_model(
    instance::ucRHInstance,
    model::JuMP.Model,
    offset::Int,
)
    is_on = model[:is_on]
    switch_on = model[:switch_on]
    switch_off = model[:switch_off]
    initial_on = model[:initial_on]
    initial_status = model[:initial_status]
    prod_above = model[:prod_above]
    total_reserve = model[:total_reserve]

    not_unfix_is_on = []
    not_unfix_switch_on = []
    not_unfix_switch_off = []
    model[:offset] = offset

    # fix varaible values
    for g in instance.scenarios[1].thermal_units
        if g.initial_status > 0
            fix(initial_on[g.name], 1.0; force= true)
            fix(initial_status[g.name], g.initial_status; force=true)
            fix(prod_above[instance.scenarios[1].name, g.name, 0], g.initial_power - g.min_power[offset+1]; force=true)
        else
            fix(initial_on[g.name], 0.0; force= true)
            fix(initial_status[g.name], g.initial_status; force=true)
            fix(prod_above[instance.scenarios[1].name, g.name, 0], 0.0; force=true)
        end
        
        # println("$(g.name) initial power $(g.initial_power) min power $(g.min_power[offset+1])")
    end


    ########################################### _add_unit_commitment! ##########################################
    # _add_status_vars! must run
    for g in instance.scenarios[1].thermal_units
        for t in 1:model[:nsize]
            if g.must_run[offset+t]
                # printstyled("$(g.name) must be on at time $(t)\n"; color=:red)
                fix(is_on[g.name, t], 1.0; force = true)
                fix(switch_on[g.name, t], (t == 1 ? 1.0 - _is_initially_on(g) : 0.0); force = true)
                fix(switch_off[g.name, t], 0.0; force = true)

                push!(not_unfix_is_on, (g.name, t))
                push!(not_unfix_switch_on, (g.name, t))
                push!(not_unfix_switch_off, (g.name, t))
            end
        end
    end


    # Minimum up/down-time for initial periods
    for g in instance.scenarios[1].thermal_units
        if g.initial_status > 0
            for i in 1:(g.min_uptime-g.initial_status)
                if i <= model[:nsize]
                    fix(switch_off[g.name, i], 0.0; force = true)
                    push!(not_unfix_switch_off, (g.name, i))
                end
            end
        else
            for i in 1:(g.min_downtime+g.initial_status)
                if i <= model[:nsize]
                    fix(switch_on[g.name, i], 0.0; force= true)
                    push!(not_unfix_switch_on, (g.name, i))
                end
            end
        end
    end

    # _add_startup_cost_eqs!
    initial_sum = model[:initial_sum]
    for g in instance.scenarios[1].thermal_units
        S = length(g.startup_categories)
        for t in 1:model[:nsize]
            for s in 1:S
                # If unit has not switched off in the last `delay` time periods, startup category is forbidden.
                # The last startup category is always allowed.
                if s < S
                    range_start = t - g.startup_categories[s+1].delay + 1
                    range_end = t - g.startup_categories[s].delay
                    range = (range_start:range_end)
                    range1 = (range_start+offset:range_end+offset)
                    # fix(initial_sum[g.name, t, s], (g.initial_status < 0 && (g.initial_status + 1 in range) ? 1.0 : 0.0); force= true)
                    fix(initial_sum[g.name, t, s], (model[:true_initial_status][g.name] < 0 && (model[:true_initial_status][g.name] + 1 in range1) ? 1.0 : 0.0); force= true)
                
                    for i in range
                        if i < 1
                            if i + offset >= 1
                                fix(model[:switch_off_fixed][g.name, i, s], model[:switch_off_ts][g.name, i+offset]; force= true)
                            else
                                fix(model[:switch_off_fixed][g.name, i, s], 0.0; force= true)
                            end
                        end
                    end
                end
            end
        end
    end

    # _add_startup_shutdown_limit_eqs!
    # Shutdown limit
    for g in instance.scenarios[1].thermal_units
        if g.initial_power > g.shutdown_limit
            fix(switch_off[g.name, 1], 0.0; force = true)
            push!(not_unfix_switch_off, (g.name, 1))
        end
    end



    # ramp; total_reserve
    if offset == 0
        # initial setting total reserve to 0
        for g in instance.scenarios[1].thermal_units
            fix(total_reserve[instance.scenarios[1].name, g.name, 0], 0.0; force = true)
        end
    else
        # update total reserve
        for g in instance.scenarios[1].thermal_units
            fix(total_reserve[instance.scenarios[1].name, g.name, 0], model[:initial_total_reserve][g.name]; force = true)
        end
    end

    # update load for each bus
    bus_load = model[:bus_load]
    for b in instance.scenarios[1].buses 
        for t in 1:model[:nsize]
            fix(bus_load[b.name, t], b.load[offset+t]; force = true)
        end
    end

    return not_unfix_is_on, not_unfix_switch_on, not_unfix_switch_off
end


function clean_model(
    instance::ucRHInstance,
    model::JuMP.Model,
    offset::Int,
)
    is_on = model[:is_on]
    switch_on = model[:switch_on]
    switch_off = model[:switch_off]
    initial_on = model[:initial_on]
    initial_status = model[:initial_status]
    prod_above = model[:prod_above]

    # fix varaible values
    for g in instance.scenarios[1].thermal_units
        unfix(initial_on[g.name])
        unfix(initial_status[g.name])
        unfix(prod_above[instance.scenarios[1].name, g.name, 0])
    end


    ########################################### _add_unit_commitment! ##########################################
    # _add_status_vars! must run
    for g in instance.scenarios[1].thermal_units
        for t in 1:model[:nsize]
            if is_fixed(is_on[g.name, t])
                unfix(is_on[g.name, t])
            end
            if is_fixed(switch_on[g.name, t])
                unfix(switch_on[g.name, t])
            end
            if is_fixed(switch_off[g.name, t])
                unfix(switch_off[g.name, t])
            end
        end
    end

    # _add_startup_cost_eqs!
    initial_sum = model[:initial_sum]
    for g in instance.scenarios[1].thermal_units
        S = length(g.startup_categories)
        for t in 1:model[:nsize]
            for s in 1:S-1
                if is_fixed(initial_sum[g.name, t, s])
                    unfix(initial_sum[g.name, t, s])
                end
            end
        end
    end
end

function unupdate_model(;
    instance::ucRHInstance,
    model::JuMP.Model,
    nInt,nCont,
    up_res, dn_res, p_last
)
    @info "undo updating model..."
    time_model = @elapsed begin
        # fix must on based on up_res
        is_on = model[:is_on]
        for g in instance.scenarios[1].thermal_units
            for t in 1:nInt
                if JuMP.is_fixed(is_on[g.name, t])
                    JuMP.unfix(is_on[g.name, t])
                end
            end
            for t in nInt+1:nCont+nInt
                if JuMP.is_fixed(is_on[g.name, t])
                    JuMP.unfix(is_on[g.name, t])
                    set_lower_bound(is_on[g.name,t],0.0)
                    set_upper_bound(is_on[g.name,t],1.0)
                end
            end
        end
    end
    @info @sprintf("undo updated model in %.2f seconds", time_model)
    return 
end