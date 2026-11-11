
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
- [`MultiPort`](@ref): returns a `Vector` of the buffered values, ordered by
  ascending connection id - that is, in the order the inputs were attached.
  The vector is freshly built, so a node may consume or reorder it without
  touching its own buffer. Use [`getinputconnections`](@ref) for the matching
  connection ids when a node needs to tell its producers apart.

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
_getinputdata(node::AbstractDataNode, port::PortSpec{SinglePort}) =
    buffersingle(node.input_buffer[port.label])

#  Единственное значение порта. Общая форма достаёт его через пару, которую
#  отдаёт итератор; контейнер по умолчанию хранит значения подряд, поэтому
#  берёт напрямую — на цепочке из SinglePort это и есть разница.
function buffersingle(buffer)
    len = length(buffer)
    len == 1 && return first(buffer)[2]
    len == 0 && return nothing
    error("Multiple connections in single port")
end
function buffersingle(buffer::PortBuffer)
    len = length(buffer.vals)
    len == 1 && return @inbounds buffer.vals[1]
    len == 0 && return nothing
    error("Multiple connections in single port")
end
#  Порядок обхода `Dict` в Julia не определён порядком вставки: на 12 входах,
#  подключённых по алфавиту, словарь отдавал `cbfedahgjkli`. Поэтому узел не
#  мог опереться ни на имя (номер связи ему ни о чём не говорит), ни даже на
#  позицию — то есть на MultiPort нельзя было написать ничего, кроме
#  коммутативной свёртки. Отдаём значения вектором по возрастанию номера
#  связи, то есть в порядке, в котором входы подключали; заодно это копия, и
#  узел, прибравший за собой, больше не вытирает собственный буфер.
_getinputdata(node::AbstractDataNode, port::PortSpec{MultiPort}) =
    buffervalues(node.input_buffer[port.label])

"""
    buffervalues(buffer)  -> Vector
    bufferkeys(buffer)    -> Vector{Int}
    buffersingle(buffer)

How the engine reads one port's buffer. The three are what a container may
specialize, and [`PortBuffer`](@ref) - the default - specializes all three.

`buffervalues` and `bufferkeys` give the values and the connection ids
**ordered by ascending connection id**; they are what [`getinputdata`](@ref)
and [`getinputconnections`](@ref) return for a [`MultiPort`](@ref), so the two
line up position for position. `buffersingle` gives the one buffered value of a
[`SinglePort`](@ref), `nothing` when the buffer is empty, and raises when more
than one connection has written - the generic form reaches it through the pair
the iterator yields, which is worth avoiding in a container that stores its
values contiguously (measured: a 200-node `SinglePort` chain runs 20 % faster
for it).

The default works for any container keyed by connection id: it collects the
keys, sorts them, and indexes. That is two allocations and a sort on every
call, because a `Dict` cannot report an order it does not keep.

A container that *does* keep its keys in order can say so, and then the sort
and one of the allocations go away:

```julia
MetidaFlows.bufferkeys(b::SortedBuffer)   = copy(b.cids)
MetidaFlows.buffervalues(b::SortedBuffer) = copy(b.vals)
MetidaFlows.buffersingle(b::SortedBuffer) = length(b.vals) == 1 ? b.vals[1] :
                                            isempty(b.vals) ? nothing :
                                            error("Multiple connections in single port")
```

Both must return a **fresh** vector in the same order: the node is free to
sort, consume or empty what it is given, and must not reach the buffer through
it. Returning `b.vals` itself would hand the engine's buffer back to the node.
"""
function buffervalues(buffer)
    ks = sort!(collect(keys(buffer)))
    return [buffer[k] for k in ks]
end

@doc (@doc buffervalues)
bufferkeys(buffer) = sort!(collect(keys(buffer)))

#  Контейнер по умолчанию ключи уже держит упорядоченными, поэтому собирать
#  и сортировать нечего — только скопировать, чтобы узел не дотянулся до
#  буфера через возвращённый вектор. Замерено: 48 Б / 18 нс против
#  208 Б / 256 нс у словаря на двух входах.
buffervalues(buffer::PortBuffer) = copy(buffer.vals)
bufferkeys(buffer::PortBuffer)   = copy(buffer.cids)

"""
    getinputconnections(node::AbstractDataNode, l::Symbol)

Connection ids buffered on input port `l`, ascending - the same order in which
[`getinputdata`](@ref) returns the values of a [`MultiPort`](@ref).

Needs no [`Workflow`](@ref), so it is callable from [`execute_unsafe!`](@ref),
which is given only the node. The ids are what a node zips against its values
when it has to tell its producers apart:

```julia
for (cid, v) in zip(getinputconnections(node, :ins), getinputdata(node, :ins))
    # settings[:role][cid] - the meaning the graph author assigned at build time
end
```

Raises an error when `l` is not an input port of the node specification.

See [`bufferkeys`](@ref buffervalues) for how a custom buffer container reports
its order.
"""
function getinputconnections(node::AbstractDataNode, l::Symbol)
    isportexist(node, l, :input) || error("Wrong port label: $(l) is not an input port of node $(getid(node))")
    return bufferkeys(node.input_buffer[l])
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
