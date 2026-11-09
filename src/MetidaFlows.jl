"""
    MetidaFlows
 
A lightweight, node-based workflow engine for analytical pipelines.
 
A workflow is a directed graph of [`DataNode`](@ref)s wired through typed
ports. Every node declares its interface with a [`NodeSpec`](@ref); the engine
validates connections, moves values between nodes through input buffers,
tracks node status and recomputes only what became stale.
 
Two execution models are available:
 
- [`DAW`](@ref) - deterministic data analysis workflow, executed in topological order;
- [`ABW`](@ref) - agent-based workflow, executed from a readiness queue.
"""

module MetidaFlows

using NamedGraphs
using Dates

import NamedGraphs: add_vertex!, add_edge!, is_cyclic

import NamedGraphs.Graphs: topological_sort

import Base: show, keys, getindex, setindex!, empty!

export AbstractNodeType, 
NodeSpec,
PortSpec,
DataNode, 
NodeConnection, 
Workflow,
ExecuteSettings, 
add_node!,
delete_node!,
add_connection!, 
delete_connection!,
setsettings!,
setdata!,
scheduler!,
execute!,
getstatus,
getdata,
getinputdata,
getmeta,
getinputmeta,
isnodeexist,
isportexist,
failed_nodes,
check_failed_nodes
#=
# In publick API, but not exported:
# Execution:

execute_unsafe!,
validate_node,
validate_settings, 
validate_result,

# Serialization and schemas:

workflow_to_dict,
node_to_dict, 
node_properties_to_dict,
spec_to_dict, 
portspec_to_dict,
connection_to_dict,

settings_schema,
node_schema,

ismetasource,
getmeta_unsafe,
=#
#
"""
    AbstractDataNode
 
Supertype of workflow nodes. The package ships one concrete implementation, [`DataNode`](@ref); generic functions dispatch on this abstract type.
"""
abstract type AbstractDataNode end
#
"""
    AbstractNodeType
 
Supertype of node *behaviour* tags. A user-defined node type is a singleton
subtype used as the first type parameter of [`DataNode`](@ref); execution and
validation are attached to it through multiple dispatch:
 
```julia
struct MyNode <: AbstractNodeType end
 
function MetidaFlows.execute_unsafe!(node::DataNode{MyNode})
    setdata!(node, :out, 42)
    return [:out]
end
```
"""
abstract type AbstractNodeType end
#
abstract type AbstractAuditEvent end
#
"""
    WorkFlowType
 
Supertype of workflow execution models. Concrete subtypes ([`DAW`](@ref),
[`ABW`](@ref)) parameterise [`Workflow`](@ref) and select the
[`scheduler!`](@ref) implementation.
"""
abstract type WorkFlowType end
#
"""
    DAW <: WorkFlowType
 
Data Analysis Workflow: a deterministic acyclic graph. Its scheduler rejects
cyclic graphs, resets every node and executes the whole graph in topological
order, each node exactly once per run.
"""
struct DAW <: WorkFlowType end # Data Analysis Workflow
"""
    ABW <: WorkFlowType
 
Agent-Based Workflow: execution is driven by a readiness queue instead of a
fixed topological order. Nodes without input ports seed the queue, and every
executed node enqueues the children attached to its ready output ports.
"""
struct ABW <: WorkFlowType end # Agent-Based Workflow

"""
    LogMsg(id::UInt64, timestamp::DateTime, level::Symbol, message::String)
    LogMsg(level::Symbol, message::String)
 
Log record kept in `Workflow.log` and in the node execution state.
 
The two-argument form generates a random `id` and stamps the current time.
Records are currently produced in one place only: [`execute!`](@ref) appends
an `:error` record to `workflow.log` when [`execute_unsafe!`](@ref) raises.
"""
struct LogMsg
    id::UInt64
    timestamp::DateTime
    level::Symbol
    message::String
    function LogMsg(id, timestamp, level, message)
        new(id,
        timestamp, 
        level, 
        message)
    end
    function LogMsg(level, message)
        LogMsg(rand(UInt64), # change to thread safe
        now(), 
        level, 
        message)
    end
end
#
"""
    AbstractNodeFields
 
Supertype of the node field containers: [`NodeState`](@ref) and the reserved
`AbstractNodeSettings`, `AbstractNodeData`, `AbstractNodeInputBuffer`.
 
Subtypes get a `Dict`-like interface over their fields, so a node can be
backed either by plain `Dict`s (the default) or by purpose-built structs:
 
```julia
state = NodeState()
state[:exec_n]         # getindex  -> getfield
state[:exec_n] = 1     # setindex! -> setfield! (mutable subtypes only)
keys(state)            # (:exec_n, :ready_ports, :execution_id, :log)
```
 
`setindex!` raises an error for immutable subtypes.
"""
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
Base.keys(obj::AbstractNodeFields) = fieldnames(typeof(obj))

"""
    ExecuteSettings(; execute_upstream = true, invalidate_downstream = true,
                      check_cyclic = true, check_input_buffer = true)
    ExecuteSettings(execute_upstream, invalidate_downstream, check_cyclic, check_input_buffer)
    ExecuteSettings(all_flags::Bool)

Execution flags consumed by [`execute!`](@ref):

- `execute_upstream` - recursively execute parent nodes first;
- `invalidate_downstream` - invalidate child nodes after successful execution;
- `check_cyclic` - detect re-entrant execution of the same node (`Ring detected`);
- `check_input_buffer` - require data on every `required` input port.

The single-argument form sets all four flags to the same value.
"""
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
"""
    NodeState()
 
Per-node execution state with dict-like field access:
 
- `exec_n::Int` - number of times [`execute_unsafe!`](@ref) was entered since
  the last full reset. Incremented by [`execute!`](@ref) right before the node
  body runs, so a node rejected by validation leaves it unchanged while a
  failed node does not.
 
  Zeroed by `reset!(model)` in every reset mode, by `reset!(node)` and by
  `empty!(state)` — but **not** by [`mark_dirty!`](@ref), so invalidating a
  subtree does not lose the count. In a cyclic [`ABW`](@ref) run the counter
  therefore holds the number of loop turns, and a node may read its own
  `node.state[:exec_n]` inside [`execute_unsafe!`](@ref) as the current turn
  number;
- `ready_ports::Vector{Symbol}` - output ports produced by the last successful execution (used by [`push_buffer!`](@ref));
- `execution_id::UInt64` - id of the run that last touched the node;
- `log::Vector{LogMsg}` - per-run node log (cleared at the start of a run).
 
Reset in place with `empty!(state)`.
"""
mutable struct NodeState <: AbstractNodeState
    exec_n::Int
    ready_ports::Vector{Symbol}
    execution_id::UInt64
    log::Vector{LogMsg}
    function NodeState()
        new(0, Symbol[], 0, LogMsg[])
    end
end 
"""
    Base.empty!(ns::NodeState)

Empty node execution state.
"""
function Base.empty!(ns::NodeState)
    ns.exec_n = 0
    empty!(ns.ready_ports)
    ns.execution_id = 0
    empty!(ns.log)
end
#
"""
    AbstractPortType
 
Supertype of port arity tags: [`SinglePort`](@ref) and [`MultiPort`](@ref).
"""
abstract type AbstractPortType end
"""
    MultiPort

Port type that accepts any number of connections;
[`getinputdata`](@ref) returns the whole buffer `Dict(connection_id => value)`.
"""
struct MultiPort <: AbstractPortType end
"""
    SinglePort

Port type that accepts at most one connection (the default);
[`getinputdata`](@ref) returns the single buffered value or `nothing`.
"""
struct SinglePort <: AbstractPortType end
#
"""
    PortSpec(name, datatype, label, ::T = SinglePort(); required::Bool = true,
             kind::Symbol = :normal) where T <: AbstractPortType
 
Specification of a node port.
 
Fields:
- `name::String` - human-readable name of the port.
- `datatype::Type` - Julia type of the port data (connection type checking).
- `label::Symbol` - unique label used for referencing the port in code.
- `required::Bool` - whether the port must have buffered data for execution.
- `kind::Symbol` - how the schedulers treat connections attached to the port.
 
The optional positional argument selects the port arity:
[`SinglePort`](@ref) (default) or [`MultiPort`](@ref).
 
# Port kinds
| `kind` | Meaning |
|---|---|
| `:normal` | an ordinary data connection: [`isready`](@ref) waits for its producer and [`execution_node_validation`](@ref) requires a value when `required` |
| `:feedback` | **input ports only**: closes a cycle and carries the value of the previous iteration. Not waited for, not required |
| `:terminal` | a slot for a result that is not meant to be connected |
| `:error` | reserved for error routing; must be `required = false` and its `datatype` must be a subtype of `Exception` |
 
Constraints are checked at construction time. `kind = :feedback` on an
**output** port is rejected by the [`NodeSpec`](@ref) constructor: a delay is a
property of the consumer, not of the producer.
 
Only [`isready`](@ref) and [`execution_node_validation`](@ref) read the kind.
Buffering, invalidation and serialization are identical for all kinds.
 
# Example
```julia
PortSpec("value", Int, :val)                                  # required single port
PortSpec("items", Int, :vals, MultiPort())                    # multi-connection port
PortSpec("hint",  Int, :in; required = false)                 # optional port
PortSpec("state", Int, :prev; kind = :feedback)                # closes a cycle
PortSpec("report", DataFrame, :out; kind = :terminal)          # result slot
```
"""
struct PortSpec{T <: AbstractPortType}
    name::String
    datatype::Type
    label::Symbol
    required::Bool
    kind::Symbol
    function PortSpec(name, datatype, label, ::T = SinglePort(); required::Bool = true, kind::Symbol = :normal) where T <: AbstractPortType
        if kind ∉ (:normal, :terminal, :feedback, :error)
            error("Invalid port kind: $kind (use only :normal, :terminal, :feedback, :error)")
        end
        if kind == :error && required
            error("Error ports cannot be required")
        end
        if kind == :error && !(datatype <: Exception)
            error("Error ports must have a supertype of Exception")
        end
        new{T}(name, datatype, label, required, kind)
    end
end
#
"""
    NodeSpec(name, input_ports, output_ports, settings)
    NodeSpec(name, input_ports, output_ports)

Static description of a node interface: its ports and the settings keys it
understands. The spec is the single source of truth - a port label that is not
listed here is rejected by [`getdata`](@ref), [`setdata!`](@ref),
[`getinputdata`](@ref) and by connection validation.
 
Fields:
- `name::String` - human-readable node name.
- `input_ports::Vector{PortSpec}`, `output_ports::Vector{PortSpec}` - port specifications.
- `settings::Vector{Symbol}` - settings keys advertised through the node schema.
- `portmap::Dict{Tuple{Symbol,Symbol}, Int}` - `(direction, label) => port index`, built by the constructor.
 
# Example
```julia
spec = NodeSpec("Filter",
    [PortSpec("Input table", DataFrame, :table)],
    [PortSpec("Filtered table", DataFrame, :table)],
    [:column, :threshold])
```
"""
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
            if v.kind == :feedback
                error("Output port $(v.label) cannot be of kind :feedback")
            end
            portmap[(:output, v.label)] = i
        end
        new(name, input_ports, output_ports, settings, portmap)
    end
    function NodeSpec(name, input_ports, output_ports)
        NodeSpec(name, input_ports, output_ports, Symbol[])
    end
end

#
"""
    NodeProperties(id, status, position)

Mutable node identity and presentation data: the workflow-assigned `id`, the
execution `status` (see [`getstatus`](@ref)) and the graph editor `position`.
The zero-argument form creates `(0, :idle, (0, 0))`.
"""
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
"""
    NodeConnection(output_id, output_port, input_id, input_port)

Directed edge from an output port of the parent node (`output_id`) to an input
port of the child node (`input_id`).
 
Connections are stored under an integer identifier, and that identifier is
also the key used inside the child input buffer - so several connections can
feed one [`MultiPort`](@ref) without overwriting each other.
"""
struct NodeConnection
    output_id::Int       # parent node id
    output_port::Symbol  # parent node port
    input_id::Int        # child node id
    input_port::Symbol   # child node port
end
# Node
"""
    DataNode(type::Type{T}, properties, spec, settings::SettingsT, data::DataT, state::StateT, input_buffer::Dict{Symbol, Dict{Int, BufferT}} ) where T <: AbstractNodeType where SettingsT where DataT  where StateT  where BufferT
    DataNode(type::Type, id, status, position, spec; settings = Dict{Symbol, Any}(), data = Dict{Symbol, Any}(), state = NodeState(), input_buffer = Dict{Symbol, Dict{Int, Any}}())
    DataNode(type::Type, spec; settings = Dict{Symbol, Any}(), data = Dict{Symbol, Any}(), state = NodeState(), input_buffer = Dict{Symbol, Dict{Int, Any}}())

Concrete workflow node.
 
The first type parameter is the user-defined behaviour tag
([`AbstractNodeType`](@ref)) on which [`execute_unsafe!`](@ref) and the
validation hooks dispatch; the remaining parameters are the types of the
containers, so a node can be backed by plain `Dict`s (the default) or by
custom structs.
 
Fields:
- `properties::NodeProperties` - id, status, position.
- `spec::NodeSpec` - port and settings interface.
- `settings` - configuration values (`Dict{Symbol, Any}` by default).
- `data` - cached output values, keyed by output port label.
- `state` - execution state ([`NodeState`](@ref) by default).
- `input_buffer` - `input_buffer[port label][connection id] = value`.
 
The constructor creates an empty buffer entry for every input port declared in
`spec` and rejects buffer keys that are not input ports.
 
# Example
```julia
node = DataNode(MyNode, spec)
id   = add_node!(workflow, node)
```
"""
struct DataNode{T <: AbstractNodeType, SettingsT, DataT, StateT, BufferT} <: AbstractDataNode
    properties::NodeProperties
    spec::NodeSpec
    settings::SettingsT   # Dict{Symbol, Any}() by default
    data::DataT           # Dict{Symbol, Any}() by default
    state::StateT         # NodeState by default
    # input_buffer[port_label][connection_id] = data
    input_buffer::Dict{Symbol, Dict{Int, BufferT}} # Dict{Symbol, Any}() by default
    function DataNode(type::Type{T}, properties::NodeProperties, spec::NodeSpec, settings::SettingsT, data::DataT, state::StateT, input_buffer::Dict{Symbol, Dict{Int, BufferT}} ) where T <: AbstractNodeType where SettingsT where DataT  where StateT  where BufferT
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
    function DataNode(type::Type, id, status, position, spec::NodeSpec; settings = Dict{Symbol, Any}(), data = Dict{Symbol, Any}(), state = NodeState(), input_buffer = Dict{Symbol, Dict{Int, Any}}())
        DataNode(type,  NodeProperties(id, status, position), spec, settings, data, state, input_buffer)
    end
    function DataNode(type::Type, properties::NodeProperties, spec::NodeSpec; settings = Dict{Symbol, Any}(), data = Dict{Symbol, Any}(), state = NodeState(), input_buffer = Dict{Symbol, Dict{Int, Any}}())
        DataNode(type,  properties, spec, settings, data, state, input_buffer)
    end
    function DataNode(type::Type, spec::NodeSpec; settings = Dict{Symbol, Any}(), data = Dict{Symbol, Any}(), state = NodeState(), input_buffer = Dict{Symbol, Dict{Int, Any}}())
        DataNode(type,  NodeProperties(), spec, settings, data, state, input_buffer)
    end
end

"""
    NODE_REGISTER::Dict{String, Tuple{Type, NodeSpec}}
 
Node types that can be restored from a snapshot: `nodetypestr` => (node type,
node specification).
 
A snapshot names a node type with [`nodetypestr`](@ref), and this table is what
turns that name back into a type. A type that is not registered cannot be
loaded, and nothing from a snapshot is ever resolved as a Julia name - which is
why loading an untrusted file cannot execute anything.
 
See [`register_node!`](@ref), [`isregistered`](@ref),
[`getregnodeinfo`](@ref), [`unregister_all!`](@ref).
"""
const NODE_REGISTER = Dict{String, Tuple{Type, NodeSpec}}()

"""
    register_node!(node::DataNode; overwrite = false, skipmode = false) -> String | Nothing
    register_node!(model::Workflow; skipmode = false) -> Vector{String}
 
Register the type and the specification of a node in [`NODE_REGISTER`](@ref),
so that a snapshot naming it can be restored. Returns the key, which is
[`nodetypestr`](@ref) of the node.
 
Registering a different type under a key already taken raises; `overwrite`
replaces the entry, `skipmode` returns `nothing` instead of raising. The
`Workflow` form walks every node of a graph and returns the keys it added - a
graph normally holds several nodes of one type, so `skipmode = true` is
what you want there.
 
!!! warning "Register from `__init__`, not at top level"
    A package that registers its nodes in top-level code loses the
    registration: the call runs while that package is precompiled, and a
    mutation of another module's global state is not captured in the
    precompiled image. At load time top-level code no longer runs, so the
    register stays empty - with no error at all.
 
    ```julia
    module AcmeNodes
    using MetidaFlows
    struct FancyFilter <: MetidaFlows.AbstractNodeType end
    fancy_spec() = NodeSpec("Fancy filter", PortSpec[], PortSpec[], [:column])
 
    function __init__()
        MetidaFlows.register_node!(DataNode(FancyFilter, fancy_spec()))
    end
    end
    ```
"""
function register_node!(node::DataNode{T}; overwrite = false, skipmode = false) where T
    typestr = nodetypestr(node)
    if isregistered(node) && !overwrite 
        if skipmode
            return nothing
        else
            error("Node $(typestr) alredy exists, use `overwrite = true` to overwrite, or `skipmode = true` to skip existed nodes")
        end
    end
    NODE_REGISTER[typestr] = (T, node.spec)
    typestr
end

"""
    unregister_node!(typestr::AbstractString) -> Bool
    unregister_node!(node::DataNode) -> Bool
 
Remove one node type from [`NODE_REGISTER`](@ref). Returns whether it was
there.
"""
function unregister_node!(typestr::AbstractString)
    key = String(typestr)
    haskey(NODE_REGISTER, key) || return false
    delete!(NODE_REGISTER, key)
    return true
end
unregister_node!(node::T) where T <: DataNode = unregister_node!(nodetypestr(node))

"""
    getregnodeinfo(typestr::String) -> Tuple{Type, NodeSpec}
 
Registered type and specification of a node. Raises, naming the type, when it
is not registered - that name is what tells a user which package is missing.
"""
function getregnodeinfo(typestr::String)
    isregistered(typestr) ||
        error("Node \"$(typestr)\" is not registered, call `register_node!` before deserialization")
    NODE_REGISTER[typestr]
end

"""
    isregistered(node::DataNode) -> Bool
    isregistered(typestr::String) -> Bool
 
Whether a node type is in [`NODE_REGISTER`](@ref).
"""
function isregistered(node::T) where T <: DataNode
    return haskey(NODE_REGISTER, nodetypestr(node))
end
function isregistered(typestr::String)
    return haskey(NODE_REGISTER, typestr)
end

"""
    unregister_all!() -> Bool
 
Empty [`NODE_REGISTER`](@ref). Mostly useful in tests, to start from a known
register.
"""
function unregister_all!()
    empty!(NODE_REGISTER)
    true
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
"""
    Workflow{T <: WorkFlowType}
 
Container holding the nodes, the connections and the connection indices of a workflow.
 
Fields:
- `id`, `name` - workflow identity.
- `nodes::Dict{Int, DataNode}` - nodes by identifier.
- `connections::Dict{Int, NodeConnection}` - connections by identifier.
- `incoming`, `outgoing` - `node id => [connection ids]` indices.
- `n_iter`, `c_iter` - monotonically increasing id counters; identifiers of
  deleted nodes and connections are never reused.
- `run_id` - identifier of the current scheduler run.
- `log`, `audit_log` - reserved for engine-level logging and audit events.
"""
mutable struct Workflow{T <: WorkFlowType}
    id::Int                      # model ID
    name::String                 # Workflow name
    n_iter::Int                  # node iterator
    nodes::Dict{Int, DataNode}   # {Node id, Node}
    c_iter::Int                            # connection iterator
    connections::Dict{Int, NodeConnection} # {Connection id, Connection}
    incoming::Dict{Int, Vector{Int}} # {Node id, [connection ids]} 
    outgoing::Dict{Int, Vector{Int}} # {Node id, [connection ids]}
    run_id::UInt64
    log::Vector{LogMsg}
    audit_log::Vector{AbstractAuditEvent}
end
#
"""
    Workflow(id::Int; type::Symbol = :DAW)

Create a new workflow model with the specified identifier and type.

`type` selects the execution model and the concrete type parameter of the
result: `:DAW` gives a `Workflow{DAW}`, `:ABW` gives a `Workflow{ABW}`.
Any other value raises an error.
"""
function Workflow(id::Int; type::Symbol = :DAW)
    if type == :DAW
        Workflow{DAW}(id, "Default", 0, Dict{Int, DataNode}(), 0, Dict{Int, NodeConnection}(), Dict{Int, Vector{Int}}(), Dict{Int, Vector{Int}}(), 0, LogMsg[], AbstractAuditEvent[])
    elseif type == :ABW
        Workflow{ABW}(id, "Default", 0, Dict{Int, DataNode}(), 0, Dict{Int, NodeConnection}(), Dict{Int, Vector{Int}}(), Dict{Int, Vector{Int}}(), 0, LogMsg[], AbstractAuditEvent[])
    else
        error("Unknown workflow type: $(type) (expected :DAW or :ABW)")
    end
end

"""
    workflowtypestr(w::Workflow) -> String
 
`"DAW"` or `"ABW"`, as written into a snapshot under the `"type"` key.
"""
workflowtypestr(::Workflow{DAW}) = "DAW"
workflowtypestr(::Workflow{ABW}) = "ABW"

function register_node!(model::Workflow; skipmode = false)
    names = String[]
    for (k, node) in model.nodes
        name = node.spec.name
        rn   = register_node!(node; skipmode = skipmode)
        if !isnothing(rn) push!(names, rn) end
    end
    names
end


#worflowtypestr(::Workflow{:ABW}) = "ABW"
#
"""
    nodetypestr(node::DataNode{T}) where T

Return string representation of node type `T`.
"""
function nodetypestr(::DataNode{T}) where T
    string(parentmodule(T), ".", nameof(T))
end

# Include get*
include("getters.jl")

# Include set*
include("setters.jl")

# Include execute function
include("execute.jl")

# Include scheduler!
include("scheduler.jl")

# Include show functions
include("show.jl")

# Include matadata functions
include("meta.jl")

# Include schemas and serialization functions
include("schemas_serialization.jl")

"""
    haveinputs(node::AbstractDataNode)
 
Returns `true` if node has at least one input port defined in its spec.
 
# Notes
A `:feedback` port is still an input port, so a node whose only inputs are
feedback ports also returns `true`. The [`ABW`](@ref) scheduler seeds its
queue with nodes for which this function returns `false`, which is why every
cyclic workflow needs at least one node with no input ports at all - see
[`scheduler!`](@ref).
"""
function haveinputs(node::AbstractDataNode)
    return !isempty(node.spec.input_ports)
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

"""
    isportinspec(p::Symbol, spec::NodeSpec, direction::Symbol)

Check whether label `p` is declared in `spec`. `direction` is `:input`,
`:output` or `:both`; unlike [`isportexist`](@ref), an unknown direction
simply yields `false` instead of raising.
"""
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
"""
    ismultiport(ps::PortSpec{MultiPort})
    ismultiport(ps::PortSpec{SinglePort})

Check whether a port specification is a multiport.
"""
function ismultiport(ps::PortSpec{MultiPort})
    return true
end
function ismultiport(ps::PortSpec{SinglePort})
    return false
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

#
"""
    check_connection_validity(model, c::NodeConnection)

Validate a connection before it is registered. Raises an error unless:
 
- both nodes exist in the workflow;
- both ports exist in the corresponding node specifications;
- the target input port is free, or declared as a [`MultiPort`](@ref);
- the output port datatype is a subtype of the input port datatype.
 
A rejected connection does not consume a connection identifier.
"""
function check_connection_validity(model, c::NodeConnection; throw_error::Bool = true, throw_warn::Bool = true)
    input_id = c.input_id
    output_id = c.output_id
    input_port = c.input_port
    output_port = c.output_port
    # check nodes exist
    haskey(model.nodes, output_id) || (throw_error ? error("Output (parent) node  doesn't exist") : return false)
    haskey(model.nodes, input_id)  || (throw_error ? error("Input (child) node doesn't exist") : return false)
    
    parent_node = getnode(model, output_id)
    child_node  = getnode(model, input_id)
    # check ports exist
    isportexist(parent_node, output_port, :output) || (throw_error ? error("Output node port $output_port doesn't exist") : return false)
    isportexist(child_node, input_port, :input) || (throw_error ? error("Input node port $input_port doesn't exist") : return false)

    getportspec(parent_node, output_port, :output).kind == :terminal && throw_warn && @warn "Output port $output_port is terminal and should not be connected" # Warn, but allow connection 

    if haskey(model.incoming, input_id) # check if child node has incoming connections
        if length(model.incoming[input_id]) > 0
            for cid in model.incoming[input_id] # for all incoming connections of child node
                existed_con = model.connections[cid]
                if existed_con.input_port == input_port && !ismultiport(getportspec(child_node, input_port, :input))
                    throw_error ? error("Node port occupied by another connection") : return false
                end
            end
        end 
    end
    out_type = getporttype(parent_node, output_port, :output)
    in_type  = getporttype(child_node, input_port, :input)

    out_type <: in_type || (throw_error ? error("Type mismatch") : return false)
    return true
end

"""
    add_connection!(model::Workflow, c::NodeConnection)
    add_connection!(model::Workflow, id_out::Int, port_out::Symbol, id_in::Int, port_in::Symbol)

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
    check_connection_validity(model, c)
    id = model.c_iter += 1
    model.connections[id] = c
    output_node = getnode(model, c.output_id)
    # Инвалидируем дочерние ноды
    invalidate_downstream!(model, c.input_id) 
    if getstatus(output_node) == :clean 
        output_data = getdata(output_node, c.output_port)
        input_node  = getnode(model, c.input_id)
        # записываем в буфер
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
    refreshind!(model::Workflow) -> Workflow
 
Rebuild the `incoming`/`outgoing` indices from `model.connections`.
 
Cheaper than keeping them in a snapshot and safer: the indices cannot disagree
with the connections they index. Used by [`dict_to_workflow`](@ref) after the
nodes and connections are in place.
"""
function refreshind!(model::Workflow)
    empty!(model.incoming)
    empty!(model.outgoing)
    for (k,c) in model.connections
        push!(get!(model.incoming, c.input_id, Int[]), k)
        push!(get!(model.outgoing, c.output_id, Int[]), k)
    end
    # sort! не косметика
    for v in values(model.incoming); sort!(v); end
    for v in values(model.outgoing); sort!(v); end
  
    return model
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
        # Инвалидируем дочерние ноды
        invalidate_downstream!(model, c.input_id) 
        # invalidate_downstream! инвалидирует буфер, поэтому инвалиджируем только буфер конкретного соединения
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
 
Assigns a new unique node identifier and registers the node in workflow
storage. Identifiers come from a monotonically increasing counter and are
never reused.
 
# Notes
A node whose status is neither `:idle` nor `:clean` is reset on insertion,
which clears its settings, input buffers and execution state. A freshly
created node and an already computed node are inserted unchanged, so a node
may be configured before or after it joins the workflow.
 
# Returns
Assigned node identifier (`Int`).
"""
function add_node!(model::Workflow, node::AbstractDataNode)
    # If Node node is not in :idle or :clean state, reset it to clear any previous execution state.
    if !(getstatus(node) in [:idle, :clean]) reset!(node) end
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



"""
    reset!(model::Workflow; soft::Bool = false)

Invalidate the whole workflow.

Zeroes the execution counter `exec_n` of every node, then applies
[`mark_dirty!`](@ref) to each of them, forwarding `soft`:

- `soft = false` (default): statuses become `:dirty`, cached output data and
  `ready_ports` are dropped, and the buffers of `:feedback` input ports are
  cleared;
- `soft = true`: only statuses are reset; cached output data and the feedback
  buffers survive.

Clearing the feedback buffers is what makes a full reset a full reset for a
cyclic workflow: those buffers hold the state of the last turn, and a loop head
that still finds it there resumes the previous run instead of starting a new
one. `soft = true` keeps them on purpose - that is how state is carried between
[`scheduler!`](@ref) calls.

This is the only place where `exec_n` is zeroed for the whole workflow, so the
counter measures work done since the last `reset!` rather than since the last
invalidation.

Node settings, the buffers of `:normal` input ports and execution logs are kept
in both cases - use `reset!(node)` for a full per-node reset.

# Returns
The workflow.
"""
function reset!(model::Workflow; soft::Bool = false)
    for (k, node) in model.nodes
        node.state.exec_n = 0
        mark_dirty!(node, soft = soft)
        # Полный сброс обязан снять состояние цикла
        if !soft
            for ps in node.spec.input_ports
                ps.kind == :feedback || continue
                empty!(node.input_buffer[ps.label])
            end
        end
    end
    model
end
"""
    reset!(node::AbstractDataNode)
 
Reset node to its initial state.
 
Performs the following operations:
- sets node status to `:idle`,
- clears node settings,
- clears the contents of every input buffer, keeping the port keys,
- resets execution state (`exec_n`, `ready_ports`, `execution_id`, node log),
- clears cached output data stored in `node.data`.
 
Unlike [`mark_dirty!`](@ref), this drops the node configuration as well, so it
is meant for reusing a node object rather than for invalidation.
 
# Returns
The node.
"""
function reset!(node::AbstractDataNode)
    setstatus!(node, :idle)
    empty!(node.settings)
    for (l, b) in node.input_buffer; empty!(b); end
    empty!(node.state)
    empty!(node.data)
    node
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
    mark_dirty!(node::AbstractDataNode; soft::Bool = false)
 
Invalidate node execution result.
 
Performs the following operations:
- sets node status to `:dirty`,
- clears `ready_ports`,
- clears cached output data stored in `node.data`.
 
With `soft = true` the last two steps are skipped: the status and the counter
are reset, but `ready_ports` and `node.data` are left in place. That is what
`reset_mode = :soft` of [`scheduler!`](@ref) uses to keep results between
runs.
 
This function intentionally does **not** clear:
- node settings,
- input buffer,
- execution logs.
- execution counters/state metadata.
 
# Returns
The node.
"""
function mark_dirty!(node::AbstractDataNode; soft::Bool = false)
    setstatus!(node, :dirty)
    if soft return node end
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
        if haskey(model.outgoing, id) # if outgoing connection exists
            for con_id in model.outgoing[id] # for each outgoing connection
                # get connection by id
                con = model.connections[con_id]
                # get child node
                children_node = getnode(model, con.input_id)
                # delete only port buffer
                invalidate_buffer!(children_node, con.input_port, con_id)
                # if not, can be multiple ivalidation runs in 2 or more connections 
                invalidate_downstream!(model, con.input_id)
            end
        end
    end
    
end

"""
    mark_dirty_downstream!(model::Workflow, id::Int)

Mark the node and everything downstream of it `:dirty`, following **`:normal`**
edges only.

Unlike [`invalidate_downstream!`](@ref) this touches nothing but the statuses:
cached output data and input buffers are left in place, because a cyclic
workflow carries its loop state in those buffers.

Used by [`scheduler!`](@ref) for an [`ABW`](@ref) workflow after a node has
published. Marking the whole cone - and not only the direct children - is what
makes a turn independent of the order in which the connections were created:
[`isready`](@ref) then holds a node back until every one of its `:normal`
ancestors has been recomputed during this turn.

A connection entering a port with `kind = :feedback` is not followed: a
feedback edge means "next turn", so invalidation must not propagate through it.

The walk stops at nodes that are already `:dirty`, which bounds the total work
of one turn and terminates inside a cycle. It is iterative, so graph depth
cannot overflow the stack.
"""
function mark_dirty_downstream!(model::Workflow, id::Int)
    stack = Int[id]
    while !isempty(stack)
        nid  = pop!(stack)
        node = getnode(model, nid)
        getstatus(node) == :dirty && continue
        setstatus!(node, :dirty)
        for con_id in get(model.outgoing, nid, Int[])
            con   = model.connections[con_id]
            child = getnode(model, con.input_id)
            getportspec(child, con.input_port, :input).kind == :feedback && continue
            push!(stack, con.input_id)
        end
    end
    return model
end


"""
    invalidate_buffer!(node::AbstractDataNode, l::Symbol, con::Int)

Delete input buffer entry for a specific port and connection (id).
"""
function invalidate_buffer!(node::AbstractDataNode, l::Symbol, con::Int)
    # input_buffer[port_label][connection_id] = data
    delete!(node.input_buffer[l], con)
    return node
end

"""
    isready(model::Workflow, id::Int)
 
Check whether node is ready for execution in ABW.
 
A node is ready when every producer connected to it through a **`:normal`**
input port has status `:clean`. Connections entering ports of any other kind
are not waited for.
 
This asymmetry is what makes cycles possible: a `:feedback` edge carries the
value of the previous iteration, so requiring its producer to be `:clean`
would deadlock - the node would wait for a producer that waits for the node.
 
# Notes
- Current node status itself is not checked.
- Input buffer completeness is validated separately via
  [`execution_node_validation`](@ref).
- A node with `:normal` input ports but no incoming connection is ready
  immediately; it just never gets enqueued unless something feeds it.
"""
function isready(model::Workflow, id::Int)
    node = getnode(model, id)
    connections = get(model.incoming, id, Int[])
    for con_id in connections
        con = getconnection(model, con_id)
        parent_node = getnode(model, con.output_id)
        ps = getportspec(node, con.input_port, :input)
        if ps.kind == :normal && getstatus(parent_node) != :clean return false end # ps.kind == :normal - crytical for cycling
    end
    return true
end
"""
    validate_node(node::AbstractDataNode)
    validate_node(model::Workflow, node_id::Int)

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
    execution_node_validation(node::AbstractDataNode, check_input_buffer::Bool = true)
 
Internal function. Validate node readiness before execution.
 
With `check_input_buffer` enabled, checks that:
- every input port that is `required` **and** of kind `:normal` has a value in
  `node.input_buffer`,
- [`validate_node`](@ref) succeeds.
 
Optional ports and ports of kind `:feedback` or `:error` may be empty: a
feedback buffer is empty on the first pass of a loop by definition.
 
With `check_input_buffer` disabled only [`validate_node`](@ref) is consulted.
The [`ABW`](@ref) scheduler runs nodes that way.
 
# Returns
- `true` if node is ready for execution.
- `false` otherwise.
"""
function execution_node_validation(node::AbstractDataNode, check_input_buffer::Bool = true)
    # All ports must have something in input_buffer if port is required
    if check_input_buffer
        return all(x-> length(node.input_buffer[x.label]) > 0 || !x.required || x.kind != :normal, node.spec.input_ports) && validate_node(node)
    else
        return validate_node(node)
    end
end
"""
    validate_settings(node::AbstractDataNode)
    validate_settings(model::Workflow, node_id::Int)

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
    validate_result(model::Workflow, node_id::Int)

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
"""
    push_buffer!(model::Workflow, id::Int)
    push_buffer!(model::Workflow, id::Int, port::Symbol)
    push_buffer!(model::Workflow, id::Int, ready_ports::Vector{Symbol})

Propagate output data from a node to its downstream children.
"""
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
"""
    makegraph(model::Workflow)
 
Build directed graph representation of workflow: node identifiers become
vertex names and every connection becomes an edge.
 
# Notes
All connections are included regardless of the `kind` of the ports they
attach to. A `:feedback` edge is therefore an ordinary edge here, so a graph
with a feedback loop is cyclic and [`scheduler!`](@ref) for a [`DAW`](@ref)
workflow rejects it. That is by design: cycles are an [`ABW`](@ref) feature.
"""
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


# End Module:
end
