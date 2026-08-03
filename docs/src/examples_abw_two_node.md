```@setup mfexample
const PKCSV_PATH = joinpath(dirname(@__FILE__), "conc.csv")
```

## ABW — a two-node loop: worker and controller

Example 3 kept the whole loop inside one node. That is compact, but the
stopping policy is hard-wired into the algorithm. Splitting the loop in two
separates them: one node does the work, the other decides whether to continue.
The policy then becomes a replaceable node — swap the controller and the same
worker runs under a different criterion.

```
LoadData ──:table──▶ Trim ──:state──▶ Control ──:next──▶ Trim (:previous, feedback)
                       ▲                          ├──:result      ▶ (terminal)
                       └──────────────────────────┘  └──:iterations ▶ (terminal)
```

Only the edge `Control :next → Trim :previous` closes the cycle, so only that
one is declared `kind = :feedback`. The edge `Trim → Control` is an ordinary
forward edge: `Control` must wait for `Trim`, and it does.

### State carried by the loop

```@example mfexample
using MetidaFlows
using CSV, DataFrames, Statistics

struct LoadData <: AbstractNodeType end
struct Trim     <: AbstractNodeType end
struct Control  <: AbstractNodeType end

struct TrimState2
    table::DataFrame
    iter::Int
end

zscores(c) = abs.(c .- mean(c)) ./ std(c)
```

### Interfaces

```@example mfexample
load_spec = NodeSpec("Load data",
    PortSpec[],
    [PortSpec("Table", DataFrame, :table)],
    [:file])

trim_spec = NodeSpec("Trim",
    [PortSpec("Table",    DataFrame, :table),
     PortSpec("Previous", TrimState2, :previous; kind = :feedback)],
    [PortSpec("State", TrimState2, :state)])

control_spec = NodeSpec("Control",
    [PortSpec("State", TrimState2, :state)],
    [PortSpec("Next",       TrimState2, :next),
     PortSpec("Result",     DataFrame, :result;     kind = :terminal),
     PortSpec("Iterations", Int,       :iterations; kind = :terminal)],
    [:z, :maxiter])
```

### Behaviour

`Trim` knows only how to remove one observation. It has no idea when to stop:

```@example mfexample
function MetidaFlows.execute_unsafe!(node::DataNode{LoadData})
    setdata!(node, :table, DataFrame(CSV.File(node.settings[:file])))
    return [:table]
end

function MetidaFlows.execute_unsafe!(node::DataNode{Trim})
    previous = getinputdata(node, :previous)

    # first pass: the feedback buffer is empty, start from the normal input
    state = previous === nothing ?
        TrimState2(getinputdata(node, :table), 0) :
        previous

    i = argmax(zscores(state.table.Concentration))
    setdata!(node, :state, TrimState2(state.table[Not(i), :], state.iter + 1))
    return [:state]
end
```

`Control` knows only the criterion. Its choice of output port is the control
flow: publishing `:next` keeps the loop running, publishing the terminal ports
ends it.

```@example mfexample
function MetidaFlows.execute_unsafe!(node::DataNode{Control})
    state = getinputdata(node, :state)
    zmax  = maximum(zscores(state.table.Concentration))

    converged = zmax <= node.settings[:z]
    exhausted = state.iter >= node.settings[:maxiter]

    if converged || exhausted
        setdata!(node, :result, state.table)
        setdata!(node, :iterations, state.iter)
        return [:result, :iterations]      # nothing goes back into the loop
    end

    setdata!(node, :next, state)
    return [:next]                         # one more turn
end
```

### Assembling and running

```@example mfexample
w = Workflow(4; type = :ABW)
w.name = "Trim with a separate controller"

load    = add_node!(w, DataNode(LoadData, load_spec))
trim    = add_node!(w, DataNode(Trim,     trim_spec))
control = add_node!(w, DataNode(Control,  control_spec))

add_connection!(w, load,    :table, trim,    :table)
add_connection!(w, trim,    :state, control, :state)
add_connection!(w, control, :next,  trim,    :previous)    # the cycle

setsettings!(w, load,    Dict(:file => PKCSV_PATH))
setsettings!(w, control, Dict(:z => 1.6, :maxiter => 10))

scheduler!(w)

getdata(w, control, :iterations)
getdata(w, control, :result)
```

Replacing the policy means replacing one node. A controller that stops after a
fixed number of passes needs no change to `Trim`:

```julia
function MetidaFlows.execute_unsafe!(node::DataNode{Control})
    state = getinputdata(node, :state)
    if state.iter >= node.settings[:iterations]
        setdata!(node, :result, state.table)
        setdata!(node, :iterations, state.iter)
        return [:result, :iterations]
    end
    setdata!(node, :next, state)
    return [:next]
end
```

### How the scheduler drives it

```
queue := [LoadData]                     only nodes without normal inputs are seeded

pop LoadData → executes → enqueues Trim
pop Trim     → isready: :table normal, LoadData is :clean → ready
                        :previous is :feedback → not checked
             → executes, publishes :state → enqueues Control
pop Control  → isready: Trim is :clean → ready
             → executes, publishes :next
             → :next feeds Trim through a :feedback port
             → Trim is marked :dirty and enqueued
pop Trim     → executes again, now :previous holds the state
pop Control  → executes again, re-evaluates the criterion
...
pop Control  → publishes :result and :iterations instead of :next
             → both are terminal and unconnected → nothing is enqueued
queue is empty → scheduler! returns true
```

Every node enqueued by the scheduler is marked `:dirty` first, so `Control`
re-evaluates its criterion on every turn instead of replaying its first
decision. Without that, the second node of a loop would stay `:clean`, and
[`execute!`](@ref) would return its stored `ready_ports` without recomputing.

Nodes outside the loop are unaffected: `LoadData` is nobody's child, stays
`:clean`, and its result is read from the buffer on every pass.

### Why the forward edge stays `:normal`

It is tempting to mark both edges of the loop as `:feedback`. Do not.
`isready` checks only `:normal` edges, and that check is what makes a
node with several producers wait for all of them. Mark `Trim → Control` as
feedback and `Control` becomes eligible to run before `Trim` has produced
anything — harmless in this two-node chain, wrong as soon as a third node
joins the loop.

The rule is one line long: **an edge is either a barrier or a delay.** Mark as
`:feedback` exactly the edges that close a cycle, and no others.
