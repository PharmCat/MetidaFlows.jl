```@meta
CurrentModule = MetidaFlows
```

```@setup mfexample
PKCSV_PATH = joinpath(pwd(), "conc.csv")
```

## ABW - a cyclic graph with a feedback port

`DAW` rejects cycles: it needs a topological order. `ABW` executes a cycle if
the edge that closes it enters a port declared with `kind = :feedback`. Such a
port carries the value of the **previous** iteration, so it is excluded from
the readiness check - the loop is broken by construction, exactly like a unit
delay in a block diagram.

This workflow trims outliers one observation at a time and stops either when
the data is clean or when the iteration budget runs out:

```
LoadData ──:table──▶ TrimLoop ──:result──▶ (terminal)
                       ▲    │
                       └────┘  :state ──▶ :previous  (kind = :feedback)
```

`TrimLoop` decides on every pass which port to publish, and that choice is the
control flow: publishing `:state` keeps the loop running, publishing
`:result` ends it.

### State carried by the loop

```@example mfexample
using MetidaFlows
using CSV, DataFrames, Statistics

struct LoadData <: AbstractNodeType end
struct TrimLoop <: AbstractNodeType end

# everything the next iteration needs to continue
struct TrimState
    table::DataFrame
    iter::Int
    zmax::Float64
end

zscores(c) = abs.(c .- mean(c)) ./ std(c)
```

### Interfaces

```@example mfexample
load_spec = NodeSpec("Load data",
    PortSpec[],
    [PortSpec("Table", DataFrame, :table)],
    [:file])

trim_spec = NodeSpec("Trim loop",
    [PortSpec("Table",     DataFrame, :table),
     PortSpec("Previous",  TrimState, :previous; kind = :feedback)],
    [PortSpec("State",      TrimState, :state),
     PortSpec("Result",     DataFrame, :result;     kind = :terminal),
     PortSpec("Iterations", Int,       :iterations; kind = :terminal)],
    [:z, :maxiter])
```

`:previous` is the loop-carried input. `:result` and `:iterations` are
terminal: they hold the answer and are not meant to be connected.

### Behaviour

```@example mfexample
function MetidaFlows.execute_unsafe!(node::DataNode{LoadData})
    setdata!(node, :table, DataFrame(CSV.File(node.settings[:file])))
    return [:table]
end

function MetidaFlows.execute_unsafe!(node::DataNode{TrimLoop})
    previous = getinputdata(node, :previous)

    # first pass: the feedback buffer is empty, start from the normal input
    state = previous === nothing ? TrimState(getinputdata(node, :table), 0, Inf) : previous

    z    = zscores(state.table.Concentration)
    i    = argmax(z)
    zmax = z[i]

    converged = zmax <= node.settings[:z]
    exhausted = state.iter >= node.settings[:maxiter]

    if converged || exhausted
        setdata!(node, :result, state.table)
        setdata!(node, :iterations, state.iter)
        return [:result, :iterations]        # nothing is published into the loop
    end

    setdata!(node, :state, TrimState(state.table[Not(i), :], state.iter + 1, zmax))
    return [:state]                          # one more turn
end
```

### Assembling and running

```@example mfexample
w = Workflow(3; type = :ABW)
w.name = "Iterative trimming"

load = add_node!(w, DataNode(LoadData, load_spec))
trim = add_node!(w, DataNode(TrimLoop, trim_spec))

add_connection!(w, load, :table, trim, :table)
add_connection!(w, trim, :state, trim, :previous)     # the cycle

setsettings!(w, load, Dict(:file => PKCSV_PATH))      # assuming PKCSV_PATH exists
setsettings!(w, trim, Dict(:z => 1.6, :maxiter => 10))

scheduler!(w, throw_error = true)

ri = getdata(w, trim, :iterations)      # how many observations were removed
df = getdata(w, trim, :result)          # the trimmed dataset
println("Removed:", ri)
df[1:3, :]
```

The graph itself, after the run - green is `:clean`, and the orange arc is the
`:feedback` edge that closes the loop. See
[Drawing a workflow](guide.md#Drawing-a-workflow) for the helper this uses.

```@setup mfexample
include(joinpath(pkgdir(MetidaFlows), "docs", "plotgraph.jl"))
```

```@example mfexample
plotworkflow(w)
```

One call to [`scheduler!`](@ref) runs the whole loop to completion.

### How the scheduler drives it

```
queue := [LoadData]                      only nodes with no input ports at all are seeded

pop LoadData → executes → pushes :table  → enqueues TrimLoop
pop TrimLoop → isready: :table normal, LoadData is :clean → ready
                        :previous is :feedback → not checked
             → executes, publishes :state
             → the child of :state is TrimLoop itself, through a :feedback port
             → the scheduler marks it :dirty again and re-enqueues it
pop TrimLoop → executes, now :previous holds the previous state
...
pop TrimLoop → publishes :result instead of :state
             → :result has no connections → nothing is enqueued
queue is empty → scheduler! returns true
```

Two independent stops guard the loop. The node's own `:maxiter` is the
intended one. The scheduler's `maxiter` keyword (1000 by default) is a
backstop: if a node keeps publishing into the loop forever, the run aborts
with an error instead of hanging.

### Counting iterations instead of testing convergence

If the process should simply run a fixed number of times, drop the condition
and keep the counter:

```julia
state.iter >= node.settings[:iterations] && return [:result, :iterations]
```

The counter travels inside `TrimState`, so it is part of the loop rather than
hidden node state - a restarted workflow starts counting from zero.

### A loop body may span several nodes

Nothing above is limited to one node. Every node the scheduler enqueues is
marked `:dirty` first, and along `:normal` edges the whole cone below it is
marked too ([`mark_dirty_downstream!`](@ref)), so a node reached through an
ordinary port recomputes on each turn instead of replaying its first decision.
The state still travels through the one `:feedback` edge that closes the cycle.

[A two-node loop](examples_abw_two_node.md) splits this example into a worker
and a controller, and [bubble sort](examples_bubble_sort.md) runs a body of a
dozen nodes. The rule to keep is a narrower one: mark as `:feedback` only the
edges that close a cycle. `isready` waits on `:normal` edges, and that wait is
what makes a node of the body wait for the rest of it.
