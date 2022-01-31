using DataFrames, ProbabilisticCircuits

include("load_mnist.jl")

# construct HCLT structure
train_gpu, test_gpu = mnist_gpu()
num_hidden_cats = 32

# train_gpu, valid_x, test_x = twenty_datasets("nltcs")
# train_gpu = to_gpu(Matrix(train_gpu))
@time circuit = hclt(train_gpu; num_cats=2, num_hidden_cats)
@time circuit = hclt(train_gpu; num_cats=2, num_hidden_cats)

uniform_parameters!(circuit; perturbation = 0.4)

write("mnist_bits_hclt_$num_hidden_cats.jpc.gz", circuit)