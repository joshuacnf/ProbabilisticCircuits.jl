using Pkg; Pkg.activate(@__DIR__)
using CUDA, LogicCircuits, ProbabilisticCircuits, DataFrames, BenchmarkTools
CUDA.allowscalar(false)

# pc_file = "meihua_hclt.jpc"
# pc_file = "meihua_hclt_small.jpc"
# pc_file = "rat_mnist_r10_l10_d4_p20.jpc"
pc_file = "mnist_hclt_cat16.jpc"

pc = read(pc_file, ProbCircuit)
num_nodes(pc), num_edges(pc)

# generate some fake data
# TODO; figure out row vs col major
data = Array{Union{Bool,Missing}}(replace(rand(0:2, num_variables(pc), 10000), 2 => missing));
data[:,1] .= missing;
cu_data = to_gpu(data);

# create minibatch
batch_i = 1:512;
cu_batch_i = CuVector(batch_i);
batch_df_cpu = DataFrame(transpose(data[:, batch_i]), :auto);
batch_df = to_gpu(batch_df_cpu);


# try current MAR code
pbc_cpu = ParamBitCircuit(pc, batch_df);
pbc = to_gpu(pbc_cpu);
CUDA.@time reuse = marginal_all(pbc, batch_df);
CUDA.@time marginal_all(pbc, batch_df, reuse);

# custom bits circuit

module BitsProbCircuits
        
    using DirectedAcyclicGraphs, ProbabilisticCircuits, CUDA

    struct BitsLiteral
        literal::Int
    end

    struct BitsInnerNode
        issum::Bool
    end
    const BitsNode = Union{BitsLiteral, BitsInnerNode}

    struct SumEdge 
        parent_id::Int
        child_id::Int
        logprob::Float32
    end

    struct MulEdge 
        parent_id::Int
        child_id::Int
    end

    const BitsEdge = Union{SumEdge,MulEdge}
    const EdgeLayer = Vector{BitsEdge}

    abstract type AbstractBitsProbCircuit end

    struct BitsProbCircuit <: AbstractBitsProbCircuit
        nodes::Vector{BitsNode}
        edge_layers::Vector{EdgeLayer}
        BitsProbCircuit(num_nodes:: Int, num_layers::Int) = new(
            Vector{BitsNode}(undef, num_nodes),
            EdgeLayer[EdgeLayer() for i = 1:num_layers-1]
        )
    end

    function BitsProbCircuit(pc)
        node2label = label_nodes(pc)
        node2layer, num_layers = feedforward_layers(pc)
        bpc = BitsProbCircuit(num_nodes(pc), num_layers)
        foreach(pc) do node 
            pid = node2label[node]
            if isleaf(node)
                bnode = BitsLiteral(literal(node))
            else
                if issum(node)
                    bnode = BitsInnerNode(true)
                    for (c, logp) in zip(children(node), node.log_probs)
                       layer = bpc.edge_layers[node2layer[c]]
                       edge = SumEdge(pid, node2label[c], logp)
                       push!(layer, edge) 
                    end
                else
                    @assert ismul(node)
                    bnode = BitsInnerNode(false)
                    for c in children(node)
                       layer = bpc.edge_layers[node2layer[c]]
                       edge = MulEdge(pid, node2label[c])
                       push!(layer, edge) 
                    end
                end
            end
            bpc.nodes[pid] = bnode
        end
        bpc, node2label
    end

    num_edge_layers(bpc::AbstractBitsProbCircuit) = 
        length(bpc.edge_layers)


    const CuEdgeLayer = CuVector{BitsEdge}

    struct CuProbCircuit <: AbstractBitsProbCircuit
        nodes::CuVector{BitsNode}
        edge_layers::Vector{CuEdgeLayer}
        CuProbCircuit(bpc::BitsProbCircuit) = begin
            nodes = cu(bpc.nodes)
            edge_layers = map(cu, bpc.edge_layers)
            new(nodes, edge_layers)
        end
    end

end

@time bpc, node2label = BitsProbCircuits.BitsProbCircuit(pc);
@time cu_bpc = BitsProbCircuits.CuProbCircuit(bpc);

for i = 1:BitsProbCircuits.num_edge_layers(bpc)
    println("Layer $i/$(BitsProbCircuits.num_edge_layers(bpc)): $(length(bpc.edge_layers[i])) edges")
end

# allocate memory for MAR
mars = Matrix{Float32}(undef, num_nodes(pc), length(batch_i));
cu_mars = cu(mars);

# custom MAR initialization kernels
init_mar(node::BitsProbCircuits.BitsInnerNode, data, example_id) = 
    node.issum ? -Inf32 : zero(Float32)

function init_mar(leaf::BitsProbCircuits.BitsLiteral, data, example_id)
    lit = leaf.literal
    v = data[abs(lit), example_id]
    if ismissing(v)
        zero(Float32)
    elseif (lit > 0) == v
        zero(Float32)
    else
        -Inf32
    end
end

function init_mar!(mars, bpc, data, example_ids)
    broadcast!(mars, bpc.nodes, transpose(example_ids)) do node, example_id
        init_mar(node, data, example_id)
    end
end

# initialize node marginals
@time init_mar!(mars, bpc, data, batch_i);
CUDA.@time init_mar!(cu_mars, cu_bpc, cu_data, cu_batch_i);

function logsumexp(x::Float32,y::Float32)::Float32
    if x == -Inf32
        y
    elseif y == -Inf32
        x
    elseif x > y
        x + log1p(exp(y-x))
    else
        y + log1p(exp(x-y))
    end 
end

function logincexp(matrix::CuDeviceArray, i, j, v)
    CUDA.@atomic matrix[i,j] = logsumexp(matrix[i,j], v)
    nothing
end

function logincexp(matrix::Array, i, j, v)
    # should also be atomic for CPU multiprocessing?
    matrix[i,j] = logsumexp(matrix[i,j], v)
    nothing
end

function logmulexp(matrix::CuDeviceArray, i, j, v)
    CUDA.@atomic matrix[i,j] += v
    nothing
end

function logmulexp(matrix::Array, i, j, v)
    # should also be atomic for CPU multiprocessing?
    matrix[i,j] += v
    nothing
end

function eval_edge!(mars, edge::BitsProbCircuits.SumEdge, example_id)
    child_prob = mars[edge.child_id, example_id]
    edge_prob = child_prob + edge.logprob
    logincexp(mars, edge.parent_id, example_id, edge_prob)
    nothing
end

function eval_edge!(mars, edge::BitsProbCircuits.MulEdge, example_id)
    child_prob = mars[edge.child_id, example_id]
    logmulexp(mars, edge.parent_id, example_id, child_prob)
    nothing
end

function eval_layer!(mars::Array, bpc, layer_id)
    for edge in bpc.edge_layers[layer_id]
        for example_id in 1:size(mars,2)
            eval_edge!(mars, edge, example_id)
        end
    end
    nothing
end

function eval_layer!_kernel(mars, layer)
    index_x = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    index_y = (blockIdx().y - 1) * blockDim().y + threadIdx().y
    stride_x = blockDim().x * gridDim().x
    stride_y = blockDim().y * gridDim().y
    for example_id = index_x:stride_x:size(mars,2)
        for edge_id = index_y:stride_y:length(layer)
            eval_edge!(mars, layer[edge_id], example_id)
        end
    end
    nothing
end

function eval_layer!(mars, bpc, layer_id)
    layer = bpc.edge_layers[layer_id]
    kernel = @cuda name="eval_layer!" launch=false eval_layer!_kernel(mars, layer) 
    config = launch_configuration(kernel.fun)
    # @show config
    threads, blocks = LogicCircuits.balance_threads_2d(size(mars,2), length(layer), config.threads)
    # @show threads, blocks
    kernel(mars, layer; threads, blocks)
    nothing
end

# run 1 layer
@time eval_layer!(mars, bpc, 1);
CUDA.@time eval_layer!(cu_mars, cu_bpc, 1);

# run entire circuit
function eval_circuit!(mars, bpc, data, example_ids)
    init_mar!(mars, bpc, data, example_ids)
    for i in 1:BitsProbCircuits.num_edge_layers(bpc)
        eval_layer!(mars, bpc, i)
    end
    nothing
end

CUDA.@time eval_circuit!(mars, bpc, data, batch_i);
CUDA.@time eval_circuit!(cu_mars, cu_bpc, cu_data, cu_batch_i);

@btime marginal_all(pbc_cpu, batch_df_cpu); # old cpu code
@btime eval_circuit!(mars, bpc, data, batch_i); # new CPU code

@btime CUDA.@sync marginal_all(pbc, batch_df, reuse); # old GPU code
@btime CUDA.@sync eval_circuit!(cu_mars, cu_bpc, cu_data, cu_batch_i); # new GPU code

nothing