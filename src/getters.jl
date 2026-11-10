
# --------------------------------------------------------
# Basic functions
# --------------------------------------------------------

"""
    getnode(model::Workflow, id::Int)

 Return node by identifier `id`.
"""
function getnode(model::Workflow, id::Int)
    return model.nodes[id]
end
"""
    getconnection(model::Workflow, id::Int)

Return connection by identifier `id`.
"""
function getconnection(model::Workflow, id::Int)
    return model.connections[id]
end
# --------------------------------------------------------
# NODE FUNCTIONS
# --------------------------------------------------------
"""
    getid(node::AbstractDataNode) -> Int

Return node unique identifier.
"""
function getid(node::AbstractDataNode)
    node.properties.id
end
"""
    getposition(node::AbstractDataNode) -> Tuple{Int,Int}

Return node UI/graph position.
"""
function getposition(node::AbstractDataNode)
    node.properties.position
end
"""
    getstatus(node::AbstractDataNode) -> Symbol

Return execution status of node.

Possible values:
- `:idle`
- `:dirty`
- `:clean`
- `:executing`
- `:failed`
- `:invalid_node`
- `:invalid_settings`
- `:invalid_result`
"""
function getstatus(node::AbstractDataNode)
    node.properties.status
end


"""
    getstate(node::AbstractDataNode, s::Symbol)

Get value from node execution state.
"""
function getstate(node::AbstractDataNode, s::Symbol)
    node.state[s]
end


"""
    getportnumber(node::AbstractDataNode, l::Symbol, direction::Symbol) 

Return index of port by label and direction (`:input` or `:output`).
"""
function getportnumber(node::AbstractDataNode, l::Symbol, direction::Symbol) 
    return node.spec.portmap[(direction, l)]
end

"""
    getporttype(node::AbstractDataNode, i::Int, direction::Symbol) 

Return Julia datatype of port by index and direction.
"""
function getporttype(node::AbstractDataNode, i::Int, direction::Symbol) 
    if direction == :input
        if i < 1 || i > length(node.spec.input_ports) error("Wrong port number") end
        return node.spec.input_ports[i].datatype
    elseif direction == :output
        if i < 1 || i > length(node.spec.output_ports) error("Wrong port number") end
        return node.spec.output_ports[i].datatype
    end
    error("Wrong port direction (input/output)")
end

"""
    getporttype(node, label, direction) -> Type

Return Julia datatype of port by label.
"""
function getporttype(node::AbstractDataNode, l::Symbol, direction::Symbol) 
    i = getportnumber(node, l, direction) 
    return getporttype(node, i, direction) 
end

"""
    getportspec(node::AbstractDataNode, l::Symbol, direction::Symbol)

Return the [`PortSpec`](@ref) of the port labelled `l` (`direction` is `:input` or `:output`).

Any other `direction` raises a `KeyError`: the specification's port map holds
`(:input, label)` and `(:output, label)` keys and nothing else, so
[`getportnumber`](@ref) fails before the direction is read here.
"""
function  getportspec(node::AbstractDataNode, l::Symbol, direction::Symbol)
    i = getportnumber(node, l, direction)
    if direction == :input
        return node.spec.input_ports[i]
    end
    return node.spec.output_ports[i]
end

"""
    getdata(node::AbstractDataNode, l::Symbol)
 
Return the output data stored under output port label `l`.
 
Returns `nothing` when the port is declared but holds no value yet - for
instance after [`mark_dirty!`](@ref). Raises an error when `l` is not an
output port of the node specification.
"""
function getdata(node::AbstractDataNode, l::Symbol)
    if isportexist(node, l, :output)
        return get(node.data, l, nothing)
    end
    #  Порты берутся из спецификации
    error("Wrong output port label `:$(l)`, ports of this node: " *
          "$([ps.label for ps in node.spec.output_ports])")
end
"""
    getdata(model::Workflow, id::Int, l::Symbol)
 
Return the output data stored under output port label `l` of node `id`.
 
Raises a `KeyError` for an unknown node id; see the two-argument method for
the port lookup rules.
"""
function getdata(model::Workflow, id::Int, l::Symbol)
    node = getnode(model, id)
    return getdata(node, l)
end


"""
    getinputdata(node::AbstractDataNode, l::Symbol)
    getinputdata(node::AbstractDataNode, l::Symbol, con::Int)
 
Read value from node input buffer.
 
The two-argument form depends on the port arity:
 
- [`SinglePort`](@ref): returns the buffered value, or `nothing` when the
  buffer is empty; more than one buffered value is an error.
- [`MultiPort`](@ref): returns the whole `Dict{connection id, value}` buffer.
 
The three-argument form returns the value written by connection `con`, or
`nothing` when that connection has nothing buffered.
 
Both forms raise an error when `l` is not an input port of the node
specification, and neither consumes or clears the buffer.
"""
function getinputdata(node::AbstractDataNode, l::Symbol) 
    if isportexist(node, l, :input)
        port = getportspec(node, l, :input)
        return _getinputdata(node, port)
    end
    error("Wrong port label")
end
function getinputdata(node::AbstractDataNode, l::Symbol, con::Int) 
    if isportexist(node, l, :input)   
        return get(node.input_buffer[l], con, nothing)
    end
    error("Wrong port label")
end
function _getinputdata(node::AbstractDataNode, port::PortSpec{SinglePort})
    len = length(node.input_buffer[port.label])
    if len == 1
        return first(node.input_buffer[port.label])[2]
    elseif len == 0
        return nothing
    else
        error("Multiple connections in single port")
    end
end
function _getinputdata(node::AbstractDataNode, port::PortSpec{MultiPort})
    return node.input_buffer[port.label]
end

"""
    getportconnections(model::Workflow, id::Int, label::Symbol; direction = :both)

Return all connections attached to a specific port.

Direction:
- `:input`
- `:output`
- `:both`
"""
function getportconnections(model::Workflow, id::Int, label::Symbol; direction = :both)
    # ADD MULTIPLE OUTPUT CONNECTION SUPPORT
    v = NodeConnection[]
    direction in (:input, :output, :both) || error("wrong direction")
    node = getnode(model, id)
    if direction == :input || direction == :both
        for con_id in get(model.incoming, id, Int[])
            con = getconnection(model, con_id)
            if con.input_port == label 
                push!(v, con) 
            end
        end
    end
    if direction == :output || direction == :both
        for con_id in get(model.outgoing, id, Int[])
            con = getconnection(model, con_id)
            if con.output_port == label 
                push!(v, con) 
            end
        end
    end
    return v
end

#  Ищем родителей (входящие соединения ноды)

"""
    get_parents(model::Workflow, id::Int)

Get parents (incoming connections of the node). Returns Vector of Tuple
(input_port, parent_id) for each incoming connection - one entry per
connection, so a node reached through several ports appears several times.

An unknown `id` gives an empty vector.

See also [`get_children`](@ref), which returns triples
(output_port, child_id, input_port).
"""
function get_parents(model::Workflow, id::Int)
    v = Vector{Tuple{Symbol, Int}}()
    if haskey(model.nodes, id) 
        # Ищем все входящие соединения
        for cid in get(model.incoming, id, Int[])
            conn = model.connections[cid]
            push!(v, (conn.input_port, conn.output_id))
        end
    end
    return v
end

 #  Ищем детей (исходящие соединения ноды)
"""
    get_children(model::Workflow, id::Int)

Get children. Returns Vector of Tuple (output_port, child_id, input_port) for each child connection.
"""
function get_children(model::Workflow, id::Int) 
    v = Tuple{Symbol, Int, Symbol}[]
    for cid in get(model.outgoing, id, Int[])
        conn = model.connections[cid]
        push!(v,
            (conn.output_port,
            conn.input_id,
            conn.input_port)
        )
    end
    return v
end


# getmeta in meta.jl

# getinputmeta in meta.jl

# getmeta_unsafe in meta.jl
