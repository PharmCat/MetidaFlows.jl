# MetidaFlows.jl

* [![Latest docs](https://img.shields.io/badge/docs-latest-blue.svg)](https://pharmcat.github.io/MetidaFlows.jl/dev/)
* [![Stable docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://pharmcat.github.io/MetidaFlows.jl/stable/)

A dataflow engine for Julia: a computation described as a graph of typed nodes
and recomputed incrementally.

You declare each step as a node with input and output ports, connect the ports,
and run the graph. A node that ran keeps its result; when a setting or an
upstream value changes, only what depends on it is recomputed. The graph is an
ordinary mutable object - you edit it between runs, ask it what failed, and
write it to a snapshot.

---

## What it is built around

**Typed ports.** A port declares a label, a datatype and a kind
(`:normal`, `:terminal`, `:feedback`, `:error`). A connection is checked when it
is created, not when it blows up mid-run. A `MultiPort` input collects any
number of connections in a defined order.

**Incremental recomputation.** A `:clean` node republishes instead of running.
Editing settings, rewiring, or publishing a new value invalidates downstream
and nothing else. What to drop between runs is one keyword - a ladder from
`:none` through `:full` to `:all`.

**No hidden copying, and a legal way to work in place.** A value published by a
producer and the value in a consumer's buffer are one object. Declaring a port
pair `handover = true` lets the consumer `take!` the value and modify it; the
engine then drops the producer's cached copy, so nothing silently mutates
somebody else's cache.

**Editing a graph that is already running.** A node can be swapped for another
under the same identifier with every connection - and every connection
identifier, which is what orders a `MultiPort` - left in place: `replace!`, or
`replacespec!` and `replaceport!` when only its ports change. Everything the
swap could break is re-checked first, so a refusal leaves the graph as it was.

**An audit log.** Every structural edit and every settings change is appended as
an explicit event, so a graph's history is replayable rather than reconstructed.

**Snapshots that never execute.** A snapshot is plain data. Loading one
constructs only node types listed in an explicit register, and a type named
inside a file is never resolved with `eval`, `Meta.parse` or `getfield`.

---

## Two schedulers

| type   | order                      | for                                            |
| ------ | -------------------------- | ---------------------------------------------- |
| `DAW`  | topological, each node once | acyclic analysis pipelines                      |
| `ABW`  | readiness queue             | cycles, feedback ports, iteration until a stop  |

---

## Installation

```julia
using Pkg
Pkg.add("MetidaFlows")
```

---

## A minimal graph

```julia
using MetidaFlows
import MetidaFlows: execute_unsafe!, setreadyports!

struct Source <: AbstractNodeType end
struct Scale  <: AbstractNodeType end

execute_unsafe!(n::DataNode{Source}) =
    (setdata!(n, :out, [1.0, 2.0, 3.0]); setreadyports!(n, :out))

function execute_unsafe!(n::DataNode{Scale})
    setdata!(n, :out, getinputdata(n, :in) .* n.settings[:k])
    return setreadyports!(n, :out)
end

w = Workflow(1)

src = add_node!(w, DataNode(Source,
    NodeSpec("Source", PortSpec[], [PortSpec("Out", Vector{Float64}, :out)])))
scl = add_node!(w, DataNode(Scale,
    NodeSpec("Scale", [PortSpec("In", Vector{Float64}, :in)],
                      [PortSpec("Out", Vector{Float64}, :out)], [:k])))

add_connection!(w, src, :out, scl, :in)
setsettings!(w, scl, Dict(:k => 2.0))

scheduler!(w)
getdata(w, scl, :out)            # [2.0, 4.0, 6.0]

setsettings!(w, scl, Dict(:k => 10.0))
scheduler!(w; reset_mode = :none)
getdata(w, scl, :out)            # [10.0, 20.0, 30.0] - Source did not run again
getstatus(w, src)                # :clean
```

A node type supplies two things: `execute_unsafe!`, which reads its inputs and
writes its outputs, and a `NodeSpec` describing its ports and the settings keys
it accepts. Everything else - ordering, caching, invalidation, logging - is the
engine's.

---

## Documentation

The guide covers building a graph, execution and invalidation, cycles and
feedback, serialization, and the node-type extension protocol:
[latest](https://pharmcat.github.io/MetidaFlows.jl/dev/) ·
[stable](https://pharmcat.github.io/MetidaFlows.jl/stable/).

The package is pre-1.0: exported names are still moving, and each minor release
notes what broke.
