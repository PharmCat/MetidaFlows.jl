```@meta
CurrentModule = MetidaFlows
```

# Typed node containers

A node keeps three things of its own — its settings, its output data and its
execution state — and by default each is a `Dict{Symbol, Any}`. That is
convenient and it is what every example in the guide uses. It is also untyped:
a settings key is whatever was put there, a typo is a missing key rather than a
compile-time error, and every read goes through a dictionary lookup returning
`Any`.

Those three containers can be **structs of your own** instead. Then a node
declares its settings the way the rest of your code does, with field names and
field types, and the engine works with them exactly as it works with a `Dict`.

```@example typed
using MetidaFlows
import MetidaFlows: PortSpec, AbstractNodeSettings, AbstractNodeData, getnode

mutable struct ScaleSettings <: AbstractNodeSettings
    factor::Float64
    ScaleSettings() = new(1.0)          # see "Resetting", below
end

mutable struct ScaleData <: AbstractNodeData
    out::Union{Float64, Nothing}
    ScaleData() = new(nothing)
end
nothing # hide
```

## What a container has to provide

Subtyping [`AbstractNodeFields`](@ref) — which is what
[`AbstractNodeSettings`](@ref), [`AbstractNodeData`](@ref) and
[`AbstractNodeState`](@ref) do — gives the struct the whole interface the
engine uses, mapped onto its fields:

```@example typed
s = ScaleSettings()
(getindex = s[:factor], keys = keys(s), haskey = haskey(s, :factor),
 get_missing = get(s, :nope, :fallback))
```

| method | maps to | the engine needs it for |
|:---|:---|:---|
| `getindex(obj, f)` | `getfield` | node bodies, [`getdata`](@ref) |
| `setindex!(obj, v, f)` | `setfield!` | [`setdata!`](@ref), [`setsettings!`](@ref) |
| `keys(obj)` | `fieldnames` | introspection, error messages |
| `haskey(obj, f)` | `hasfield` | [`settings_to_dict`](@ref) |
| `get(obj, f, default)` | field or `default` | [`getdata`](@ref) |
| `empty!(obj)` | reset, see below | [`mark_dirty!`](@ref), [`reset!`](@ref) |

You write none of these. The container must be a `mutable struct`, because the
engine writes to it.

## Resetting

`empty!` is the one method with a condition. A `Dict` can be emptied; a struct
with fixed fields has no empty state, so the generic method builds a fresh
instance with `T()` and copies its fields over. **Give the struct a
zero-argument constructor** — that is what the two above are for — or define
`Base.empty!` yourself, the way [`NodeState`](@ref) does.

```@example typed
s[:factor] = 12.5
empty!(s)
s[:factor]        # back to what ScaleSettings() gives
```

This matters more than it looks: the engine clears a node's cached output data
on every invalidation, which happens on `add_connection!`, on `setsettings!`
and at the start of every run. A data container that cannot be reset stops the
graph before it is even wired up. If neither a constructor nor an `empty!`
exists, the error says so and names the type:

```julia
julia> empty!(NoDefault(5))
ERROR: NoDefault has no zero-argument constructor, so `empty!` has nothing to
reset it to: add `NoDefault() = ...` or define `Base.empty!(::NoDefault)`
```

## How a node gets them

Four functions decide which containers a node of a given type is built with:
[`nodesettings`](@ref), [`nodedata`](@ref), [`nodestate`](@ref) and
[`nodebuffer`](@ref). Specialize the ones you need:

```@example typed
struct Scale <: AbstractNodeType end

MetidaFlows.nodesettings(::Type{Scale}) = ScaleSettings()
MetidaFlows.nodedata(::Type{Scale})     = ScaleData()
MetidaFlows.nodebuffer(::Type{Scale})   = Dict{Symbol, Dict{Int, Float64}}()

spec_scale() = NodeSpec("Scale", [PortSpec("In", Float64, :in)],
                                 [PortSpec("Out", Float64, :out)], [:factor])

MetidaFlows.execute_unsafe!(n::DataNode{Scale}) =
    (setdata!(n, :out, getinputdata(n, :in) * n.settings[:factor]); [:out])

typeof(DataNode(Scale, spec_scale()))
```

No keyword arguments: the node comes out typed because that is what its type
says it is made of. A node type you have not specialized keeps the `Dict`
default, so this is opt-in per node type and mixing the two in one graph is
normal.

Each function is called once per node and returns a **fresh** container, so two
nodes of one type never share one. An explicit keyword still wins:
`DataNode(Scale, spec_scale(); settings = Dict{Symbol, Any}())` gives that one
node a `Dict` for settings and keeps the typed data container.

## In a graph

Everything else is unchanged — the same `setsettings!`, the same scheduler, the
same statuses:

```@example typed
struct ConstF <: AbstractNodeType end
spec_const() = NodeSpec("Const", PortSpec[], [PortSpec("Out", Float64, :out)], [:value])
MetidaFlows.execute_unsafe!(n::DataNode{ConstF}) =
    (setdata!(n, :out, Float64(n.settings[:value])); [:out])

w = Workflow(0; type = :DAW)
c = add_node!(w, DataNode(ConstF, spec_const())); setsettings!(w, c, Dict(:value => 2.5))
s = add_node!(w, DataNode(Scale,  spec_scale())); setsettings!(w, s, Dict(:factor => 4.0))
add_connection!(w, c, :out, s, :in)
scheduler!(w)

(result = getdata(w, s, :out),
 scale_node  = typeof(getnode(w, s)),
 const_node  = typeof(getnode(w, c)))
```

The buffer's value type is checked on write, which is a second thing typing
buys: a producer publishing the wrong type is caught at the buffer rather than
inside the consumer's body.

```@example typed
try
    MetidaFlows.setinputbuffer!(getnode(w, s), :in, 1, "not a number")
catch e
    sprint(showerror, e)
end
```

## Through a snapshot

[`dict_to_node`](@ref) builds a loaded node from the same four functions, so a
typed graph comes back typed. Nothing about the containers is read from the
file — like the node type and the spec, they are decided by the running code,
which is what keeps loading a snapshot from being able to construct anything
your code did not declare.

```@example typed
import MetidaFlows: register_node!, workflow_to_dict, dict_to_workflow

register_node!(w)
d  = workflow_to_dict(w)
w2 = dict_to_workflow(d)
scheduler!(w2)

(loaded_node = typeof(getnode(w2, s)),
 same_type   = typeof(getnode(w2, s)) === typeof(getnode(w, s)),
 factor      = getnode(w2, s).settings[:factor],
 result      = getdata(w2, s, :out))
```

## What is not typeable yet

The **input buffer's container** is fixed. The field is declared
`Dict{Symbol, Dict{Int, BufferT}}`, so only the value type `BufferT` is a
parameter, and that is what [`nodebuffer`](@ref) chooses. A struct subtyping
[`AbstractNodeInputBuffer`](@ref) cannot be passed to a node today; allowing it
means changing the `DataNode` struct.

Two more things worth knowing before building on this:

* **state is typeable but not fully supported.** `nodestate` accepts any
  subtype of [`AbstractNodeState`](@ref), but [`request_stop!`](@ref) needs a
  `stop` field and so works on [`NodeState`](@ref) only;
  [`isstoprequested`](@ref) reports `false` for anything else. Unless you need
  a custom state, leave `nodestate` alone.
* **settings arrive as a `Dict` and are merged field by field.**
  [`setsettings!`](@ref) and the snapshot loader both write through
  `setindex!`, one key at a time, so a value whose type does not match the
  field raises a `convert` error naming the field. A key the struct does not
  have is an error too — with a `Dict` it would have been silently accepted.
