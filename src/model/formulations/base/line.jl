# ucRH.jl: Optimization Package for Security-Constrained Unit Commitment
# Copyright (C) 2020, UChicago Argonne, LLC. All rights reserved.
# Released under the modified BSD license. See COPYING.md for more details.
import MathOptInterface as MOI

function _add_transmission_line!(
    model::JuMP.Model,
    lm::TransmissionLine,
    f::ShiftFactorsFormulation,
    sc::ucRHScenario,
    nCont::Int,
    nInt::Int
)::Nothing
    overflow = _init(model, :overflow)
    for t in 1:nCont+nInt
        overflow[sc.name, lm.name, t] = @variable(model, lower_bound = 0, base_name = "overflow_$(lm.name)_$(t)")
        add_to_expression!(
            model[:obj],
            overflow[sc.name, lm.name, t],
            lm.flow_limit_penalty[t] * sc.probability,
        )
    end
    return
end

function _setup_transmission(
    formulation::ShiftFactorsFormulation,
    sc::ucRHScenario,
)::Nothing
    isf = formulation.precomputed_isf
    lodf = formulation.precomputed_lodf
    if length(sc.buses) == 1
        isf = zeros(0, 0)
        lodf = zeros(0, 0)
    elseif isf === nothing
        @info "Computing injection shift factors..."
        time_isf = @elapsed begin
            isf = ucRH._injection_shift_factors(
                buses = sc.buses,
                lines = sc.lines,
            )
        end
        @info @sprintf("Computed ISF in %.2f seconds", time_isf)
        @info "Computing line outage factors..."
        time_lodf = @elapsed begin
            lodf = ucRH._line_outage_factors(
                buses = sc.buses,
                lines = sc.lines,
                isf = isf,
            )
        end
        @info @sprintf("Computed LODF in %.2f seconds", time_lodf)
        @info @sprintf(
            "Applying PTDF and LODF cutoffs (%.5f, %.5f)",
            formulation.isf_cutoff,
            formulation.lodf_cutoff
        )
        # formulation.isf_cutoff = 0.005
        # formulation.lodf_cutoff = 0.001
        # isf[abs.(isf).< formulation.isf_cutoff] .= 0
        # lodf[abs.(lodf).< formulation.lodf_cutoff] .= 0
        isf[abs.(isf).< 0.005] .= 0
        lodf[abs.(lodf).< 0.001] .= 0
    end
    sc.isf = isf
    sc.lodf = lodf
    return
end
