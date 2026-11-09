```@meta
CurrentModule = MetidaFlows
```

## Insertion sort: nested loops on a graph

Insertion sort is two loops, one inside the other:

```julia
for i in 2:n                          # outer: which element we are inserting
    j = i - 1
    while j >= 1 && a[j] > a[j + 1]   # inner: shift it left
        a[j], a[j + 1] = a[j + 1], a[j]
        j -= 1
    end
end
```

A graph cannot nest one loop inside another. `execute_unsafe!` receives only
the node: a node sees neither the model nor its neighbours' buffers, so there
is nothing inside a node to run a second scheduler on. The nesting has to be
unrolled.

### The epoch pattern

Put **both** indices into the loop state and make one turn of the graph one
elementary step of the *inner* loop:

```julia
i = 2; j = 1
while i <= n
    if j >= 1 && a[j] > a[j + 1]
        a[j], a[j + 1] = a[j + 1], a[j];  j -= 1   # a step of the inner loop
    else
        i += 1;  j = i - 1                         # a NEW EPOCH
    end
end
```

An **epoch** is one iteration of the outer loop — the insertion of one
element. Within an epoch `j` walks down; at the end of an epoch `i` grows.
There are no two loops in the graph. There is one flat loop and a gate that
decides, on every turn, whether the current epoch continues or the next one
begins. Which kind of step a turn is follows from the state, not from the
shape of the graph.

That gives something you can measure from outside: **the number of epochs does
not depend on the data** (it is always `n - 1`), while **the number of turns
does** — from `n - 1` on sorted input to `n - 1 + n(n-1)/2` on reversed input.
This is how you can tell the nesting is real.

### A graph has no short-circuit

In `j >= 1 && a[j] > a[j + 1]` Julia does not evaluate the right-hand side
when `j == 0`. A graph evaluates everything: `isready` lets a node run only
once all of its normal parents are `:clean`, so both operands are computed on
every turn — including turns whose result will be thrown away.

So `ReadAt` and `SwapAt` here are **total**: a read past the end returns
`typemin(Int)` and a swap past the end does nothing. The gate discards such a
turn anyway.

[Bubble sort](examples_bubble_sort.md) solves the same problem the other way,
with a **pre-tested** loop: its gate sits right after the head, and a
degenerate turn never enters the body at all. Both are valid, and the
difference shows in the shape of the graph. With two indices a pre-test would
need a three-way gate *before* the body and two paths back into the head — and
a `:feedback` port with `SinglePort` arity accepts only one connection.

### The nodes

```@example insertion
using MetidaFlows
import MetidaFlows: PortSpec, getportspec

struct InsConstArray <: AbstractNodeType end  # the array source
struct InsConstInt   <: AbstractNodeType end  # an integer constant
struct InsLength     <: AbstractNodeType end  # n = length(a)
struct InsertState   <: AbstractNodeType end  # the loop state
struct InsAdd        <: AbstractNodeType end  # a + b
struct InsSub        <: AbstractNodeType end  # a - b
struct InsGreater    <: AbstractNodeType end  # a > b
struct InsNotLess    <: AbstractNodeType end  # a >= b
struct InsAnd        <: AbstractNodeType end  # a && b
struct InsReadAt     <: AbstractNodeType end  # a[k], total
struct InsSwapAt     <: AbstractNodeType end  # swap a[k], a[k+1], total
struct InsertGate    <: AbstractNodeType end  # the branch of a turn

InsVec = Vector{Int}
nothing # hide
```

The head of the loop carries all of the state and nothing else. Its normal
inputs are the initial values; its `:feedback` inputs are the state of the
previous turn, and they are not `required`, because on the first turn their
buffers are empty.

```@example insertion
spec_insconstarray() = NodeSpec("Ins const array", PortSpec[],
    [PortSpec("Array", InsVec, :array)], [:values])

spec_insconstint() = NodeSpec("Ins const int", PortSpec[],
    [PortSpec("Out", Int, :out)], [:value])

spec_inslength() = NodeSpec("Ins length",
    [PortSpec("Array", InsVec, :array)],
    [PortSpec("Length", Int, :length)])

spec_insertstate() = NodeSpec("Insert state",
    [PortSpec("Initial array",  InsVec, :init_array),
     PortSpec("Initial i",      Int,    :init_i),
     PortSpec("Initial j",      Int,    :init_j),
     PortSpec("Initial epochs", Int,    :init_epochs),
     PortSpec("Array",  InsVec, :array;  kind = :feedback, required = false),
     PortSpec("I",      Int,    :i;      kind = :feedback, required = false),
     PortSpec("J",      Int,    :j;      kind = :feedback, required = false),
     PortSpec("Epochs", Int,    :epochs; kind = :feedback, required = false)],
    [PortSpec("Array",  InsVec, :array),
     PortSpec("I",      Int,    :i),
     PortSpec("J",      Int,    :j),
     PortSpec("Epochs", Int,    :epochs)])

ins_binary_int(name)    = NodeSpec(name,
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
    [PortSpec("Out", Int, :out)])
ins_predicate_int(name) = NodeSpec(name,
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
    [PortSpec("Out", Bool, :out)])

spec_insadd()     = ins_binary_int("Ins add")
spec_inssub()     = ins_binary_int("Ins sub")
spec_insgreater() = ins_predicate_int("Ins greater")
spec_insnotless() = ins_predicate_int("Ins not less")

spec_insand() = NodeSpec("Ins and",
    [PortSpec("A", Bool, :a), PortSpec("B", Bool, :b)],
    [PortSpec("Out", Bool, :out)])

spec_insreadat() = NodeSpec("Ins read at",
    [PortSpec("Array", InsVec, :array), PortSpec("Index", Int, :index)],
    [PortSpec("Out", Int, :out)])

spec_insswapat() = NodeSpec("Ins swap at",
    [PortSpec("Array", InsVec, :array), PortSpec("Index", Int, :index)],
    [PortSpec("Out", InsVec, :out)])

spec_insertgate() = NodeSpec("Insert gate",
    [PortSpec("Done",        Bool,   :done),
     PortSpec("Step",        Bool,   :step),
     PortSpec("Array",       InsVec, :array),
     PortSpec("Array swap",  InsVec, :array_swap),
     PortSpec("I",           Int,    :i),
     PortSpec("I next",      Int,    :i_next),
     PortSpec("J dec",       Int,    :j_dec),
     PortSpec("Epochs",      Int,    :epochs),
     PortSpec("Epochs next", Int,    :epochs_next)],
    [PortSpec("Array",  InsVec, :array),
     PortSpec("I",      Int,    :i),
     PortSpec("J",      Int,    :j),
     PortSpec("Epochs", Int,    :epochs),
     PortSpec("Sorted", InsVec, :sorted;       kind = :terminal),
     PortSpec("Total epochs", Int, :total_epochs; kind = :terminal)])
nothing # hide
```

Each node is one elementary operation. The two total ones are marked.

```@example insertion
MetidaFlows.execute_unsafe!(n::DataNode{InsConstArray}) =
    (setdata!(n, :array, Vector{Int}(n.settings[:values])); [:array])
MetidaFlows.execute_unsafe!(n::DataNode{InsConstInt}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{InsLength}) =
    (setdata!(n, :length, length(getinputdata(n, :array))); [:length])

MetidaFlows.execute_unsafe!(n::DataNode{InsAdd}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{InsSub}) =
    (setdata!(n, :out, getinputdata(n, :a) - getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{InsGreater}) =
    (setdata!(n, :out, getinputdata(n, :a) > getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{InsNotLess}) =
    (setdata!(n, :out, getinputdata(n, :a) >= getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{InsAnd}) =
    (setdata!(n, :out, getinputdata(n, :a) && getinputdata(n, :b)); [:out])

# total: an index outside the array gives typemin(Int)
function MetidaFlows.execute_unsafe!(node::DataNode{InsReadAt})
    a = getinputdata(node, :array)
    k = getinputdata(node, :index)
    setdata!(node, :out, (1 <= k <= length(a)) ? a[k] : typemin(Int))
    return [:out]
end

# total: with no pair at the index, the array comes back as it is
function MetidaFlows.execute_unsafe!(node::DataNode{InsSwapAt})
    a = copy(getinputdata(node, :array))
    k = getinputdata(node, :index)
    if 1 <= k < length(a)
        a[k], a[k + 1] = a[k + 1], a[k]
    end
    setdata!(node, :out, a)
    return [:out]
end
nothing # hide
```

The head is a pure multiplexer: empty feedback buffers mean the first turn.

```@example insertion
function MetidaFlows.execute_unsafe!(node::DataNode{InsertState})
    back = getinputdata(node, :array)
    if back === nothing                       # the first turn
        setdata!(node, :array,  getinputdata(node, :init_array))
        setdata!(node, :i,      getinputdata(node, :init_i))
        setdata!(node, :j,      getinputdata(node, :init_j))
        setdata!(node, :epochs, getinputdata(node, :init_epochs))
    else                                      # the state of the previous turn
        setdata!(node, :array,  back)
        setdata!(node, :i,      getinputdata(node, :i))
        setdata!(node, :j,      getinputdata(node, :j))
        setdata!(node, :epochs, getinputdata(node, :epochs))
    end
    return [:array, :i, :j, :epochs]
end
nothing # hide
```

The gate picks one of three outcomes. Both candidates arrive ready-made,
because in a graph the branch is taken *after* both sides have been computed.

```@example insertion
INS_BRANCH = Symbol[]

function MetidaFlows.execute_unsafe!(node::DataNode{InsertGate})
    array = getinputdata(node, :array)
    if getinputdata(node, :done)              # i > n, the outer loop is over
        setdata!(node, :sorted,       array)
        setdata!(node, :total_epochs, getinputdata(node, :epochs))
        return [:sorted, :total_epochs]
    end
    if getinputdata(node, :step)              # a step of the inner loop
        push!(INS_BRANCH, :swap)
        setdata!(node, :array,  getinputdata(node, :array_swap))
        setdata!(node, :i,      getinputdata(node, :i))
        setdata!(node, :j,      getinputdata(node, :j_dec))
        setdata!(node, :epochs, getinputdata(node, :epochs))
    else                                      # a new epoch
        push!(INS_BRANCH, :epoch)
        setdata!(node, :array,  array)
        setdata!(node, :i,      getinputdata(node, :i_next))
        setdata!(node, :j,      getinputdata(node, :i))   # j = (i+1) - 1 = i
        setdata!(node, :epochs, getinputdata(node, :epochs_next))
    end
    return [:array, :i, :j, :epochs]
end
nothing # hide
```

### The graph

```
 ConstArray ─┬─▶ ArrayLength ─────────────────┐
             │                                │
             └──▶ head.init_array             ▼
 ConstTwo ──────▶ head.init_i      ┌───▶ InsGreater (done: i > n) ────┐
 ConstOne ──────▶ head.init_j      │                                 │
 ConstZero ─────▶ head.init_epochs │                                 │
                                   │                                 │
                    InsertState ───┤                                 │
                    (array,i,j,    ├───▶ InsNotLess (alive: j >= 1) ──┤
                     epochs)       │            │                    │
                         ▲         ├───▶ InsAdd (jnext: j + 1)       │
                         │         │            │                    │
                         │         ├───▶ InsReadAt (left:  a[j])     │
                         │         ├───▶ InsReadAt (right: a[jnext]) │
                         │         │            │                    │
                         │         │     InsGreater (greater) ───────┤
                         │         │            │                    │
                         │         │       InsAnd (step) ────────────┤
                         │         │                                 │
                         │         ├───▶ InsSwapAt (swapped) ────────┤
                         │         ├───▶ InsAdd (inext: i + 1) ──────┤
                         │         ├───▶ InsSub (jdec: j - 1) ───────┤
                         │         └───▶ InsAdd (enext: eps + 1) ────┤
                         │                                           │
                         │                                    InsertGate
                         │                                      │    │
                         └────── :feedback ─────────────────────┘    ▼
                            (array, i, j, epochs)          :sorted, :epochs
```

```@example insertion
function build_insertion_sort(values::Vector{Int})
    w      = Workflow(0; type = :ABW)
    w.name = "Insertion sort"

    a0    = add_node!(w, DataNode(InsConstArray, spec_insconstarray()))
    two   = add_node!(w, DataNode(InsConstInt,   spec_insconstint()))
    one   = add_node!(w, DataNode(InsConstInt,   spec_insconstint()))
    zero  = add_node!(w, DataNode(InsConstInt,   spec_insconstint()))
    len   = add_node!(w, DataNode(InsLength,     spec_inslength()))
    head  = add_node!(w, DataNode(InsertState,   spec_insertstate()))
    done  = add_node!(w, DataNode(InsGreater,    spec_insgreater()))
    alive = add_node!(w, DataNode(InsNotLess,    spec_insnotless()))
    jnext = add_node!(w, DataNode(InsAdd,        spec_insadd()))
    left  = add_node!(w, DataNode(InsReadAt,     spec_insreadat()))
    right = add_node!(w, DataNode(InsReadAt,     spec_insreadat()))
    gt    = add_node!(w, DataNode(InsGreater,    spec_insgreater()))
    step  = add_node!(w, DataNode(InsAnd,        spec_insand()))
    swap  = add_node!(w, DataNode(InsSwapAt,     spec_insswapat()))
    inext = add_node!(w, DataNode(InsAdd,        spec_insadd()))
    jdec  = add_node!(w, DataNode(InsSub,        spec_inssub()))
    enext = add_node!(w, DataNode(InsAdd,        spec_insadd()))
    gate  = add_node!(w, DataNode(InsertGate,    spec_insertgate()))

    setsettings!(w, a0,   Dict(:values => copy(values)))
    setsettings!(w, two,  Dict(:value  => 2))
    setsettings!(w, one,  Dict(:value  => 1))
    setsettings!(w, zero, Dict(:value  => 0))

    add_connection!(w, a0,   :array, head, :init_array)
    add_connection!(w, two,  :out,   head, :init_i)
    add_connection!(w, one,  :out,   head, :init_j)
    add_connection!(w, zero, :out,   head, :init_epochs)

    # the length is taken from the source: swapping does not change it
    add_connection!(w, a0,   :array,  len,  :array)

    add_connection!(w, head, :i,      done, :a)
    add_connection!(w, len,  :length, done, :b)

    add_connection!(w, head,  :j,     alive, :a)
    add_connection!(w, one,   :out,   alive, :b)
    add_connection!(w, head,  :j,     jnext, :a)
    add_connection!(w, one,   :out,   jnext, :b)
    add_connection!(w, head,  :array, left,  :array)
    add_connection!(w, head,  :j,     left,  :index)
    add_connection!(w, head,  :array, right, :array)
    add_connection!(w, jnext, :out,   right, :index)
    add_connection!(w, left,  :out,   gt,    :a)
    add_connection!(w, right, :out,   gt,    :b)
    add_connection!(w, alive, :out,   step,  :a)
    add_connection!(w, gt,    :out,   step,  :b)

    add_connection!(w, head, :array,  swap,  :array)
    add_connection!(w, head, :j,      swap,  :index)
    add_connection!(w, head, :i,      inext, :a)
    add_connection!(w, one,  :out,    inext, :b)
    add_connection!(w, head, :j,      jdec,  :a)
    add_connection!(w, one,  :out,    jdec,  :b)
    add_connection!(w, head, :epochs, enext, :a)
    add_connection!(w, one,  :out,    enext, :b)

    add_connection!(w, done,  :out,    gate, :done)
    add_connection!(w, step,  :out,    gate, :step)
    add_connection!(w, head,  :array,  gate, :array)
    add_connection!(w, swap,  :out,    gate, :array_swap)
    add_connection!(w, head,  :i,      gate, :i)
    add_connection!(w, inext, :out,    gate, :i_next)
    add_connection!(w, jdec,  :out,    gate, :j_dec)
    add_connection!(w, head,  :epochs, gate, :epochs)
    add_connection!(w, enext, :out,    gate, :epochs_next)

    add_connection!(w, gate, :array,  head, :array)
    add_connection!(w, gate, :i,      head, :i)
    add_connection!(w, gate, :j,      head, :j)
    add_connection!(w, gate, :epochs, head, :epochs)

    return (w = w, head = head, gate = gate, left = left, right = right)
end

function insertion_sort(values::Vector{Int})
    empty!(INS_BRANCH)
    g = build_insertion_sort(values)
    scheduler!(g.w; maxiter = 100_000)
    (sorted = getdata(g.w, g.gate, :sorted),
     turns  = length(INS_BRANCH),
     epochs = getdata(g.w, g.gate, :total_epochs),
     g      = g)
end

r = insertion_sort([5, 2, 9, 1, 7, 3])
(sorted = r.sorted, turns = r.turns, epochs = r.epochs)
```

Eighteen nodes, forty connections, and the sorting happens because of how they
are wired.

### Epochs are fixed, turns are not

The outer loop always runs `n - 1` times. The inner loop runs as much as the
data demands, and that is what the turn count shows:

```@example insertion
using Printf
for n in 2:7
    s = insertion_sort(collect(1:n))        # already sorted
    r = insertion_sort(collect(n:-1:1))     # reversed
    @printf("n = %d   sorted: %2d turns, %d epochs   reversed: %2d turns, %d epochs\n",
            n, s.turns, s.epochs, r.turns, r.epochs)
end
```

On reversed input every epoch does exactly one step more than the last:

```@example insertion
function epoch_lengths(branch)
    steps = Int[]; cur = 0
    for b in branch
        b === :swap ? (cur += 1) : (push!(steps, cur); cur = 0)
    end
    steps
end

r = insertion_sort(collect(6:-1:1))
epoch_lengths(INS_BRANCH)
```

And `turns == epochs + swaps`, always — a turn is either one or the other:

```@example insertion
r = insertion_sort([3, 1, 4, 1, 5, 9, 2, 6])
(turns = r.turns, epochs = r.epochs,
 swaps = count(==(:swap), INS_BRANCH),
 sum_matches = r.turns == r.epochs + count(==(:swap), INS_BRANCH))
```

### Degenerate input

An array of zero or one element never enters the outer loop, so there are no
turns at all. The body of the graph still runs once, and the read past the end
happens — which is why `ReadAt` is total:

```@example insertion
r = insertion_sort(Int[])
(sorted = r.sorted, turns = r.turns,
 left  = getdata(r.g.w, r.g.left,  :out) == typemin(Int),
 right = getdata(r.g.w, r.g.right, :out) == typemin(Int))
```

### Things to watch

* **The state in the feedback buffers is the one the loop stopped on**, that
  is `i == n + 1`. The final turn read it, saw `done`, and wrote only the
  terminal ports, leaving the feedback buffers untouched.

* **All loop state lives in `:feedback` ports, including the epoch counter.**
  Anything that has to survive a turn boundary goes there; a node cannot keep
  it anywhere else, because it sees only its own inputs.

* **The branch is taken after both sides are computed.** This costs a swap and
  three additions per turn that may be discarded. A pre-tested loop avoids
  that at the price of a more complex gate placement — see
  [bubble sort](examples_bubble_sort.md).

* **`maxiter` of the scheduler is not the length of the sort.** It counts queue
  operations: about eighteen per turn here.
