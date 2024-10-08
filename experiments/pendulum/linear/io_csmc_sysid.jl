using InsideOutNPF

using Random
using Distributions
using LinearAlgebra
using Statistics
using StatsBase

import Zygote
import Flux
import Bijectors

include("./environment.jl")

using .PendulumEnvironment: init_state
using .PendulumEnvironment: ibis_dynamics
using .PendulumEnvironment: param_prior
using .PendulumEnvironment: param_proposal
using .PendulumEnvironment: ctl_shift, ctl_scale
using .PendulumEnvironment: ctl_feature_fn

# using JLD2


Random.seed!(1)

_param_prior = MvNormal(
    param_prior.mean,
    param_prior.covar
)

input_dim = 2
output_dim = 1
recur_size = 64
dense_size = 256

ctl_encoder_fn = Flux.f64(
    Flux.Chain(
        Flux.Dense(input_dim, dense_size, Flux.relu),
        Flux.Dense(dense_size, dense_size, Flux.relu),
        Flux.Dense(dense_size, recur_size),
        # Flux.LSTM(recur_size, recur_size),
        # Flux.LSTM(recur_size, recur_size),
        Flux.GRU(recur_size, recur_size),
        Flux.GRU(recur_size, recur_size),
    ),
)

ctl_mean_fn = Flux.f64(
    Flux.Chain(
        Flux.Dense(recur_size, dense_size, Flux.relu),
        Flux.Dense(dense_size, dense_size, Flux.relu),
        Flux.Dense(dense_size, output_dim),
    ),
)

ctl_log_std = @. log(sqrt([1.0]))

ctl_bijector = (
    Bijectors.Shift(ctl_shift)
    ∘ Bijectors.Scale(ctl_scale)
    ∘ Tanh()
)

learner_policy = StatefulHomoschedasticPolicy(
    ctl_feature_fn,
    ctl_encoder_fn,
    ctl_mean_fn,
    ctl_log_std,
    ctl_bijector,
)

evaluator_policy = StatefulHomoschedasticPolicy(
    ctl_feature_fn,
    ctl_encoder_fn,
    ctl_mean_fn,
    [-20.0],
    ctl_bijector,
)

learner_loop = IBISClosedLoop(
    ibis_dynamics, learner_policy
)

evaluator_loop = IBISClosedLoop(
    ibis_dynamics, evaluator_policy
)

action_penalty = 0.0
slew_rate_penalty = 0.1
tempering = 1.0

nb_steps = 25
nb_trajectories = 128
nb_particles = 64

nb_ibis_moves = 3
nb_csmc_moves = 1

nb_iter = 25
opt_state = Flux.setup(Flux.Optimise.Adam(1e-3), learner_loop)
batch_size = 16

Flux.reset!(learner_loop.ctl)
state_struct, param_struct = smc_with_ibis_marginal_dynamics(
    nb_steps,
    nb_trajectories,
    nb_particles,
    init_state,
    learner_loop,
    _param_prior,
    param_proposal,
    nb_ibis_moves,
    action_penalty,
    slew_rate_penalty,
    tempering,
)
idx = rand(Categorical(state_struct.weights[:, end]))
reference = IBISReference(
    state_struct.trajectories[:, :, idx],
    param_struct.particles[:, :, :, idx],
    param_struct.weights[:, :, idx],
    param_struct.log_weights[:, :, idx],
    param_struct.log_likelihoods[:, :, idx]
)

backward_sample = true

learner_loop, _ = markovian_score_climbing_with_ibis_marginal_dynamics(
    nb_iter,
    opt_state,
    batch_size,
    nb_steps,
    nb_trajectories,
    nb_particles,
    init_state,
    learner_loop,
    evaluator_loop,
    _param_prior,
    action_penalty,
    slew_rate_penalty,
    tempering,
    reference,
    nb_csmc_moves,
    backward_sample,
    param_proposal,
    nb_ibis_moves,
    true
)

# jldsave("./experiments/pendulum/linear/data/linear_pendulum_ibis_csmc_ctl.jld2"; evaluator_loop.ctl)