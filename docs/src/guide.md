```@meta
CurrentModule = MetidaFlows
```

# User guide

This page describes the execution model in detail. It assumes you have read the quick start example on the home page.

---

## Anatomy of a node

A node has two halves: a *declaration* that never changes and a *state* that the engine mutates.

| Part | Type | Contents |
|---|---|---|
| `spec` | [`NodeSpec`](@ref) | ports and settings keys - the contract |
| `properties` | [`NodeProperties`](@ref) | id, status, editor position |
| `settings` | `Dict{Symbol,Any}` | configuration values |
| `data` | `Dict{Symbol,Any}` | cached outputs, keyed by output port label |
| `state` | [`NodeState`](@ref) | ready ports, run id, per-run log |
| `input_buffer` | nested `Dict` | `input_buffer[port][connection id] = value` |

The spec is the single source of truth. [`setdata!`](@ref) refuses labels that
are not output ports, [`getinputdata`](@ref) refuses labels that are not input
ports, and connection validation refuses ports that do not exist at all.

Ports are declared with [`PortSpec`](@ref):

```julia
PortSpec("Input table", DataFrame, :table)                       # required SinglePort
PortSpec("Extra", Int, :extra, SinglePort(); required = false)   # optional
PortSpec("Values", Int, :values, MultiPort())                    # many-to-one
```

The `datatype` is used for connection type checking, `label` is the symbol you
use everywhere in code, and `required` controls whether the engine refuses to
run a node whose buffer is still empty.

Introspection helpers: [`haveinputs`](@ref), [`getportnumber`](@ref),
[`getporttype`](@ref), [`getportspec`](@ref), [`isportexist`](@ref),
[`ismultiport`](@ref), [`nodetypestr`](@ref).

---

## Building a graph

```julia
w  = Workflow(1)                      # Workflow{DAW}
id = add_node!(w, DataNode(MyNode, spec))
cid = add_connection!(w, parent_id, :out, child_id, :in)
```

[`add_connection!`](@ref) validates through
[`check_connection_validity`](@ref) and raises unless:

* both nodes exist,
* both ports exist in their specs,
* the target input port is free, or declared as a [`MultiPort`](@ref),
* the output datatype is a subtype of the input datatype.

A rejected connection consumes nothing. Identifiers come from monotonically
increasing counters, so **ids of deleted nodes and connections are never
reused** - after `delete_node!(w, 2)` the next node is `3`.

Two ordering rules are worth remembering:

* [`add_node!`](@ref) resets a node not in `:idle` or `:clean` state. 
Configure with [`setsettings!`](@ref) *after* adding.
* if the parent is already `:clean` when the connection is created, its output
  is copied into the child buffer immediately - no recomputation needed.

Topology queries: [`getnode`](@ref), [`getconnection`](@ref),
[`isnodeexist`](@ref), [`find_connections`](@ref),
[`getportconnections`](@ref), [`get_parents`](@ref), [`get_children`](@ref).

---

## Writing node behaviour

Behaviour is attached to a singleton [`AbstractNodeType`](@ref) subtype through
[`execute_unsafe!`](@ref):

```julia
struct Doubler <: AbstractNodeType end

function MetidaFlows.execute_unsafe!(node::DataNode{Doubler})
    x = getinputdata(node, :in)
    setdata!(node, :out, 2x)
    return [:out]          # ports produced by this call
end
```

The returned vector is the contract with the engine: only connections leaving
these ports are refreshed by [`push_buffer!`](@ref), and the vector is stored
as the `ready_ports` state. A node may legitimately return a subset of its
output ports.

Four optional hooks specialise validation; all default to `true`:

| Hook | When | Status on failure |
|---|---|---|
| [`validate_node`](@ref) | before execution, from [`execution_node_validation`](@ref) | `:invalid_node` |
| [`validate_settings`](@ref) | before execution | `:invalid_settings` |
| [`validate_result`](@ref) | after execution, before propagation | `:invalid_result` |
| [`setsettings_unsafe!`](@ref) | on settings assignment | - (customisation point) |

Because [`validate_result`](@ref) runs *before* [`push_buffer!`](@ref), a node
that fails result validation never publishes anything downstream.

---

## Statuses and the execution lifecycle

| Status | Meaning |
|---|---|
| `:idle` | freshly created, never executed, no settings applied |
| `:dirty` | needs (re)computation |
| `:executing` | currently running - also used to detect re-entry |
| `:clean` | up to date, outputs cached |
| `:failed` | [`execute_unsafe!`](@ref) raised |
| `:invalid_node` | structure or required inputs missing |
| `:invalid_settings` | [`validate_settings`](@ref) returned `false` |
| `:invalid_result` | [`validate_result`](@ref) returned `false` |

[`execute!`](@ref) walks these stages:

1. reset the per-run node log if the run changed;
2. detect re-entry (`check_cyclic`) and warn instead of recursing forever;
3. return immediately if the node is already `:clean`;
4. mark `:executing`;
5. execute parents recursively (`execute_upstream`);
6. validate structure, required inputs (`check_input_buffer`) and settings;
7. call [`execute_unsafe!`](@ref);
8. validate the result;
9. store `ready_ports` and push outputs into the child buffers;
10. invalidate children (`invalidate_downstream`);
11. mark `:clean`.

The four flags in parentheses come from [`ExecuteSettings`](@ref):

```julia
execute!(w, id)                                                   # all flags on
execute!(w, id; settings = ExecuteSettings(; execute_upstream = false))
execute!(w, id; settings = ExecuteSettings(false))                # all flags off
```

`execute!` returns the vector of ports produced, or an empty vector when the
node was rejected or failed - so an empty result is a signal to inspect
[`getstatus`](@ref).

---

## Invalidation and caching

Caching is what makes incremental recomputation work: a `:clean` node returns
its stored `ready_ports` without calling [`execute_unsafe!`](@ref) again.
Everything that could make a cached result wrong therefore has to mark nodes
`:dirty`.

[`invalidate_downstream!`](@ref) is the propagation primitive. Starting at a
node it marks it `:dirty`, drops its cached outputs, deletes the child buffer
entry belonging to each outgoing connection and recurses. Traversal stops at
nodes that are already `:dirty`, since their subtree was invalidated earlier.

It is triggered by [`setsettings!`](@ref), [`add_connection!`](@ref),
[`delete_connection!`](@ref) and by [`execute!`](@ref) itself.

Three reset levels are available:

| Function | Status | Cached outputs | Settings, buffers, logs |
|---|---|---|---|
| [`reset_status!`](@ref) | `:dirty` | kept | kept |
| [`mark_dirty!`](@ref), [`reset!`](@ref) on a workflow | `:dirty` | cleared | kept |
| [`reset!`](@ref) on a node | `:idle` | cleared | cleared |

Low-level buffer access - [`setinputbuffer!`](@ref),
[`invalidate_buffer!`](@ref), [`push_buffer!`](@ref) - is available when you
drive execution manually, but note that writing a buffer by hand bypasses
invalidation.

---

## Schedulers

```julia
scheduler!(w)                    # DAW
scheduler!(w; maxiter = 5000)    # ABW
```

|  | [`DAW`](@ref) | [`ABW`](@ref) |
|---|---|---|
| Order | topological, via [`makegraph`](@ref) | readiness queue |
| Cycles | rejected before execution | not detected up front |
| Per run | [`reset!`](@ref): statuses and cached outputs | statuses only |
| Required inputs | enforced | **not** enforced (`ExecuteSettings(false)`) |
| Nodes executed | every node, once | only nodes reachable from input-free nodes |

Both return `true` when the traversal finishes. That is *not* a success flag:
individual nodes may still end up `:failed` or `:invalid_*`, so check
[`getstatus`](@ref) when correctness matters.

In `ABW`, a node popped while a parent is still `:dirty` is dropped and
re-queued later by that parent; [`isready`](@ref) implements the check. A node
that has input ports but no incoming connection never becomes ready and stays
`:dirty`.

---

## Many-to-one inputs

A [`MultiPort`](@ref) input accepts any number of connections. Values are
keyed by connection id, so parents never overwrite each other:

```julia
spec = NodeSpec("Collect",
    [PortSpec("values", Int, :ins, MultiPort())],
    [PortSpec("sum", Int, :out)])

function MetidaFlows.execute_unsafe!(node::DataNode{Collect})
    buffer = getinputdata(node, :ins)          # Dict{connection id, value}
    setdata!(node, :out, sum(values(buffer); init = 0))
    return [:out]
end
```

For a [`SinglePort`](@ref), [`getinputdata`](@ref) returns the single value, or
`nothing` if the buffer is empty. A specific connection can always be read with
`getinputdata(node, label, connection_id)`.

---

## Serialization and schemas

[`workflow_to_dict`](@ref) produces a JSON-ready snapshot of the structure:
nodes, connections and the incoming/outgoing indices. Note that `"nodes"` and
`"connections"` are keyed by stringified ids while `"incoming"` and
`"outgoing"` keep integer ids, and that execution state (`run_id`, logs,
cached data) is not included.

Building blocks: [`node_to_dict`](@ref), [`node_properties_to_dict`](@ref),
[`spec_to_dict`](@ref), [`portspec_to_dict`](@ref),
[`connection_to_dict`](@ref).

Schemas describe a node to a UI. Extend them per node type:

```julia
function MetidaFlows.settings_schema_usermod!(d, node::DataNode{MyNode})
    d["schema"] = Dict("threshold" => Dict(
        "type" => Float64, "default" => 0.5, "required" => true,
        "validator" => x -> 0 <= x <= 1))
    return d
end

function MetidaFlows.node_schema_usermod!(d, node::DataNode{MyNode})
    d["section"] = "Statistics"
    d["color"]   = "#8b5cf6"
    return d
end
```

[`settings_schema`](@ref) and [`node_schema`](@ref) call these hooks. Keep in
mind that the `"settings"` key of [`node_to_dict`](@ref) holds the settings
*schema*, not the current values.

---

## A larger example

Loading a CSV file, converting it and summarising it:

```julia
using MetidaFlows, CSV, DataFrames
using MetidaFlows: Workflow, NodeSpec, PortSpec, DataNode, AbstractNodeType,
                   add_node!, add_connection!, setsettings!, scheduler!,
                   getdata, setdata!, getinputdata

struct LoadCSV     <: AbstractNodeType end
struct ToDataFrame <: AbstractNodeType end
struct Summarise   <: AbstractNodeType end

csv_spec = NodeSpec("Load CSV", PortSpec[],
    [PortSpec("CSV File", CSV.File, :csv)], [:file])

df_spec = NodeSpec("DataFrame",
    [PortSpec("CSV File", CSV.File, :csv)],
    [PortSpec("DataFrame", DataFrame, :dataframe)])

sum_spec = NodeSpec("Summary",
    [PortSpec("DataFrame", DataFrame, :dataframe)],
    [PortSpec("Row count", Int, :nrows)])

function MetidaFlows.execute_unsafe!(node::DataNode{LoadCSV})
    setdata!(node, :csv, CSV.File(node.settings[:file]))
    return [:csv]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ToDataFrame})
    setdata!(node, :dataframe, DataFrame(getinputdata(node, :csv)))
    return [:dataframe]
end

function MetidaFlows.execute_unsafe!(node::DataNode{Summarise})
    setdata!(node, :nrows, size(getinputdata(node, :dataframe), 1))
    return [:nrows]
end

w   = Workflow(0)
id1 = add_node!(w, DataNode(LoadCSV, csv_spec))
id2 = add_node!(w, DataNode(ToDataFrame, df_spec))
id3 = add_node!(w, DataNode(Summarise, sum_spec))

add_connection!(w, id1, :csv, id2, :csv)
add_connection!(w, id2, :dataframe, id3, :dataframe)

setsettings!(w, id1, Dict(:file => "data.csv"))

scheduler!(w)
getdata(w, id3, :nrows)
```

Changing the file path invalidates the whole chain; executing `id3` again
recomputes all three nodes. Changing nothing and executing again recomputes
nothing.

---

## Things to keep in mind

* Settings are **merged**, not replaced: `setsettings!` only overwrites the
  keys you pass.
* Manual `execute!` with `execute_upstream = false` will not refresh stale
  parents; the node is simply rejected with `:invalid_node` if a required
  input is missing.

## Port kinds

Every [`PortSpec`](@ref) carries a `kind`, defaulting to `:normal`. The kind
does not change how data is stored or read — it changes how the schedulers
treat the connections attached to the port.

| `kind` | Applies to | Effect |
|---|---|---|
| `:normal` | input, output | the default: an ordinary data connection |
| `:feedback` | **input only** | closes a cycle; carries the value of the previous iteration |
| `:terminal` | output (by intent) | a slot for a result that is not meant to be connected |
| `:error` | input, output | reserved for error routing; must be `required = false` and its datatype must be a subtype of `Exception` |

Declaring `kind = :feedback` on an output port is rejected by the
[`NodeSpec`](@ref) constructor: a delay is a property of the consumer, not of
the producer.

Two engine functions read the kind:

* [`isready`](@ref) waits only for producers connected through `:normal`
  ports. Anything else is not waited for.
* [`execution_node_validation`](@ref) requires a filled input buffer only for
  `:normal` ports, so a feedback port may be empty on the first pass.

Everything else — buffering, invalidation, serialization — is identical for
all kinds.

---

## Rule 1. Cycles are an `ABW` feature

[`makegraph`](@ref) builds the graph from **all** connections, whatever the
kind of the ports they attach to. [`scheduler!`](@ref) for a
[`DAW`](@ref) workflow rejects the result if it is cyclic:

```julia
scheduler!(w)   # ERROR: workflow is cyclic
```

This is deliberate. `DAW` guarantees that every node executes exactly once per
run in dependency order, and that guarantee has no meaning in a graph with a
cycle. A feedback edge does not change it: in a `DAW` workflow a
`:feedback` port is simply an input that is exempt from the required-buffer
check, and nothing more — there is no delay, no iteration, no second pass.

Use [`ABW`](@ref) for anything that has to iterate.

---

## Rule 2. A cyclic `ABW` workflow needs a seed node

The `ABW` scheduler starts from nodes that have **no input ports at all**:

```julia
for (id, node) in model.nodes
    if !haveinputs(node)
        push!(queue, id)
    end
end
```

A `:feedback` port is still an input port. A node whose only inputs are
feedback (or `:error`) ports is therefore *not* a starting point, and a loop
made only of such nodes never begins.

**Every cyclic workflow must contain at least one node with no input ports,
and the loop must be reachable from it through `:normal` connections.**

This is not merely a scheduling detail. A loop needs two things to be
well-defined: a delay, so that the cycle has a direction in time, and an
initial value, so that the first pass has something to compute with. The
`:feedback` port provides the first; the seed node provides the second. A
graph consisting only of a loop has neither a beginning nor initial data, and
there is nothing sensible for the scheduler to do with it.

In practice the seed node is the one that loads or generates the data — as
`LoadData` in the examples — and the loop body starts from its normal input on
the first pass:

```julia
previous = getinputdata(node, :previous)      # empty on the first pass
state = previous === nothing ?
    initial_state(getinputdata(node, :table)) :
    previous
```

### Diagnosing a loop that never started

A workflow that cannot be seeded is not an error: the queue is empty, the loop
body is never reached, and [`scheduler!`](@ref) returns `true` having executed
nothing. The symptom is that the nodes stay `:dirty`:

```julia
scheduler!(w)

stalled = [id for (id, node) in w.nodes if getstatus(node) != :clean]
```

If `stalled` contains the whole loop, check that some node upstream of it has
no input ports.

The same check is worth running after any `ABW` run for another reason: a node
that has normal inputs but no incoming connection never becomes ready either,
and stays `:dirty` in exactly the same way.