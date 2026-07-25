module MetidaFlows

using NamedGraphs

import NamedGraphs: add_vertex!, add_edge!, is_cyclic

import NamedGraphs.Graphs: topological_sort

import Base: show, keys, getindex, setindex!
#
abstract type AbstractDataNode end
#
abstract type AbstractNodeType end
#
abstract type AbstractAuditEvent end
#
abstract type WorkFlowType end
#
struct DAW <: WorkFlowType end # Data Analysis Workflow
struct ABW <: WorkFlowType end # Agent-Based Workflow


struct LogMsg
    id::UInt64
    timestamp
    level::Symbol
    message::String
end
#
abstract type AbstractNodeFields end
abstract type AbstractNodeSettings <: AbstractNodeFields end
abstract type AbstractNodeData  <: AbstractNodeFields end
abstract type AbstractNodeState  <: AbstractNodeFields end
abstract type AbstractNodeInputBuffer  <: AbstractNodeFields end

# Обеспечивает Dict совместимое поведение AbstractNodeFields (NodeState)
Base.getindex(obj::AbstractNodeFields, f::Symbol) = getfield(obj, f)
function Base.setindex!(obj::T, val, f::Symbol) where T <: AbstractNodeFields
    ismutabletype(T) || error("immutable")
    setfield!(obj, f, val)
end
Base.keys(obj::AbstractNodeFields) = fieldnames(obj)

struct ExecuteSettings
    execute_upstream::Bool
    invalidate_downstream::Bool 
    check_cyclic::Bool
    check_input_buffer::Bool
    function ExecuteSettings(execute_upstream, invalidate_downstream, check_cyclic, check_input_buffer)
        new(execute_upstream, invalidate_downstream, check_cyclic, check_input_buffer)
    end
    function ExecuteSettings(;
        execute_upstream::Bool = true,
        invalidate_downstream::Bool = true,
        check_cyclic::Bool = true,
        check_input_buffer::Bool = true)
        ExecuteSettings(execute_upstream, invalidate_downstream, check_cyclic, check_input_buffer)
    end
    function ExecuteSettings(all_flags::Bool)
         ExecuteSettings(all_flags, all_flags, all_flags, all_flags)
    end
end
# Minimal fields for NodeState
# Dict compatible struct and minimal methods
mutable struct NodeState <: AbstractNodeState
    exec_n::Int
    ready_ports::Vector{Symbol}
    execution_id::UInt64
    log::Vector{LogMsg}
    function NodeState()
        new(0, Symbol[], 0, LogMsg[])
    end
end 
#
abstract type AbstractPortType end
struct MultiPort <: AbstractPortType end
struct SinglePort <: AbstractPortType end
#

"""
    PortSpec(name, datatype, label, ::T = SinglePort(); required::Bool = true) where T <: AbstractPortType

Specification of a node port.

Fields:
- `name::String` - human-readable name of the port.
- `datatype::Type` - Julia type of the port data.
- `label::Symbol` - unique label used for referencing the port in code.
- `required::Bool` - whether the port is required for execution.
"""
struct PortSpec{T <: AbstractPortType}
    name::String
    datatype::Type
    label::Symbol
    required::Bool
    function PortSpec(name, datatype, label, ::T = SinglePort(); required::Bool = true) where T <: AbstractPortType
        new{T}(name, datatype, label, required)
    end
end
#
struct NodeSpec
    name::String
    input_ports::Vector{PortSpec}   
    output_ports::Vector{PortSpec}
    settings::Vector{Symbol}
    portmap::Dict{Tuple{Symbol, Symbol}, Int} 
    function NodeSpec(name, input_ports, output_ports, settings)
        portmap = Dict{Tuple{Symbol, Symbol}, Int}()
        for (i, v) in enumerate(input_ports)
            portmap[(:input, v.label)] = i
        end
        for (i, v) in enumerate(output_ports)
            portmap[(:output, v.label)] = i
        end
        new(name, input_ports, output_ports, settings, portmap)
    end
    function NodeSpec(name, input_ports, output_ports)
        NodeSpec(name, input_ports, output_ports, Symbol[])
    end
end
#
mutable struct NodeProperties
    id::Int
    status::Symbol # => :clean, :dirty, :executing, :failed, :idle, :invalid_*
    position::Tuple{Int, Int}
    function NodeProperties(id, status, position)
        new(id, status, position)
    end
    function NodeProperties()
        new(0, :idle, (0,0))
    end
end
#
struct NodeConnection
    output_id::Int       # parent node id
    output_port::Symbol  # parent node port
    input_id::Int        # child node id
    input_port::Symbol   # child node port
end
# Node
struct DataNode{T <: AbstractNodeType, SettingsT, DataT, StateT, BufferT} <: AbstractDataNode
    properties::NodeProperties
    spec::NodeSpec
    settings::SettingsT   # Dict{Symbol, Any}() by default
    data::DataT           # Dict{Symbol, Any}() by default
    state::StateT         # NodeState by default
    input_buffer::Dict{Symbol, Dict{Int, BufferT}} # Dict{Symbol, Any}() by default
    function DataNode(type::Type{T}, properties, spec, settings::SettingsT, data::DataT, state::StateT, input_buffer::Dict{Symbol, Dict{Int, BufferT}} ) where T <: AbstractNodeType where SettingsT where DataT  where StateT  where BufferT
        for k in keys(input_buffer)
            isportinspec(k, spec, :input) || error("Input buffer key $k doesn't match any input port in node specification")
        end
        for ip in spec.input_ports
            if !haskey(input_buffer, ip.label)
                input_buffer[ip.label] = Dict{Int, BufferT}()
            end
        end
        new{T, SettingsT, DataT, StateT, BufferT}(properties, spec, settings, data, state, input_buffer)
    end
    function DataNode(type::Type, id, status, position, spec; settings = Dict{Symbol, Any}(), data = Dict{Symbol, Any}(), state = NodeState(), input_buffer = Dict{Symbol, Dict{Int, Any}}())
        DataNode(type,  NodeProperties(id, status, position), spec, settings, data, state, input_buffer)
    end
    function DataNode(type::Type, spec; settings = Dict{Symbol, Any}(), data = Dict{Symbol, Any}(), state = NodeState(), input_buffer = Dict{Symbol, Dict{Int, Any}}())
        DataNode(type,  NodeProperties(), spec, settings, data, state, input_buffer)
    end
end

#=
Cтатусы:
:idle - just created
:clean - executed
:dirty - changes in settings or 
:executing
:failed
:invalid_
=#
# Model structure DAW
mutable struct Workflow{WorkFlowType}
    id::Int                      # model ID
    name::String                 # Workflow name
    n_iter::Int                  # 
    nodes::Dict{Int, DataNode}   # {Node id, Node}
    c_iter::Int
    connections::Dict{Int, NodeConnection} # {Connection id, Connection}
    incoming::Dict{Int, Vector{Int}} # {Node id, [connection ids]} 
    outgoing::Dict{Int, Vector{Int}} # {Node id, [connection ids]}
    run_id::UInt64
    log::Vector{LogMsg}
    audit_log::Vector{AbstractAuditEvent}
end
#
function Workflow(id::Int; type::Symbol = :DAW)
    if type == :DAW
        Workflow{DAW}(id, "Default", 0, Dict{Int, DataNode}(), 0, Dict{Int, NodeConnection}(), Dict{Int, Vector{Int}}(), Dict{Int, Vector{Int}}(), 0, LogMsg[], AbstractAuditEvent[])
    else
        Workflow{ABW}(id, "Default", 0, Dict{Int, DataNode}(), 0, Dict{Int, NodeConnection}(), Dict{Int, Vector{Int}}(), Dict{Int, Vector{Int}}(), 0, LogMsg[], AbstractAuditEvent[])
    end
end
#
function nodetypestr(::DataNode{T}) where T
    string(T)
end
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
    getstate(node::AbstractDataNode, s::Symbol)

Get value from node execution state.
"""
function getstate(node::AbstractDataNode, s::Symbol)
    node.state[s]
end
"""
    setstate!(node::AbstractDataNode, s::Symbol, v) -> DataNode

Store value in node execution state.
"""
function setstate!(node::AbstractDataNode, s::Symbol, v)
    node.state[s] = v
    node
end

function setreadyports!(node::AbstractDataNode, v)
    portvec = getstate(node, :ready_ports)
    resize!(portvec, length(v))
    @inbounds for i in eachindex(v)
        portvec[i] = v[i]
    end
    node
end

"""
    haveinputs(node::AbstractDataNode)

Returns `true` if node has at least one input port defined in its spec.
"""
function haveinputs(node::AbstractDataNode)
    return !isempty(node.spec.input_ports)
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
"""
function  getportspec(node::AbstractDataNode, l::Symbol, direction::Symbol)
    i = getportnumber(node, l, direction) 
    if direction == :input
        return node.spec.input_ports[i]
    elseif direction == :output
        return node.spec.output_ports[i]
    end
    error("Wrong direction")
end
"""
    isportexist(node::AbstractDataNode, port::Symbol, direction::Symbol = :any)

Check whether a port exists in node specification.

Direction:
- `:input`
- `:output`
- `:any`
"""
function isportexist(node::AbstractDataNode, port::Symbol, direction::Symbol = :any)
    if !(direction in (:input, :output, :any)) error("Wrong direction [:input, :output, :any]") end
    if direction == :input || direction == :any
        for p in node.spec.input_ports
            if port == p.label
                return true
            end
        end
    end
    if direction == :output || direction == :any
        for p in node.spec.output_ports
            if port == p.label
                return true
            end
        end
    end
    return false
end


function isportinspec(p::Symbol, spec::NodeSpec, direction::Symbol)
    if direction == :input || direction == :both
        for sp in spec.input_ports
            if p == sp.label return true end
        end
    end
    if direction == :output || direction == :both
        for sp in spec.output_ports
            if p == sp.label return true end
        end
    end
    return false
end

#=
"""
    getdata(node::AbstractDataNode, i::Int) 

Return output data by output port index.
"""
function getdata(node::AbstractDataNode, i::Int) 
    if i < 1 || i > length(node.spec.output_ports) error("Wrong port number") end
    l = node.spec.output_ports[i].label
    return node.data[l]
end
=#

"""
    getdata(node::AbstractDataNode, l::Symbol)

Return output data stored under output port label.
"""
function getdata(node::AbstractDataNode, l::Symbol)
    if isportexist(node, l, :output) 
        return get(node.data, l, nothing)
    end
    error("Wrong port label, available ports: $(collect(keys(node.data)))")
end
"""
    getdata(model::Workflow, id::Int, l::Symbol)

Return output data stored under output port label.
"""
function getdata(model::Workflow, id::Int, l::Symbol)
    node = getnode(model, id)
    return getdata(node, l)
end


"""
    setdata!(node::AbstractDataNode, l::Symbol, d) 

Store output data in node.
"""
function setdata!(node::AbstractDataNode, l::Symbol, d) 
    if isportexist(node, l, :output) 
        node.data[l] = d
        return true
    end
    error("Wrong port label")
end

"""
    getinputdata(node::AbstractDataNode, l::Symbol)

Read value from node input buffer.

Does NOT consume or clear buffer.
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
    setinputbuffer!(node::AbstractDataNode, label::Symbol, connection_id::Int, value)

Write value into node input buffer.

Used by workflow engine to propagate outputs between nodes.
"""
function setinputbuffer!(node::AbstractDataNode, l::Symbol, con::Int, d)
    #if !haskey(node.input_buffer, l) 
    #    node.input_buffer[l] = Dict{Int, Any}()
    #end
    node.input_buffer[l][con] = d
    node
end


    # Find connections by node id
"""
    find_connections(model::Workflow, id::Int)

Return all connection IDs associated with a node
(both incoming and outgoing).
"""
function find_connections(model::Workflow, id::Int)
    v = Int[]
    if haskey(model.incoming, id)
        append!(v, model.incoming[id])
    end
    if haskey(model.outgoing, id)
        append!(v, model.outgoing[id])
    end
    return v
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

#
function check_connection_validity(model, c::NodeConnection)
    input_id = c.input_id
    output_id = c.output_id
    input_port = c.input_port
    output_port = c.output_port
    # check nodes exist
    haskey(model.nodes, output_id) || error("Output (parent) node  doesn't exist")
    haskey(model.nodes, input_id)  || error("Input (child) node doesn't exist")
    # check ports exist
    isportexist(model.nodes[output_id], output_port, :output) || error("Output node port $output_port doesn't exist")
    isportexist(model.nodes[input_id], input_port, :input) || error("Input node port $input_port doesn't exist")

    if haskey(model.incoming, input_id)
        if length(model.incoming[input_id]) > 0
            for cid in model.incoming[input_id]
                existed_con = model.connections[cid]
                if existed_con.input_port == input_port error("Node port occupied by another connection") end
            end
        end 
    end
    out_type = getporttype(model.nodes[output_id], output_port, :output)
    in_type  = getporttype(model.nodes[input_id], input_port, :input)

    out_type <: in_type || error("Type mismatch")
    true
end
"""
    add_connection!(model::Workflow, c::NodeConnection)

Add connection to workflow.

Performs:
- connection validation,
- connection registration,
- incoming/outgoing index updates.

If the source node already has status `:clean`,
its output data is immediately propagated into
the target node input buffer.

# Returns
Assigned connection identifier (`Int`).
"""
function add_connection!(model::Workflow, c::NodeConnection)::Int
    check_connection_validity(model, c) || return 0
    id = model.c_iter += 1
    model.connections[id] = c
    output_node = getnode(model, c.output_id)
    if getstatus(output_node) == :clean 
        output_data = getdata(output_node, c.output_port)
        input_node  = getnode(model, c.input_id)
        #@port = getportspec(input_node, c.input_port, :input)
        setinputbuffer!(input_node, c.input_port, id, output_data) # id - connection id 
    end
    # Add index
    push!(get!(model.incoming, c.input_id, Int[]), id)
    push!(get!(model.outgoing, c.output_id, Int[]), id)
    return id
end
function add_connection!(model::Workflow, id_out::Int, port_out::Symbol, id_in::Int, port_in::Symbol)
    connection = NodeConnection(id_out, port_out, id_in, port_in)
    return add_connection!(model, connection)
end

"""
    delete_connection!(model::Workflow, id::Int)

Remove connection from workflow.

Performs:
- deletion of corresponding child input buffer entry,
- removal from incoming/outgoing indices,
- deletion from workflow connection storage.

# Returns
- `true` if connection existed and was removed.
- `false` otherwise.
"""
function delete_connection!(model::Workflow, id::Int)
    if haskey(model.connections, id)
        c = model.connections[id]
        # Удаляем буфер
        input_node = getnode(model, c.input_id)
        invalidate_buffer!(input_node, c.input_port, id)
        # Удаляем индексы
        filter!(x -> x != id, model.outgoing[c.output_id])
        filter!(x -> x != id, model.incoming[c.input_id])
        # Удаляем связь
        delete!(model.connections, id) 
        return true
    end
    return false
end
"""
    add_node!(model::Workflow, node::AbstractDataNode)

Add node to workflow.

Assigns a new unique node identifier
and registers the node in workflow storage.

# Returns
Assigned node identifier (`Int`).
"""
function add_node!(model::Workflow, node::AbstractDataNode)
    id = model.n_iter += 1
    setid!(node, id)
    model.nodes[id] = node
    return id
end
"""
    delete_node!(model::Workflow, id::Int)

Remove node from workflow.

Performs:
- deletion of all incoming and outgoing connections,
- cleanup of connection indices,
- removal of node from workflow storage.

# Returns
- `true` if node existed and was removed.
- `false` otherwise.
"""
function delete_node!(model::Workflow, id::Int)
    if haskey(model.nodes, id)
        # Находим связи
        cons = find_connections(model, id)
        # Если есть - удаляем связи
        if length(cons) > 0
            for k in cons
                delete_connection!(model, k)
            end
        end
        # Удаляем ноду
        delete!(model.nodes, id) 
        # delete index if exist
        if haskey(model.incoming, id) delete!(model.incoming, id)  end
        if haskey(model.outgoing, id) delete!(model.outgoing, id) end
        return true
    end
    return false
end
    #  Ищем родителей (входящие соединения ноды)
"""
    get_parents(model::Workflow, id::Int)

Return parents - id vector
"""
function get_parents(model::Workflow, id::Int)
    v = Dict{Symbol, Int}()
    if haskey(model.nodes, id) 
        # Ищем все входящие соединения
        for cid in get(model.incoming, id, Int[])
            conn = model.connections[cid]
            v[conn.input_port] = conn.output_id
        end
    end
    return v
end
    #  Ищем детей (исходящие соединения ноды)
"""
    get_children(model::Workflow, id::Int)

Get children.
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

"""
    reset!(model::Workflow)

Reset workflow execution state.

Marks every node in the workflow as `:dirty` using [`mark_dirty!`](@ref),
clears node execution state, and removes all cached output data.
"""
function reset!(model::Workflow)
    for (k, node) in model.nodes
        mark_dirty!(node)
    end
    model
end
"""
    reset_status!(model::Workflow)

Reset only node statuses.

Sets status of every node in the workflow to `:dirty`.
"""
function reset_status!(model::Workflow)
    for (k, v) in model.nodes
        setstatus!(v, :dirty)
    end 
end
"""
    mark_dirty!(node::AbstractDataNode)

Invalidate node execution result.

Performs the following operations:
- sets node status to `:dirty`,
- clears `ready_ports`,
- clears cached output data stored in `node.data`.

This function intentionally does **not** clear:
- node settings,
- input buffer,
- execution logs,
- execution counters/state metadata.
"""
function mark_dirty!(node::AbstractDataNode)
    setstatus!(node, :dirty)
    empty!(node.state[:ready_ports])
    empty!(node.data)
    node
end
"""
    invalidate_downstream!(model::Workflow, id::Int)

Recursively invalidate all downstream nodes.

Marks the specified node and all descendant nodes as `:dirty`
using [`mark_dirty!`](@ref).

The traversal follows all outgoing connections recursively.
"""
function invalidate_downstream!(model::Workflow, id::Int)
    node = getnode(model, id)
    if getstatus(node) != :dirty
        mark_dirty!(node)
        children = get_children(model, id)
        for (op, c, ip) in children
            children_node = getnode(model, c)
            # delete oly port buffer
            invalidate_buffer!(children_node, ip, id)
            #delete!(children_node.input_buffer, ip)
            # if not, can be multiple ivalidation runs in 2 or more connections 
            invalidate_downstream!(model, c)
        end
    end
    
end
function invalidate_buffer!(node::AbstractDataNode, l::Symbol, con::Int)
    delete!(node.input_buffer[l], con)
    return node
end

"""
    setsettings!(model::Workflow, id::Int, settings::Dict{Symbol, <: Any})

Apply new node settings and invalidate dependent nodes.

Settings are applied using
[`setsettings_unsafe!`](@ref),
after which the target node and all downstream nodes
are invalidated via [`invalidate_downstream!`](@ref).

# Notes
This function is the safe high-level entry point
for mutating node configuration inside a workflow.
"""
function setsettings!(model::Workflow, id::Int, settings::Dict{Symbol, <: Any})
    node = getnode(model, id)
    setsettings_unsafe!(node, settings)
    invalidate_downstream!(model, id)
    node
end
"""
    setsettings_unsafe!(node::AbstractDataNode, settings::Dict{Symbol, <: Any})

Direct mutation of node settings without invalidation. Can be re-implemented for every node type.

Default implementation copies all provided key-value pairs into `node.settings`.

# Warning
This function does NOT invalidate cached execution results or downstream nodes.

Use [`setsettings!`](@ref) for normal workflow operation
"""
function setsettings_unsafe!(node::AbstractDataNode, settings::Dict{Symbol, <: Any})
    for (k, v) in settings
        node.settings[k] = v
    end
    node
end



"""
    isready(model::Workflow, id::Int)

Check whether node is ready for execution.

A node is considered ready when:
- all parent nodes connected through incoming edges have status `:clean`.

# Notes
- Current node status itself is not checked.
- Input buffer completeness is validated separately via
  [`execution_node_validation`](@ref).
"""
function isready(model::Workflow, id::Int)
    node = getnode(model, id)
    connections = get(model.incoming, id, Int[])
    for con_id in connections
        con = getconnection(model, con_id)
        parent_node = getnode(model, con.output_id)
        if getstatus(parent_node) != :clean return false end  
    end
    # проверить статус самого узла?
    return true
end


"""
    validate_node(node::AbstractDataNode)

Validate node structure and configuration.

Default implementation always returns `true`.

This function is intended for specialization by concrete node implementations.

Typical validation rules may include:
- internal consistency checks,
- structural constraints,
- node-specific invariants.

# Returns
- `true` if node structure is valid.
- `false` otherwise.
"""
function validate_node(node::AbstractDataNode)
    true
end
function validate_node(model::Workflow, node_id::Int)
    validate_node(getnode(model, node_id))
end

"""
    execution_node_validation(node::AbstractDataNode)

Internal function. Validate node readiness before execution.

Checks that:
- every declared input port has a corresponding value
  in `node.input_buffer`,
- [`validate_node`](@ref) succeeds.

This validation is intended for runtime execution safety,
ensuring that all required inputs are available before
calling [`execute_unsafe!`](@ref).

# Returns
- `true` if node is ready for execution.
- `false` otherwise.
"""
function execution_node_validation(node::AbstractDataNode, check_input_buffer::Bool = true)
    # All ports must have something in input_buffer if port is required
    if check_input_buffer
        return all(x-> length(node.input_buffer[x.label]) > 0 || !x.required, node.spec.input_ports) && validate_node(node)
    else
        return validate_node(node)
    end
end


"""
    validate_settings(node::AbstractDataNode) 

Validate node settings before execution.

Default implementation always returns `true`.

This function is intended for specialization by concrete node implementations.

Typical validation rules may include:
- required setting presence,
- range checks,
- semantic validation of configuration values.

# Returns
- `true` if settings are valid.
- `false` otherwise.
"""
function validate_settings(node::AbstractDataNode) 
    # not used yet
    true
end
function validate_settings(model::Workflow, node_id::Int)
    validate_settings(getnode(model, node_id))
end
"""
    validate_result(node::AbstractDataNode)

Validate node execution result.

Called after node execution completes.

Default implementation always returns `true`.

This function is intended for specialization by concrete node implementations.

Typical validation rules may include:
- output datatype verification,
- required output ports presence,
- shape or schema validation,
- domain-specific consistency checks.

# Returns
- `true` if execution result is valid.
- `false` otherwise.
"""
function validate_result(node::AbstractDataNode)
    true
end
function validate_result(model::Workflow, node_id::Int)
    validate_result(getnode(model, node_id))
end

function push_buffer!(model::Workflow, id::Int)
    node = getnode(model, id)
    ready_ports = node.state[:ready_ports]
    return push_buffer!(model::Workflow, id::Int, ready_ports)
end
function push_buffer!(model::Workflow, id::Int, port::Symbol)
    node = getnode(model, id)
    ready_ports = Symbol[port]
    return push_buffer!(model::Workflow, id::Int, ready_ports)
end
function push_buffer!(model::Workflow, id::Int, ready_ports::Vector{Symbol})
    node = getnode(model, id)
    haskey( model.outgoing, id) || return model
    for cid in model.outgoing[id]
        con = model.connections[cid]
        con.output_port in ready_ports || continue
        child = getnode(model, con.input_id)
        child.input_buffer[con.input_port][cid] = getdata(node, con.output_port)
    end
    return model
end

    # Main executing
    # :clean, :dirty, :executing, :failed
"""
    execute!(model::Workflow, id::Int; execute_upstream::Bool = true, invalidate_downstream::Bool = true, check_cyclic::Bool = true)

Execute workflow node.

Main workflow execution entry point.

# Execution Stages
1. Initialize per-run execution state and logs.
2. Optionally detect recursive cyclic execution.
3. Skip execution for nodes already marked `:clean`.
4. Mark node as `:executing`.
5. Optionally execute upstream dependencies recursively.
6. Validate node structure and execution readiness.
7. Validate node settings.
8. Execute node implementation via [`execute_unsafe!`](@ref).
9. Store execution state (`ready_ports`).
10. Propagate outputs downstream through input buffers.
11. Optionally invalidate downstream nodes.
12. Validate execution result.
13. Mark node as `:clean`.

# Arguments
- `execute_upstream`:
  recursively execute all parent nodes before executing current node.
- `invalidate_downstream`:
  invalidate downstream execution results after successful execution.
- `check_cyclic`:
  detect recursive execution loops during direct execution calls.

# Returns
Vector of output port labels (`Vector{Symbol}`) produced during execution.
"""
function execute!(model::Workflow, id::Int; settings::ExecuteSettings = ExecuteSettings()) 
    node =  getnode(model, id)

    if getstate(node, :execution_id) != model.run_id
        empty!(getstate(node, :log))
        setstate!(node, :execution_id, model.run_id)
    end

    if settings.check_cyclic
        # Это обнаружит цикл только при повторном заходе в тот же узел в рамках одного вызова. 
        # Не является настоящей защитой от циклов (реализовано в scheduler!)
        if getstatus(node) == :executing
            @warn "Ring detected"
            return Symbol[]
        end
    end
    #
    if getstatus(node) == :clean
        # clean node - no need for executing
        return getstate(node, :ready_ports)
    end
    #
    # need to catch errors...
    setstatus!(node, :executing)
    # Check and execute parent nodes
    # execute_upstream should bu use carefully
    if settings.execute_upstream
        if length(model.nodes) > 1000 @warn "A large number of nodes (nodes count = $(length(model.nodes))) can cause stack overflow." end
        parents = get_parents(model, id)
        for (k,p) in parents
            execute!(model, p; settings = settings)
        end
    end
    # Check is valid 
    if !execution_node_validation(node, settings.check_input_buffer)
        setstatus!(node, :invalid_node)
        return Symbol[]
    end
    if !validate_settings(node)
        setstatus!(node, :invalid_settings)
        return Symbol[]
    end
    # Execute node
    ready_ports = execute_unsafe!(node)
    # Save state ready_ports
    setreadyports!(node, ready_ports)
    # push outputs for each ready port
    push_buffer!(model, id)
    # Invalidate children
    if settings.invalidate_downstream
        children = get_children(model, id)
        for (op, c, ip) in children
            invalidate_downstream!(model, c)
        end
    end
    # Post-execution validation
    if !validate_result(node)
        setstatus!(node, :invalid_result)
        return Symbol[]
    end
    #
    setstatus!(node, :clean)
    return ready_ports
end

"""
    execute_unsafe!(node::AbstractDataNode)

Low-level node execution interface.

This function contains node-specific execution logic.

The default implementation throws an error and must be specialized for every executable node type.
"""
function execute_unsafe!(node::AbstractDataNode)
    error("Node type undefined")
end
   
    # --------------------------------------------------------
    # support functions
    # --------------------------------------------------------
"""
    isnodeexist(model::Workflow, id::Int)
"""
function isnodeexist(model::Workflow, id::Int)
    return haskey(model.nodes, id)
end

# --------------------------------------------------------
# Graph builder
# --------------------------------------------------------
function makegraph(model::Workflow)
    g = NamedDiGraph{Int}()
    for (k, v) in model.nodes
        add_vertex!(g, k)
    end
    for (k, v) in model.connections
        add_edge!(g, v.output_id, v.input_id)
    end
    g
end


    # --------------------------------------------------------
    # Scheduler functions
    # --------------------------------------------------------
"""
    scheduler!(model::Workflow{DAW})

Execute entire data analysis workflow (DAW) using topological ordering.

This scheduler is designed for deterministic acyclic data-analysis workflows.

# Execution Steps
1. Build workflow graph.
2. Validate graph acyclicity.
3. Generate new workflow `run_id`.
4. Reset node execution states.
5. Execute nodes in topological order.

# Notes
- Nodes are executed exactly once per scheduler run.
- Upstream execution and downstream invalidation are disabled
  because execution order is already guaranteed by topology.
- Cyclic workflows are rejected before execution starts.
"""
function scheduler!(model::Workflow{DAW})
    g = makegraph(model)
    if is_cyclic(g) error("workflow is cyclic") end
    model.run_id = rand(UInt64) # change to thread safe
    reset!(model)

    order = topological_sort(g)
    for id in order
        execute!(model, id; settings = ExecuteSettings(;execute_upstream = false, invalidate_downstream = false, check_cyclic = false)) 
    end
    return true
end
"""
    scheduler!(model::Workflow{ABW}; maxiter = 1000)

Execute workflow using queue-based agent/event scheduling.

This scheduler is intended for dynamic or agent-based workflows (ABW), where execution readiness is determined during runtime.

# Arguments
- `maxiter`:
  maximum number of scheduler iterations before aborting execution.
"""
function scheduler!(model::Workflow{ABW}; maxiter = 1000)
    # change to thread safe
    model.run_id = rand(UInt64)
    for (id, node) in model.nodes
        setstatus!(node, :dirty)
    end
    queued = Set{Int}() # Ноды которые уже добавлены - не реализовано
    queue = Int[]
    #
    for (id, node) in model.nodes
        if !haveinputs(node)
            push!(queue, id)
            push!(queued, id)
        end
    end
    # execute
    iter = 0
    while length(queue) > 0
        if iter > maxiter
            error("max iterations reached")
        end
        id = popfirst!(queue)
        delete!(queued, id)
        if isready(model, id)
            ready_ports = execute!(model, id; settings = ExecuteSettings(false))
            for port in ready_ports
                cons = getportconnections(model, id, port; direction = :output)
                for con in cons
                    # добавляем только если нет в очереди
                    if !(con.input_id in queued)
                        push!(queue, con.input_id)
                        push!(queued, con.input_id)
                    end
                end
            end
        end
        iter += 1
    end
    return true
end

# --------------------------------------------------------
# SHOW functions
# --------------------------------------------------------
function show(io::IO, n::AbstractDataNode)
    println(io, "Node:")
    println(io, "  ID: ", getid(n))
    println(io, "  Status: ", getstatus(n))
    println(io, "  spec:")
    println(io, n.spec)
    print(io, "  Settings:", n.settings)
end

#
function show(io::IO, n::NodeSpec)
    println(io, "     Name: ", n.name)
    print(io, "     Input ports: ")
    if length(n.input_ports) == 0 
        println(io, "empty")
    else
        println(io, "")
        for (i,p) in enumerate(n.input_ports)
            print(io, "        #$i ", p)
        end
    end
    print(io, "     Output ports: ",)
    if length(n.output_ports) == 0 
        println(io, "empty")
    else
        println(io, "")
        for (i,p) in enumerate(n.output_ports)
            print(io, "        #$i ", p)
        end
    end
    println(io, "     Available settings: ", n.settings)
end

function show(io::IO, n::PortSpec)
    println(io, "Port name: $(n.name); label: \"$(n.label)\"; datatype: $(n.datatype).")
end

function show(io::IO, c::T) where T <: NodeConnection
    println(io, "Node Connection:")
    println(io, "  Output node ID: ", c.output_id, " (Output port: ", c.output_port , ")")
    print(io, "  Input node ID: ", c.input_id, " (Input port: ", c.input_port, ")")
end

# --------------------------------------------------------
# STRUCT TO DICT FOR JSON
# --------------------------------------------------------
"""
    settings_schema(node::AbstractDataNode) -> Dict

Default settings schema.
"""
function settings_schema(node::AbstractDataNode)
    d  = Dict{Symbol, Any}()
    d[:settingslist] = copy(node.spec.settings)
    settings_schema_usermod!(d, node::AbstractDataNode)
    return d
end
"""
    settings_schema_usermod!(d, node::AbstractDataNode) -> Dict

Modify settings schema for user-defined node types.

Possible user modifications:

```julia
settings_schema_usermod!(d, node::DataNode{MyNodeType})
    settings_dict = Dict{Symbol, Any}()
    settings_dict[:my_setting1] = Dict(:type => Int, 
        :default => 0, 
        :description => "My setting 1", 
        :required => true, 
        :pinned => true,
        :source	=> "upstream",
        :validator => (x -> x >= 0))
        
    settings_dict[:my_setting2] = Dict(:type => Array{Int}, 
        :default => [0], 
        :description => "My setting 2", 
        :required => true, 
        :pinned => false,
        :source	=> "none",
        :validator => (x -> x in [1,2,3]))
    d[:schema] = settings_dict
end
```
"""
function settings_schema_usermod!(d, node::AbstractDataNode)
    return d
end
"""
    node_schema(node::AbstractDataNode) -> Dict

Default node schema.
"""
function node_schema(node::AbstractDataNode)
    d  = Dict{Symbol, Any}()
    d[:settings_schema] = settings_schema(node)
    d[:spec]            = spec_to_dict(node.spec)
    node_schema_usermod!(d, node::AbstractDataNode)
    return d
end
"""
    node_schema_usermod!(d, node::AbstractDataNode) -> Dict

Modify node schema for user-defined node types.

Possible user modifications:

```julia
node_schema_usermod!(d, node::AbstractDataNode)
    d[:section]   = "Section 1"
    d[:groupname] = "Group 1"
    d[:color]     = "#8b5cf6"
end
```
"""
function node_schema_usermod!(d, node::AbstractDataNode)
    return d
end
"""
    node_to_dict(node::AbstractDataNode; specs::Bool = true) -> Dict

Convert node to JSON-serializable dictionary.
"""
function node_to_dict(node::AbstractDataNode; specs::Bool = true, settings::Bool = true)
    d                = Dict{Symbol, Any}()
    d[:id]           = getid(node)
    d[:properties]   = node_properties_to_dict(node.properties)
    if specs
        d[:spec]     = spec_to_dict(node.spec)
    end
    d[:status]       = getstatus(node)
    if settings
        d[:settings] = settings_schema(node)
    end
    return d
end
"""
    node_properties_to_dict(np::NodeProperties) -> Dict

Convert node properties to JSON-serializable dictionary.
"""
function node_properties_to_dict(np::NodeProperties)
    d            = Dict{Symbol, Any}()
    d[:id]       = np.id
    d[:status]   = np.status
    d[:position] = np.position
    return d
end
"""
    spec_to_dict(spec::NodeSpec) -> Dict

Convert NodeSpec to dictionary representation.
"""
function spec_to_dict(spec::NodeSpec)
    d                = Dict{Symbol, Any}()
    d[:name]         = spec.name
    d[:input_ports]  = [portspec_to_dict(i) for i in spec.input_ports]
    d[:output_ports] = [portspec_to_dict(i) for i in spec.output_ports]
    d[:settings]     = copy(spec.settings)
    return d
end
"""
    portspec_to_dict(ps::PortSpec) -> Dict

Convert PortSpec to dictionary representation.
"""
function portspec_to_dict(ps::PortSpec)
    d            = Dict{Symbol, Any}()
    d[:name]     = ps.name
    d[:label]    = ps.label
    d[:datatype] = string(ps.datatype)
    d[:required] = ps.required
    d[:type]     = portspec_to_dict_type(ps)
    return d
end
function portspec_to_dict_type(ps::PortSpec{MultiPort})
    return "MultiPort"
end
function portspec_to_dict_type(ps::PortSpec{SinglePort})
    return "SinglePort"
end
"""
    connection_to_dict(conn::NodeConnection) -> Dict

Convert connection to dictionary representation.
"""
function connection_to_dict(nc::NodeConnection)
    d               = Dict{Symbol, Union{Int, Symbol}}()
    d[:output_id]   = nc.output_id
    d[:output_port] = nc.output_port
    d[:input_id]    = nc.input_id
    d[:input_port]  = nc.input_port
    return d
end
"""
    workflow_to_dict(w::Workflow) -> Dict

Convert workflow to dictionary representation.
"""
function workflow_to_dict(w::Workflow)
    d               = Dict{Symbol, Any}()
    d[:id]          = w.id
    d[:name]        = w.name
    d[:n_iter]      = w.n_iter
    n               = Dict{Symbol, Dict}()
    for (k,v) in w.nodes
        n[string(k)] = node_to_dict(v)
    end
    d[:nodes]       = n
    d[:c_iter]      = w.c_iter
    c               = Dict{Symbol, Dict}()
    for (k,v) in w.connections
        c[string(k)] = connection_to_dict(v)
    end
    d[:connections] = c
    i               = Dict{Symbol, Dict}()
    for (k,v) in w.incoming
        i[string(k)] = v
    end
    d[:incoming]    = i
    o               = Dict{Symbol, Dict}()
    for (k, v) in w.outgoing
        o[string(k)] = v
    end
    d[:outgoing]    = o
    return d
end
# End Module:
end
