# Decision #
# ========================== #
@enum DecisionState NotTaken Taken Known

mutable struct Decision{T}
    state::DecisionState
    value::T
end
state(decision::Decision) = decision.state
decision_value(decision::Decision) = state(decision) == NotTaken ? NaN : decision.value

function Decision(value, ::Type{T}) where T
    return Decision(Taken, T(value))
end

function KnownDecision(value, ::Type{T}) where T
    return Decision(Known, T(value))
end

function Decision(info::JuMP.VariableInfo, ::Type{T}) where T
    if info.has_fix
        return Decision(Taken, T(info.fixed_value))
    end
    return Decision(NotTaken, T(NaN))
end

function KnownDecision(info::JuMP.VariableInfo, ::Type{T}) where T
    value = if info.has_fix
        # Value fixed at construction
        T(info.fixed_value)
    else
        # Value is known, but not yet set. Pick a feasible value for now
        value = if info.has_lb
            T(info.lower_bound)
        elseif info.has_ub
            T(info.upper_bound)
        else
            zero(T)
        end
    end
    return Decision(Known, value)
end

Base.copy(decision::Decision) = Decision(decision.state, decision.value)

# Decisions #
# ========================== #
struct IgnoreDecisions end

const DecisionMap = OrderedDict{MOI.VariableIndex, Decision{Float64}}
const StageMap = Dict{MOI.VariableIndex, Int}
const ConstraintMap = MOIU.DoubleDicts.MainIndexDoubleDict

struct Decisions{N}
    decisions::NTuple{N, DecisionMap}
    stage_map::StageMap
    constraint_map::ConstraintMap

    function Decisions(::Val{N}) where N
        decisions = ntuple(Val(N)) do i
            DecisionMap()
        end
        return new{N}(decisions, StageMap(), MOIU.DoubleDicts.IndexDoubleDict())
    end

    function Decisions(decisions::NTuple{N, DecisionMap}) where N
        return new{N}(decisions, StageMap(), MOIU.DoubleDicts.IndexDoubleDict())
    end
end

function num_stages(::IgnoreDecisions)
    return 0
end
function num_stages(decisions::Decisions{N}) where N
    return N
end

function Base.getindex(decisions::Decisions, stage::Integer)
    return decisions.decisions[stage]
end

function has_decision(decisions::Decisions{N}, stage::Integer, index::MOI.VariableIndex) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    decisions.stage_map[index] == stage || error("Decision $index is mapped to stage $(decisions.stage_map[index])")
    return haskey(decisions.decisions[stage], index)
end
function has_decision(decisions::Decisions, index::MOI.VariableIndex)
    haskey(decisions.stage_map, index) || error("Decision $index not properly stage mapped.")
    return has_decision(decisions, decisions.stage_map[index], index)
end

function stage(decisions::Decisions, index::MOI.VariableIndex)
    haskey(decisions.stage_map, index) || error("Decision $index not properly stage mapped.")
    return decisions.stage_map[index]
end
function set_stage!(decisions::Decisions{N}, index::MOI.VariableIndex, stage::Integer) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    decisions.stage_map[index] = stage
    return nothing
end

function decision(decisions::DecisionMap, index::MOI.VariableIndex)
    return decisions[index]
end
function decision(decisions::Decisions{N}, stage::Integer, index::MOI.VariableIndex) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    return decision(decisions.decisions[stage], index)
end
function decision(decisions::Decisions, index::MOI.VariableIndex)
    haskey(decisions.stage_map, index) || error("Decision $index not properly stage mapped.")
    return decision(decisions, decisions.stage_map[index], index)
end

function decision_value(decisions::Decisions{N}, stage::Integer, index::MOI.VariableIndex) where N
    return decision_value(decision(decisions, stage, index))
end
function decision_value(decisions::Decisions, index::MOI.VariableIndex)
    return decision_value(decision(decisions, index))
end

function set_decision!(decisions::DecisionMap, index::MOI.VariableIndex, decision::Decision)
    decisions[index] = decision
    return nothing
end
function set_decision!(decisions::Decisions{N}, stage::Integer, index::MOI.VariableIndex, decision::Decision) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    set_decision!(decisions.decisions[stage], index, decision)
    return nothing
end
function set_decision!(decisions::Decisions{N}, index::MOI.VariableIndex, decision::Decision) where N
    haskey(decisions.stage_map, index) || error("Decision $index not properly stage mapped.")
    set_decision!(decisions, decisions.stage_map[index], index, decision)
    return nothing
end

function remove_decision!(::IgnoreDecisions, ::MOI.VariableIndex)
    return nothing
end
function remove_decision!(decisions::DecisionMap, index::MOI.VariableIndex)
    delete!(decisions, index)
    return nothing
end
function remove_decision!(decisions::Decisions{N}, stage::Integer, index::MOI.VariableIndex) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    if !has_decision(decisions, stage, index)
        return nothing
    end
    delete!(decisions.decisions[stage], index)
    delete!(decisions.stage_map, index)
    return nothing
end
function remove_decision!(decisions::Decisions{N}, index::MOI.VariableIndex) where N
    haskey(decisions.stage_map, index) || error("Decision $index not properly stage mapped.")
    remove_decision!(decisions, decisions.stage_map[index], index)
    return nothing
end

function mapped_constraint(decisions::Decisions, ci::MOI.ConstraintIndex)
    if haskey(decisions.constraint_map, ci)
        return decisions.constraint_map[ci]
    else
        return typeof(ci)(0)
    end
end
function map_constraint!(decisions::Decisions, ci::MOI.ConstraintIndex, inner::MOI.ConstraintIndex)
    decisions.constraint_map[ci] = inner
    return nothing
end
function remove_mapped_constraint!(decisions::Decisions, ci::MOI.ConstraintIndex)
    haskey(decisions.constraint_map, ci) || error("Constraint $ci not properly mapped.")
    delete!(decisions.constraint_map, ci)
    return nothing
end

function clear!(decisions::Decisions)
    map(decisions.decisions) do decisions
        empty!(decisions)
    end
    empty!(decisions.stage_map)
    empty!(decisions.constraint_map)
    return nothing
end

function all_decisions(decisions::DecisionMap)
    return filter(decisions) do (index, decision)
        state(decision) != Known
    end |> keys |> collect
end
function all_decisions(decisions::Decisions{N}, stage::Integer) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    return all_decisions(decisions[stage])
end

function all_known_decisions(decisions::DecisionMap)
    return filter(decisions) do (index, decision)
        state(decision) == Known
    end |> keys |> collect
end
function all_known_decisions(decisions::Decisions{N}, stage::Integer) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    return all_known_decisions(decisions[stage])
end

function num_decisions(decisions::DecisionMap)
    return count(decisions) do (index, decision)
        return state(decision) != Known
    end
end
function num_decisions(decisions::Decisions{N}, stage::Integer) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    return num_decisions(decisions[stage])
end

function num_known_decisions(decisions::DecisionMap)
    return count(decisions) do (index, decision)
        state(decision) == Known
    end
end
function num_known_decisions(decisions::Decisions{N}, stage::Integer) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    return num_known_decisions(decisions[stage])
end

function untake_decisions!(decisions::DecisionMap)
    need_update = false
    # Update states and values
    for key in all_decisions(decisions)
        if decisions[key].state != NotTaken
            decisions[key].state = NotTaken
            need_update |= true
        end
    end
    return need_update
end
function untake_decisions!(decisions::Decisions{N}, stage::Integer) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    return untake_decisions!(decisions[stage])
end

function take_decisions!(decisions::DecisionMap, x::AbstractVector)
    # Check decision length
    num_decisions(decisions) == length(x) || error("Given decision of length $(length(x)) not compatible with number of defined decision variables $(num_decisions(decisions)).")
    # Update states and values (assume x given in sorted order)
    for (key, val) in zip(all_decisions(decisions), x)
        decisions[key].state = Taken
        decisions[key].value = val
    end
    return nothing
end
function take_decisions!(decisions::Decisions{N}, stage::Integer, x::AbstractVector) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    take_decisions!(decisions[stage], x)
    return nothing
end

function update_known_decisions!(decisions::DecisionMap, x::AbstractVector)
    # Check decision length
    num_known_decisions(decisions) == length(x) || error("Given decision of length $(length(x)) not compatible with number of defined known decision variables $(num_known_decisions(decisions)).")
    # Update values (assume x given in sorted order)
    for (key, val) in zip(all_known_decisions(decisions), x)
        decisions[key].value = val
    end
    return nothing
end
function update_known_decisions!(decisions::Decisions{N}, stage::Integer, x::AbstractVector) where N
    1 <= stage <= N || error("Stage $stage not in range 1 to $N.")
    update_known_decisions!(decisions[stage], x)
end

is_decision_type(::DataType) = false

include("variable_interface.jl")
include("expressions/expressions.jl")
include("functions/functions.jl")
include("sets.jl")
include("modifications.jl")
include("bridges/bridges.jl")
include("macros.jl")
include("updates.jl")
include("moi_overrides.jl")
