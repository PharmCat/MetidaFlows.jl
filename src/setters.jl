
"""
    setid!(node::AbstractDataNode, id::Int) -> DataNode

Set node identifier. Mutates node in-place.
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

Write value into node input buffer.

Used by workflow engine to propagate outputs between nodes.
"""
function setinputbuffer!(node::AbstractDataNode, l::Symbol, con::Int, d)
    # input_buffer[port_label][connection_id] = data
    node.input_buffer[l][con] = d
    node
end

"""
    setsettings!(model::Workflow, id::Int, settings::Dict{Symbol, <: Any})
 
Apply new node settings and invalidate dependent nodes.
 
Settings are applied using [`setsettings_unsafe!`](@ref), after which the
target node and all downstream nodes are invalidated via
[`invalidate_downstream!`](@ref).
 
# Notes
- This function is the safe high-level entry point for mutating node
  configuration inside a workflow.
- Settings are **merged**: only the keys present in `settings` are
  overwritten, the rest are kept.
- The keys are **not** checked against the list in [`NodeSpec`](@ref): that
  list is a declaration, and an unknown key is simply stored. Enforce what
  matters in [`validate_settings`](@ref).
- An undeclared key is stored but **not written to a snapshot**:
  [`settings_to_dict`](@ref) writes only the declared ones. So a setting kept
  off the list lives for as long as the object does and no longer, which is
  the one place where the asymmetry has a consequence.
 
# Returns
The node.
"""
function setsettings!(model::Workflow, id::Int, settings::Dict{Symbol, <: Any})
    node = getnode(model, id)
    setsettings_unsafe!(node, settings)
    invalidate_downstream!(model, id)
    #  Ключи сортируются: порядок обхода переданного `Dict` машинно-зависим,
    #  а журнал одинаковых правок обязан быть одинаковым.
    audit!(model, SettingsChanged(id, sort!(collect(keys(settings)))))
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