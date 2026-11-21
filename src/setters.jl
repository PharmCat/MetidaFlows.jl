
"""
    setid!(node::AbstractDataNode, id::Int) -> DataNode

Set node identifier. Mutates node in-place.

Pure mutation: a workflow keys its `nodes` dictionary separately, so this does
not move a node that is already in a graph, it only makes the node disagree
with the key it is stored under. Changing a node under an existing identifier
is [`replace!`](@ref replace!(::Workflow, ::AbstractDataNode, ::Int)).
"""
function setid!(node::AbstractDataNode, id::Int)
    node.properties.id = id
    node
end

"""
    setposition!(node::AbstractDataNode, p::Tuple{Int,Int}) -> DataNode

Set UI/graph position of node.
"""
function setposition!(node::AbstractDataNode, p::Tuple{Int, Int})
    node.properties.position = p
    node
end

"""
    setstatus!(node::AbstractDataNode, s::Symbol) -> DataNode

Set execution status of node.

This does NOT trigger validation or propagation.
Pure mutation.
"""
function setstatus!(node::AbstractDataNode, s::Symbol)
    node.properties.status = s
    node
end

"""
    setstate!(node::AbstractDataNode, s::Symbol, v) -> DataNode

Store value in node execution state.

`s` is a field name of the node's state object - with the default
[`NodeState`](@ref) one of `:exec_n`, `:ready_ports`, `:execution_id`, `:log`,
`:stop`. Any other name raises, and so does a value the field cannot hold.
"""
function setstate!(node::AbstractDataNode, s::Symbol, v)
    node.state[s] = v
    node
end

"""
    setreadyports!(node::AbstractDataNode, labels::Symbol...) -> Vector{Symbol}
    setreadyports!(node::AbstractDataNode, labels) -> Vector{Symbol}

Record which output ports the current execution published, in the node's own
storage, and return that storage.

This is what a node returns from [`execute_unsafe!`](@ref) instead of building
a label vector:

```julia
function MetidaFlows.execute_unsafe!(node::DataNode{Doubler})
    setdata!(node, :out, 2 * getinputdata(node, :in))
    return setreadyports!(node, :out)          # instead of return [:out]
end
```

The vector belongs to the node and is reused, so from the second execution on
the label list costs nothing. Measured on a chain where every node publishes
one port: 175 bytes per node per run against 111 at a thousand nodes, 219
against 155 at ten thousand. The run itself gets about 4 % faster - the saving
is allocation, not arithmetic.

Returning a vector built in the node - `return [:out]` - keeps working and
means the same thing. The engine stores it through this same function.

With no labels it records that the execution published nothing, which is what a
gate that did not fire returns:

```julia
return setreadyports!(node)                    # instead of return Symbol[]
```

# The labels are checked, which is the one difference

Every label passed to the varargs form has to be an output port of the node's
[`NodeSpec`](@ref); one that is not raises. The call sits in the node's own
code, so the engine catches it, the node ends `:failed`, and the message in
`model.log` names the label.

Returning a vector instead leaves the labels on trust: a label that was never
written, or is not an output port at all, ends the node `:clean` and its
consumer silently gets nothing - a symptom that shows up one node downstream.
That is the reason to prefer this function over a vector even where the
allocation does not matter.

The collection form does **not** check, because it is also how the engine
stores what a node returned: by that point the value has already come back
from user code, and raising there would escape the run instead of marking the
node.
"""
function setreadyports!(node::AbstractDataNode, labels::Symbol...)
    for l in labels
        isportexist(node, l, :output) ||
            error("Port $(l) is not an output port of node $(getid(node))")
    end
    portvec = getstate(node, :ready_ports)
    resize!(portvec, length(labels))
    @inbounds for i in eachindex(labels)
        portvec[i] = labels[i]
    end
    return portvec
end

function setreadyports!(node::AbstractDataNode, v)
    portvec = getstate(node, :ready_ports)
    resize!(portvec, length(v))
    @inbounds for i in eachindex(v)
        portvec[i] = v[i]
    end
    return portvec
end

"""
    setdata!(node::AbstractDataNode, l::Symbol, d) 

Store `d` as the value of output port `l` and return `true`.
 
Raises an error when `l` is not an output port of the node specification.
This is what a node implementation calls from [`execute_unsafe!`](@ref)
before returning the list of ready ports.
"""
function setdata!(node::AbstractDataNode, l::Symbol, d) 
    if isportexist(node, l, :output) 
        node.data[l] = d
        return true
    end
    error("Wrong port label")
end

"""
    setinputbuffer!(node::AbstractDataNode, label::Symbol, connection_id::Int, value)

Write value into node input buffer, under the identifier of the connection that
carried it.

Used by workflow engine to propagate outputs between nodes, from
[`push_buffer!`](@ref). The label is not checked against the specification: a
label the node does not have raises from the buffer container itself.
"""
function setinputbuffer!(node::AbstractDataNode, l::Symbol, con::Int, d)
    # input_buffer[port_label][connection_id] = data
    node.input_buffer[l][con] = d
    node
end

"""
    setsettings!(model::Workflow, id::Int, settings::Dict{Symbol, <: Any}; replace = false)
 
Apply new node settings and invalidate dependent nodes.
 
Settings are applied using [`setsettings_unsafe!`](@ref), or
[`replacesettings_unsafe!`](@ref) when `replace = true`, after which the
target node and all downstream nodes are invalidated via
[`invalidate_downstream!`](@ref).
 
# Notes
- This function is the safe high-level entry point for mutating node
  configuration inside a workflow.
- Settings are **merged** by default: only the keys present in `settings` are
  overwritten, the rest are kept. `replace = true` makes `settings` the whole
  configuration instead, dropping every key it does not mention - the only way
  to remove a setting, and what restoring a saved version needs.
- `replace = true` is recorded in the change log, so a reader can tell which
  of the two a [`SettingsChanged`](@ref) record meant.
- The keys are **not** checked against the list in [`NodeSpec`](@ref): that
  list is a declaration, and an unknown key is simply stored. Enforce what
  matters in [`validate_settings`](@ref).
- `model.ver` is **not** raised: it versions the graph's structure, and four
  cached values hang on it. Settings change what a node computes, not what the
  graph looks like, so raising it would throw away the topological sort and the
  readiness map for nothing. Invalidation, not the version, is what makes the
  node recompute.
- An undeclared key is stored but **not written to a snapshot**:
  [`settings_to_dict`](@ref) writes only the declared ones. So a setting kept
  off the list lives for as long as the object does and no longer, which is
  the one place where the asymmetry has a consequence.
 
# Returns
The node.
"""
function setsettings!(model::Workflow, id::Int, settings::Dict{Symbol, <: Any}; replace::Bool = false)
    node = getnode(model, id)
    replace ? replacesettings_unsafe!(node, settings) : setsettings_unsafe!(node, settings)
    invalidate_downstream!(model, id)
    #  Ключи сортируются: порядок обхода переданного `Dict` машинно-зависим,
    #  а журнал одинаковых правок обязан быть одинаковым.
    audit!(model, SettingsChanged(id, sort!(collect(keys(settings))), replace))
    node
end
"""
    setsettings_unsafe!(node::AbstractDataNode, settings::Dict{Symbol, <: Any})

Direct mutation of node settings without invalidation. Can be re-implemented for every node type.

Default implementation copies all provided key-value pairs into `node.settings`,
one key at a time, so a container that is a struct rather than a `Dict` - see
[`AbstractNodeFields`](@ref) - is written through `setindex!` and keeps its
field types. A key it refuses, because the type does not match the field or
because the field does not exist, raises an error naming the node and the key.

# Warning
This function does NOT invalidate cached execution results or downstream nodes.

Use [`setsettings!`](@ref) for normal workflow operation
"""
function setsettings_unsafe!(node::AbstractDataNode, settings::Dict{Symbol, <: Any})
    for (k, v) in settings
        #  Присваивание в типизированный контейнер отказывает на чужом типе
        #  или на незнакомом поле, и без контекста наружу выходит голый
        #  `TypeError: in setfield!, expected Int64, got ... String`.
        try
            node.settings[k] = v
        catch e
            error("Node $(getid(node)) setting `:$(k)`: $(sprint(showerror, e))")
        end
    end
    node
end

"""
    replacesettings_unsafe!(node::AbstractDataNode, settings::Dict{Symbol, <: Any})

Make `settings` the node's whole configuration, without invalidation. What
[`setsettings!`](@ref) calls at `replace = true`, and, like
[`setsettings_unsafe!`](@ref), a point a node type may re-implement.

The default implementation removes every key the node holds and `settings` does
not, then writes `settings` the ordinary way. "Remove" is `delete!` on the
settings container: on a `Dict` the key is gone, and on a struct container -
see [`AbstractNodeFields`](@ref) - there is no such thing as a missing field,
so the field goes back to the value it has in a freshly constructed container.
A container of one's own therefore needs `keys` and `delete!` for this to work;
`setsettings_unsafe!` alone needs neither.

Removal comes first, on a copy of the key list, because deleting from a
container while iterating it is not allowed.

# Warning
This function does NOT invalidate cached execution results or downstream nodes.

Use [`setsettings!`](@ref)`(model, id, settings; replace = true)` for normal
workflow operation.
"""
function replacesettings_unsafe!(node::AbstractDataNode, settings::Dict{Symbol, <: Any})
    for k in collect(keys(node.settings))
        haskey(settings, k) && continue
        try
            delete!(node.settings, k)
        catch e
            error("Node $(getid(node)) setting `:$(k)` cannot be removed: $(sprint(showerror, e))")
        end
    end
    return setsettings_unsafe!(node, settings)
end