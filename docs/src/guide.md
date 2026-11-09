```@meta
CurrentModule = MetidaFlows
```

```@setup mfexample
using MetidaFlows, CSV, DataFrames
CSV_PATH = joinpath(pwd(), "data.csv")
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

Two different jobs share this part of the API:

* **serializing a workflow** — turning the graph into plain dictionaries, so it
  can be written to JSON and inspected;
* **describing a node** — telling a user interface which settings the node
  accepts, how to render them and how to present the node itself.

The first is fixed: the engine knows what a graph is made of. The second is
open-ended, because only the node author knows what its settings mean, so the
engine provides two hooks and gets out of the way.

### Serializing a workflow

[`workflow_to_dict`](@ref) produces a JSON-ready snapshot of the structure:
nodes, connections and the incoming/outgoing indices.

```julia
d = workflow_to_dict(w)
keys(d)   # "id", "name", "n_iter", "c_iter", "nodes", "connections", "incoming", "outgoing"
```

Two details are easy to trip over:

* `"nodes"` and `"connections"` are keyed by *stringified* ids, while
  `"incoming"` and `"outgoing"` keep integer node ids;
* execution state — `run_id`, logs, cached output data and the current setting
  *values* — is not included. The snapshot describes structure only.

Building blocks, usable on their own: [`node_to_dict`](@ref),
[`node_properties_to_dict`](@ref), [`spec_to_dict`](@ref),
[`portspec_to_dict`](@ref), [`connection_to_dict`](@ref).

### What a schema is

A schema is the dictionary a graph editor reads to draw one node: its ports,
its settings form, its place in the node palette.

The engine fills in only what it can know by itself. Take a filtering node that
declares two settings:

```@example mfexample
using MetidaFlows: settings_schema, node_schema, getnode

struct FilterRows <: AbstractNodeType end

filter_spec = NodeSpec("Filter rows",
    [PortSpec("Table", DataFrame, :table)],
    [PortSpec("Table", DataFrame, :table)],
    [:column, :threshold])

settings_schema(DataNode(FilterRows, filter_spec))
```

`"settingslist"` is a copy of `spec.settings` — the keys the node understands,
and nothing more. It is enough to know *that* there are two settings, but not
enough to render a form: no types, no defaults, no labels.

[`node_schema`](@ref) adds the port specification:

```@example mfexample
sort(collect(keys(node_schema(DataNode(FilterRows, filter_spec)))))
```

Everything beyond that comes from the two hooks.

### Describing settings: `settings_schema_usermod!`

Specialize it on your node type and fill in `d`:

```@example mfexample
function MetidaFlows.settings_schema_usermod!(d, node::DataNode{FilterRows})
    d["schema"] = Dict{String, Any}(
        "column" => Dict{String, Any}(
            "type"        => "Symbol",
            "description" => "Column to compare",
            "required"    => true,
            "options"     => Symbol[]),
        "threshold" => Dict{String, Any}(
            "type"        => "Float64",
            "default"     => 0.0,
            "description" => "Keep rows whose value is greater than this",
            "required"    => true,
            "min"         => 0.0))
    return d
end

settings_schema(DataNode(FilterRows, filter_spec))["schema"]["threshold"]
```

The contract is short:

* `d` arrives already holding `"settingslist"`; add to it, don't rebuild it;
* the hook receives the node, so the schema may depend on its current state;
* **mutate `d`** — the return value is discarded (see *Things to watch*).

### Conventional keys

The engine never reads the contents of `"schema"`: it passes the dictionary
through untouched. The keys are therefore a contract between the node author
and the interface, not a format the package enforces. These are the ones worth
keeping to, because the rest of the ecosystem expects them:

| Key | Meaning |
|---|---|
| `"type"` | datatype of the value, as a string (`"Int"`, `"Symbol"`, `"Vector{Float64}"`) |
| `"default"` | value to offer when the setting is unset |
| `"description"` | one line for a label or tooltip |
| `"required"` | whether the node cannot run without it |
| `"options"` | allowed values, for a dropdown |
| `"min"`, `"max"` | bounds for a numeric input |
| `"pinned"` | show on the node body, not only in the settings panel |
| `"source"` | where the value comes from: `"upstream"`, `"user"`, `"none"` |

Validation is a separate matter: a schema tells the interface what to *offer*,
while [`validate_settings`](@ref) decides whether the node may run. Keep the
real check there — a value can always arrive without passing through a form.

### Options that come from upstream

The useful case is a setting whose choices are only known from the producer: a
column name that exists in the file the parent node will read. The engine
supplies the fact — [`getinputmeta`](@ref) — and the caller composes the form.

The producer describes its output through [`getmeta_unsafe`](@ref), reading
only the header:

```@example mfexample
struct ReadTable <: AbstractNodeType end

read_spec = NodeSpec("Read table", PortSpec[],
    [PortSpec("Table", DataFrame, :table)], [:file])

function MetidaFlows.execute_unsafe!(node::DataNode{ReadTable})
    setdata!(node, :table, DataFrame(CSV.File(node.settings[:file])))
    return [:table]
end

MetidaFlows.ismetasource(node::DataNode{ReadTable}, ::Symbol) = haskey(node.settings, :file)

function MetidaFlows.getmeta_unsafe(node::DataNode{ReadTable}, ::Symbol, inmeta)
    path = get(node.settings, :file, nothing)
    (path === nothing || !isfile(path)) && return nothing
    return (columns = propertynames(CSV.File(path; limit = 0)),)
end

# a row filter does not change the schema, so it passes the input description through
MetidaFlows.getmeta_unsafe(::DataNode{FilterRows}, ::Symbol, inmeta) = inmeta[:table]
nothing # hide
```

Filling the options is then three lines on the caller's side:

```@example mfexample
function filter_form(w, id)
    d = settings_schema(getnode(w, id))
    m = getinputmeta(w, id)[:table]
    m === nothing || (d["schema"]["column"]["options"] = m.columns)
    return d
end
nothing # hide
```

```@example mfexample
wf  = Workflow(1)
src = add_node!(wf, DataNode(ReadTable,  read_spec))
flt = add_node!(wf, DataNode(FilterRows, filter_spec))
add_connection!(wf, src, :table, flt, :table)

filter_form(wf, flt)["schema"]["column"]["options"]   # the source is not configured yet
```

```@example mfexample
setsettings!(wf, src, Dict(:file => CSV_PATH))

filter_form(wf, flt)["schema"]["column"]["options"]   # names taken from the file header
```

Nothing has been executed: the file was opened for its header only. An empty
list of options is an honest signal that the producer is not configured yet.

### Describing the node: `node_schema_usermod!`

The same pattern, one level up — everything about the node itself rather than
its settings. `d` arrives holding `"settings_schema"` and `"spec"`:

```@example mfexample
function MetidaFlows.node_schema_usermod!(d, node::DataNode{FilterRows})
    d["section"]     = "Tables"           # node palette section
    d["groupname"]   = "Filtering"        # group within that section
    d["color"]       = "#8b5cf6"
    d["icon"]        = "filter"
    d["description"] = "Keeps rows whose value in the chosen column exceeds a threshold."

    # the hook sees the node, so the caption may depend on its settings
    col = get(node.settings, :column, nothing)
    d["caption"] = col === nothing ? "not configured" : "filter on $(col)"
    return d
end

sort(collect(keys(node_schema(getnode(wf, flt))))) 
```

```@example mfexample
node_schema(getnode(wf, flt))["caption"]
```

```@example mfexample
setsettings!(wf, flt, Dict(:column => :length, :threshold => 100.0))

node_schema(getnode(wf, flt))["caption"]
```

Use this hook for presentation and grouping; use
`settings_schema_usermod!` for the form itself.

### Things to watch

* **The hook's return value is ignored.** Both hooks are called for their
  effect on `d`, and `settings_schema` / `node_schema` return the `d` they
  passed in. A hook that builds a fresh dictionary and returns it silently
  does nothing:

  ```julia
  # wrong: the dictionary is built, but d is untouched, so the result is lost
  function MetidaFlows.settings_schema_usermod!(d, node::DataNode{MyNode})
      return Dict("schema" => ...)
  end
  ```

  Write into `d` and return it, as in the examples above.

* **Functions do not survive JSON.** A `"validator" => x -> x >= 0` entry
  encodes as the string `"#2"` — no error, just a useless value. Express
  constraints declaratively (`"min"`, `"max"`, `"options"`) and keep the
  executable check in [`validate_settings`](@ref). Types are safer written as
  strings: `"type" => "Float64"` rather than `"type" => Float64`.

* **`node_to_dict`'s `"settings"` key holds the settings *schema*, not the
  current values.** Setting values are not part of any dictionary the package
  produces; read them from `node.settings`.

* Both hooks are called on every `settings_schema` / `node_schema` call, so
  keep them cheap. Inspecting a file is fine; computing anything is not.

---

## A larger example

Loading a CSV file, converting it and summarising it:

```@example mfexample
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

setsettings!(w, id1, Dict(:file => CSV_PATH))

scheduler!(w, throw_error = true)
getdata(w, id3, :nrows) # 3
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
nothing.

Check the execution counters rather than the statuses:

```julia
scheduler!(w)

idle = [id for (id, node) in w.nodes if getstate(node, :exec_n) == 0]
```

If `idle` contains the whole loop, check that some node upstream of it has no
input ports. The same check catches a different mistake: a node that has
normal inputs but no incoming connection never becomes ready either, and never
runs.

`exec_n` is the right signal here and `getstatus` is not. In a cyclic
workflow a finished run legitimately leaves part of the graph `:dirty` - see
*Rule 3* - so "not `:clean`" does not mean "never ran".

---

## Rule 3. Inside a turn, a node waits for all of its normal ancestors

The `ABW` scheduler serves a FIFO queue, and [`isready`](@ref) lets a node run
once every producer on a `:normal` port is `:clean`. On its own that is not
enough for a loop: at the start of a turn the whole body is still `:clean`
**from the previous turn**, so a node could run on values that are one turn old.

What prevents it is step 4 of the scheduler. When a node publishes, the
scheduler marks `:dirty` not only its direct children but **everything
downstream of them**, following `:normal` edges
([`mark_dirty_downstream!`](@ref)). A node is therefore held back until every
one of its `:normal` ancestors has been recomputed during this turn.

This matters because without it the result would depend on the order in which
the connections were created. `model.outgoing` keeps connection ids in
insertion order, and that is the order the queue is served in, so a node with
a short edge from the loop head and a longer path to the same value could be
served before the long path caught up. Two workflows with identical nodes and
identical edges would then behave differently.

So you are free to wire a loop body the way the algorithm reads: each node
takes the inputs it needs, from whatever depth. There is no need to equalize
path lengths or to thread values through intermediate nodes.

A feedback edge is never followed by this invalidation: it means "next turn",
so marking through it would restart the body from the middle of a turn.

### Two consequences worth knowing

**A finished cyclic run leaves part of the graph `:dirty`.** On the last pass
the loop head marks the body dirty as usual, the gate then publishes only a
terminal port, and the body is never recomputed — correctly, because there was
nothing left to compute. So for a cyclic workflow "every node is `:clean`" is
not a completion signal; use `exec_n`, or the data on the terminal port.

**A full reset clears the loop state.** [`reset!`](@ref) with `soft = false`
— which is what `reset_mode = :full` uses — empties the buffers of `:feedback`
ports along with the cached output data. Without that a second
[`scheduler!`](@ref) call would find the last turn's state in the feedback
buffer and resume the previous run instead of starting a new one. `:soft` keeps
those buffers on purpose: that is how state is carried between runs.

`reset_mode = :none` is a third thing again, and not a no-op on a cycle:
[`execute!`](@ref) returns the stored `ready_ports` of a `:clean` node, the
scheduler propagates from them, and the children recompute on whatever the
buffers still hold. Use `:soft` to continue a loop and `:full` to start one.