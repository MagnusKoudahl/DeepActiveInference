
using OpenAIGym
import AutoGrad
import Random
using Statistics
using Flux

const STATE_SIZE = 8
const ACTION_SIZE =4

mutable struct History
    nS::Int
    nA::Int
    γ::Float64
    states::Vector{Float64}
    actions::Vector{Int}
    rewards::Vector{Float64}
end
History(nS, nA, γ) = History(nS, nA, γ, zeros(0),zeros(Int, 0),zeros(0))


function discount(rewards, γ)
    R = similar(rewards)
    R[end] = rewards[end]
    for k = length(rewards)-1:-1:1
        R[k] = γ * R[k+1] + rewards[k]
    end
    # return R
    return (R .- mean(R)) ./ (std(R) + 1e-10) #speeds up training a lot
 
end

basenet = Dense(STATE_SIZE,128)



function predict(s, policynet,valuenet)
    #println(size(s))
    #baseout = basenet(s)
    v = valuenet(s)
    p = policynet(s)
    return p, v
end
function sample_action(probs)
    @assert size(probs, 2) == 1
    cprobs = cumsum(probs, dims=1)
    sampled = cprobs .> rand()
    return mapslices(argmax, sampled, dims=1)[1] 
end


function replay()
  batch_size = min(BATCH_SIZE, length(memory))
  minibatch = sample(memory, batch_size, replace = false)

  x = Matrix{Float32}(STATE_SIZE, batch_size)
  y = Matrix{Float32}(ACTION_SIZE, batch_size)
  for (iter, (state, action, reward, next_state, done)) in enumerate(minibatch)
    target = reward
    if !done
      target += γ * maximum(valuenet(next_state |> gpu).data)
    end

    target_f = model(state |> gpu).data
    target_f[action] = target

    x[:, iter] .= state
    y[:, iter] .= target_f
  end
  x = x |> gpu
  y = y |> gpu

  Flux.train!(value_loss, [(x, y)], opt)

end

function policy_loss(p,lp,A)
    l = -mean(lp .* A.data)
    #regloss =  L2Reg(A)
    entloss = 0.1f0 * mean(softmax(p) .* logsoftmax(p))
    #println("loss: $l, entloss: $entloss")
    return l# + entloss
end

function loss(history,opt_p, opt_v, policynet, valuenet)
    #println("$(typeof(history)), $history")
    nS, nA = history.nS, history.nA
    M = length(history.states)÷nS
    states = reshape(history.states, nS, M)
    R = discount(history.rewards, history.γ)

    #p, V = predict(w, states)
    p,V = predict(states, policynet, valuenet)
    #println("p: $(typeof(p)), $(size(p))")
    #println("V: $(typeof(V)), $(size(V))")
    V = vec(V) 
    #println("V: $(typeof(V)), $(size(V))")
    A = R .- V
    #println("A: $(typeof(A)), $(size(A))")
    inds = history.actions + nA*(0:M-1)
    lp = logsoftmax(p)[inds]

    l = -mean(lp .* A.data)
    #regloss =  L2Reg(A)
    #entloss = 0.1f0 * mean(softmax(p) .* logsoftmax(p))
    #println("loss: $l, entloss: $entloss")
    #return l #+ entloss
    Flux.train!(policy_loss, Flux.params(policynet), [[p,lp,A]], opt_p)
    Flux.train!(L2Reg, Flux.params(valuenet), [[A]],opt_v)
    return policy_loss(p,lp,A), L2Reg(A)
end

L2Reg(x) = mean(x .* x)
using PyCall
using Plots, Images, ImageView
np = pyimport("numpy")
function main(
    hidden = [100], # width inner layers
    lr = 1e-2,
    γ = 0.99, #discount rate
    episodes = 15000,
    render = true,
    infotime = 50)
    env = GymEnv("LunarLander-v2")
    seed = -1
    seed > 0 && (Random.seed!(seed); seed!(env, seed))
    opt_p=ADAM(0.005)
    opt_v = ADAM(0.005)
    nS, nA = STATE_SIZE, ACTION_SIZE
    #opt = [Adam(lr=lr) for _=1:length(w)]
    avgreward = 0
    ep_rewards = []
    plosses = []
    vlosses = []
    num_anim = 0
    pyenv = env.pyenv
    valuenet = Chain(Dense(STATE_SIZE, 100,Flux.relu), Dense(100,1))
    policynet = Chain(Dense(STATE_SIZE, 100, Flux.relu), Dense(100,ACTION_SIZE))
    for episode=1:episodes
        state = reset!(env)
        episode_rewards = 0
        history = History(nS, nA, γ)
        for t=1:500
            #println("in inner loop!")
            p, V = predict(state, policynet, valuenet)
            p = softmax(p)
            #println("$(typeof(p)), $(size(p))")
            action = sample_action(p.data)

            reward, next_state = step!(env, action-1)
            done = env.done
            append!(history.states, state)
            push!(history.actions, action)
            push!(history.rewards, reward)
            state = next_state
            episode_rewards += reward

            #episode % infotime == 0 && render && Gym.render(env)
            done && break # this breaks it after every episode!
        end
        if avgreward > 100 && num_anim < 20
            state = reset!(env)
            frames = []
            for t=1:10000
                #println("in inner loop!")
                #p, V = predict(state)
                p = policynet(state)
                p = softmax(p)
                #println("$(typeof(p)), $(size(p))")
                #println("action probs: $(p.data)")
                action = sample_action(p.data)

                reward, next_state = step!(env, action-1)
                append!(history.states, state)
                push!(history.actions, action)
                push!(history.rewards, reward)
                done = env.done
                #remember(state, action, reward, next_state, done)
                state = next_state
                episode_rewards += reward
                f = np.array(pyenv.render(mode="rgb_array")) ./255f0
                push!(frames, deepcopy(f))
                #episode % infotime == 0 && render && Gym.render(env)
                done && break # this breaks it after every episode!
            end
            anim = @animate for bib in frames
                Plots.plot(colorview(RGB, permutedims(bib, [3,1,2])), xticks=[],yticks=[])
            end
            gif(anim, "lunar_lander_PG_anim_$num_anim.gif", fps=30)
            num_anim +=1
        end
        #println("episode:$episode, episode reward:$episode_rewards")
        avgreward = 0.1 * episode_rewards + avgreward * 0.9
        if episode % infotime == 0
            println("episode:$episode, avgreward:$avgreward")
            close(env)
        end
        ploss, vloss = loss(history,opt_p, opt_v, policynet, valuenet)
        push!(ep_rewards, episode_rewards)
        push!(plosses, ploss.data)
        push!(vlosses, vloss.data)
        if num_anim >=20
            break
        end
    end
    return ep_rewards, plosses, vlosses
end
main()
