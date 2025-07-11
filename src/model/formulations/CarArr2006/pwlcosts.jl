# ucRH.jl: Optimization Package for Security-Constrained Unit Commitment
# Copyright (C) 2020, UChicago Argonne, LLC. All rights reserved.
# Released under the modified BSD license. See COPYING.md for more details.

function _add_production_piecewise_linear_eqs!(
    model::JuMP.Model,
    g::ThermalUnit,
    formulation_prod_vars::Gar1962.ProdVars,
    formulation_pwl_costs::CarArr2006.PwlCosts,
    formulation_status_vars::StatusVarsFormulation,
    sc::ucRHScenario,
    nCont::Int,
    nInt::Int
)::Nothing
    eq_prod_above_def = _init(model, :eq_prod_above_def)
    eq_segprod_limit = _init(model, :eq_segprod_limit)
    segprod = model[:segprod]
    gn = g.name

    # Gar1962.ProdVars
    prod_above = model[:prod_above]

    K = length(g.cost_segments)
    for t in 1:nCont+nInt
        gn = g.name
        for k in 1:K
            # Equation (45) in Kneuven et al. (2020)
            # NB: when reading instance, ucRH.jl already calculates
            #     difference between max power for segments k and k-1 so the
            #     value of cost_segments[k].mw[t] is the max production *for
            #     that segment*
            eq_segprod_limit[sc.name, gn, t, k] = @constraint(
                model,
                segprod[sc.name, gn, t, k] <= g.cost_segments[k].mw[t]
            )

            # Also add this as an explicit upper bound on segprod to make the
            # solver's work a bit easier
            set_upper_bound(
                segprod[sc.name, gn, t, k],
                g.cost_segments[k].mw[t],
            )

            # Definition of production
            # Equation (43) in Kneuven et al. (2020)
            eq_prod_above_def[sc.name, gn, t] = @constraint(
                model,
                prod_above[sc.name, gn, t] ==
                sum(segprod[sc.name, gn, t, k] for k in 1:K)
            )

            # Objective function
            # Equation (44) in Kneuven et al. (2020)
            add_to_expression!(
                model[:obj],
                segprod[sc.name, gn, t, k],
                sc.probability * g.cost_segments[k].cost[t],
            )
        end
    end
end
