```@meta
CurrentModule = MetidaFlows
```

## Gradient descent on a graph

The second algorithm of the zoo, after [bubble sort](examples_bubble_sort.md).
It adds four things that example did not have:

* the loop stops on a **floating-point criterion** rather than a counter, and
  there are **two** stop conditions — converged or out of iterations — so the
  gate chooses between three outcomes and reports which one fired;
* the loop is **post-tested**: you need a step to have a gradient, so the body
  always runs at least once;
* the **objective function is a subgraph, not a node**. Evaluating `f` at two
  points means two copies of its subgraph, and changing the objective is a
  setting or a rewiring rather than an edit to any node's code;
* the central difference is a real **diamond inside the cycle**: two branches
  compute `f(x+h)` and `f(x-h)` and meet at the gradient.

The arithmetic nodes are generic — `SubFloat` appears five times in the graph,
`MulFloat` three times. The algorithm lives in the wiring.

### The state that travels around the loop

| Value | Meaning |
|---|---|
| `x` | the current point |
| `iter` | how many steps have been taken |

One turn computes the gradient at `x` by a central difference, steps to
`x - rate * grad`, increments `iter`, and then tests both stop conditions. The
objective is `f(y) = (y - c)²`, so the gradient is exactly `2(x - c)` — the
central difference of a quadratic is its derivative, with no truncation error.

### The graph

```
 ConstFloat(x0) ─┐                   ┌─▶ AddFloat(x,h) ─▶ Sub(−c) ─▶ Mul(²) ───┐
 ConstInt(0) ────┼─▶ DescentState ───┤                                         │
                 │        ▲          └─▶ SubFloat(x,h) ─▶ Sub(−c) ─▶ Mul(²) ───┤
 ConstFloat(c) ──┼────────┼──────────────────▶ ↑               ↑               │
                 │        │                                  SubFloat(fp,fm)   │
 ConstFloat(h) ──┼────────┼──▶ AddFloat(h,h) ──────────────────▶ DivFloat ──▶ grad
                 │        │                                                    │
 ConstFloat(rate)┼────────┼───────────────────▶ MulFloat(rate, grad) ──────────┤
                 │        │                             │                      │
                 │        │                      SubFloat(x, step) ─▶ x'       │
                 │        │                                                    ▼
 ConstFloat(tol) ┼────────┼───────────────────▶ LessFloat ◀── AbsFloat(grad) ──┘
                 │        │                         │
 ConstInt(1) ────┼────────┼──▶ AddInt(iter,1) ─▶ NotLessInt ◀── ConstInt(maxiter)
                 │        │             │              │
                 │        │             │        OrBool(conv, exh)
                 │        │             ▼              ▼
                 │        └─ :feedback ──── DescentGate ──▶ :minimum
                 │                                      ──▶ :iterations
                 └────────────────────────────────────────▶ :reason
```

Twenty-six nodes of thirteen types. Every node takes exactly the inputs it
needs, from whatever depth: there are no pass-through rails, because
[`isready`](@ref) holds a node back until all of its `:normal` ancestors have
been recomputed during the turn — see *Rule 3* in the guide.

!!! note "This graph needs that guarantee"
    `SubFloat(x, step)` has one input straight from the loop head and the
    other eight nodes downstream of it, and no order of connection creation
    can save it: the node is always queued on the first wave. Bubble sort's
    natural wiring happened to survive without the guarantee; this one cannot.

### The node types

```@example descent
using MetidaFlows

struct ConstFloat   <: AbstractNodeType end   # вещественная константа
struct ConstInt     <: AbstractNodeType end
struct DescentState <: AbstractNodeType end   # loop state (x, iter)
struct AddFloat     <: AbstractNodeType end
struct SubFloat     <: AbstractNodeType end
struct MulFloat     <: AbstractNodeType end
struct DivFloat     <: AbstractNodeType end
struct AbsFloat     <: AbstractNodeType end
struct LessFloat    <: AbstractNodeType end
struct AddInt       <: AbstractNodeType end
struct NotLessInt   <: AbstractNodeType end
struct OrBool       <: AbstractNodeType end
struct DescentGate  <: AbstractNodeType end   # branch: another step, or the answer
nothing # hide
```

### Interfaces

The loop head is the only node with `:feedback` ports. Its normal inputs are
the starting point and the starting counter; the feedback inputs carry the
state of the previous iteration and are not `required`, because their buffers
are empty on the first one.

```@example descent
state_spec = NodeSpec("Descent state",
    [PortSpec("Initial x",    Float64, :init_x),
     PortSpec("Initial iter", Int,     :init_iter),
     PortSpec("X",            Float64, :x;    kind = :feedback, required = false),
     PortSpec("Iteration",    Int,     :iter; kind = :feedback, required = false)],
    [PortSpec("X",         Float64, :x),
     PortSpec("Iteration", Int,     :iter)])
```

The gate publishes the state onward while the loop runs, and three terminal
ports when it stops — the point, the iteration count, and the reason:

```@example descent
gate_spec = NodeSpec("Descent gate",
    [PortSpec("Stop",      Bool,    :stop),
     PortSpec("Converged", Bool,    :converged),
     PortSpec("X",         Float64, :x),
     PortSpec("Iteration", Int,     :iter)],
    [PortSpec("X",          Float64, :x),
     PortSpec("Iteration",  Int,     :iter),
     PortSpec("Minimum",    Float64, :minimum;    kind = :terminal),
     PortSpec("Iterations", Int,     :iterations; kind = :terminal),
     PortSpec("Reason",     Symbol,  :reason;     kind = :terminal)])
```

The arithmetic is generic — two inputs, one output:

```@example descent
binary(name, out) = NodeSpec(name,
    [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
    [PortSpec("Out", out, :out)])

add_spec  = binary("Add float",  Float64)
sub_spec  = binary("Sub float",  Float64)
mul_spec  = binary("Mul float",  Float64)
div_spec  = binary("Div float",  Float64)
less_spec = binary("Less float", Bool)

abs_spec = NodeSpec("Abs float",
    [PortSpec("A", Float64, :a)], [PortSpec("Out", Float64, :out)])
addint_spec = NodeSpec("Add int",
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b)], [PortSpec("Out", Int, :out)])
notless_spec = NodeSpec("Not less int",
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b)], [PortSpec("Out", Bool, :out)])
or_spec = NodeSpec("Or bool",
    [PortSpec("A", Bool, :a), PortSpec("B", Bool, :b)], [PortSpec("Out", Bool, :out)])
float_spec = NodeSpec("Const float", PortSpec[],
    [PortSpec("Value", Float64, :out)], [:value])
int_spec = NodeSpec("Const int", PortSpec[],
    [PortSpec("Value", Int, :out)], [:value])
nothing # hide
```

### Behaviour

The generic nodes are one line each, so they are written in a loop — which is
the point: none of them knows anything about gradient descent.

```@example descent
for (T, op) in ((AddFloat, +), (SubFloat, -), (MulFloat, *), (DivFloat, /))
    @eval MetidaFlows.execute_unsafe!(n::DataNode{$T}) =
        (setdata!(n, :out, $op(getinputdata(n, :a), getinputdata(n, :b))); [:out])
end

MetidaFlows.execute_unsafe!(n::DataNode{ConstFloat}) =
    (setdata!(n, :out, Float64(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{ConstInt}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{AbsFloat}) =
    (setdata!(n, :out, abs(getinputdata(n, :a))); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{LessFloat}) =
    (setdata!(n, :out, getinputdata(n, :a) < getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{AddInt}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{NotLessInt}) =
    (setdata!(n, :out, getinputdata(n, :a) >= getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{OrBool}) =
    (setdata!(n, :out, getinputdata(n, :a) || getinputdata(n, :b)); [:out])
nothing # hide
```

The head starts from the initial values while the feedback buffer is empty, and
from the loop state once it is not:

```@example descent
function MetidaFlows.execute_unsafe!(node::DataNode{DescentState})
    back = getinputdata(node, :x)
    if back === nothing                       # first iteration
        setdata!(node, :x,    getinputdata(node, :init_x))
        setdata!(node, :iter, getinputdata(node, :init_iter))
    else
        setdata!(node, :x,    back)
        setdata!(node, :iter, getinputdata(node, :iter))
    end
    return [:x, :iter]
end
```

The gate ends the run by publishing only terminal ports, so nothing reaches the
body and the queue drains:

```@example descent
function MetidaFlows.execute_unsafe!(node::DataNode{DescentGate})
    x    = getinputdata(node, :x)
    iter = getinputdata(node, :iter)
    if !getinputdata(node, :stop)
        setdata!(node, :x,    x)
        setdata!(node, :iter, iter)
        return [:x, :iter]                    # one more step
    end
    setdata!(node, :minimum,    x)
    setdata!(node, :iterations, iter)
    setdata!(node, :reason, getinputdata(node, :converged) ? :converged : :exhausted)
    return [:minimum, :iterations, :reason]
end
```

### Building the graph

```@example descent
function descent_graph(; x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5,
                         c = 3.0, maxiter = 1000)
    w = Workflow(0; type = :ABW)
    w.name = "Gradient descent"

    cx0   = add_node!(w, DataNode(ConstFloat, float_spec))
    crate = add_node!(w, DataNode(ConstFloat, float_spec))
    ctol  = add_node!(w, DataNode(ConstFloat, float_spec))
    ch    = add_node!(w, DataNode(ConstFloat, float_spec))
    cc    = add_node!(w, DataNode(ConstFloat, float_spec))
    ci0   = add_node!(w, DataNode(ConstInt,   int_spec))
    cone  = add_node!(w, DataNode(ConstInt,   int_spec))
    cmax  = add_node!(w, DataNode(ConstInt,   int_spec))

    head  = add_node!(w, DataNode(DescentState, state_spec))

    xp    = add_node!(w, DataNode(AddFloat,  add_spec))     # x + h
    xm    = add_node!(w, DataNode(SubFloat,  sub_spec))     # x - h
    dp    = add_node!(w, DataNode(SubFloat,  sub_spec))     # (x+h) - c
    fp    = add_node!(w, DataNode(MulFloat,  mul_spec))     # dp * dp
    dm    = add_node!(w, DataNode(SubFloat,  sub_spec))     # (x-h) - c
    fm    = add_node!(w, DataNode(MulFloat,  mul_spec))     # dm * dm
    twoh  = add_node!(w, DataNode(AddFloat,  add_spec))     # h + h
    diff  = add_node!(w, DataNode(SubFloat,  sub_spec))     # fp - fm
    grad  = add_node!(w, DataNode(DivFloat,  div_spec))     # diff / 2h
    step  = add_node!(w, DataNode(MulFloat,  mul_spec))     # rate * grad
    nextx = add_node!(w, DataNode(SubFloat,  sub_spec))     # x - step
    agrad = add_node!(w, DataNode(AbsFloat,  abs_spec))
    conv  = add_node!(w, DataNode(LessFloat, less_spec))    # |grad| < tol
    nexti = add_node!(w, DataNode(AddInt,    addint_spec))
    exh   = add_node!(w, DataNode(NotLessInt, notless_spec))
    stop  = add_node!(w, DataNode(OrBool,    or_spec))
    gate  = add_node!(w, DataNode(DescentGate, gate_spec))

    add_connection!(w, cx0, :out, head, :init_x)
    add_connection!(w, ci0, :out, head, :init_iter)

    # two points for the central difference
    add_connection!(w, head, :x, xp, :a); add_connection!(w, ch, :out, xp, :b)
    add_connection!(w, head, :x, xm, :a); add_connection!(w, ch, :out, xm, :b)

    # the objective, twice: f(y) = (y - c)^2
    add_connection!(w, xp, :out, dp, :a); add_connection!(w, cc, :out, dp, :b)
    add_connection!(w, dp, :out, fp, :a); add_connection!(w, dp, :out, fp, :b)
    add_connection!(w, xm, :out, dm, :a); add_connection!(w, cc, :out, dm, :b)
    add_connection!(w, dm, :out, fm, :a); add_connection!(w, dm, :out, fm, :b)

    # the gradient
    add_connection!(w, ch,   :out, twoh, :a); add_connection!(w, ch,   :out, twoh, :b)
    add_connection!(w, fp,   :out, diff, :a); add_connection!(w, fm,   :out, diff, :b)
    add_connection!(w, diff, :out, grad, :a); add_connection!(w, twoh, :out, grad, :b)

    # the step
    add_connection!(w, crate, :out, step,  :a); add_connection!(w, grad, :out, step, :b)
    add_connection!(w, head,  :x,   nextx, :a); add_connection!(w, step, :out, nextx, :b)

    # the two stop conditions
    add_connection!(w, grad,  :out,  agrad, :a)
    add_connection!(w, agrad, :out,  conv,  :a); add_connection!(w, ctol, :out, conv, :b)
    add_connection!(w, head,  :iter, nexti, :a); add_connection!(w, cone, :out, nexti, :b)
    add_connection!(w, nexti, :out,  exh,   :a); add_connection!(w, cmax, :out, exh,  :b)
    add_connection!(w, conv,  :out,  stop,  :a); add_connection!(w, exh,  :out, stop, :b)

    # the gate and the feedback edges
    add_connection!(w, stop,  :out, gate, :stop)
    add_connection!(w, conv,  :out, gate, :converged)
    add_connection!(w, nextx, :out, gate, :x)
    add_connection!(w, nexti, :out, gate, :iter)
    add_connection!(w, gate, :x,    head, :x)
    add_connection!(w, gate, :iter, head, :iter)

    for (id, value) in ((cx0, x0), (crate, rate), (ctol, tol), (ch, h), (cc, c))
        setsettings!(w, id, Dict(:value => value))
    end
    setsettings!(w, ci0,  Dict(:value => 0))
    setsettings!(w, cone, Dict(:value => 1))
    setsettings!(w, cmax, Dict(:value => maxiter))

    return (w = w, gate = gate, cc = cc, diff = diff, fp = fp, fm = fm)
end
nothing # hide
```

### Running it

```@example descent
g = descent_graph(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 3.0)
scheduler!(g.w; maxiter = 200_000)

(minimum    = getdata(g.w, g.gate, :minimum),
 iterations = getdata(g.w, g.gate, :iterations),
 reason     = getdata(g.w, g.gate, :reason))
```

The step contracts the error by `1 - 2 * rate` every iteration, so seventy-one
of them bring `|x - 3|` under `5e-7`, which is where `|grad| < tol` fires.

Hit the iteration limit instead and the reason changes:

```@example descent
g2 = descent_graph(x0 = 0.0, rate = 0.1, c = 3.0, maxiter = 10)
scheduler!(g2.w; maxiter = 200_000)

(minimum    = getdata(g2.w, g2.gate, :minimum),
 iterations = getdata(g2.w, g2.gate, :iterations),
 reason     = getdata(g2.w, g2.gate, :reason))
```

### Changing the objective

The point of the minimum is a setting of one node:

```@example descent
g3 = descent_graph(x0 = 0.0, rate = 0.1, c = 7.0)
scheduler!(g3.w; maxiter = 200_000)
getdata(g3.w, g3.gate, :minimum)
```

The *shape* of the objective is wiring. Scaling it by two — `f(y) = 2(y-c)²` —
is two more nodes and a rewiring of the gradient's difference, after which the
same learning rate converges in thirty-three iterations instead of
seventy-one:

```@example descent
using MetidaFlows: delete_connection!, getconnection

g4 = descent_graph(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 3.0)
cs  = add_node!(g4.w, DataNode(ConstFloat, float_spec))
sp  = add_node!(g4.w, DataNode(MulFloat,   mul_spec))
sm  = add_node!(g4.w, DataNode(MulFloat,   mul_spec))
setsettings!(g4.w, cs, Dict(:value => 2.0))

for cid in collect(keys(g4.w.connections))          # detach the difference
    getconnection(g4.w, cid).input_id == g4.diff && delete_connection!(g4.w, cid)
end
add_connection!(g4.w, g4.fp, :out, sp, :a); add_connection!(g4.w, cs, :out, sp, :b)
add_connection!(g4.w, g4.fm, :out, sm, :a); add_connection!(g4.w, cs, :out, sm, :b)
add_connection!(g4.w, sp, :out, g4.diff, :a)
add_connection!(g4.w, sm, :out, g4.diff, :b)

scheduler!(g4.w; maxiter = 200_000)
(minimum = getdata(g4.w, g4.gate, :minimum),
 iterations = getdata(g4.w, g4.gate, :iterations))
```

No node's code changed. The objective is a part of the graph, so it is edited
like the rest of the graph.

### Things to watch

* **A step that is too large does not just fail to converge — it reports
  success.** With `rate = 1.5` the error doubles every iteration, and after
  thirty-seven of them the point is at about `-3.8e11`. There
  `eps(x) ≈ 6.1e-5` is larger than `h = 1e-5`, so `x + h == x` bit for bit,
  `f(x+h) - f(x-h)` is exactly zero, and `|grad| < tol` fires:

  ```@example descent
  g5 = descent_graph(x0 = 0.0, rate = 1.5, tol = 1e-6, h = 1e-5, c = 3.0,
                     maxiter = 50)
  scheduler!(g5.w; maxiter = 200_000)
  x = getdata(g5.w, g5.gate, :minimum)
  (minimum = x, reason = getdata(g5.w, g5.gate, :reason),
   h_vanishes = x + 1e-5 === x, eps_x = eps(x))
  ```

  A criterion built on `|grad|` alone cannot tell "flat because we are at the
  optimum" from "flat because the difference underflowed". A real
  implementation scales the step with the point — `h = h₀ * max(1, |x|)` — or
  also requires that `f` decreased. This is a property of the numerical
  derivative, not of the engine, and the plain Julia version of the same
  arithmetic reproduces it exactly.

* **`maxiter` of the scheduler is not `maxiter` of the algorithm.** The
  algorithm's limit is the `ConstInt` feeding `NotLessInt`; the scheduler's
  limit counts queue operations and needs to be large enough for all of them
  — roughly twenty per iteration here.

* **The loop is post-tested.** Starting exactly at the minimum still costs one
  iteration, of zero length, because the gradient is only known after a step.

* **A full reset starts over.** `reset_mode = :full` clears the feedback
  buffers, so a second [`scheduler!`](@ref) call repeats the descent;
  `:soft` keeps the loop state and continues from the last point.
