```@meta
CurrentModule = MetidaFlows
```

## Bubble sort as a graph

This example builds an algorithm out of the graph itself. Nothing is hidden
inside a node that does the real work: every elementary operation — read an
element, compare two numbers, assign an element, advance an index, close the
loop — is a node of its own, and the sorting happens because of how they are
wired.

It is also the smallest complete example of an iterative `ABW` workflow with a
pre-tested loop.

One turn of the graph is one comparison of neighbours, so a run of `n` elements
takes `n(n-1)/2` turns.

### The state that travels around the loop

Bubble sort needs three values between steps:

| Value | Meaning |
|---|---|
| `array` | the array as it is now |
| `index` | the left element of the pair being compared |
| `limit` | the end of the current pass; everything above it is already sorted |

A turn compares `array[index]` with `array[index + 1]`, swaps them if they are
out of order, and then either advances `index` or — at the end of a pass —
resets it to `1` and lowers `limit` by one. The loop stops when `limit`
reaches `1`.

The loop is **pre-tested**: `MoreWork` computes `limit > 1` and `LoopGate`
either lets the turn into the body or publishes the result. An array of zero or
one element therefore never reaches `array[index + 1]`.

### The graph

```
 ConstArray ─┬─▶ ArrayLength ──┐
             └─────────────────┤
                               ├─▶ LoopState ─▶ MoreWork ─▶ LoopGate ──▶ :sorted
 ConstOne ─────────────────────┘        ▲                       │
                                        │                       ▼
                                        │                   ReadLeft
                                        │                       │
   ConstOne ────────────────────────────┼──────────────▶  NextIndex
                                        │                       │
                                        │                   ReadRight
                                        │                       │
                                        │                  ComparePair
                                        │                       │
                                        │                  AssignLeft
                                        │                       │
                                        │                  AssignRight
                                        │                       │
                                        │                  ChooseArray
                                        │                       │
                                        │                    PassEnd
                                        │                       │
   ConstOne ────────────────────────────┼──────────────▶ AdvanceIndex
                                        │                       │
   ConstOne ────────────────────────────┼──────────────▶  LowerLimit
                                        │                       │
                                        └─── :feedback ─── ShrinkLimit
```

The body is a straight chain: `ReadLeft` → `NextIndex` → … → `ShrinkLimit`,
and each stage takes everything from the stage before it. `ConstOne` is one
node, drawn four times: it feeds the four stages that need the literal `1`.

### The node catalogue

Seventeen nodes, one per step of the algorithm:

| Node | Elementary operation |
|---|---|
| `ConstArray` | the input array |
| `ConstOne` | the constant `1` |
| `ArrayLength` | `n = length(array)` |
| `LoopState` | holds `(array, index, limit)` between turns |
| `MoreWork` | `go = limit > 1` |
| `LoopGate` | branch: another turn, or publish the result |
| `ReadLeft` | `left = array[index]` |
| `NextIndex` | `next = index + 1` |
| `ReadRight` | `right = array[next]` |
| `ComparePair` | `greater = left > right` |
| `AssignLeft` | `work[index] = right` |
| `AssignRight` | `work[next] = left` |
| `ChooseArray` | `array = greater ? work : array` |
| `PassEnd` | `done = next >= limit` |
| `AdvanceIndex` | `index = done ? 1 : next` |
| `LowerLimit` | `lower = limit - 1` |
| `ShrinkLimit` | `limit = done ? lower : limit` |

The swap is three nodes rather than one. `AssignLeft` and `AssignRight` always
write, on a copy of the array, and `ChooseArray` then picks between the copy and
the original. That keeps assignment an assignment, with no condition hidden
inside it.

### Why the body is a pipeline

Each body node here takes **everything from the single node before it**,
including values it does not touch and only passes on. That is a choice of
style, not something the engine requires: laid out this way a turn reads as the
list of steps of the algorithm, and each node does exactly one operation.

The engine guarantees the consistency of a turn on its own. When a node
publishes, the scheduler marks `:dirty` everything downstream of its children
along `:normal` edges, so [`isready`](@ref) holds a node back until every one
of its `:normal` ancestors has been recomputed during this turn — see *Rule 3*
in the guide. A node may therefore take its inputs from any depth, and the
same graph behaves the same whatever order its connections were created in.

So the natural layout works too: `GetElement(array, index)` reading the array
straight from the loop head, a `SelectArray` taking one branch from the head
and the other through three nodes, and so on. It needs about forty connections
instead of seventy for the same seventeen nodes. The pipeline is kept here
because the rails make the state of a turn explicit, which is what this page is
trying to show.

### The node types

```@example bubble
using MetidaFlows

struct ConstArray   <: AbstractNodeType end
struct ConstOne     <: AbstractNodeType end
struct ArrayLength  <: AbstractNodeType end
struct LoopState    <: AbstractNodeType end
struct MoreWork     <: AbstractNodeType end
struct LoopGate     <: AbstractNodeType end
struct ReadLeft     <: AbstractNodeType end
struct NextIndex    <: AbstractNodeType end
struct ReadRight    <: AbstractNodeType end
struct ComparePair  <: AbstractNodeType end
struct AssignLeft   <: AbstractNodeType end
struct AssignRight  <: AbstractNodeType end
struct ChooseArray  <: AbstractNodeType end
struct PassEnd      <: AbstractNodeType end
struct AdvanceIndex <: AbstractNodeType end
struct LowerLimit   <: AbstractNodeType end
struct ShrinkLimit  <: AbstractNodeType end

const IntVec = Vector{Int}
nothing # hide
```

### Interfaces

The loop head is the only node with `:feedback` ports. Its normal inputs are
the initial values; the feedback inputs carry the state of the previous turn,
and they are not `required`, because on the first turn their buffers are empty.

```@example bubble
state_spec = NodeSpec("Loop state",
    [PortSpec("Initial array", IntVec, :init_array),
     PortSpec("Initial index", Int,    :init_index),
     PortSpec("Initial limit", Int,    :init_limit),
     PortSpec("Array",         IntVec, :array; kind = :feedback, required = false),
     PortSpec("Index",         Int,    :index; kind = :feedback, required = false),
     PortSpec("Limit",         Int,    :limit; kind = :feedback, required = false)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit)])
```

The gate publishes the state onward while the loop runs, and the answer on a
`:terminal` port when it stops:

```@example bubble
gate_spec = NodeSpec("Loop gate",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Go",    Bool,   :go)],
    [PortSpec("Array",  IntVec, :array),
     PortSpec("Index",  Int,    :index),
     PortSpec("Limit",  Int,    :limit),
     PortSpec("Sorted", IntVec, :sorted; kind = :terminal)])
```

The rest are plain: each declares the rails it needs and the rails it passes
on, plus whatever it computes.

```@example bubble
array_spec  = NodeSpec("Const array", PortSpec[], [PortSpec("Array", IntVec, :array)], [:values])
one_spec    = NodeSpec("Const one",   PortSpec[], [PortSpec("One", Int, :one)], [:value])
length_spec = NodeSpec("Array length",
    [PortSpec("Array", IntVec, :array)], [PortSpec("Length", Int, :length)])

# a helper, so the rails below stay readable
port(::Type{Int},    label, name) = PortSpec(name, Int,    label)
port(::Type{Bool},   label, name) = PortSpec(name, Bool,   label)
port(::Type{IntVec}, label, name) = PortSpec(name, IntVec, label)

rails(pairs...) = [port(T, l, n) for (T, l, n) in pairs]

more_spec = NodeSpec("More work",
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :limit, "Limit"),
          (Int, :one, "One")),
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :limit, "Limit"),
          (Bool, :go, "Go")))

readleft_spec = NodeSpec("Read left",
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :limit, "Limit")),
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :limit, "Limit"),
          (Int, :left, "Left")))

nextindex_spec = NodeSpec("Next index",
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :limit, "Limit"),
          (Int, :left, "Left"), (Int, :one, "One")),
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :next, "Next"),
          (Int, :limit, "Limit"), (Int, :left, "Left")))

readright_spec = NodeSpec("Read right",
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :next, "Next"),
          (Int, :limit, "Limit"), (Int, :left, "Left")),
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :next, "Next"),
          (Int, :limit, "Limit"), (Int, :left, "Left"), (Int, :right, "Right")))

compare_spec = NodeSpec("Compare pair",
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :next, "Next"),
          (Int, :limit, "Limit"), (Int, :left, "Left"), (Int, :right, "Right")),
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :next, "Next"),
          (Int, :limit, "Limit"), (Int, :left, "Left"), (Int, :right, "Right"),
          (Bool, :greater, "Greater")))

assignleft_spec = NodeSpec("Assign left",
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :next, "Next"),
          (Int, :limit, "Limit"), (Int, :left, "Left"), (Int, :right, "Right"),
          (Bool, :greater, "Greater")),
    rails((IntVec, :source, "Source"), (IntVec, :work, "Work"), (Int, :next, "Next"),
          (Int, :limit, "Limit"), (Int, :left, "Left"), (Bool, :greater, "Greater")))

assignright_spec = NodeSpec("Assign right",
    rails((IntVec, :source, "Source"), (IntVec, :work, "Work"), (Int, :next, "Next"),
          (Int, :limit, "Limit"), (Int, :left, "Left"), (Bool, :greater, "Greater")),
    rails((IntVec, :source, "Source"), (IntVec, :work, "Work"), (Int, :next, "Next"),
          (Int, :limit, "Limit"), (Bool, :greater, "Greater")))

choose_spec = NodeSpec("Choose array",
    rails((IntVec, :source, "Source"), (IntVec, :work, "Work"), (Int, :next, "Next"),
          (Int, :limit, "Limit"), (Bool, :greater, "Greater")),
    rails((IntVec, :array, "Array"), (Int, :next, "Next"), (Int, :limit, "Limit")))

passend_spec = NodeSpec("Pass end",
    rails((IntVec, :array, "Array"), (Int, :next, "Next"), (Int, :limit, "Limit")),
    rails((IntVec, :array, "Array"), (Int, :next, "Next"), (Int, :limit, "Limit"),
          (Bool, :done, "Done")))

advance_spec = NodeSpec("Advance index",
    rails((IntVec, :array, "Array"), (Int, :next, "Next"), (Int, :limit, "Limit"),
          (Bool, :done, "Done"), (Int, :one, "One")),
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :limit, "Limit"),
          (Bool, :done, "Done")))

lower_spec = NodeSpec("Lower limit",
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :limit, "Limit"),
          (Bool, :done, "Done"), (Int, :one, "One")),
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :limit, "Limit"),
          (Int, :lower, "Lower"), (Bool, :done, "Done")))

shrink_spec = NodeSpec("Shrink limit",
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :limit, "Limit"),
          (Int, :lower, "Lower"), (Bool, :done, "Done")),
    rails((IntVec, :array, "Array"), (Int, :index, "Index"), (Int, :limit, "Limit")))
nothing # hide
```

### Behaviour

The two nodes that matter are the head and the gate. The head starts from the
initial values while the feedback buffer is empty, and from the loop state once
it is not:

```@example bubble
function MetidaFlows.execute_unsafe!(node::DataNode{LoopState})
    back = getinputdata(node, :array)
    if back === nothing                       # first turn
        setdata!(node, :array, getinputdata(node, :init_array))
        setdata!(node, :index, getinputdata(node, :init_index))
        setdata!(node, :limit, getinputdata(node, :init_limit))
    else                                      # state of the previous turn
        setdata!(node, :array, back)
        setdata!(node, :index, getinputdata(node, :index))
        setdata!(node, :limit, getinputdata(node, :limit))
    end
    return [:array, :index, :limit]
end
```

The gate ends the run by publishing **only** a terminal port: nothing reaches
the body, no child is marked `:dirty`, and the queue drains.

```@example bubble
function MetidaFlows.execute_unsafe!(node::DataNode{LoopGate})
    if getinputdata(node, :go)
        setdata!(node, :array, getinputdata(node, :array))
        setdata!(node, :index, getinputdata(node, :index))
        setdata!(node, :limit, getinputdata(node, :limit))
        return [:array, :index, :limit]       # one more turn
    end
    setdata!(node, :sorted, getinputdata(node, :array))
    return [:sorted]                          # the loop ends here
end
```

The rest are one line of work each, plus the rails:

```@example bubble
function MetidaFlows.execute_unsafe!(node::DataNode{ConstArray})
    setdata!(node, :array, Vector{Int}(node.settings[:values]))
    return [:array]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ConstOne})
    setdata!(node, :one, node.settings[:value])
    return [:one]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ArrayLength})
    setdata!(node, :length, length(getinputdata(node, :array)))
    return [:length]
end

# forward every port the node does not change
function forward!(node, ports)
    for p in ports
        setdata!(node, p, getinputdata(node, p))
    end
end

function MetidaFlows.execute_unsafe!(node::DataNode{MoreWork})
    forward!(node, (:array, :index, :limit))
    setdata!(node, :go, getinputdata(node, :limit) > getinputdata(node, :one))
    return [:array, :index, :limit, :go]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ReadLeft})
    forward!(node, (:array, :index, :limit))
    setdata!(node, :left, getinputdata(node, :array)[getinputdata(node, :index)])
    return [:array, :index, :limit, :left]
end

function MetidaFlows.execute_unsafe!(node::DataNode{NextIndex})
    forward!(node, (:array, :index, :limit, :left))
    setdata!(node, :next, getinputdata(node, :index) + getinputdata(node, :one))
    return [:array, :index, :next, :limit, :left]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ReadRight})
    forward!(node, (:array, :index, :next, :limit, :left))
    setdata!(node, :right, getinputdata(node, :array)[getinputdata(node, :next)])
    return [:array, :index, :next, :limit, :left, :right]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ComparePair})
    forward!(node, (:array, :index, :next, :limit, :left, :right))
    setdata!(node, :greater, getinputdata(node, :left) > getinputdata(node, :right))
    return [:array, :index, :next, :limit, :left, :right, :greater]
end

function MetidaFlows.execute_unsafe!(node::DataNode{AssignLeft})
    source = getinputdata(node, :array)
    work   = copy(source)
    work[getinputdata(node, :index)] = getinputdata(node, :right)
    forward!(node, (:next, :limit, :left, :greater))
    setdata!(node, :source, source)
    setdata!(node, :work,   work)
    return [:source, :work, :next, :limit, :left, :greater]
end

function MetidaFlows.execute_unsafe!(node::DataNode{AssignRight})
    work = copy(getinputdata(node, :work))
    work[getinputdata(node, :next)] = getinputdata(node, :left)
    forward!(node, (:source, :next, :limit, :greater))
    setdata!(node, :work, work)
    return [:source, :work, :next, :limit, :greater]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ChooseArray})
    forward!(node, (:next, :limit))
    setdata!(node, :array, getinputdata(node, :greater) ? getinputdata(node, :work) :
                                                          getinputdata(node, :source))
    return [:array, :next, :limit]
end

function MetidaFlows.execute_unsafe!(node::DataNode{PassEnd})
    forward!(node, (:array, :next, :limit))
    setdata!(node, :done, getinputdata(node, :next) >= getinputdata(node, :limit))
    return [:array, :next, :limit, :done]
end

function MetidaFlows.execute_unsafe!(node::DataNode{AdvanceIndex})
    forward!(node, (:array, :limit, :done))
    setdata!(node, :index, getinputdata(node, :done) ? getinputdata(node, :one) :
                                                       getinputdata(node, :next))
    return [:array, :index, :limit, :done]
end

function MetidaFlows.execute_unsafe!(node::DataNode{LowerLimit})
    forward!(node, (:array, :index, :limit, :done))
    setdata!(node, :lower, getinputdata(node, :limit) - getinputdata(node, :one))
    return [:array, :index, :limit, :lower, :done]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ShrinkLimit})
    forward!(node, (:array, :index))
    setdata!(node, :limit, getinputdata(node, :done) ? getinputdata(node, :lower) :
                                                       getinputdata(node, :limit))
    return [:array, :index, :limit]
end
nothing # hide
```

### Building the graph

```@example bubble
function bubble_graph(values::Vector{Int})
    w = Workflow(0; type = :ABW)
    w.name = "Bubble sort"

    src   = add_node!(w, DataNode(ConstArray,   array_spec))
    one   = add_node!(w, DataNode(ConstOne,     one_spec))
    len   = add_node!(w, DataNode(ArrayLength,  length_spec))
    head  = add_node!(w, DataNode(LoopState,     state_spec))
    more  = add_node!(w, DataNode(MoreWork,     more_spec))
    gate  = add_node!(w, DataNode(LoopGate,     gate_spec))
    rleft = add_node!(w, DataNode(ReadLeft,     readleft_spec))
    nidx  = add_node!(w, DataNode(NextIndex,    nextindex_spec))
    rrght = add_node!(w, DataNode(ReadRight,    readright_spec))
    cmp   = add_node!(w, DataNode(ComparePair,  compare_spec))
    aleft = add_node!(w, DataNode(AssignLeft,   assignleft_spec))
    argt  = add_node!(w, DataNode(AssignRight,  assignright_spec))
    choos = add_node!(w, DataNode(ChooseArray,  choose_spec))
    pend  = add_node!(w, DataNode(PassEnd,      passend_spec))
    adv   = add_node!(w, DataNode(AdvanceIndex, advance_spec))
    lower = add_node!(w, DataNode(LowerLimit,   lower_spec))
    shrnk = add_node!(w, DataNode(ShrinkLimit,  shrink_spec))

    # initial values
    add_connection!(w, src, :array,  len,  :array)
    add_connection!(w, src, :array,  head, :init_array)
    add_connection!(w, one, :one,    head, :init_index)
    add_connection!(w, len, :length, head, :init_limit)

    # pre-test and branch
    for p in (:array, :index, :limit); add_connection!(w, head, p, more, p); end
    add_connection!(w, one, :one, more, :one)
    for p in (:array, :index, :limit, :go); add_connection!(w, more, p, gate, p); end

    # the body: one producer per node
    wire(from, to, ports) = for p in ports; add_connection!(w, from, p, to, p); end
    wire(gate,  rleft, (:array, :index, :limit))
    wire(rleft, nidx,  (:array, :index, :limit, :left))
    wire(nidx,  rrght, (:array, :index, :next, :limit, :left))
    wire(rrght, cmp,   (:array, :index, :next, :limit, :left, :right))
    wire(cmp,   aleft, (:array, :index, :next, :limit, :left, :right, :greater))
    wire(aleft, argt,  (:source, :work, :next, :limit, :left, :greater))
    wire(argt,  choos, (:source, :work, :next, :limit, :greater))
    wire(choos, pend,  (:array, :next, :limit))
    wire(pend,  adv,   (:array, :next, :limit, :done))
    wire(adv,   lower, (:array, :index, :limit, :done))
    wire(lower, shrnk, (:array, :index, :limit, :lower, :done))

    # the constant 1
    add_connection!(w, one, :one, nidx,  :one)
    add_connection!(w, one, :one, adv,   :one)
    add_connection!(w, one, :one, lower, :one)

    # the feedback edge closes the loop
    for p in (:array, :index, :limit); add_connection!(w, shrnk, p, head, p); end

    setsettings!(w, src, Dict(:values => values))
    setsettings!(w, one, Dict(:value => 1))
    return w, gate, head, cmp
end
nothing # hide
```

### Running it

```@example bubble
w, gate, head, cmp = bubble_graph([5, 1, 4, 2, 8])
scheduler!(w; maxiter = 20_000)
getdata(w, gate, :sorted)
```

A pass of the pre-test costs one extra execution of the head, the test and the
gate, so the counters show the shape of the run:

```@example bubble
using MetidaFlows: getstate, getnode
(turns = getstate(getnode(w, cmp), :exec_n),
 head_runs = getstate(getnode(w, head), :exec_n))
```

Five elements give `5 * 4 / 2 = 10` turns, and the head runs eleven times — the
eleventh closes the loop. Every node of the body runs exactly once per turn:
that is the synchronous layout paying off.

An array that needs no work never enters the body:

```@example bubble
w1, gate1, _, _ = bubble_graph([42])
scheduler!(w1)
getdata(w1, gate1, :sorted)
```

### Things to watch

* **`maxiter` scales with the work.** Each turn costs roughly one scheduler
  iteration per body node, so `n` elements need about `17 * n(n-1)/2`
  iterations. The default `maxiter = 1000` covers five elements; twenty need
  about four thousand. The run aborts with an error rather than hanging.

* **A full reset starts the loop over.** `reset_mode = :full` — the default —
  calls [`reset!`](@ref), which drops the cached data and clears the buffers of
  `:feedback` ports, so a second [`scheduler!`](@ref) call sorts again from the
  beginning. Pass `reset_mode = :soft` to keep the loop state and continue
  where the previous call stopped.

* **`reset_mode = :none` is not a no-op here.** [`execute!`](@ref) on a
  `:clean` node returns its stored `ready_ports`, the scheduler propagates from
  them, and the children recompute on whatever the buffers still hold. Use
  `:soft` to continue a loop and `:full` to start one.

* **A finished run leaves the body `:dirty`.** On the last pass the loop head
  marks the body dirty as usual and the gate then publishes only `:sorted`, so
  the body is never recomputed. For a cyclic workflow "every node is `:clean`"
  is not a completion signal; read the terminal port, or `exec_n`.

* **The result lives on a `:terminal` port.** `:sorted` is never connected;
  read it with [`getdata`](@ref) once the run is over.

* **`DAW` will not take this graph.** A cycle closed by a `:feedback` port is
  still a cycle, and the `DAW` scheduler rejects it by design.

## The graph

The graph, after a run: See [Drawing a workflow](guide.md#Drawing-a-workflow) for the helper this uses.

```@setup bubble
include(joinpath(pkgdir(MetidaFlows), "docs", "plotgraph.jl"))
```

```@example bubble
wp = first(bubble_graph([3, 1, 2]))
scheduler!(wp; maxiter = 20_000)
plotworkflow(wp; label = :id)
```
