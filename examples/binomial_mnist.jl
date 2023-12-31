using CUDA
using ProbabilisticCircuits
using ProbabilisticCircuits: BitsProbCircuit, CuBitsProbCircuit, loglikelihoods, full_batch_em, mini_batch_em
using MLDatasets
using Images
using Plots

# device!(collect(devices())[2])

function mnist_cpu()
    train_cpu = collect(transpose(reshape(MNIST.traintensor(UInt8), 28*28, :)))
    test_cpu = collect(transpose(reshape(MNIST.testtensor(UInt8), 28*28, :)))
    train_cpu, test_cpu
end

function mnist_gpu()
    cu.(mnist_cpu())
end

function truncate(data::Matrix; bits)
    data .÷ 2^bits
end

function run(; batch_size = 512, num_epochs1 = 1, num_epochs2 = 1, num_epochs3 = 20, 
             pseudocount = 0.01, latents = 32, param_inertia1 = 0.2, param_inertia2 = 0.9, param_inertia3 = 0.95)
    train, test = mnist_cpu()
    train_gpu, test_gpu = mnist_gpu()
    # train_gpu = train_gpu[1:1024, :]
    
    trunc_train = cu(truncate(train; bits = 4))

    println("Generating HCLT structure with $latents latents... ");
    @time pc = hclt(trunc_train[1:5000,:], latents; num_cats = 256, pseudocount = 0.1, input_type = Binomial);
    init_parameters(pc; perturbation = 0.4);
    println("Number of free parameters: $(num_parameters(pc))")

    @info "Moving circuit to GPU... "
    CUDA.@time bpc = CuBitsProbCircuit(pc)

    @show length(bpc.nodes)

    softness    = 0
    @time mini_batch_em(bpc, train_gpu, num_epochs1; batch_size, pseudocount, 
    			 softness, param_inertia = param_inertia1, param_inertia_end = param_inertia2, debug = false)

    ll1 = loglikelihood(bpc, test_gpu; batch_size)
    println("test LL: $(ll1)")
    			 
    @time mini_batch_em(bpc, train_gpu, num_epochs2; batch_size, pseudocount, 
    			 softness, param_inertia = param_inertia2, param_inertia_end = param_inertia3)

    ll2 = loglikelihood(bpc, test_gpu; batch_size)
    println("test LL: $(ll2)")
    
    for iter=1:num_epochs3
        @info "Iter $iter"
        @time full_batch_em(bpc, train_gpu, 5; batch_size, pseudocount, softness)

        ll3 = loglikelihood(bpc, test_gpu; batch_size)
        println("test LL: $(ll3)")

        @time do_sample(bpc, iter)
    end

    @info "update parameters bpc => pc"
    @time ProbabilisticCircuits.update_parameters(bpc);
    
    pc, bpc
end

function do_sample(cur_pc, iteration)
    @info "Sample"
    if cur_pc isa CuBitsProbCircuit
        sms = sample(cur_pc, 100, 28*28,[UInt32]);
    elseif cur_pc isa ProbCircuit
        sms = sample(cur_pc, 100, [UInt32]);
    end

    do_img(i) = begin
        img = Array{Float32}(sms[i,1,1:28*28]) ./ 256.0
        img = transpose(reshape(img, (28, 28)))
        imresize(colorview(Gray, img), ratio=4)
    end

    arr = [do_img(i) for i=1:size(sms, 1)]
    imgs = mosaicview(arr, fillvalue=1, ncol=10, npad=4)
    save("samples/samples_hclt_$iteration.png", imgs);
end

function try_map()
    @info "MAP"
    train_gpu, _ = mnist_gpu();
    data = Array{Union{Missing, UInt32}}(train_gpu[1:10, :]);
    data[:, 1:100] .= missing;
    data_gpu = cu(data);

    # @time MAP(pc, data; batch_size=10)
    @time MAP(bpc, data_gpu; batch_size=10)
end


pc, bpc = run(; latents = 16, num_epochs1 = 0, num_epochs2 = 0, num_epochs3=2);

# arr = [dist(n).p for n in inputnodes(pc) if 300 <first(randvars(n)) <400];
# Plots.histogram(arr, normed=true, bins=50)

# do_sample(bpc, 999);
# do_sample(pc, 999);

try_map()



