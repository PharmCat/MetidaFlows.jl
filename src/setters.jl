
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
    setreadyports!(node::AbstractDataNode, v)

Set ready output ports in node execution state.

Overwrite the `ready_ports` execution state with `v`, reusing the existing
vector. Called by [`execute!`](@ref) with the value returned by
[`execute_unsafe!`](@ref).

"""
function setreadyports!(node::AbstractDataNode, v)
    portvec = getstate(node, :ready_ports)
    resize!(portvec, length(v))
    @inbounds for i in eachindex(v)
        portvec[i] = v[i]
    end
    node
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