
"""
    MAP(bpc::CuBitsProbCircuit, data::CuArray; batch_size, mars_mem=nothing)

Retruns the MAP states for a given circuit and data on gpu. Missing values should be denoted as `missing`.

Note that the MAP states are exact only when the circuit is both decomposable and deterministic, otherwise its just an approximation.

- `bpc`: BitCircuit on gpu
- `data`: CuArray{Union{Missing, data_types...}}
- `batch_size`
- `mars_mem`: Not required, advanced usage. CuMatrix to reuse memory and reduce allocations. See `prep_memory` and `cleanup_memory`.
"""
function MAP(bpc::CuBitsProbCircuit, data::CuArray;
    batch_size, mars_mem=nothing,
    mine=2,maxe=32, debug=false)

    num_examples = size(data, 1)
    num_nodes = length(bpc.nodes)
    marginals = prep_memory(mars_mem, (batch_size, num_nodes), (false, true))
 
    init_input_heap!(bpc; debug)
    
    # (TODO) Kernel does not compile if there is no Missing in eltype(states)
    states = CuArray{Union{Missing, eltype(data)}}(undef, size(data)...)
    CUDA.copy!(states, data)
    
    for batch_start = 1:batch_size:num_examples
        batch_end = min(batch_start+batch_size-1, num_examples)
        batch = batch_start:batch_end
        num_batch_examples = length(batch)
        
        eval_circuit_max!(marginals, bpc, data, batch; mine, maxe, debug = false)
        map_downward!(marginals, bpc, states, batch; debug)
    end
    cleanup_memory(marginals, mars_mem)
    return states
end

function init_input_heap!(bpc::CuBitsProbCircuit; debug = false)
    num_nodes = length(bpc.nodes)
    num_input_nodes = length(bpc.input_node_ids)

    args = (bpc.nodes, bpc.input_node_ids, bpc.heap)
    kernel = @cuda name="init_input_heap!" launch=false init_input_heap_kernel!(args...)
    threads = launch_configuration(kernel.fun).threads
    blocks = cld(num_input_nodes, threads)
    if debug
        println("Init input MAP State and MAP-LLs on heap")
        @show threads blocks num_input_nodes
        CUDA.@time kernel(args...; threads, blocks)
    else
        kernel(args...; threads, blocks)
    end
end

function init_input_heap_kernel!(nodes, input_node_ids, heap)
    node_id = ((blockIdx().x - one(Int32)) * blockDim().x) + threadIdx().x 
    if node_id <= length(input_node_ids)
        orig_node_id::UInt32 = input_node_ids[node_id]
        inputnode = nodes[orig_node_id]::BitsInput
        init_heap_map_state!(dist(inputnode), heap)
        init_heap_map_loglikelihood!(dist(inputnode), heap)
    end
    nothing
end


struct CuStack
    # parallel stacks for each example (max stack size is features + 3 which is preallocated)
    mem::CuMatrix{Int32} 

    # Index of Top of each stack for each example
    tops::CuArray{UInt32}

    CuStack(examples, features) = begin
        new(CUDA.zeros(Int32, examples, features + 3), 
            CUDA.zeros(UInt32, examples))
    end
end

function pop_cuda!(stack_mem, stack_tops, i)
    # Empty Stack
    if stack_tops[i] == zero(UInt32)
        return zero(UInt32) 
    else
        val = stack_mem[i, stack_tops[i]]
        CUDA.@atomic stack_tops[i] -= one(eltype(stack_tops))
        return val
    end
end

function push_cuda!(stack_mem, stack_tops, val, i)
    stack_tops[i] += one(eltype(stack_tops))
    CUDA.@cuassert stack_tops[i] <= size(stack_mem, 2) "CUDA stack overflow"
    stack_mem[i, stack_tops[i]] = val
    return nothing
end


function map_downward!(marginals::CuMatrix, bpc::CuBitsProbCircuit, states, batch; debug=false)
    num_examples = length(batch)
    num_nodes = length(bpc.nodes)

    stack = CuStack(num_examples, size(states, 2))  
    # Push root node to all stacks
    stack.tops .= 1
    stack.mem[:, 1] .= num_nodes
    CUDA.@sync begin
        dummy_args = (marginals, states, stack.mem, stack.tops, 
                        bpc.nodes, bpc.node_begin_end, bpc.edge_layers_up.vectors, 
                        bpc.heap, batch)

        kernel = @cuda name="map_downward!" launch=false map_downward_kernel!(dummy_args...)
        config = launch_configuration(kernel.fun)    
        threads = config.threads
        blocks = cld(size(states,1), threads)
        args = (marginals, states, stack.mem, stack.tops, 
                bpc.nodes, bpc.node_begin_end, bpc.edge_layers_up.vectors, 
                bpc.heap, batch)

        if debug
            println("map_downward!...")
            @show threads, blocks, num_examples, num_nodes
            CUDA.@time kernel(args... ; threads, blocks)
        else
            kernel(args... ; threads, blocks)
        end        
    end
    nothing
end

function map_downward_kernel!(marginals, states, stack_mem, stack_tops, nodes, node_begin_end, edges, heap, batch)
    index_x = ((blockIdx().x - one(Int32)) * blockDim().x) + threadIdx().x
    stride_x = blockDim().x * gridDim().x
    for ex_id = index_x:stride_x:size(batch, 1)
        cur_node_id = pop_cuda!(stack_mem, stack_tops, ex_id)
        while cur_node_id > zero(eltype(stack_mem))
            cur_node = nodes[cur_node_id]
            if cur_node isa BitsInput
                example_id = batch[ex_id]
                if ismissing(states[example_id, cur_node.variable])
                    map_value = map_state(dist(cur_node), heap)
                    states[example_id, cur_node.variable] = map_value
                end
            elseif cur_node isa BitsSum
                max_pr = typemin(Float32)
                chosen_edge = 1
                for edge_ind = node_begin_end[cur_node_id].first: node_begin_end[cur_node_id].second
                    edge = edges[edge_ind]
                    # compute max-probability coming from child
                    child_prob = marginals[ex_id, edge.prime_id]
                    if edge.sub_id != zero(UInt32)
                        child_prob += marginals[ex_id, edge.sub_id]
                    end
                    if edge isa SumEdge
                        child_prob += edge.logp
                    end
                    
                    if child_prob > max_pr
                        max_pr = child_prob
                        chosen_edge = edge_ind
                    end
                end
                # # Push the chosen edge into stack 
                cur_edge = edges[chosen_edge]
                push_cuda!(stack_mem, stack_tops, cur_edge.prime_id, ex_id)
                if cur_edge.sub_id != zero(UInt32)
                    push_cuda!(stack_mem, stack_tops, cur_edge.sub_id, ex_id)
                end
            elseif cur_node isa BitsMul
                for edge_ind = node_begin_end[cur_node_id].first: node_begin_end[cur_node_id].second
                    edge = edges[edge_ind]
                    push_cuda!(stack_mem, stack_tops, edge.prime_id, ex_id)
                    if edge.sub_id != zero(UInt32)
                        push_cuda!(stack_mem, stack_tops, edge.sub_id, ex_id)
                    end
                end
            end
            # Pop the next Node (zero if empty)
            cur_node_id = pop_cuda!(stack_mem, stack_tops, ex_id)
        end
    end
    return nothing
end


# run entire circuit taking mode on inputs and max on sum nodes
function eval_circuit_max!(mars, bpc, data, example_ids; mine, maxe, debug=false)
    input_init_func(dist, heap) = 
        map_loglikelihood(dist, heap) 
    
    sum_agg_func(x::Float32, y::Float32) =
        max(x, y)

    init_mar!(mars, bpc, data, example_ids; mine, maxe, input_init_func, debug)
    layer_start = 1
    for layer_end in bpc.edge_layers_up.ends
        layer_up(mars, bpc, layer_start, layer_end, length(example_ids); mine, maxe, sum_agg_func, debug)
        layer_start = layer_end + 1
    end
    nothing
end
