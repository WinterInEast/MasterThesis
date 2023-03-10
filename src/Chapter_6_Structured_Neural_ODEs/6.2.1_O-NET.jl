######################################
# Step 1: construct a neural network #
######################################

using Flux
# Dense: construct a layer. For instance, Dense(2, 40, tanh) constructs a 
# 2-input and 40-output layer with the activation function tanh.
# Chain: connect layers.
# O_NET: a feedforward neural network with 2 neurons in the input layer, 
# 40 neurons in the first hidden layer, 40 neurons in the second hidden layer 
# and 2 neurons in the output layer.
O_NET = Flux.Chain(Flux.Dense(2, 20, tanh),
                    Flux.Dense(20, 10, tanh),
                    Flux.Dense(10, 2))
# ps: the initial parameters of the neural network. 
# re: a method to reconstruct the neural network with the given 
# parameters ps and input x, e.g., re(ps)(x) is the output of the 
# neural network with the given parameters ps and input x.
ps, re = Flux.destructure(O_NET)




############################
# Step 2: construct an IVP #
############################

# dz is the time derivative of z at a fixed time.
# Note: the "t" in the argument is designed for nonautonomous case. 
# This "t" is not the same concept as timesteps. 
# In the case of Hamiltonian (autonomous), this "t" will not be used.
function ODE(dz, z, θ, t)
    # In Flux.jl, re(θ)(z) is the output of O-NET with the given parameters θ and input z. 
    # In Lux.jl, this term should be rewritten as O_NET(z, θ, st).
    dz[1] = re(θ)(z)[1]
    dz[2] = re(θ)(z)[2]
end

# initial state
initial_state = [1.0, 1.0]
    
# Starting at 0.0 and ending at 19.9, the length of each step is 0.1. Thus, we have 200 time steps in total.
time_span = (0.0, 19.9)
time_step_number = 200
time_steps = range(0.0, 19.9, time_step_number)

# parameters of the neural network
θ = ps

# ODEProblem is an IVP constructor in the Julia package SciMLBase.jl
using SciMLBase
IVP = SciMLBase.ODEProblem(ODEFunction(ODE), initial_state, time_span, θ)




#########################
# Step 3: solve the IVP #
#########################

# Select a numerical method to solve the IVP
using OrdinaryDiffEq
numerical_method = ImplicitMidpoint()

# Select the adjoint method to computer the gradient of the loss with respect to the parameters. 
# ReverseDiffVJP is a callable function in the package SciMLSensitivity.jl, it uses the automatic 
# differentiation tool ReverseDiff.jl to compute the vector-Jacobian products (VJP) efficiently. 
using ReverseDiff
using SciMLSensitivity
sensitivity_analysis = InterpolatingAdjoint(autojacvec=ReverseDiffVJP(true))

# Use the ODE Solver CommonSolve.solve to yield solution. And the solution is the prediction of the state trajectories.
using CommonSolve
solution = CommonSolve.solve(IVP, numerical_method, p=θ, tstops = time_steps, sensealg=sensitivity_analysis)

# Convert the solution into a 2D-array
pred_data = Array(solution)




#####################################
# Step 4: construct a loss function #
#####################################

function ODEfunc_udho(dz, z, params, t)
    q, p = z
    m, c = params
    dz[1] = p/m
    dz[2] = -q/c
end

# mass m and spring compliance c
params = [2, 1]
# Generate data set
time_span_total = (0.0, 24.9)
time_step_number_total = 250
time_steps_total = range(0.0, 24.9, time_step_number_total)
prob = ODEProblem(ODEFunction(ODEfunc_udho), initial_state, time_span_total, params)
ode_data = Array(CommonSolve.solve(prob, ImplicitMidpoint(), tstops = time_steps_total))
# Split data set into training and test sets, 80% and 20% respectively
training_data = ode_data[:, 1:Int(time_step_number_total*0.8)]
test_data = ode_data[:, 1:Int(time_step_number_total*0.2)]



function solve_IVP(θ, batch_timesteps)
    IVP = SciMLBase.ODEProblem(ODEFunction(ODE), initial_state, (batch_timesteps[1], batch_timesteps[end]), θ)
    pred_data = Array(CommonSolve.solve(IVP, Tsit5(), p=θ, saveat = batch_timesteps, sensealg=sensitivity_analysis))
    return pred_data
end

function loss_function(θ, batch_data, batch_timesteps)
    pred_data = solve_IVP(θ, batch_timesteps)
    # "batch_data" is a batch of ode data
    loss = sum((batch_data .- pred_data) .^ 2)
    return loss, pred_data
end

callback = function(θ, loss, pred_data)
    println("loss: ", loss)
    return false
end




####################################
# Step 5: train the neural network #
####################################

# The "loss_function" returns a tuple, where the first element of the tuple is the loss
loss = loss_function(θ, training_data, time_steps)[1]

# The dataloader generates a batch of data according to the given batchsize from the "training_data".
begin
    using Flux: DataLoader
    time_steps_1 = range(0.0, 4.9, 50)
    time_steps_2 = range(0.0, 9.9, 100)
    time_steps_3 = range(0.0, 19.9, 200)
    dataloader1 = DataLoader((training_data[:,1:50], time_steps_1), batchsize = 50)
    dataloader2 = DataLoader((training_data[:,1:100], time_steps_2), batchsize = 100)
    dataloader3 = DataLoader((training_data[:,1:200], time_steps_3), batchsize = 200)
end

begin
    include("helpers/train_helper.jl")
    using Main.TrainInterface: FluxTrain, OptFunction
    using Optimization
    optf = OptFunction(loss_function)
end

# Adjust the learning rate and repeat training by using a increasing time span strategy to escape from local minima
# Please refer to https://docs.juliahub.com/DiffEqSensitivity/02xYn/6.78.2/training_tips/local_minima/
# Adjust the learning rate and repeat training
begin
    α = 0.002
    epochs = 100
    println("Training 1")
    θ = FluxTrain(optf, θ, α, epochs, dataloader1, callback)
end
  
begin
    α = 0.002
    epochs = 200
    println("Training 2")
    θ = FluxTrain(optf, θ, α, epochs, dataloader2, callback)
end

begin
    α = 0.001
    epochs = 200
    println("Training 3")
    θ = FluxTrain(optf, θ, α, epochs, dataloader3, callback)
end

# Save the parameters
begin
    using JLD2
    path = joinpath(@__DIR__, "parameters", "params_O_NET.jld2")
    JLD2.save(path, "params_O_NET", θ)
end

# Save the model
begin
    using JLD2
    path = joinpath(@__DIR__, "models", "O_NET.jld2")
    JLD2.save(path, "O_NET", O_NET, "re", re)
end




##########################
# Step 6: test the model #
##########################

# Load the parameters
begin
    using JLD2, Flux
    path = joinpath(@__DIR__, "parameters", "params_O_NET.jld2")
    θ = JLD2.load(path, "params_O_NET")
end

# Load the model
begin
    using JLD2, Flux
    path = joinpath(@__DIR__, "models", "O_NET.jld2")
    O_NET = JLD2.load(path, "O_NET")
    re = JLD2.load(path, "re")
end

# "re" is a method to reconstruct the neural network.
re(θ)(initial_state)

# Plot phase portrait
IVP_test = SciMLBase.ODEProblem(ODEFunction(ODE), initial_state, time_span_total, θ)
predict_data = CommonSolve.solve(IVP_test, numerical_method, p=θ, tstops = time_steps_total, sensealg=sensitivity_analysis)
using Plots
plot(ode_data[1,:], ode_data[2,:], lw=3, xlabel="q", ylabel="p", label="Ground truth", linestyle=:solid)
plot!(predict_data[1,:], predict_data[2,:], lw=3, label="O-NET", linestyle=:dash)

