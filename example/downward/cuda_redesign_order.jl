using Pkg; Pkg.activate("$(@__DIR__)/../")
using CUDA, LogicCircuits, ProbabilisticCircuits, DataFrames, BenchmarkTools, DirectedAcyclicGraphs
CUDA.allowscalar(false)

pc_file = "meihua_hclt.jpc"
# pc_file = "meihua_hclt_small.jpc"
# pc_file = "rat_mnist_r10_l10_d4_p20.jpc"
# pc_file = "mnist_hclt_cat16.jpc"
@time pc = ProbabilisticCircuits.read_fast(pc_file)

# pc_file = "ad_12_16.jpc.gz"
# @time pc = read(pc_file, ProbCircuit)

# @time pc = zoo_psdd("plants.psdd")

# generate some fake data
data = Array{Union{Bool,Missing}}(replace(rand(0:2, 10000, num_variables(pc)), 2 => missing));
data[1,:] .= missing;
cu_data = to_gpu(data);

# create minibatch
batchsize = 512
batch_i = 1:batchsize;
cu_batch_i = CuVector(1:batchsize);

##################################################################################
##################################################################################

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
        parent_id::UInt32
        prime_id::UInt32
        sub_id::UInt32 # 0 means no sub
        logp::Float32
        tag::UInt8
    end

    struct MulEdge 
        parent_id::UInt32
        prime_id::UInt32
        sub_id::UInt32 # 0 means no sub
        tag::UInt8
    end

    changetag(edge::SumEdge, tag) = 
        SumEdge(edge.parent_id, edge.prime_id, edge.sub_id, edge.logp, tag)

    changetag(edge::MulEdge, tag) = 
        MulEdge(edge.parent_id, edge.prime_id, edge.sub_id, tag)

    const BitsEdge = Union{SumEdge,MulEdge}
    const EdgeLayer = Vector{BitsEdge}

    abstract type AbstractBitsProbCircuit end

    struct BitsProbCircuit <: AbstractBitsProbCircuit
        nodes::Vector{BitsNode}
        edge_layers::Vector{EdgeLayer}
    end
    
    function tag_index(i,n)
        x = zero(UInt8)
        (i==1) && (x |= one(UInt8))
        (i==n) && (x |= (one(UInt8) << 1)) 
        x
    end
    
    @inline isfirst(x) = ((x & one(x)) != zero(x))
    @inline islast(x) = ((x & one(x) << 1) != zero(x))
    @inline single_out_prime(x) = ((x & one(x) << 2) != zero(x))
    @inline single_out_sub(x) = ((x & one(x) << 3) != zero(x))
    
    struct NodeInfo
        prime_id::Int
        prime_layer_id::Int
        sub_id::Int
        sub_layer_id::Int
    end

    @inline combined_layer_id(ni::NodeInfo) = max(ni.prime_layer_id, ni.sub_layer_id)

    function BitsProbCircuit(pc; eager_materialize=true, 
                                 collapse_elements=true)
        nodes = BitsNode[]
        node_infos = NodeInfo[]
        outedges = EdgeLayer[]
        uplayers = EdgeLayer[]

        downlayers = Vector{Vector{Int}}[]

        add_node(bitsnode, layer_id) = begin
            push!(nodes, bitsnode)
            push!(outedges, EdgeLayer())
            length(nodes)
        end

        add_edge(parent_layer_id, edge, child_info) = begin
            # record up edges for upward pass
            while length(uplayers) < parent_layer_id
                push!(uplayers, EdgeLayer())
            end
            push!(uplayers[parent_layer_id], edge)

            # record out edges for downward pass
            push!(outedges[child_info.prime_id], edge)
            if child_info.sub_id != 0
                push!(outedges[child_info.sub_id], edge)
            end
        end

        f_leaf(node) = begin
            node_id = add_node(BitsLiteral(literal(node)), 0)
            NodeInfo(node_id, 0, 0, 0)
        end
        
        f_inner(node, children_info) = begin
            if (length(children_info) == 1 
                && (!eager_materialize || children_info[1].sub_id == 0))
                # this is a pass-through node
                children_info[1]
            elseif (collapse_elements && ismul(node) && length(children_info) == 2 
                    && children_info[1].sub_id == 0 && children_info[2].sub_id == 0)
                # this is a simple conjunctive element that we collapse into an edge
                prime_layer_id = children_info[1].prime_layer_id
                sub_layer_id = children_info[2].prime_layer_id
                NodeInfo(children_info[1].prime_id, prime_layer_id, 
                         children_info[2].prime_id, sub_layer_id)
            else
                layer_id = maximum(combined_layer_id, children_info) + 1
                node_id = add_node(BitsInnerNode(issum(node)), layer_id)
                if issum(node)
                    for i = 1:length(children_info)
                        logp = node.log_probs[i]
                        child_info = children_info[i]
                        tag = tag_index(i, length(children_info))
                        edge = SumEdge(node_id, child_info.prime_id, child_info.sub_id, logp, tag)
                        add_edge(layer_id, edge, child_info)
                    end
                else
                    @assert ismul(node)
                    single_infos = filter(x -> (x.sub_id == 0), children_info)
                    double_infos = filter(x -> (x.sub_id != 0), children_info)
                    for i = 1:2:length(single_infos)
                        if i < length(single_infos)
                            prime_layer_id = single_infos[i].prime_layer_id
                            sub_layer_id = single_infos[i+1].prime_layer_id
                            merged_info = NodeInfo(single_infos[i].prime_id, prime_layer_id, 
                                                   single_infos[i+1].prime_id, sub_layer_id)
                            single_infos[i] = merged_info
                        end
                        push!(double_infos, single_infos[i])
                    end
                    for i = 1:length(double_infos)
                        child_info = double_infos[i]
                        tag = tag_index(i, length(double_infos))
                        edge = MulEdge(node_id, child_info.prime_id, child_info.sub_id, tag)
                        add_edge(layer_id, edge, child_info)
                    end
                end
                NodeInfo(node_id, layer_id, 0, 0)
            end
        end

        root_info = foldup_aggregate(pc, f_leaf, f_inner, NodeInfo)

        if root_info.sub_id != 0
            # manually materialize root node
            @assert ismul(pc)
            @assert num_children(pc) == 1
            layer_id = root_info.layer_id + 1
            node_id = add_node(BitsInnerNode(false), layer_id)
            edge = MulEdge(node_id, root_info.prime_id, root_info.sub_id, tag_index(1,1))
            add_edge(layer_id, edge, root_info)
        end

        tag_single_out(uplayers, outedges)

        BitsProbCircuit(nodes, uplayers)
    end

    function tag_single_out(layers, outedges)
        for layer in layers
            for i in eachindex(layer)
                edge = layer[i]
                tag = edge.tag
                if length(outedges[edge.prime_id]) == 1
                    tag |= (one(UInt8) << 2)
                end 
                if edge.sub_id != 0 && length(outedges[edge.sub_id]) == 1
                    tag |= (one(UInt8) << 3)
                end 
                if tag != edge.tag
                    layer[i] = changetag(edge, tag)
                end
            end
        end
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

@time bpc = BitsProbCircuits.BitsProbCircuit(pc; eager_materialize=true);

@time cu_bpc = BitsProbCircuits.CuProbCircuit(bpc);

##################################################################################
##################################################################################

# allocate memory for MAR
mars = Matrix{Float32}(undef, length(batch_i), length(bpc.nodes));
cu_mars = cu(mars);

function balance_threads(num_edges, num_examples, config; mine, maxe)
    # prefer to assign threads to examples, they do not require memory synchronization
    ex_threads = min(config.threads, num_examples)
    ex_blocks = cld(num_examples, ex_threads)
    edge_threads = config.threads ÷ ex_threads
    edge_blocks_min = cld(num_edges, edge_threads * maxe)
    edge_blocks_max = cld(num_edges, edge_threads * mine)
    edge_blocks_occupy = cld(config.blocks, ex_blocks)
    edge_blocks = min(max(edge_blocks_min, edge_blocks_occupy), edge_blocks_max)
    ((edge_threads, ex_threads), (edge_blocks, ex_blocks))
end

macro xrange(x_start, x_end, length)
    return quote
        blockdim = blockDim().x
        x_work::Int32 = cld($(esc(length))::Int32, (blockdim * gridDim().x))
        $(esc(x_start))::Int32 = ((blockIdx().x - one(Int32)) * blockdim + threadIdx().x - one(Int32)) * x_work + one(Int32)
        $(esc(x_end))::Int32 = min($(esc(x_start)) + x_work - one(Int32), $(esc(length))::Int32)       
    end
end

macro yindex(y_id)
    return quote
        $(esc(y_id))::Int32 = (blockIdx().y - one(Int32)) * blockDim().y + threadIdx().y
    end
end

function init_mar!_kernel(mars, nodes, data, example_ids)
    # this kernel follows the structure of the layer eval kernel, would probably be faster to have 1 thread process multiple examples, rather than multiple nodes 
    
    num_nodes::Int32 = length(nodes)
    @xrange node_start node_end num_nodes
    num_examples::Int32 = size(mars,1)
    @yindex ex_id

    if ex_id <= num_examples
        for node_id = node_start:node_end
            node = nodes[node_id]
            mars[ex_id, node_id] = 
                if (node isa BitsProbCircuits.BitsInnerNode)
                    node.issum ? -Inf32 : zero(Float32)
                else
                    orig_ex_id::Int32 = example_ids[ex_id]
                    leaf = node::BitsProbCircuits.BitsLiteral
                    lit = leaf.literal
                    v = data[orig_ex_id, abs(lit)]
                    if ismissing(v)
                        zero(Float32)
                    elseif (lit > 0) == v
                        zero(Float32)
                    else
                        -Inf32
                    end
                end
        end
    end
    nothing
end

# @device_code_warntype @cuda init_mar!_kernel(cu_mars, cu_bpc.nodes, cu_data, cu_batch_i)

function init_mar!(mars, bpc, data, example_ids; mine, maxe, debug=false)
    @assert size(mars,1) == length(example_ids)
    kernel = @cuda name="init_mar!" launch=false init_mar!_kernel(mars, bpc.nodes, data,example_ids) 
    config = launch_configuration(kernel.fun)
    threads, blocks = balance_threads(length(bpc.nodes), length(example_ids), config; mine, maxe)
    if debug
        println("Node initialization")
        println("  config=$config, threads=$threads, blocks=$blocks, nodes/thread=$(Float32(length(bpc.nodes)/threads[1]/blocks[1]))")
        CUDA.@time kernel(mars, bpc.nodes, data,example_ids; threads, blocks)
    else
        kernel(mars, bpc.nodes, data,example_ids; threads, blocks)
    end
    nothing
end

# @time CUDA.@sync init_mar!(cu_mars, cu_bpc, cu_data, cu_batch_i; mine=2, maxe=16, debug=true);
# @btime CUDA.@sync init_mar!(cu_mars, cu_bpc, cu_data, cu_batch_i; mine=2, maxe=16);

##################################################################################
###################################################################################

function logsumexp(x::Float32,y::Float32)
    if isfinite(x) && isfinite(y)
        # note: @fastmath does not work with infinite values, so do not apply above
        @fastmath max(x,y) + log1p(exp(-abs(x-y))) 
    else
        max(x,y)
    end
end

function layer_up_kernel(mars, layer)

    num_edges = length(layer) % Int32
    @xrange edge_start edge_end num_edges
    num_examples = size(mars,1) % Int32
    @yindex ex_id

    @inbounds if ex_id <= num_examples

        local acc::Float32    
        owned_node::Bool = false
        
        for edge_id = edge_start:edge_end

            edge = layer[edge_id]

            tag = edge.tag
            isfirstedge = BitsProbCircuits.isfirst(tag)
            islastedge = BitsProbCircuits.islast(tag)
            issum = edge isa BitsProbCircuits.SumEdge
            owned_node |= isfirstedge

            # compute probability coming from child
            child_prob = mars[ex_id, edge.prime_id]
            if edge.sub_id != 0
                child_prob += mars[ex_id, edge.sub_id]
            end
            if issum
                child_prob += edge.logp
            end

            # accumulate probability from child
            if isfirstedge || (edge_id == edge_start)  
                acc = child_prob
            elseif issum
                acc = logsumexp(acc, child_prob)
            else
                acc += child_prob
            end

            # write to global memory
            if islastedge || (edge_id == edge_end)   
                pid = edge.parent_id
                if islastedge && owned_node
                    # no one else is writing to this global memory
                    mars[ex_id, pid] = acc
                else
                    if issum
                        CUDA.@atomic mars[ex_id, pid] = logsumexp(mars[ex_id, pid], acc)
                    else
                        CUDA.@atomic mars[ex_id, pid] += acc
                    end 
                end             
            end
        end
    end
    nothing
end

# @device_code_warntype @cuda layer_up_kernel(cu_mars, cu_bpc.edge_layers[1])
# @device_code_llvm debuginfo=:none @cuda layer_up_kernel(cu_mars, cu_bpc.edge_layers[1])

function layer_up(mars, bpc, layer_id; mine, maxe, debug=false)
    layer = bpc.edge_layers[layer_id]
    kernel = @cuda name="layer_up" launch=false layer_up_kernel(mars, layer) 
    config = launch_configuration(kernel.fun)
    threads, blocks = balance_threads(length(layer), size(mars,1), config; mine, maxe)
    if debug
        println("Layer $layer_id")
        println("  config=$config, threads=$threads, blocks=$blocks, edges/thread=$(Float32(length(layer)/threads[1]/blocks[1]))")
        CUDA.@time kernel(mars, layer; threads, blocks)
    else
        kernel(mars, layer; threads, blocks)
    end
    nothing
end

# @btime CUDA.@sync layer_up(cu_mars, cu_bpc, 2; mine=2, maxe=16, debug = false)

# run entire circuit
function eval_circuit(mars, bpc, data, example_ids; mine, maxe, debug=false)
    init_mar!(mars, bpc, data, example_ids; mine, maxe, debug)
    for i in 1:BitsProbCircuits.num_edge_layers(bpc)
        layer_up(mars, bpc, i; mine, maxe, debug)
    end
    nothing
end


@time CUDA.@sync eval_circuit(cu_mars, cu_bpc, cu_data, cu_batch_i; mine=2, maxe=16, debug=false)
@benchmark CUDA.@sync eval_circuit(cu_mars, cu_bpc, cu_data, cu_batch_i; mine=2, maxe=16)

##################################################################################

# sudo nv-nsight-cu-cli --mode=launch julia --project=ProbabilisticCircuits/example/
# CUDA.@profile eval_circuit!(cu_mars, cu_bpc, cu_data, cu_batch_i; mine=2, maxe=16);

##################################################################################

flows = Matrix{Float32}(undef, length(batch_i), length(bpc.nodes));
cu_flows = cu(flows);

function layer_down_kernel(flows, mars, layer)

    num_edges = length(layer) % Int32
    @xrange edge_start edge_end num_edges
    num_examples = size(mars,1) % Int32
    @yindex ex_id

    @inbounds if ex_id <= num_examples

        local parent_flow 
        local parent_mar

        for edge_id = edge_start:edge_end

            edge = layer[edge_id]
            parent_id = edge.parent_id
            prime_id = edge.prime_id
            sub_id = edge.sub_id

            issum = edge isa BitsProbCircuits.SumEdge

            tag = edge.tag
            isfirstedge = BitsProbCircuits.isfirst(tag)
            # islastedge = BitsProbCircuits.islast(fol)
            
            if isfirstedge || (edge_id == edge_start)  
                parent_flow = flows[ex_id, parent_id]
                if issum
                    parent_mar = mars[ex_id, parent_id]
                end
            end

            edge_flow = parent_flow

            if issum
                child_prob = mars[ex_id, prime_id] + edge.logp
                if edge.sub_id != 0
                    child_prob += mars[ex_id, sub_id]
                end
                edge_flow = edge_flow + child_prob - parent_mar
            end

            if BitsProbCircuits.single_out_prime(tag)
                flows[ex_id, prime_id] = edge_flow
            else
                CUDA.@atomic flows[ex_id, prime_id] = logsumexp(flows[ex_id, prime_id], edge_flow)
            end
            
            if sub_id != 0 
                if BitsProbCircuits.single_out_sub(tag)
                    flows[ex_id, sub_id] = edge_flow
                else
                    CUDA.@atomic flows[ex_id, sub_id] = logsumexp(flows[ex_id, sub_id], edge_flow)
                end
            end
        end
    end
    nothing
end

# @device_code_warntype @cuda layer_down_kernel(cu_flows, cu_mars, cu_bpc.edge_layers[1])
# @device_code_llvm debuginfo=:none @cuda layer_up_kernel(cu_mars, cu_bpc.edge_layers[1])

function layer_down(flows, mars, bpc, layer_id; mine, maxe, debug=false)
    layer = bpc.edge_layers[layer_id]
    kernel = @cuda name="layer_down" launch=false layer_down_kernel(flows, mars, layer) 
    config = launch_configuration(kernel.fun)
    threads, blocks = balance_threads(length(layer), size(mars,1), config; mine, maxe)
    if debug
        println("Layer $layer_id")
        println("  config=$config, threads=$threads, blocks=$blocks, edges/thread=$(Float32(length(layer)/threads[1]/blocks[1]))")
        CUDA.@time kernel(flows, mars, layer; threads, blocks)
    else
        kernel(flows, mars, layer; threads, blocks)
    end
    nothing
end

# @btime CUDA.@sync layer_down(cu_flows, cu_mars, cu_bpc, 2; mine=2, maxe=16, debug = false)

# run entire circuit
function flows_circuit(flows, mars, bpc; mine, maxe, debug=false)
    if debug
        println("INitializing flows")
        CUDA.@time CUDA.@sync begin 
            flows .= -Inf32
            flows[:,end] .= mars[:,end]
        end
    else
        flows .= -Inf32
        flows[:,end] .= mars[:,end]
    end
    for i in BitsProbCircuits.num_edge_layers(bpc):-1:1
        layer_down(flows, mars, bpc, i; mine, maxe, debug)
    end
    nothing
end

@time CUDA.@sync flows_circuit(cu_flows, cu_mars, cu_bpc; mine=2, maxe=16, debug=false)

@benchmark CUDA.@sync flows_circuit(cu_flows, cu_mars, cu_bpc; mine=2, maxe=16)

nothing

# function test(bpc)
#     p = 0
#     n = 0
#     for edge in reduce(vcat,bpc.edge_layers)
#         if BitsProbCircuits.single_out_prime(edge.tag) 
#             p += 1
#         else
#             n+= 1
#         end
#         if edge.sub_id != 0
#             if BitsProbCircuits.single_out_sub(edge.tag) 
#                 p += 1
#             else
#                 n+= 1
#             end
#         end
#     end
#     p,n
# end

# test(bpc)

##################################################################################
##################################################################################

# try current MAR+flow code as baseline
# batch_df = to_gpu(DataFrame(transpose(data[:, batch_i]), :auto));
# pbc = to_gpu(ParamBitCircuit(pc, batch_df));
# reuse = marginal_all(pbc, batch_df);
# reuse2 = marginal_flows_down(pbc, reuse);

# @benchmark CUDA.@sync marginal_all(pbc, batch_df, reuse)
# @benchmark CUDA.@sync marginal_flows_down(pbc, reuse, reuse2)
