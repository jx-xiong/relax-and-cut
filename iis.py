import gurobipy as gp

instance_name = "case2746wop"
m = gp.read(f"infeasible_{instance_name}.mps")
m.computeIIS()
m.write(f"infeasible_{instance_name}.ilp")