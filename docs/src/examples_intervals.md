```@meta
CurrentModule = MetidaFlows
```

## Interval arithmetic: an algorithm the scheduler never runs

Every other example in this section is computed by a scheduler. This one is
computed by [`getmeta`](@ref), and **not one node is executed**.

That is what the metadata mechanism is, named properly: `getmeta` walks up the
graph, asks the producers, and hands their answers to
[`getmeta_unsafe`](@ref) as `inmeta`. It is **abstract interpretation** — a
second, parallel semantics of the same graph, in which descriptions travel
where values normally do, and `nothing` is the top of the lattice, "unknown".

Interval arithmetic is the most revealing algorithm to put in that second
semantics, for one reason: its answer is *checkable by the first one*. An
estimate is not merely plausible — it must contain the result for every input
from the declared ranges, and a run of the graph either confirms that or
refutes it.

```
values:     f(x, y) = (x · y + x) / (y − 2)
metadata:   [lo, hi] of every port, by the rules of interval arithmetic
```

### The rules

```@example iv
using MetidaFlows
import MetidaFlows: PortSpec, getmeta, getinputmeta, ismetasource, getnode, getstatus

struct IvConst <: AbstractNodeType end
struct IvAdd   <: AbstractNodeType end
struct IvSub   <: AbstractNodeType end
struct IvMul   <: AbstractNodeType end
struct IvDiv   <: AbstractNodeType end
struct IvOut   <: AbstractNodeType end

spec_const() = NodeSpec("Iv const", PortSpec[],
    [PortSpec("Out", Float64, :out)], [:value, :lo, :hi])
spec_bin(name) = NodeSpec(name,
    [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
    [PortSpec("Out", Float64, :out)])
spec_out() = NodeSpec("Iv out", [PortSpec("In", Float64, :in)],
    [PortSpec("Out", Float64, :out; kind = :terminal)])

# the ordinary semantics
MetidaFlows.execute_unsafe!(n::DataNode{IvConst}) =
    (setdata!(n, :out, Float64(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvAdd}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvSub}) =
    (setdata!(n, :out, getinputdata(n, :a) - getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvMul}) =
    (setdata!(n, :out, getinputdata(n, :a) * getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvDiv}) =
    (setdata!(n, :out, getinputdata(n, :a) / getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvOut}) =
    (setdata!(n, :out, getinputdata(n, :in)); [:out])
nothing # hide
```

The second semantics is one method per node type. A constant describes itself —
but only once its range is set, which is what [`ismetasource`](@ref) is for:

```@example iv
MetidaFlows.ismetasource(n::DataNode{IvConst}, ::Symbol) =
    haskey(n.settings, :lo) && haskey(n.settings, :hi)

# NOTE: total, not merely consistent with `ismetasource` — see below
function MetidaFlows.getmeta_unsafe(n::DataNode{IvConst}, ::Symbol, inmeta)
    (haskey(n.settings, :lo) && haskey(n.settings, :hi)) || return nothing
    (lo = Float64(n.settings[:lo]), hi = Float64(n.settings[:hi]))
end

both(m) = (a = m[:a]; b = m[:b]; (isnothing(a) || isnothing(b)) ? nothing : (a, b))

MetidaFlows.getmeta_unsafe(n::DataNode{IvAdd}, ::Symbol, m) =
    (p = both(m); isnothing(p) ? nothing :
        (lo = p[1].lo + p[2].lo, hi = p[1].hi + p[2].hi))

# subtraction flips the ends of the subtrahend
MetidaFlows.getmeta_unsafe(n::DataNode{IvSub}, ::Symbol, m) =
    (p = both(m); isnothing(p) ? nothing :
        (lo = p[1].lo - p[2].hi, hi = p[1].hi - p[2].lo))

# multiplication is not monotone in sign: all four products of the ends
function MetidaFlows.getmeta_unsafe(n::DataNode{IvMul}, ::Symbol, m)
    p = both(m); isnothing(p) && return nothing
    a, b = p
    q = (a.lo*b.lo, a.lo*b.hi, a.hi*b.lo, a.hi*b.hi)
    (lo = minimum(q), hi = maximum(q))
end

# and division refuses, instead of answering, when the divisor may be zero
function MetidaFlows.getmeta_unsafe(n::DataNode{IvDiv}, ::Symbol, m)
    p = both(m); isnothing(p) && return nothing
    a, b = p
    b.lo <= 0 <= b.hi &&
        error("Division by an interval containing zero: [$(b.lo), $(b.hi)]")
    q = (a.lo/b.lo, a.lo/b.hi, a.hi/b.lo, a.hi/b.hi)
    (lo = minimum(q), hi = maximum(q))
end

MetidaFlows.getmeta_unsafe(n::DataNode{IvOut}, ::Symbol, m) = m[:in]
nothing # hide
```

### The graph

Eight nodes, nine connections. `x` feeds two consumers and so does `y` — two
diamonds, and the second one turns out to matter more than the first:

```
 x   → mul·a      y   → mul·b
 mul → add·a      x   → add·b      ← x arrives twice
 y   → sub·a      k   → sub·b      ← y arrives twice
 add → div·a      sub → div·b
 div → out·in                      :out is terminal
```

```@example iv
function build(; xlo = 1.0, xhi = 3.0, ylo = 4.0, yhi = 5.0, shift = 2.0)
    w = Workflow(0; type = :DAW)
    cx = add_node!(w, DataNode(IvConst, spec_const()))
    cy = add_node!(w, DataNode(IvConst, spec_const()))
    ck = add_node!(w, DataNode(IvConst, spec_const()))
    setsettings!(w, cx, Dict(:value => (xlo+xhi)/2, :lo => xlo, :hi => xhi))
    setsettings!(w, cy, Dict(:value => (ylo+yhi)/2, :lo => ylo, :hi => yhi))
    setsettings!(w, ck, Dict(:value => shift, :lo => shift, :hi => shift))
    mul = add_node!(w, DataNode(IvMul, spec_bin("Iv mul")))
    add = add_node!(w, DataNode(IvAdd, spec_bin("Iv add")))
    sub = add_node!(w, DataNode(IvSub, spec_bin("Iv sub")))
    div = add_node!(w, DataNode(IvDiv, spec_bin("Iv div")))
    out = add_node!(w, DataNode(IvOut, spec_out()))
    add_connection!(w, cx, :out, mul, :a); add_connection!(w, cy, :out, mul, :b)
    add_connection!(w, mul, :out, add, :a); add_connection!(w, cx, :out, add, :b)
    add_connection!(w, cy, :out, sub, :a);  add_connection!(w, ck, :out, sub, :b)
    add_connection!(w, add, :out, div, :a); add_connection!(w, sub, :out, div, :b)
    add_connection!(w, div, :out, out, :in)
    (w = w, cx = cx, cy = cy, mul = mul, add = add, sub = sub, div = div, out = out)
end

evaluate!(g, xv, yv) = begin
    setsettings!(g.w, g.cx, Dict(:value => xv))
    setsettings!(g.w, g.cy, Dict(:value => yv))
    scheduler!(g.w)
    getdata(g.w, g.out, :out)
end
nothing # hide
```

### An answer with no work done

```@example iv
g    = build()
pred = getmeta(g.w, g.out, :out)

(predicted = pred,
 executions = sum(n -> n.state.exec_n, values(g.w.nodes)),
 clean_nodes = count(n -> getstatus(n) === :clean, values(g.w.nodes)),
 run_id = g.w.run_id)
```

Every intermediate port answers the same way, and still nothing runs:

```@example iv
(mul = getmeta(g.w, g.mul, :out),
 add = getmeta(g.w, g.add, :out),
 sub = getmeta(g.w, g.sub, :out),
 executions_after_all_that = sum(n -> n.state.exec_n, values(g.w.nodes)))
```

### Checked by the first semantics

A grid over the declared box — not random points, so the check is the same on
every machine and every Julia version — and every value must land inside:

```@example iv
function sweep!(g, pred, m)
    lo, hi, inside, total = Inf, -Inf, 0, 0
    for i in 0:m, j in 0:m
        v = evaluate!(g, 1.0 + 2.0*i/m, 4.0 + 1.0*j/m)
        lo = min(lo, v); hi = max(hi, v)
        total += 1
        pred.lo <= v <= pred.hi && (inside += 1)
    end
    (observed_lo = lo, observed_hi = hi, inside = inside, total = total)
end
sweep!(g, pred, 44)
```

### Neither bound is reached, and that is the interesting part

The estimate is `[5/3, 9]`, the truth is `[2, 7.5]`. The gap is not slack in
the implementation — it is the **dependency problem**, and this graph shows it
twice over.

`f(x, y) = x·(y+1)/(y−2)` grows with `x` and falls with `y`, so the real
extremes sit at the corners `(3, 4)` and `(1, 5)`:

```@example iv
(at_3_4 = evaluate!(g, 3.0, 4.0), at_1_5 = evaluate!(g, 1.0, 5.0),
 predicted = pred)
```

The predicted maximum of `9` would need `y = 5` in the numerator and `y = 4` in
the denominator **at the same time**. For the metadata pass those are two
independent arrivals of `y`: it propagates ranges, not identities. The same
thing in its purest form — `x − x` can only be zero, and the estimate cannot
know it:

```@example iv
w  = Workflow(0; type = :DAW)
cx = add_node!(w, DataNode(IvConst, spec_const()))
setsettings!(w, cx, Dict(:value => 0.5, :lo => 0.0, :hi => 1.0))
sb = add_node!(w, DataNode(IvSub, spec_bin("Iv sub")))
ou = add_node!(w, DataNode(IvOut, spec_out()))
add_connection!(w, cx, :out, sb, :a)
add_connection!(w, cx, :out, sb, :b)      # the same node into both inputs
add_connection!(w, sb, :out, ou, :in)

predicted = getmeta(w, ou, :out)
scheduler!(w)
(predicted = predicted, actual = getdata(w, ou, :out))
```

An estimate that is too wide is correct; one that is too narrow would be a bug.
That asymmetry is the whole discipline of abstract interpretation, and it is
why the containment check above is the test that matters.

### Refusing before the data is touched

This is the practical payoff. Widen `y` so that `y − 2` can be zero, and the
metadata pass refuses to produce an answer — with nothing executed:

```@example iv
g2 = build(ylo = 1.0, yhi = 5.0)
(divisor = getmeta(g2.w, g2.sub, :out),
 verdict = try
     getmeta(g2.w, g2.out, :out)
 catch e
     sprint(showerror, e)
 end,
 executions = sum(n -> n.state.exec_n, values(g2.w.nodes)))
```

The refusal is earned: the run really does blow up inside that box.

```@example iv
evaluate!(g2, 2.0, 2.0)
```

### Unknown propagates, and the rule must be total

Take the range off `y`. It stops being a metadata source, the walk continues
past it, and — because a constant has no inputs — `getmeta_unsafe` is called
with an **empty** `inmeta`:

```@example iv
g3 = build()
yn = getnode(g3.w, g3.cy)
delete!(yn.settings, :lo); delete!(yn.settings, :hi)

(is_source = ismetasource(yn, :out),
 y_itself  = getmeta(g3.w, g3.cy, :out),
 whole_expression = getmeta(g3.w, g3.out, :out),
 branch_not_using_y = getmeta(g3.w, g3.cx, :out))
```

!!! warning "`getmeta_unsafe` must be total"
    The [`ismetasource`](@ref) docstring warns against reading `inmeta[:label]`
    in a branch declared a metadata source — the dictionary there is empty. The
    mirror half is just as easy to get wrong, and it is what the `|| return
    nothing` above is for: the method is **also** called on the *not a source*
    branch, where the settings it wants may be missing. Reaching for
    `settings[:lo]` unconditionally raises `KeyError` instead of answering
    `nothing`, from inside the walk, far from the node that caused it.

    Write the method so that it answers for every state the node can be in, not
    only for the states in which `ismetasource` returns `true`.

### The same rules over a polynomial

Nothing about the two semantics is tied to one expression. Build Horner's
scheme out of the same nodes and the metadata pass answers "what are the bounds
of `P(x)` on this interval" — again without running:

```@example iv
function build_poly(coeffs; xlo = 0.0, xhi = 4.0)
    w  = Workflow(0; type = :DAW)
    cx = add_node!(w, DataNode(IvConst, spec_const()))
    setsettings!(w, cx, Dict(:value => (xlo+xhi)/2, :lo => xlo, :hi => xhi))
    prev = add_node!(w, DataNode(IvConst, spec_const()))
    setsettings!(w, prev, Dict(:value => coeffs[1], :lo => coeffs[1], :hi => coeffs[1]))
    for k in 2:length(coeffs)
        ca = add_node!(w, DataNode(IvConst, spec_const()))
        setsettings!(w, ca, Dict(:value => coeffs[k], :lo => coeffs[k], :hi => coeffs[k]))
        m = add_node!(w, DataNode(IvMul, spec_bin("Iv mul")))
        a = add_node!(w, DataNode(IvAdd, spec_bin("Iv add")))
        add_connection!(w, prev, :out, m, :a); add_connection!(w, cx, :out, m, :b)
        add_connection!(w, m, :out, a, :a);    add_connection!(w, ca, :out, a, :b)
        prev = a
    end
    out = add_node!(w, DataNode(IvOut, spec_out()))
    add_connection!(w, prev, :out, out, :in)
    (w = w, cx = cx, out = out)
end

# (x−1)(x−2)(x−3) on [0, 4], coefficients from the leading one down
p = build_poly([1.0, -6.0, 11.0, -6.0]; xlo = 0.0, xhi = 4.0)
(bounds = getmeta(p.w, p.out, :out),
 nodes = length(p.w.nodes),
 executions = sum(n -> n.state.exec_n, values(p.w.nodes)))
```

A degenerate interval makes the estimate exact, which is the sanity check that
the two semantics agree where they must:

```@example iv
q = build_poly([1.0, -6.0, 11.0, -6.0]; xlo = 2.5, xhi = 2.5)
est = getmeta(q.w, q.out, :out)
setsettings!(q.w, q.cx, Dict(:value => 2.5))
scheduler!(q.w)
(estimate = est, actual = getdata(q.w, q.out, :out))
```

### Describing the whole graph at once

Asking port by port re-walks the graph from the top every time. The memo lives
for one call, so a chain of `n` nodes costs `n` walks of `O(n)` where one walk
would do. [`getmeta(model)`](@ref getmeta) asks once and returns every output
port of every node, keyed by `(node id, port label)`:

```@example iv
d = getmeta(p.w)
(ports = length(d), estimate_at_output = d[(p.out, :out)])
```

The gap is quadratic in the length of the graph: the test suite pins an 8-node
chain at 8 rule invocations against 36 asked port by port, and a 101-node chain
at 101 against 5151. The answers are identical to the port-by-port ones — same
memo, same rules, asked in one pass.

A rule that raises takes the whole call with it rather than returning a
half-described graph; see [`MetaRuleError`](@ref) below.

### Things to watch

* **The walk does not cache between calls.** Each `getmeta` recomputes;
  within one call a shared ancestor is described once, which is why the eight
  rules of this graph fire eight times even though `x` and `y` are each needed
  twice. Memoize inside the node if describing a source is expensive, and use
  the whole-graph form above instead of a loop over ports.

* **An error from a rule names its node.** The walk is recursive, so a
  `KeyError` from a rule would otherwise surface with nothing to say about where
  it came from. [`MetaRuleError`](@ref) wraps it with the node id and the port
  and keeps the original in `.cause` — that is what the refusal above printed.
  Errors from the walk itself (an unknown port label, `maxdepth`) are not
  wrapped: they already name their node.

* **A metadata source cuts the walk short.** Everything above a node that
  returns `true` from [`ismetasource`](@ref) is never visited — which is the
  point when the node *is* the authority on what it produces, and a trap when
  it is not.

* **`:feedback` and `:error` edges are not followed**, so this pass is acyclic
  even in a cyclic `ABW` workflow. It also means a loop cannot be *analysed* by
  it: there is no fixed-point iteration here, only one upward pass.

* **Intervals are the cheapest useful abstract domain, not the best one.**
  Everything above holds for any lattice with a rule per node type — units,
  signs, schemas, shapes. What changes is only what `getmeta_unsafe` returns.
