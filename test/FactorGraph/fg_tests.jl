using Test
using ProbabilisticCircuits
using LogicCircuits
using Pkg.Artifacts

fg_file(name) =
    artifact"circuit_model_zoo" * LogicCircuits.LoadSave.zoo_version * "/fgs/$name"

@testset "Load small fg and test forward pass" begin
    file = fg_file("asia.uai")
    fg = fromUAI(file)
    @test length(fg.vars) == 8
    @test legnth(fg.facs) == 8
    circuit1, var_lits, fac_lits = compile_factor_graph(fg)
    circuit2 = PlainLogicCircuit(circuit1)
    circuit3 = smooth(circuit2)
    gv = get_varprob(fg, var_lits, fac_lits)
    @test wmc_chavira(circuit3, gv) ≈ 1.0 atol = 1e-6
end
