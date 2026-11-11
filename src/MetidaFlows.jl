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
getinputconnections,
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
request_stop!,
isstoprequested,
failed_nodes,
check_failed_nodes,
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
settings_to_dict,
node_state_to_dict,
value_to_dict,

dict_to_workflow,
dict_to_node,
dict_to_connection,
dict_to_properties,
dict_to_spec,
dict_to_settings!,
dict_to_node_state!,
dict_to_value,

settings_to_dict_usermod!,
dict_to_settings_usermod!,

# Node register:

NODE_REGISTER,
register_node!,
unregister_node!,
unregister_all!,
isregistered,
getregnodeinfo,
nodetypestr,

settings_schema,
node_schema,

ismetasource,
getmeta_unsafe,
MetaRuleError,

initbuffer!,
buffervalues,
bufferkeys,
buffersingle,
PortBuffer,

NodeAdded,
NodeDeleted,
ConnectionAdded,
ConnectionDeleted,
SettingsChanged,
audit!,
log!,
audit_event_to_dict,
dict_to_audit_event,
AUDIT_EVENT_NAMES,
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
"""
    AbstractAuditEvent

Supertype of the records in `Workflow.audit_log`: a **change log of the graph**
in the order the edits happened.

Five concrete events, one per model-level mutator:
[`NodeAdded`](@ref), [`NodeDeleted`](@ref), [`ConnectionAdded`](@ref),
[`ConnectionDeleted`](@ref) and [`SettingsChanged`](@ref).

That set is the mutators that take a [`Workflow`](@ref), which is also the
boundary of what the log can see: [`setid!`](@ref) and [`setposition!`](@ref)
are given a node and no model, so moving a node in an editor is not an edit
this log records.

# What it is not
- **Not an undo stack.** [`SettingsChanged`](@ref) records which setting keys
  changed, not their values before and after: the log would otherwise carry a
  second copy of every value a user ever typed, into every snapshot.
- **Not a trace of execution.** Running a graph is not an edit. The per-run
  log of a node is [`NodeState`](@ref)`.log`, and the workflow's is
  `Workflow.log` ([`LogMsg`](@ref)).
- **Not timestamped.** The vector's order *is* the sequence, and it is the same
  on every machine; a wall clock would only add something that is not
  reproducible.

Recording is **off by default** - see [`Workflow`](@ref) and the `audit`
keyword - and when it is on, **nothing is ever dropped**: the log is neither
capped nor truncated by the engine. A change log with holes in it answers "did
this happen?" with a maybe, which is worse than having none, so the switch is
all or nothing. Trimming it, if a long editing session needs that, is the
caller's business. Cascades fall out of the mutators: [`delete_node!`](@ref) deletes the
node's connections through [`delete_connection!`](@ref), so the log shows each
[`ConnectionDeleted`](@ref) and then the [`NodeDeleted`](@ref).

!!! compat "Implemented in 0.3.0"
    Until 0.3.0 this type had no concrete subtype and nothing was ever written
    to `audit_log`.
"""
abstract type AbstractAuditEvent end

"""
    NodeAdded(id, type) <: AbstractAuditEvent

A node with id `id` was added by [`add_node!`](@ref).

`type` is the node type's **registry name** as [`nodetypestr`](@ref) renders it,
a `String` and not a `Type`: an audit record travels into snapshot files, and
nothing read out of a file is ever resolved to a type.
"""
struct NodeAdded <: AbstractAuditEvent
    id::Int
    type::String
end

"""
    NodeDeleted(id) <: AbstractAuditEvent

The node with id `id` was removed by [`delete_node!`](@ref). Its connections are
removed first, each as a [`ConnectionDeleted`](@ref) ahead of this record.
"""
struct NodeDeleted <: AbstractAuditEvent
    id::Int
end

"""
    ConnectionAdded(id, output_id, output_port, input_id, input_port) <: AbstractAuditEvent

A connection with id `id` was added by [`add_connection!`](@ref), from
`output_port` of node `output_id` to `input_port` of node `input_id`.

The ports are carried because the connection itself is gone from the model by
the time a deletion is read back, and a log that could not say what was
connected would not describe the graph it logged.
"""
struct ConnectionAdded <: AbstractAuditEvent
    id::Int
    output_id::Int
    output_port::Symbol
    input_id::Int
    input_port::Symbol
end

"""
    ConnectionDeleted(id) <: AbstractAuditEvent

The connection with id `id` was removed by [`delete_connection!`](@ref), or by
[`delete_node!`](@ref) removing one of its endpoints. Connection ids are never
reused, so the matching [`ConnectionAdded`](@ref) earlier in the log says what
it was.
"""
struct ConnectionDeleted <: AbstractAuditEvent
    id::Int
end

"""
    SettingsChanged(id, keys) <: AbstractAuditEvent

Settings of node `id` were written by [`setsettings!`](@ref). `keys` are the
setting names that were passed, in sorted order - values are deliberately not
recorded, see [`AbstractAuditEvent`](@ref).

Sorted rather than as given: the caller passes a `Dict`, whose iteration order
is not the insertion order, so recording them as they came would make the log
differ between machines on identical edits.
"""
struct SettingsChanged <: AbstractAuditEvent
    id::Int
    keys::Vector{Symbol}
end

#  Структурное равенство на всё семейство. Умолчание Julia для неизменяемой
#  структуры сводится к `===`, а `NodeAdded` несёт `String`, а
#  `SettingsChanged` — `Vector`: два объекта с одинаковым содержимым дают
#  `false`. Для журнала это дефект, а не придирка — равенство нужно, чтобы
#  сравнить журнал до и после круга через снимок. `hash` обязателен вместе с
#  `==`, иначе события нельзя положить в `Set` или ключ `Dict`.
function Base.:(==)(a::AbstractAuditEvent, b::AbstractAuditEvent)
    typeof(a) === typeof(b) || return false
    return all(f -> getfield(a, f) == getfield(b, f), fieldnames(typeof(a)))
end
function Base.hash(e::AbstractAuditEvent, h::UInt)
    h = hash(typeof(e), h)
    for f in fieldnames(typeof(e)); h = hash(getfield(e, f), h); end
    return h
end
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

Supertype of the node field containers: [`NodeState`](@ref),
[`AbstractNodeSettings`](@ref), [`AbstractNodeData`](@ref),
[`AbstractNodeState`](@ref), [`AbstractNodeInputBuffer`](@ref).

A node's `settings`, `data` and `state` can be plain `Dict`s - the default - or
purpose-built **structs**, so a workflow can be fully typed with no `Dict`
anywhere. Subtypes of this type get the `Dict`-like interface the engine uses,
over their own fields:

```julia
mutable struct FilterSettings <: MetidaFlows.AbstractNodeSettings
    column::Symbol
    threshold::Float64
    FilterSettings() = new(:none, 0.0)      # see `empty!` below
end

s = FilterSettings()
s[:threshold]           # getindex  -> getfield
s[:threshold] = 1.5     # setindex! -> setfield!  (mutable subtypes only)
keys(s)                 # (:column, :threshold)  -> fieldnames
haskey(s, :column)      # -> hasfield
get(s, :missing, nothing)
empty!(s)               # back to FilterSettings()
```

# The protocol
These five methods are what the engine calls on a container, and all five come
from this type:

| method | meaning | needed by |
|:---|:---|:---|
| `getindex(obj, f)` | `getfield` | [`getdata`](@ref), node bodies |
| `setindex!(obj, v, f)` | `setfield!`, mutable only | [`setdata!`](@ref), [`setsettings!`](@ref) |
| `keys(obj)` | `fieldnames` | error messages, introspection |
| `haskey(obj, f)` | `hasfield` | [`settings_to_dict`](@ref) |
| `get(obj, f, default)` | field or `default` | [`getdata`](@ref) |
| `empty!(obj)` | every field back to what the zero-argument constructor gives | [`mark_dirty!`](@ref), [`reset!`](@ref) |

`empty!` is the only one with a condition: a struct has no "empty" state of its
own, so the generic method rebuilds one with `T()` and copies its fields over.
**Give the struct a zero-argument constructor**, or define `Base.empty!`
yourself - [`NodeState`](@ref) does the latter. Without either, `empty!` raises
and names the type, because the engine clears cached output data on every
invalidation and cannot proceed.

Which container a node gets is decided by [`nodesettings`](@ref),
[`nodedata`](@ref), [`nodestate`](@ref) and [`nodebuffer`](@ref) - specialize
those on the node type and both hand-built and loaded graphs come out typed.

See also [`DataNode`](@ref).
"""
abstract type AbstractNodeFields end

"""
    AbstractNodeSettings <: AbstractNodeFields

Supertype for a node's **settings** container when it is a struct rather than a
`Dict`. See [`AbstractNodeFields`](@ref) for the protocol and
[`nodesettings`](@ref) for how a node gets one.
"""
abstract type AbstractNodeSettings <: AbstractNodeFields end

"""
    AbstractNodeData <: AbstractNodeFields

Supertype for a node's **output data** container when it is a struct rather
than a `Dict`. See [`AbstractNodeFields`](@ref) for the protocol and
[`nodedata`](@ref) for how a node gets one.

A `Dict` is emptied by invalidation; a struct is reset instead, so it needs a
zero-argument constructor or its own `Base.empty!`.
"""
abstract type AbstractNodeData  <: AbstractNodeFields end

"""
    AbstractNodeState <: AbstractNodeFields

Supertype of node execution state. The package ships [`NodeState`](@ref).
[`request_stop!`](@ref) needs a `stop` field and so works on `NodeState` only;
[`isstoprequested`](@ref) reports `false` for any other subtype.
"""
abstract type AbstractNodeState  <: AbstractNodeFields end

"""
    AbstractNodeInputBuffer <: AbstractNodeFields

Supertype for an input-buffer container: the outer mapping from input port
label to that port's buffer. Choose one per node type with
[`nodebuffer`](@ref).

A subtype needs one **field per declared input port**, named after the port and
holding a container keyed by connection id - [`initbuffer!`](@ref) checks that
on construction, because fields cannot be added later. The per-connection level
stays an associative container: connection ids are handed out at runtime, so no
struct can have a field per connection.

```julia
mutable struct CellBuffer <: MetidaFlows.AbstractNodeInputBuffer
    diag::PortBuffer{Int}
    up::PortBuffer{Int}
    left::PortBuffer{Int}
    CellBuffer() = new(PortBuffer{Int}(), PortBuffer{Int}(), PortBuffer{Int}())
end
MetidaFlows.nodebuffer(::Type{Cell}) = CellBuffer()
```

Getting `buffer[:diag]` off such a struct is a field access, where a `Dict`
hashes a `Symbol`; the per-port containers are concretely typed, so what the
engine reads out of them needs no boxing.

!!! compat "Reachable since 0.3.0"
    Until 0.3.0 the `input_buffer` field was declared
    `Dict{Symbol, Dict{Int, BufferT}}`, which fixed the container and left only
    the value type free, so a subtype of this type could not be passed to a
    node at all.
"""
abstract type AbstractNodeInputBuffer  <: AbstractNodeFields end

# Обеспечивает Dict совместимое поведение AbstractNodeFields (NodeState)
Base.getindex(obj::AbstractNodeFields, f::Symbol) = getfield(obj, f)
function Base.setindex!(obj::T, val, f::Symbol) where T <: AbstractNodeFields
    ismutabletype(T) || error("$(T) is immutable: a node container that the engine writes to must be a `mutable struct`")
    setfield!(obj, f, val)
end
Base.keys(obj::AbstractNodeFields)                   = fieldnames(typeof(obj))
Base.haskey(obj::AbstractNodeFields, f::Symbol)      = hasfield(typeof(obj), f)
Base.get(obj::AbstractNodeFields, f::Symbol, default) =
    hasfield(typeof(obj), f) ? getfield(obj, f) : default
#  «Опустошения» у структуры с фиксированными полями нет, поэтому за эталон
#  берётся свежесозданный экземпляр. Это и позволяет не требовать от автора
#  ничего, кроме конструктора без аргументов.
function Base.empty!(obj::T) where T <: AbstractNodeFields
    ismutabletype(T) ||
        error("$(T) is immutable: `empty!` cannot reset it; make it a `mutable struct`")
    hasmethod(T, Tuple{}) ||
        error("$(T) has no zero-argument constructor, so `empty!` has nothing to reset it to: " *
              "add `$(nameof(T))() = ...` or define `Base.empty!(::$(T))`")
    fresh = T()
    for f in fieldnames(T)
        setfield!(obj, f, getfield(fresh, f))
    end
    return obj
end


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
    SETTINGS

Package-wide settings, in one mutable table. The engine reads three keys from
it; anything else you put there is yours.

```julia
MetidaFlows.SETTINGS[:audit]     = true    # вести журнал правок графа
MetidaFlows.SETTINGS[:logging]   = false   # не писать сообщения движка
MetidaFlows.SETTINGS[:log_limit] = 200     # и держать не больше 200
MetidaFlows.SETTINGS[:my_thing]  = "..."   # своё — читайте через `get`
```

| key | type | default | what it controls |
|:---|:---|:---|:---|
| `:logging` | `Bool` | `true` | whether [`log!`](@ref) records anything |
| `:audit` | `Bool` | `false` | whether [`audit!`](@ref) records anything |
| `:log_limit` | `Int` | `1000` | how many messages a log keeps; `0` means no limit |

A value of the wrong type, or one of these three keys deleted, raises an error
naming the key rather than failing somewhere inside a run.

# The eviction policy, in one place
A log at its limit **drops its oldest record** to make room for the newest, so
what a log holds is the most recent `:log_limit` messages. A log whose length
equals the limit is therefore *possibly truncated*, and that is the only signal
there is - the count of what was dropped is not kept. When the whole history
matters, raise the limit or set it to `0`; when nothing should be recorded at
all, set `:logging` to `false`.

`:log_limit` bounds both logs that hold [`LogMsg`](@ref): `Workflow.log` and a
node's own `node.state[:log]`. It does **not** apply to the graph change log:
`audit_log` is never capped and never evicts, because a record of an edit that
may or may not be there cannot be used to tell what the graph went through.
See [`AbstractAuditEvent`](@ref).

!!! note "These are process-wide"
    One table for every workflow in the process. Two graphs open at once cannot
    differ, and code that changes a setting has to put it back - a test that
    needs the audit log on, above all, or it changes what every later test
    sees.
"""
const SETTINGS = Dict{Symbol, Any}(
    :logging   => true,
    :audit     => false,
    :log_limit => 1000,
)

#  Чтение настройки движка: ключ обязан быть и быть нужного типа. Проверка
#  здесь, а не на месте использования, чтобы ошибка называла ключ, а не
#  вываливалась TypeError из середины прогона.
function _setting(key::Symbol, ::Type{T}) where T
    haskey(SETTINGS, key) ||
        error("MetidaFlows.SETTINGS has no `:$(key)`: it is one of the engine's own " *
              "settings and should not be removed from the table")
    v = SETTINGS[key]
    v isa T ||
        error("MetidaFlows.SETTINGS[:$(key)] should be a $(T), got $(typeof(v)): $(repr(v))")
    return v::T
end

#  Общая реализация политики для обоих логов. `limit <= 0` — без предела.
#
#  Снимаем с головы ДО записи, а не подрезаем после: в установившемся режиме
#  это ровно один `popfirst!`, который у `Vector` амортизированно O(1) —
#  массив держит смещение с головы и хвост не двигает, — и массив при этом
#  не растёт. Замерено на пределе 1000: 5,7 нс против 8,0 нс на сообщение у
#  варианта «push! и подрезать после», и одинаково на пределах 100 и 10000.
#
#  Массовый срез нужен для другого случая: предел ПОНИЗИЛИ на живом логе. По
#  одному сообщению за запись он сходился бы к новому пределу сотни записей.
function _logpush!(v::Vector{LogMsg}, msg::LogMsg, limit::Int)
    if limit > 0
        extra = length(v) - limit + 1          # сколько снять, чтобы после push! было ровно limit
        if extra == 1
            popfirst!(v)
        elseif extra > 1
            deleteat!(v, 1:extra)
        end
    end
    push!(v, msg)
    return v
end

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
- `log::Vector{LogMsg}` - the node's own log, written by the node through
  [`log!`](@ref) and by nothing in the engine; cleared by `empty!(state)` and
  `reset!(node)`, **not** by `reset!(model)`;
  bounded by [`SETTINGS`](@ref)`[:log_limit]`, oldest dropped first.
 
Reset in place with `empty!(state)`.
"""
mutable struct NodeState <: AbstractNodeState
    exec_n::Int
    ready_ports::Vector{Symbol}
    execution_id::UInt64
    log::Vector{LogMsg}
    stop::Bool
    function NodeState()
        new(0, Symbol[], 0, LogMsg[], false)
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
    ns.stop = false
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
[`getinputdata`](@ref) returns the buffered values as a `Vector`, ordered by
ascending connection id; [`getinputconnections`](@ref) gives the matching ids.
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

"""
    PortBuffer{V}() <: AbstractDict{Int, V}

The container the engine puts under one input port by default: values keyed by
connection id, **kept in ascending key order**.

That order is the contract [`getinputdata`](@ref) publishes for a
[`MultiPort`](@ref), so a container that already holds its keys sorted answers
with a copy instead of collecting, sorting and hashing - see
[`buffervalues`](@ref). Two parallel vectors, binary search to place a write.

# Why sorted and not insertion-ordered
An insertion-ordered container (`OrderedDict` and friends) would record the
order in which producers **finished**, which is scheduling order and not wiring
order. Measured on three branches of different length feeding one port, wired
as connections `[5, 8, 9]`: the short branch publishes first, so insertion order
is `[9, 8, 5]` and the values come out reversed. Worse, overwriting a key does
not move it, so a second run inherits whatever the first run's schedule
happened to be. Sorting by key is independent of when anything ran.

# Cost against a `Dict`
Measured per read, with `V = Any`:

| | `Dict{Int, Any}` | `PortBuffer{Any}` |
|:---|---:|---:|
| build + one write + one read (a `SinglePort`) | 448 B / 84 ns | **192 B / 60 ns** |
| read 2 values in order | 208 B / 256 ns | **48 B / 18 ns** |
| read 1000 values in order | 24 584 B / 12 850 ns | **8 040 B / 857 ns** |

Writing is cheaper too at one connection per port, which is the common case,
and the insert costs more only when a port has many connections *and* they
arrive out of order.

It is an `AbstractDict`, so code that treated a port's buffer as a dictionary -
`buf[cid]`, `get`, `haskey`, iteration over pairs, `length`, `isempty`,
`empty!`, `delete!` - keeps working unchanged.
"""
mutable struct PortBuffer{V} <: AbstractDict{Int, V}
    cids::Vector{Int}
    vals::Vector{V}
    PortBuffer{V}() where V = new{V}(Int[], V[])
end

Base.length(b::PortBuffer)  = length(b.cids)
Base.isempty(b::PortBuffer) = isempty(b.cids)
Base.keys(b::PortBuffer)    = b.cids
Base.values(b::PortBuffer)  = b.vals
Base.haskey(b::PortBuffer, c::Int) = !isempty(searchsorted(b.cids, c))
function Base.getindex(b::PortBuffer, c::Int)
    r = searchsorted(b.cids, c)
    isempty(r) && throw(KeyError(c))
    return b.vals[first(r)]
end
function Base.get(b::PortBuffer, c::Int, default)
    r = searchsorted(b.cids, c)
    return isempty(r) ? default : b.vals[first(r)]
end
function Base.setindex!(b::PortBuffer, v, c::Int)
    n = length(b.cids)
    #  Самый частый случай — порт с одной связью, и вообще номер больше всех
    #  уже лежащих: тогда ни искать, ни сдвигать нечего.
    if n == 0 || c > @inbounds b.cids[n]
        push!(b.cids, c); push!(b.vals, v)
        return b
    end
    i = searchsortedfirst(b.cids, c)
    if b.cids[i] == c
        b.vals[i] = v                      # перезапись: место то же
    else
        insert!(b.cids, i, c)
        insert!(b.vals, i, v)
    end
    return b
end
function Base.delete!(b::PortBuffer, c::Int)
    r = searchsorted(b.cids, c)
    if !isempty(r)
        deleteat!(b.cids, first(r)); deleteat!(b.vals, first(r))
    end
    return b
end
Base.empty!(b::PortBuffer) = (empty!(b.cids); empty!(b.vals); b)
function Base.iterate(b::PortBuffer, i::Int = 1)
    i > length(b.cids) && return nothing
    return (b.cids[i] => b.vals[i], i + 1)
end

"""
    initbuffer!(buffer, spec::NodeSpec)

Prepare an input buffer against the node specification, and return it.

Called by the [`DataNode`](@ref) constructor. Two things have to hold afterwards:
every entry of `buffer` names a declared `:input` port, and every declared
`:input` port has an entry - the engine indexes `buffer[label]` without checking.

How the second is achieved depends on the container, which is why this is a
function and not a loop in the constructor:

- a dictionary is **grown**: a missing port gets a fresh empty entry of the
  dictionary's own value type, so `Dict{Symbol, PortBuffer{Any}}` keeps giving
  `PortBuffer{Any}` and a typed `Dict{Symbol, PortBuffer{Float64}}` keeps giving
  `PortBuffer{Float64}`;
- a struct ([`AbstractNodeFields`](@ref)) is **checked**: fields cannot be
  added, so a port without a field is an error naming the field to declare.

Define a method for a container that is neither.

# Example
```julia
mutable struct PairBuffer <: MetidaFlows.AbstractNodeInputBuffer
    a::PortBuffer{Float64}
    b::PortBuffer{Float64}
    PairBuffer() = new(PortBuffer{Float64}(), PortBuffer{Float64}())
end
MetidaFlows.nodebuffer(::Type{MyNode}) = PairBuffer()
```
"""
function initbuffer!(buffer::AbstractDict, spec::NodeSpec)
    for k in keys(buffer)
        isportinspec(k, spec, :input) ||
            error("Input buffer key $k doesn't match any input port in node specification")
    end
    V = valtype(buffer)
    for ip in spec.input_ports
        haskey(buffer, ip.label) && continue
        #  Нарастить словарь можно только если его тип значения — конкретный
        #  контейнер. `Dict{Symbol, Any}` сюда проходит по типу, но создать
        #  `Any()` нельзя, и без этой проверки ошибка была бы невнятной.
        (isconcretetype(V) && hasmethod(V, Tuple{})) ||
            error("Input buffer of type $(typeof(buffer)) has no entry for input port " *
                  "`:$(ip.label)`, and its value type $(V) cannot be constructed to make one. " *
                  "Use a buffer whose value type is a concrete container, such as " *
                  "`Dict{Symbol, PortBuffer{Any}}`, or fill the entry in before building the node.")
        buffer[ip.label] = V()
    end
    return buffer
end
function initbuffer!(buffer::AbstractNodeFields, spec::NodeSpec)
    #  Оба перечня собираются и сообщаются вместе. Структура с опечаткой в
    #  имени поля нарушает обе проверки сразу, и по одной из них не видно,
    #  что надо переименовать: «нет поля `in`» и «поле `inp` не порт» —
    #  одна и та же ошибка, рассказанная с двух сторон.
    missing_fields = Symbol[ip.label for ip in spec.input_ports if !haskey(buffer, ip.label)]
    extra_fields   = Symbol[k for k in keys(buffer) if !isportinspec(k, spec, :input)]
    if !isempty(missing_fields) || !isempty(extra_fields)
        msg = "Input buffer of type $(typeof(buffer)) does not match the node specification: "
        isempty(missing_fields) ||
            (msg *= "no field for input port(s) " * join(("`$(f)`" for f in missing_fields), ", ") * "; ")
        isempty(extra_fields) ||
            (msg *= "field(s) " * join(("`$(f)`" for f in extra_fields), ", ") *
                    " name no input port; ")
        msg *= "a struct buffer needs exactly one field per input port, named after it, " *
               "holding a container keyed by connection id."
        error(msg)
    end
    return buffer
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
    DataNode(type::Type{T}, properties, spec, settings::SettingsT, data::DataT, state::StateT, input_buffer::BufferT) where T <: AbstractNodeType where SettingsT where DataT where StateT where BufferT
    DataNode(type::Type, id, status, position, spec; settings = Dict{Symbol, Any}(), data = Dict{Symbol, Any}(), state = NodeState(), input_buffer = Dict{Symbol, PortBuffer{Any}}())
    DataNode(type::Type, spec; settings = Dict{Symbol, Any}(), data = Dict{Symbol, Any}(), state = NodeState(), input_buffer = Dict{Symbol, PortBuffer{Any}}())

Concrete workflow node.

The first type parameter is the user-defined behaviour tag
([`AbstractNodeType`](@ref)) on which [`execute_unsafe!`](@ref) and the
validation hooks dispatch; the remaining four are the types of the containers,
so a node can be backed by plain `Dict`s (the default) or by custom structs.

Fields:
- `properties::NodeProperties` - id, status, position.
- `spec::NodeSpec` - port and settings interface.
- `settings` - configuration values (`Dict{Symbol, Any}` by default).
- `data` - cached output values, keyed by output port label.
- `state` - execution state ([`NodeState`](@ref) by default).
- `input_buffer` - `input_buffer[port label][connection id] = value`
  (`Dict{Symbol, PortBuffer{Any}}` by default).

!!! compat "Changed in 0.3.0"
    `BufferT` is the type of the **whole buffer container**, not of the value
    inside it. Before 0.3.0 the field was declared
    `Dict{Symbol, Dict{Int, BufferT}}`, which fixed the container and left only
    the value type free; a node backed by a buffer struct was therefore
    impossible. Code that spelled the full `DataNode{...}` type out, or
    dispatched on its last parameter, has to be updated - nothing in this
    package did.

[`initbuffer!`](@ref) prepares the buffer against `spec`: for a dictionary it
creates an empty entry for every declared input port, for a struct it checks
that a field exists for each, and either way it rejects entries that are not
input ports.

# Example
```julia
node = DataNode(MyNode, spec)
id   = add_node!(workflow, node)
```

See [`AbstractNodeFields`](@ref) for what a container has to support, and
[`nodebuffer`](@ref) for choosing one per node type.
"""
struct DataNode{T <: AbstractNodeType, SettingsT, DataT, StateT, BufferT} <: AbstractDataNode
    properties::NodeProperties
    spec::NodeSpec
    settings::SettingsT   # Dict{Symbol, Any}() by default
    data::DataT           # Dict{Symbol, Any}() by default
    state::StateT         # NodeState by default
    # input_buffer[port_label][connection_id] = data
    input_buffer::BufferT          # Dict{Symbol, PortBuffer{Any}}() by default
    function DataNode(type::Type{T}, properties::NodeProperties, spec::NodeSpec, settings::SettingsT, data::DataT, state::StateT, input_buffer::BufferT) where T <: AbstractNodeType where SettingsT where DataT  where StateT  where BufferT
        initbuffer!(input_buffer, spec)
        new{T, SettingsT, DataT, StateT, BufferT}(properties, spec, settings, data, state, input_buffer)
    end
    #  Умолчания берутся из nodesettings / nodedata / nodestate / nodebuffer:
    #  Julia вычисляет выражение умолчания только когда аргумент не передан,
    #  поэтому лишних контейнеров не создаётся.
    function DataNode(type::Type, id, status, position, spec::NodeSpec; settings = nodesettings(type), data = nodedata(type), state = nodestate(type), input_buffer = nodebuffer(type))
        DataNode(type,  NodeProperties(id, status, position), spec, settings, data, state, input_buffer)
    end
    function DataNode(type::Type, properties::NodeProperties, spec::NodeSpec; settings = nodesettings(type), data = nodedata(type), state = nodestate(type), input_buffer = nodebuffer(type))
        DataNode(type,  properties, spec, settings, data, state, input_buffer)
    end
    function DataNode(type::Type, spec::NodeSpec; settings = nodesettings(type), data = nodedata(type), state = nodestate(type), input_buffer = nodebuffer(type))
        DataNode(type,  NodeProperties(), spec, settings, data, state, input_buffer)
    end
end

"""
    nodesettings(::Type) -> container
    nodedata(::Type)     -> container
    nodestate(::Type)    -> container
    nodebuffer(::Type)   -> Dict{Symbol, PortBuffer{T}}

Fresh containers for a node of the given node type. These are the defaults of
the [`DataNode`](@ref) keyword constructors and what [`dict_to_node`](@ref)
builds a loaded node with, so **one method here types a node everywhere** - by
hand, in a graph, and after a round trip through a snapshot.

Default: `Dict{Symbol, Any}()` for settings and data, [`NodeState`](@ref) for
state, `Dict{Symbol, PortBuffer{Any}}()` for the input buffer. Each is called
once per node, and only when the corresponding keyword is not given, so a
container is never built and thrown away.

```julia
mutable struct ScaleSettings <: MetidaFlows.AbstractNodeSettings
    factor::Float64
    ScaleSettings() = new(1.0)
end
mutable struct ScaleData <: MetidaFlows.AbstractNodeData
    out::Union{Float64, Nothing}
    ScaleData() = new(nothing)
end

struct Scale <: AbstractNodeType end
MetidaFlows.nodesettings(::Type{Scale}) = ScaleSettings()
MetidaFlows.nodedata(::Type{Scale})     = ScaleData()
MetidaFlows.nodebuffer(::Type{Scale})   = Dict{Symbol, PortBuffer{Float64}}()

node = DataNode(Scale, spec_scale())
# DataNode{Scale, ScaleSettings, ScaleData, NodeState, Dict{Symbol, PortBuffer{Float64}}}
```

Specialize them independently: typed settings with `Dict` data is a perfectly
good combination.

`nodebuffer` chooses the buffer **container**, so all three levels of it are
yours: the outer mapping from port label to buffer (a `Dict` or a struct with
one field per input port), the per-port container keyed by connection id, and
the value type. A value type narrower than `Any` is checked on every write,
which is how a port carrying the wrong type is caught early.

```julia
MetidaFlows.nodebuffer(::Type{Scale}) = ScaleBuffer()   # <: AbstractNodeInputBuffer
```

See [`AbstractNodeFields`](@ref) for what a container struct has to provide,
[`initbuffer!`](@ref) for how it is checked against the spec, and
[`buffervalues`](@ref) for teaching a per-port container to report its own
order cheaply.
"""
nodesettings(::Type) = Dict{Symbol, Any}()

@doc (@doc nodesettings)
nodedata(::Type)     = Dict{Symbol, Any}()

@doc (@doc nodesettings)
nodestate(::Type)    = NodeState()

@doc (@doc nodesettings)
nodebuffer(::Type)   = Dict{Symbol, PortBuffer{Any}}()

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
replaces the entry, `skipmode` returns `nothing` instead of raising.

The `Workflow` form registers every node type of a graph and returns the keys it
added, sorted. A graph normally holds several nodes of one type, and that is not
a repeated registration: each type is registered once per call, from its first
node, and the remaining nodes of that type are passed over. So
`register_node!(w)` is the ordinary call, and the flags mean for a graph exactly
what they mean for a node - what to do about a key that was **already taken
before this call**. A type whose spec has changed is the case for
`overwrite = true`; `skipmode = true` keeps whatever is registered.
 
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
            error("Node $(typestr) already registered, use `overwrite = true` to replace it, or `skipmode = true` to keep it")
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


mutable struct GraphCache
    ver::Int
    ic_ver::Int
    ts_ver::Int
    is_cyclic::Bool
    topological_sort::Vector{Int}
    graph::NamedDiGraph{Int}
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
- `log` - engine log messages ([`LogMsg`](@ref)); see [`SETTINGS`](@ref)`[:logging]`
  and [`log!`](@ref).
- `audit_log` - the graph change log; empty unless [`SETTINGS`](@ref)`[:audit]`
  is on, see [`AbstractAuditEvent`](@ref).
"""
mutable struct Workflow{T <: WorkFlowType}
    id::Int                      # model ID
    ver::Int                     # version
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
    graph::GraphCache
end
#
"""
    Workflow(id::Int; type::Symbol = :DAW)

Create a new workflow model with the specified identifier and type.

`type` selects the execution model and the concrete type parameter of the
result: `:DAW` gives a `Workflow{DAW}`, `:ABW` gives a `Workflow{ABW}`.
Any other value raises an error.

Whether a graph records its edits, whether the engine records messages, and how
many of those it keeps are **package-wide** settings, not properties of a
workflow: see [`SETTINGS`](@ref).
"""
function Workflow(id::Int; type::Symbol = :DAW)
    if type == :DAW
        Workflow{DAW}(id, 0, "Default", 0, Dict{Int, DataNode}(), 0, Dict{Int, NodeConnection}(), Dict{Int, Vector{Int}}(), Dict{Int, Vector{Int}}(), 0, LogMsg[], AbstractAuditEvent[], GraphCache(0, 0, 0, false, Int[], NamedDiGraph{Int}()))
    elseif type == :ABW
        Workflow{ABW}(id, 0, "Default", 0, Dict{Int, DataNode}(), 0, Dict{Int, NodeConnection}(), Dict{Int, Vector{Int}}(), Dict{Int, Vector{Int}}(), 0, LogMsg[], AbstractAuditEvent[], GraphCache(0, 0, 0, false, Int[], NamedDiGraph{Int}()))
    else
        error("Unknown workflow type: $(type) (expected :DAW or :ABW)")
    end
end

"""
    log!(model::Workflow, msg::LogMsg)

Append `msg` to `model.log` if [`SETTINGS`](@ref)`[:logging]` is on, and return the
model. The single place the log is written.

The log is bounded by [`SETTINGS`](@ref)`[:log_limit]` and the engine never clears it between
runs, so what it holds is the most recent `log_limit` messages of this
workflow's whole life. See [`SETTINGS`](@ref)`[:log_limit]` for the policy and
[`Workflow`](@ref) for the two knobs.

Unlike this one, the graph change log is never capped - see
[`AbstractAuditEvent`](@ref) for why an edit history with holes in it is worse
than none.
"""
function log!(model::Workflow, msg::LogMsg)
    _setting(:logging, Bool) && _logpush!(model.log, msg, _setting(:log_limit, Int))
    return model
end

"""
    log!(node::AbstractDataNode, msg::LogMsg)
    log!(node::AbstractDataNode, level::Symbol, message::AbstractString)

Append a message to **this node's own log**, `node.state[:log]`, and return the
node.

This is the log a node writes about itself, for whoever is looking at that
node - "read 1 240 rows", "3 values dropped as missing", "converged after 11
iterations". [`execute_unsafe!`](@ref) is handed only the node, which is exactly
what this needs, so a node can report from inside its own run:

```julia
function MetidaFlows.execute_unsafe!(n::DataNode{ReadCSV})
    tbl = CSV.read(n.settings[:file], DataFrame)
    log!(n, :info, "read \$(nrow(tbl)) rows")
    setdata!(n, :table, tbl)
    return [:table]
end
```

# Who writes, and who switches it off
Nothing in the engine writes here: engine messages go to `Workflow.log`
through [`log!(model, msg)`](@ref log!). That is also why this one has no
on/off switch where `Workflow.log` has `logging` - the only thing that writes a
node's log is the node's own code, so declining to call this *is* the switch.

# Bound and lifetime
The log keeps the most recent [`SETTINGS`](@ref)`[:log_limit]` messages, oldest
dropped first ([`SETTINGS`](@ref)`[:log_limit]` is 1000, `0` means no limit). That bound is
what makes logging from inside a cycle safe: a node that writes a line on every
turn of a 100 000-turn loop still holds that many records, the last ones.

It is cleared when the node's state is, which is [`reset!`](@ref)`(node)`,
`empty!(node.state)`, and `add_node!` on a node that is neither `:idle` nor
`:clean`. [`reset!`](@ref)`(model)` does **not** clear it, so messages survive
a re-run of the workflow; the limit is what keeps that bounded.

A custom [`AbstractNodeState`](@ref) needs a `log` field to be written to, and
a node whose state has none raises an error naming the type. A state without a
`log_limit` field is fine - the default is used.
"""
function log!(node::AbstractDataNode, msg::LogMsg)
    haskey(node.state, :log) ||
        error("Node $(getid(node)) has state of type $(typeof(node.state)), which has no " *
              "`log` field, so there is nowhere to write. Add a `log::Vector{LogMsg}` field " *
              "to it, or do not call `log!` on this node.")
    _logpush!(node.state[:log], msg, _setting(:log_limit, Int))
    return node
end
log!(node::AbstractDataNode, level::Symbol, message::AbstractString) =
    log!(node, LogMsg(level, String(message)))

"""
    audit!(model::Workflow, event::AbstractAuditEvent)

Append `event` to `model.audit_log` if [`SETTINGS`](@ref)`[:audit]` is on, and return
the model. The single place the log is written, so the check sits in one place and
a mutator records with one line.
"""
function audit!(model::Workflow, event::AbstractAuditEvent)
    _setting(:audit, Bool) && push!(model.audit_log, event)
    return model
end

#  Ни кольцевого буфера, ни предела длины — намеренно. Журнал правок с
#  дырами отвечает на вопрос «это случилось?» словом «может быть», а это
#  хуже, чем отсутствие журнала. Поэтому всё или ничего, и ничего между.

"""
    workflowtypestr(w::Workflow) -> String
 
`"DAW"` or `"ABW"`, as written into a snapshot under the `"type"` key.
"""
workflowtypestr(::Workflow{DAW}) = "DAW"
workflowtypestr(::Workflow{ABW}) = "ABW"

function register_node!(model::Workflow; overwrite = false, skipmode = false)
    names = String[]
    seen  = Set{String}()
    for (_, node) in model.nodes
        typestr = nodetypestr(node)
        #  Несколько узлов одного типа в одном графе — это не повторная
        #  регистрация: тип внесён этим же вызовом и из этого же графа.
        #  Без этого естественный `register_node!(w)` падал на втором
        #  таком узле, то есть почти на любом настоящем графе.
        typestr in seen && continue
        push!(seen, typestr)
        rn = register_node!(node; overwrite = overwrite, skipmode = skipmode)
        isnothing(rn) || push!(names, rn)
    end
    #  Порядок обхода `model.nodes` машинно-зависим, порядок возврата — нет.
    sort!(names)
    return names
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
    model.ver += 1
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
    audit!(model, ConnectionAdded(id, c.output_id, c.output_port, c.input_id, c.input_port))
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
        # Версия графа
        model.ver += 1
        # Удаляем связь
        delete!(model.connections, id) 
        audit!(model, ConnectionDeleted(id))
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
    # Версия графа
    model.ver += 1
    setid!(node, id)
    model.nodes[id] = node
    audit!(model, NodeAdded(id, nodetypestr(node)))
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
        # Версия графа
        model.ver += 1
        # Удаляем ноду
        delete!(model.nodes, id) 
        # delete index if exist
        if haskey(model.incoming, id) delete!(model.incoming, id)  end
        if haskey(model.outgoing, id) delete!(model.outgoing, id) end
        #  Связи сняты выше через delete_connection!, значит в журнале их
        #  удаления уже стоят — каскад виден сам, без особого события.
        audit!(model, NodeDeleted(id))
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
        reset_node!(node, soft)
    end
    model
end

#  БАРЬЕР ФУНКЦИИ. `model.nodes` — `Dict{Int, DataNode}`, а `DataNode` без
#  параметров абстрактен: тип узла в графе разный, иначе и быть не может.
#  Поэтому в теле цикла каждое `node.state` было бы поиском поля в рантайме.
#  Узел, переданный аргументом, компилируется по своему конкретному типу: на
#  входе один динамический диспатч, внутри всё статически.
function reset_node!(node::N, soft::Bool) where N <: AbstractDataNode
    node.state.exec_n = 0
    #  Признак остановки принадлежит прогону
    node.state.stop   = false
    mark_dirty!(node, soft)
    soft && return node
    # Полный сброс обязан снять состояние цикла
    for ps in node.spec.input_ports
        ps.kind == :feedback || continue
        empty!(node.input_buffer[ps.label])
    end
    return node
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
    #  Обходим порты спеки, а не сам контейнер: ключи буфера ей и так равны
    #  (это проверяет `initbuffer!`), зато структуре не нужна итерация.
    for ps in node.spec.input_ports; empty!(node.input_buffer[ps.label]); end
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
mark_dirty!(node::AbstractDataNode; soft::Bool = false) = mark_dirty!(node, soft)

#  Позиционная форма для горячего пути: вызов с кваргом собирает NamedTuple,
#  и на сбросе это 56 байт на узел на прогон.
function mark_dirty!(node::AbstractDataNode, soft::Bool)
    setstatus!(node, :dirty)
    soft && return node
    empty!(node.state[:ready_ports])
    empty!(node.data)
    return node
end
"""
    request_stop!(node::AbstractDataNode)

Ask the scheduler to end the run as soon as this node finishes.

Called from inside [`execute_unsafe!`](@ref) by a node that knows there is
nothing left worth computing - a search that found its answer, a check that
failed a precondition. What the node publishes is published as usual, so a
result can travel out through a `:terminal` port in the same execution; what
changes is that **nothing more is executed**.

```julia
function MetidaFlows.execute_unsafe!(n::DataNode{Found})
    setdata!(n, :answer, getinputdata(n, :in))
    request_stop!(n)
    return [:answer]
end
```

Both schedulers honour it: [`ABW`](@ref) stops serving the queue and
[`DAW`](@ref) leaves the topological traversal. Nodes that were queued or
still ahead in the order are not executed and end the run `:dirty`, exactly as
they do below a failure - a stop is **not** a failure, so
[`failed_nodes`](@ref) stays empty and `strict` does not raise. The scheduler
appends an `:info` record to `model.log` naming the node that stopped it.

The flag lives in the node's [`NodeState`](@ref) and is cleared by
[`reset!`](@ref), so the next run starts clean. With `reset_mode = :none`
nothing is reset, so a stop requested by an earlier run is still there and the
next one ends on that node again.

Which node stopped a run is an ordinary query afterwards:

```julia
[id for (id, n) in w.nodes if isstoprequested(n)]
```

See also [`isstoprequested`](@ref).
"""
request_stop!(node::AbstractDataNode) = (request_stop!(node.state); node)
request_stop!(st::NodeState) = (st.stop = true; st)
request_stop!(st::AbstractNodeState) = error("Node state of type $(typeof(st)) has no `stop` field; `request_stop!` needs a `NodeState`")

"""
    isstoprequested(node::AbstractDataNode) -> Bool

Whether [`request_stop!`](@ref) was called on this node and not yet cleared by
[`reset!`](@ref). A node whose state type has no `stop` field - a custom
`AbstractNodeState` - always reports `false`, so a stop can never be requested
by accident.
"""
isstoprequested(node::AbstractDataNode) = isstoprequested(node.state)
isstoprequested(st::NodeState) = st.stop
isstoprequested(::AbstractNodeState) = false

"""
    invalidate_unpublished!(model::Workflow, id::Int, ready_ports::Vector{Symbol})

Clear the consumer buffers of every `:normal` connection leaving a port that
this execution did **not** publish to.

Called by [`execute!`](@ref) right after [`push_buffer!`](@ref), and it is what
keeps "there is no value" distinguishable from "there is last turn's value".
Without it a node that publishes a port on one turn and not on the next leaves
its consumer reading the earlier value and reporting `:clean` - and a consumer
with an optional port can never tell that the producer went silent, which is
what makes conditional evaluation work at all.

`:feedback` connections are left alone: their buffers *are* the state of a
loop, which is exactly what has to survive a turn. So are `:error` ones, which
latch a diagnosis until something reads it.

See also [`push_buffer!`](@ref), [`invalidate_buffer!`](@ref).
"""
function invalidate_unpublished!(model::Workflow, id::Int, ready_ports::Vector{Symbol})
    haskey(model.outgoing, id) || return model
    node = getnode(model, id)
    for cid in model.outgoing[id]
        con = model.connections[cid]
        con.output_port in ready_ports && continue
        child = getnode(model, con.input_id)
        getportspec(child, con.input_port, :input).kind == :normal || continue
        invalidate_buffer!(child, con.input_port, cid)
    end
    return model
end

"""
    invalidate_stale_optional!(model::Workflow, id::Int)

Clear this node's buffer for every `:normal` connection entering an **optional**
port whose producer is not `:clean`.

The producer has not published in the current turn, so whatever sits in that
buffer came from an earlier one. [`invalidate_unpublished!`](@ref) covers the
producer that *ran* and stayed silent; this covers the producer that did not
run at all, whose buffer nothing else touches - [`mark_dirty_downstream!`](@ref)
deliberately leaves input buffers alone, because in a cyclic workflow they are
the loop state.

Called by [`scheduler!`](@ref) with `release_optional = true`, for the node it
is about to release, and only for one: a node that is ready under the ordinary
rule has every producer `:clean` and nothing stale to clear.

See also [`isready`](@ref), [`invalidate_buffer!`](@ref).
"""
function invalidate_stale_optional!(model::Workflow, id::Int)
    node = getnode(model, id)
    for con_id in get(model.incoming, id, Int[])
        con = getconnection(model, con_id)
        ps  = getportspec(node, con.input_port, :input)
        ps.kind == :normal || continue
        ps.required        && continue
        getstatus(getnode(model, con.output_id)) == :clean && continue
        invalidate_buffer!(node, con.input_port, con_id)
    end
    return model
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
        mark_if_clean!(getnode(model, nid)) || continue
        for con_id in get(model.outgoing, nid, Int[])
            con = model.connections[con_id]
            isfeedbackport(getnode(model, con.input_id), con.input_port) && continue
            push!(stack, con.input_id)
        end
    end
    return model
end

#  БАРЬЕРЫ. Параметр `N` обязателен: у `getstatus` и `getportspec` по одному
#  методу, поэтому без него Julia девиртуализует их и встроит прямо в
#  абстрактный контекст — доступ к полю снова станет динамическим, и барьера
#  не получится. С параметром она вынуждена подобрать специализацию по
#  фактическому типу узла.
function mark_if_clean!(node::N) where N <: AbstractDataNode
    getstatus(node) == :dirty && return false
    setstatus!(node, :dirty)
    return true
end

isfeedbackport(node::N, port::Symbol) where N <: AbstractDataNode =
    getportspec(node, port, :input).kind == :feedback


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
    isready(model::Workflow, id::Int; wait_optional::Bool = true)

Check whether a node is ready for execution.

A node is ready when, for every connection entering a **`:normal`** input
port, the producer has status `:clean` **and**, if the port is `required`, that
producer actually published to the port this connection leaves. Connections
entering ports of any other kind are not waited for.
 
The kind asymmetry is what makes cycles possible: a `:feedback` edge carries
the value of the previous iteration, so requiring its producer to be `:clean`
would deadlock - the node would wait for a producer that waits for the node.
 
The publication condition is what makes conditional evaluation work. A node
that publishes only some of its output ports - every gate in the package does
this - leaves the others with no value at all, and
[`invalidate_unpublished!`](@ref) clears the consumer buffers so that nothing
of the previous turn is read in their place. A consumer whose port is
`required` therefore is not ready and does not run, in either scheduler; one
whose port is `required = false` is ready and reads `nothing`, which is where
a condition can be acted on.

# `wait_optional`
An optional port's producer is waited for by default, and that wait is not
about the value - it is what separates "the producer published nothing" from
"the producer has not run yet". Both read `nothing`, and only the first one is
an answer.

With `wait_optional = false` an optional port stops contributing to readiness
altogether: a producer that is not `:clean` is read as absent instead of being
waited for. That is only sound where the producer has already had its chance
to run, so this is not something to set by hand - it is what
`scheduler!(model; release_optional = true)` uses, in the one place each
scheduler can guarantee it. Required ports are unaffected.

A node released this way may still be holding an earlier turn's value in the
optional port's buffer, which [`invalidate_stale_optional!`](@ref) clears.

# Notes
- Current node status itself is not checked.
- A port with **no connection at all** is a different case: this function
  walks connections and cannot see such a port. Completeness of required
  buffers is validated separately by [`execution_node_validation`](@ref),
  which both schedulers enable: such a port makes the node `:invalid_node`.
- A node with `:normal` input ports but no incoming connection is ready
  immediately; it just never gets enqueued unless something feeds it.
"""
function isready(model::Workflow, id::Int; wait_optional::Bool = true)
    return isready_node(model, getnode(model, id), id, wait_optional)
end

function isready_node(model::Workflow, node::N, id::Int,
                      wait_optional::Bool) where N <: AbstractDataNode
    connections = get(model.incoming, id, Int[])
    for con_id in connections
        con = getconnection(model, con_id)
        ps = getportspec(node, con.input_port, :input)
        ps.kind == :normal || continue
        isparentready(getnode(model, con.output_id), con, ps, wait_optional) || return false
    end
    return true
end

#  Родитель у каждой связи свой, поэтому ему нужен отдельный барьер.
function isparentready(parent_node::N, con::NodeConnection, ps::PortSpec,
                       wait_optional::Bool) where N <: AbstractDataNode
        if ps.required
            getstatus(parent_node) != :clean && return false # crytical for cycling
            #  Родитель :clean, но в ЭТОТ порт на своём исполнении не публиковал: значения нет и не будет.
            # Для обязательного порта это значит "не готов2, и узел не исполняется — иначе он посчитал бы на nothing.
            (con.output_port in getstate(parent_node, :ready_ports)) || return false
        elseif wait_optional
            #  Отсутствие значения на необязательном порту законно, на
            #  нем и стоит условное вычисление. Но ждать производителя
            #  все равно надо, пока он может отработать: иначе `nothing`
            #  значит не "нечего ждать", а "еще не посчитано".
            getstatus(parent_node) != :clean && return false
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
Both schedulers enable it, so a `required` `:normal` port left without a
connection makes the node `:invalid_node` in either engine. A port that *has* a
connection whose producer published nothing is a different case, caught earlier
by [`isready`](@ref).
 
# Returns
- `true` if node is ready for execution.
- `false` otherwise.
"""
function execution_node_validation(node::AbstractDataNode, check_input_buffer::Bool = true)
    #  Обязательный обычный порт должен иметь значение в буфере. 
    # Цикл вместо `all` с замыканием: замыкание захватывает node и аллоцирует, а
    #  эта функция зовётся на каждое исполнение узла.
    if check_input_buffer
        for ps in node.spec.input_ports
            ps.kind == :normal || continue
            ps.required        || continue
            isempty(node.input_buffer[ps.label]) && return false
        end
    end
    return validate_node(node)
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
    haskey(model.outgoing, id) || return model
    return push_buffer_from!(model, getnode(model, id), id, ready_ports)
end

#  БАРЬЕР: публикующий узел приходит аргументом, поэтому `getdata` из него
#  уходит статическим вызовом, а не диспатчем на каждую связь.
function push_buffer_from!(model::Workflow, node::N, id::Int,
                           ready_ports::Vector{Symbol}) where N <: AbstractDataNode
    for cid in model.outgoing[id]
        con = model.connections[cid]
        con.output_port in ready_ports || continue
        #  У потребителя тип свой, поэтому ему нужен собственный барьер.
        setinputbuffer!(getnode(model, con.input_id), con.input_port, cid,
                        getdata(node, con.output_port))
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
    if model.ver == model.graph.ver
        return  model.graph.graph
    end
    g = NamedDiGraph{Int}()
    for (k, v) in model.nodes
        add_vertex!(g, k)
    end
    for (k, v) in model.connections
        add_edge!(g, v.output_id, v.input_id)
    end
    model.graph.ver = model.ver
    model.graph.graph = g
    return g
end

function is_cyclic(model::Workflow)
    if model.ver == model.graph.ic_ver
        return  model.graph.is_cyclic
    end
    g  = makegraph(model)
    ic = is_cyclic(g)
    model.graph.is_cyclic = ic
    model.graph.ic_ver = model.ver 
    return ic
end

function topological_sort(model::Workflow)
    if model.ver == model.graph.ts_ver
        return model.graph.topological_sort
    end
    g  = makegraph(model)
    ts = topological_sort(g)
    model.graph.ts_ver = model.ver 
    model.graph.topological_sort = ts
    return ts
end



# End Module:
end
