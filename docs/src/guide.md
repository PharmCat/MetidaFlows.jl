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

## Drawing a workflow

A graph you can look at is the fastest way to find out whether the one you
built is the one you meant. The package itself draws nothing and depends on no
plotting library; the documentation uses **GraphPlot** and **Compose**, and the
helper it uses is `docs/plotgraph.jl` in the repository - fifty lines you are
welcome to copy into your own project:

```julia
using Pkg; Pkg.add(["GraphPlot", "Compose"])
include(joinpath(pkgdir(MetidaFlows), "docs", "plotgraph.jl"))
plotworkflow(w)
```

Every drawing in the examples comes from that one call. A picture of a
workflow after a run:

```@setup drawing
using MetidaFlows
include(joinpath(pkgdir(MetidaFlows), "docs", "plotgraph.jl"))
```

```@example drawing
using MetidaFlows

struct Source <: AbstractNodeType end
struct Risky  <: AbstractNodeType end
struct Handle <: AbstractNodeType end
struct Keep   <: AbstractNodeType end

MetidaFlows.execute_unsafe!(n::DataNode{Source}) = (setdata!(n, :out, 99); [:out])
function MetidaFlows.execute_unsafe!(n::DataNode{Risky})
    v = getinputdata(n, :in)
    v > 10 && (setdata!(n, :err, DomainError(v, "too large")); return [:err])
    setdata!(n, :out, v); [:out]
end
MetidaFlows.execute_unsafe!(n::DataNode{Handle}) = (setdata!(n, :text, "handled"); [:text])
MetidaFlows.execute_unsafe!(n::DataNode{Keep})   = (setdata!(n, :kept, getinputdata(n, :in)); [:kept])

w = Workflow(1)
s = add_node!(w, DataNode(Source, NodeSpec("Source", PortSpec[], [PortSpec("out", Int, :out)])))
r = add_node!(w, DataNode(Risky,  NodeSpec("Risky", [PortSpec("in", Int, :in)],
        [PortSpec("out", Int, :out),
         PortSpec("err", Exception, :err; kind = :error, required = false)])))
h = add_node!(w, DataNode(Handle, NodeSpec("Handler",
        [PortSpec("err", Exception, :err; kind = :error, required = false)],
        [PortSpec("text", String, :text; kind = :terminal)])))
k = add_node!(w, DataNode(Keep,   NodeSpec("Result", [PortSpec("in", Int, :in)],
        [PortSpec("kept", Int, :kept; kind = :terminal)])))
add_connection!(w, s, :out, r, :in)
add_connection!(w, r, :err, h, :err)
add_connection!(w, r, :out, k, :in)
scheduler!(w)

plotworkflow(w)
```

Three things are encoded, and together they turn the drawing into a report of
the last run rather than a diagram of the wiring:

| | |
|:---|:---|
| **node colour** | its [status](guide_execution.md#Statuses-and-the-execution-lifecycle): green `:clean`, yellow `:dirty`, red `:failed`, purple `:invalid_*`, grey `:idle` |
| **edge colour** | the `kind` of the **input** port it enters: grey `:normal`, orange `:feedback`, red `:error` |
| **left to right** | the layers: a node sits one layer right of its latest producer |

Two connections between the same pair of nodes are **one** edge in the
drawing - a graph has no parallel edges - so a loop carrying four values back
is a single orange arc. The colour of the more telling kind wins, which is why
the arc is orange rather than grey when a pair is wired both ways.

In the picture above that is the whole story of the run: the error branch was
taken (red), so `Result` was never reached and stayed `:dirty` (yellow).

### Laying a graph out so it reads

A spring layout - GraphPlot's default - is the wrong tool for a dataflow
graph: it optimises edge lengths, and the one thing a reader wants, *which way
the data goes*, is exactly what it discards. The helper does two things
instead.

**Layers come from the longest path, counting `:normal` edges only.** A
`:feedback` edge is what closes a cycle, so including it would mean no
layering exists at all. Left out, every workflow gets the same left-to-right
reading - and the feedback edge becomes the one arc that visibly goes back.

**Within a layer, nodes are ordered by the average position of their
parents**, two passes of it. That is the barycentre step of the classic
layered method, and it is what stops siblings from being scattered to opposite
edges of the canvas; on the [edit distance](examples_edit_distance.md) lattice
it removes the crossings entirely.

### Three things that will bite you

If you write your own drawing code rather than copying the helper, these cost
an evening each:

* **`makegraph` returns a `NamedDiGraph`, and GraphPlot cannot draw it**
  (`method == not implemented`). Convert to a `SimpleDiGraph` and keep a
  vertex ↔ node id mapping - you need that mapping anyway to line labels and
  colours up with vertices.
* **Per-edge colours and self-loops do not mix** under the default straight
  edges: GraphPlot hands the *same* colour vector to the straight edges and to
  the self-loop curves, so a node that feeds itself - every one-node cycle -
  is painted with the colour of the graph's *first* edge. Passing
  `linetype = "curve"` puts every edge on the same list and the colours line
  up again.
* **A constant coordinate becomes 0.5, not 0.** GraphPlot rescales each axis
  to `[-1, 1]`, and when every value on an axis is equal its scaler returns
  `0.5`. A chain - one node per layer - is therefore drawn a quarter of the
  canvas below centre until you shift it back.

And one of your own making: do not `import` `src`, `dst`, `nv` or `edges` into
the module where the drawing runs. Those names are short enough to collide
with the code being documented - in the edit-distance example `src` is a
vector of integers - and Julia resolves the collision by quietly ignoring the
import, after which the call goes somewhere else entirely.

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
