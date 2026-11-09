```@meta
CurrentModule = MetidaFlows
```

## Modular exponentiation: an algorithm that skips work

Every other example in this section computes something. This one is about
*not* computing: the whole value of binary exponentiation is that it performs a
multiplication only where the exponent has a one bit.

```julia
result = 1;  base = x;  e = n
while e > 0
    if isodd(e)
        result = result * base % m      # only on set bits
    end
    base = base * base % m              # every turn
    e >>= 1
end
```

So conditional evaluation here is not decoration. Compute the product on every
turn and throw the extra away, and the algorithm stops being cheap in
multiplications — which is the only thing it was ever cheap in.

### Both idioms, and both load-bearing

The [guide](guide.md#Conditional-evaluation) describes two ways to make a
computation conditional. This graph uses one of each, and the choice between
them is forced:

* **the operation decides.** `PMulModIf` always runs — it checks a flag — and
  multiplies and publishes only on an odd turn. That is where the work is
  saved.
* **an optional port merges the branches.** The gate's `:product` port is
  `required = false`: on an even turn there is no product, the gate reads
  `nothing`, and carries the previous `result` forward. That is how two
  branches rejoin one loop state without a second writer into a feedback port.

A full guard — a node that relays everything the multiplication needs, or
publishes nothing — does *not* work here, and the reason is worth knowing. The
guard goes silent, so the multiplication is not ready and never runs, so it
stays `:dirty`, and the gate waits for its `:clean` — optional port or not.
Waiting is about the producer's *status*, not about the value.

That failure is measured, and it is a quiet one: the queue drains, nothing
throws, and `3^5 mod 7` comes back as `nothing` after two turns instead of a
result. By default the guard form belongs at a dead end, where nothing
downstream is waiting; this product has to come back into the loop.

`scheduler!(w; release_optional = true)` lifts that restriction, and then the
guard is the *better* of the two idioms here — it saves the node execution as
well as the multiplication. Both are measured side by side at the end of this
page.

### The nodes

```@example power
using MetidaFlows
import MetidaFlows: PortSpec, getstatus, getnode, getstate

struct PConst     <: AbstractNodeType end  # an integer constant
struct PowState   <: AbstractNodeType end  # the loop state
struct PIsZero    <: AbstractNodeType end  # a == 0
struct PIsOdd     <: AbstractNodeType end  # isodd(a)
struct PMulMod    <: AbstractNodeType end  # a * b % m
struct PMulModIf  <: AbstractNodeType end  # a * b % m, only when told to
struct PHalf      <: AbstractNodeType end  # a >> 1
struct PowGate    <: AbstractNodeType end  # the branch of a turn
struct PowGuard   <: AbstractNodeType end  # relays the pair, or publishes nothing

spec_pconst() = NodeSpec("P const", PortSpec[],
    [PortSpec("Out", Int, :out)], [:value])
spec_piszero() = NodeSpec("P is zero",
    [PortSpec("A", Int, :a)], [PortSpec("Out", Bool, :out)])
spec_pisodd() = NodeSpec("P is odd",
    [PortSpec("A", Int, :a)], [PortSpec("Out", Bool, :out)])
spec_phalf() = NodeSpec("P half",
    [PortSpec("A", Int, :a)], [PortSpec("Out", Int, :out)])
spec_pmulmod() = NodeSpec("P mul mod",
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b), PortSpec("M", Int, :m)],
    [PortSpec("Out", Int, :out)])

spec_pmulmodif() = NodeSpec("P mul mod if",
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b), PortSpec("M", Int, :m),
     PortSpec("Pass", Bool, :pass)],
    [PortSpec("Out", Int, :out)])

spec_powguard() = NodeSpec("Pow guard",
    [PortSpec("Result", Int, :result), PortSpec("Base", Int, :base),
     PortSpec("Pass", Bool, :pass)],
    [PortSpec("Result", Int, :result), PortSpec("Base", Int, :base)])

spec_powstate() = NodeSpec("Pow state",
    [PortSpec("Initial result", Int, :init_result),
     PortSpec("Initial base",   Int, :init_base),
     PortSpec("Initial exp",    Int, :init_exp),
     PortSpec("Result",   Int, :result; kind = :feedback, required = false),
     PortSpec("Base",     Int, :base;   kind = :feedback, required = false),
     PortSpec("Exponent", Int, :exp;    kind = :feedback, required = false)],
    [PortSpec("Result",   Int, :result),
     PortSpec("Base",     Int, :base),
     PortSpec("Exponent", Int, :exp)])

# :product is the optional port — the whole merge rests on it
spec_powgate() = NodeSpec("Pow gate",
    [PortSpec("Done",      Bool, :done),
     PortSpec("Result",    Int,  :result),
     PortSpec("Product",   Int,  :product; required = false),
     PortSpec("Base next", Int,  :base_next),
     PortSpec("Exp next",  Int,  :exp_next)],
    [PortSpec("Result",   Int, :result),
     PortSpec("Base",     Int, :base),
     PortSpec("Exponent", Int, :exp),
     PortSpec("Value",    Int, :value; kind = :terminal)])
nothing # hide
```

The conditional node is three lines, and the first of them is the whole point:

```@example power
MULS = Ref(0)      # how many multiplications were actually performed

MetidaFlows.execute_unsafe!(n::DataNode{PConst}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{PIsZero}) =
    (setdata!(n, :out, getinputdata(n, :a) == 0); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{PIsOdd}) =
    (setdata!(n, :out, isodd(getinputdata(n, :a))); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{PHalf}) =
    (setdata!(n, :out, getinputdata(n, :a) >> 1); [:out])

function MetidaFlows.execute_unsafe!(n::DataNode{PMulMod})
    MULS[] += 1
    setdata!(n, :out, (getinputdata(n, :a) * getinputdata(n, :b)) %
                      getinputdata(n, :m))
    return [:out]
end

function MetidaFlows.execute_unsafe!(n::DataNode{PMulModIf})
    getinputdata(n, :pass) || return Symbol[]        # nothing is published
    MULS[] += 1
    setdata!(n, :out, (getinputdata(n, :a) * getinputdata(n, :b)) %
                      getinputdata(n, :m))
    return [:out]
end

# the guard form: everything the multiplication needs goes through here
MetidaFlows.execute_unsafe!(n::DataNode{PowGuard}) =
    getinputdata(n, :pass) ?
        (setdata!(n, :result, getinputdata(n, :result));
         setdata!(n, :base,   getinputdata(n, :base)); [:result, :base]) :
        Symbol[]

function MetidaFlows.execute_unsafe!(node::DataNode{PowGate})
    result = getinputdata(node, :result)
    if getinputdata(node, :done)
        setdata!(node, :value, result)
        return [:value]
    end
    product = getinputdata(node, :product)           # nothing on an even turn
    setdata!(node, :result, isnothing(product) ? result : product)
    setdata!(node, :base,   getinputdata(node, :base_next))
    setdata!(node, :exp,    getinputdata(node, :exp_next))
    return [:result, :base, :exp]
end

function MetidaFlows.execute_unsafe!(node::DataNode{PowState})
    back = getinputdata(node, :result)
    if back === nothing
        setdata!(node, :result, getinputdata(node, :init_result))
        setdata!(node, :base,   getinputdata(node, :init_base))
        setdata!(node, :exp,    getinputdata(node, :init_exp))
    else
        setdata!(node, :result, back)
        setdata!(node, :base,   getinputdata(node, :base))
        setdata!(node, :exp,    getinputdata(node, :exp))
    end
    return [:result, :base, :exp]
end
nothing # hide
```

### The graph

```
 PConst(1) ─▶ head.init_result       ┌──▶ PIsZero (done: e == 0) ──┐
 PConst(x) ─▶ head.init_base         │                             │
 PConst(n) ─▶ head.init_exp          ├──▶ PIsOdd (odd: isodd e) ───┼──┐
                                     │            │                │  │
                      PowState ──────┤            └── :pass ──┐    │  │
                      (result,       │                        ▼    │  │
                       base, exp)    ├──▶ PMulModIf (product) ─────┼──┤
                           ▲         ├──▶ PMulMod  (base²) ────────┤  │
                           │         └──▶ PHalf    (e >> 1) ───────┤  │
 PConst(m) ─────────────────────────────▶ (both multiplications)   │  │
                           │                                 PowGate ◀┘
                           └────── :feedback ───────────────────┘  │
                             (result, base, exp)                   ▼
                                                                :value
```

Eleven nodes, twenty-one connections.

```@example power
function build_power(x::Int, n::Int, m::Int; guard::Bool = false)
    w      = Workflow(0; type = :ABW)
    w.name = "Modular exponentiation"

    cone = add_node!(w, DataNode(PConst, spec_pconst()))
    cx   = add_node!(w, DataNode(PConst, spec_pconst()))
    cn   = add_node!(w, DataNode(PConst, spec_pconst()))
    cm   = add_node!(w, DataNode(PConst, spec_pconst()))
    setsettings!(w, cone, Dict(:value => 1 % m))
    setsettings!(w, cx,   Dict(:value => x % m))
    setsettings!(w, cn,   Dict(:value => n))
    setsettings!(w, cm,   Dict(:value => m))

    head = add_node!(w, DataNode(PowState,  spec_powstate()))
    done = add_node!(w, DataNode(PIsZero,   spec_piszero()))
    odd  = add_node!(w, DataNode(PIsOdd,    spec_pisodd()))
    prod = guard ? add_node!(w, DataNode(PMulMod,   spec_pmulmod())) :
                   add_node!(w, DataNode(PMulModIf, spec_pmulmodif()))
    sqr  = add_node!(w, DataNode(PMulMod,   spec_pmulmod()))
    half = add_node!(w, DataNode(PHalf,     spec_phalf()))
    gate = add_node!(w, DataNode(PowGate,   spec_powgate()))

    add_connection!(w, cone, :out, head, :init_result)
    add_connection!(w, cx,   :out, head, :init_base)
    add_connection!(w, cn,   :out, head, :init_exp)

    add_connection!(w, head, :exp, done, :a)
    add_connection!(w, head, :exp, odd,  :a)
    add_connection!(w, head, :exp, half, :a)

    if guard
        #  everything the multiplication needs goes through the guard, so on
        #  an even turn the multiplication is not even executed
        gd = add_node!(w, DataNode(PowGuard, spec_powguard()))
        add_connection!(w, head, :result, gd, :result)
        add_connection!(w, head, :base,   gd, :base)
        add_connection!(w, odd,  :out,    gd, :pass)     # the condition
        add_connection!(w, gd, :result, prod, :a)
        add_connection!(w, gd, :base,   prod, :b)
    else
        add_connection!(w, head, :result, prod, :a)
        add_connection!(w, head, :base,   prod, :b)
        add_connection!(w, odd,  :out,    prod, :pass)   # the condition
    end
    add_connection!(w, cm,   :out,    prod, :m)

    add_connection!(w, head, :base, sqr, :a)
    add_connection!(w, head, :base, sqr, :b)
    add_connection!(w, cm,   :out,  sqr, :m)

    add_connection!(w, done, :out,    gate, :done)
    add_connection!(w, head, :result, gate, :result)
    add_connection!(w, prod, :out,    gate, :product)
    add_connection!(w, sqr,  :out,    gate, :base_next)
    add_connection!(w, half, :out,    gate, :exp_next)

    add_connection!(w, gate, :result, head, :result)
    add_connection!(w, gate, :base,   head, :base)
    add_connection!(w, gate, :exp,    head, :exp)

    (w = w, head = head, prod = prod, sqr = sqr, gate = gate, odd = odd)
end

function power(x::Int, n::Int, m::Int; guard::Bool = false, release::Bool = false)
    MULS[] = 0
    g = build_power(x, n, m; guard = guard)
    scheduler!(g.w; maxiter = 1_000_000, release_optional = release)
    sqrs = getnode(g.w, g.sqr).state.exec_n
    (value = getdata(g.w, g.gate, :value),
     turns = getnode(g.w, g.head).state.exec_n,
     runs  = getnode(g.w, g.prod).state.exec_n,   # executions of the node
     muls  = MULS[] - sqrs,                       # multiplications performed
     sqrs  = sqrs, g = g)
end

r = power(3, 5, 7)
(value = r.value, check = powermod(3, 5, 7),
 turns = r.turns, node_runs = r.runs, multiplications = r.muls)
```

### The node runs every turn; the multiplication does not

That distinction is the measurement. The conditional node is executed on every
turn — it only looks at a flag — while the number of multiplications it
performs is exactly the number of one bits in the exponent:

```@example power
using Printf
function table()
    for n in (1, 2, 3, 5, 15, 16, 100, 255, 256, 1023, 1024)
        p = power(3, n, 1_000_003)
        @printf("n = %4d (%12s)  turns %3d  node runs %3d  multiplications %2d  ones %2d\n",
                n, string(n, base = 2), p.turns, p.runs, p.muls, count_ones(n))
    end
end
table()
```

A power of two is the extreme case: one multiplication however large the
exponent.

```@example power
r = power(3, 2^20, 1_000_003)
(value = r.value, check = powermod(3, 2^20, 1_000_003),
 turns = r.turns, multiplications = r.muls)
```

Compare that with the twenty-two multiplications a graph that computed the
product on every turn would perform — same answer, all of the work:

```@example power
r = power(3, 2^20, 1_000_003)
(conditional = r.muls, unconditional = r.turns,
 naive_repeated_multiplication = 2^20 - 1)
```

### What the graph looks like on an even turn

With the exponent `2 = 0b10` the first turn is even, the second odd, the third
the final one. Afterwards the conditional node is `:clean` — it ran — but it
published nothing on that last turn, and the gate's buffer for `:product` is
empty rather than holding the previous turn's value:

```@example power
r = power(3, 2, 1_000_003)
prod = getnode(r.g.w, r.g.prod)
(value = r.value, turns = r.turns, multiplications = r.muls,
 node_status = getstatus(prod),
 published_last = getstate(prod, :ready_ports),
 gate_sees = getinputdata(getnode(r.g.w, r.g.gate), :product))
```

### The guard form, and what releasing it costs

Everything above routes the condition *into* the multiplication. The guard form
routes the condition into a node ahead of it, so on an even turn the
multiplication has no input at all and is never executed. In the cycle that
deadlocks, and the deadlock is silent — no result, no error:

```@example power
r = power(3, 5, 7; guard = true)
(value = r.value, turns = r.turns, multiplications = r.muls)
```

With `release_optional = true` the scheduler, once its queue has run dry,
releases the gate — whose `:product` is optional — and the loop continues:

```@example power
function compare(n, m = 1_000_003)
    a = power(3, n, m)                                    # condition in the node
    b = power(3, n, m; guard = true, release = true)      # condition in a guard
    (n = n, ones = count_ones(n),
     value_ok = a.value == b.value == powermod(3, n, m),
     turns = a.turns,
     runs_conditional = a.runs, runs_guarded = b.runs,
     muls_conditional = a.muls, muls_guarded = b.muls)
end
compare.((1, 5, 16, 100, 1024))
```

Same answer, same number of multiplications — and the guarded node is executed
only on the turns that use it, instead of on every turn. For `n = 1024` that is
one execution against twelve.

The price is that "no value" now also covers "the producer failed", so an
exception upstream of an optional port arrives as `nothing` rather than as a
node that did not run. That is why the flag is opt-in rather than the default.

### Things to watch

* **One squaring is wasted.** The exit test lives in the gate, at the end of a
  turn, so the final turn squares the base and the gate discards it. The
  imperative loop tests before squaring and does one less. That is the price of
  a post-tested loop, the same as in [gradient
  descent](examples_gradient_descent.md).

* **The modulus comes from a constant node that runs once.** It executes on the
  first turn and stays `:clean` — nothing marks it dirty, because it is not
  downstream of the loop head — so its value stays in the multiplications'
  buffers. If it were re-executed every turn it would be ordinary work; as it
  is, it is free.

* **`:product` must be `required = false`.** Declare it required and the gate
  is simply not ready on an even turn: the value is not coming, the node does
  not run, and the loop stops. The flag is the whole difference between "this
  may be absent" and "wait for it".
