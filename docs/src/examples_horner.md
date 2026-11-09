```@meta
CurrentModule = MetidaFlows
```

## Horner's scheme: a `DAW` algorithm with the loop unrolled

Every other algorithm in these examples is an `ABW` workflow: one flat loop,
all state in `:feedback` ports, and a graph whose size says nothing about the
size of the problem. Horner's scheme is the opposite.

```julia
value = a[n]
for k in n-1:-1:0
    value = value * x + a[k]
end
```

Here the loop is **unrolled into the structure**. Every iteration is a separate
pair of nodes — one multiplication, one addition — so the degree of the
polynomial is visible in the size of the graph. There are no feedback ports, no
state, no turns, and every node executes exactly once per run.

|  | `ABW` (sorting, descent, Newton) | `DAW` (Horner) |
|:---|:---|:---|
| the loop | turns through a cycle | unrolled into nodes |
| state between steps | `:feedback` buffers | none |
| graph size | fixed | grows with the problem |
| executions per node | many | exactly one |

### Value and derivative from one scheme

The same scheme yields `p'(x)` if a second sum is carried alongside:

```julia
b = a[n];  d = 0
for k in n-1:-1:0
    d = d * x + b        # the PREVIOUS b, before it is updated
    b = b * x + a[k]
end
# p(x) = b, p'(x) = d
```

In the graph that means the output of every `b` stage goes to **two**
consumers: the next `b` stage and the matching `d` stage. The result is a
diamond at every stage — a real branching DAG rather than a chain.

### The nodes

```@example horner
using MetidaFlows
import MetidaFlows: PortSpec, getstatus, getnode, get_children

struct HConstF <: AbstractNodeType end  # a Float64 source
struct HMul    <: AbstractNodeType end  # a * b
struct HAdd    <: AbstractNodeType end  # a + b
struct HResult <: AbstractNodeType end  # collects the result

spec_hconstf() = NodeSpec("H const float", PortSpec[],
    [PortSpec("Out", Float64, :out)], [:value])
spec_hmul() = NodeSpec("H mul",
    [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
    [PortSpec("Out", Float64, :out)])
spec_hadd() = NodeSpec("H add",
    [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
    [PortSpec("Out", Float64, :out)])

spec_hresult() = NodeSpec("H result",
    [PortSpec("Value",      Float64, :value),
     PortSpec("Derivative", Float64, :derivative)],
    [PortSpec("Value",      Float64, :value;      kind = :terminal),
     PortSpec("Derivative", Float64, :derivative; kind = :terminal)])

MetidaFlows.execute_unsafe!(n::DataNode{HConstF}) =
    (setdata!(n, :out, Float64(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{HMul}) =
    (setdata!(n, :out, getinputdata(n, :a) * getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{HAdd}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])
function MetidaFlows.execute_unsafe!(node::DataNode{HResult})
    setdata!(node, :value,      getinputdata(node, :value))
    setdata!(node, :derivative, getinputdata(node, :derivative))
    return [:value, :derivative]
end
nothing # hide
```

`HResult` looks redundant — it only passes two values through. It exists
because **a port kind lives in the spec, and a spec is shared by every node of
its type.** The output of the last `HAdd` is connected to nothing, so it is
terminal by intent; but marking it `kind = :terminal` would mark the output of
every intermediate stage too, and those *are* connected. A dedicated node type
is the only way to give a particular place in the graph a terminal port.

### The graph

```
 HConstF(x) ──────┬─────────────┬──────────────┬─────────────┐
                  │             │              │             │
 HConstF(a3) ─▶ HMul ─▶ HAdd ─▶ HMul ─▶ HAdd ─▶ HMul ─▶ HAdd ─▶ HResult
      │           ▲  b1    ▲      ▲  b2    ▲      ▲  b3    ▲   :value
 HConstF(a2) ─────┘        │      │        │      │        │
 HConstF(a1) ──────────────┼──────┘        │      │        │
 HConstF(a0) ──────────────┼───────────────┼──────┘        │
                           │               │               │
 HConstF(0) ─▶ HMul ─▶ HAdd ─▶ HMul ─▶ HAdd ─▶ HMul ─▶ HAdd ─▶ HResult
                  ▲     ▲ d1      ▲     ▲ d2     ▲     ▲ d3   :derivative
                  └── x │         └── x │        └── x │
    b stages ──────────┴───────────────┴──────────────┘
```

```@example horner
function build_horner(coeffs::Vector{Float64}, x::Float64)
    n      = length(coeffs) - 1
    w      = Workflow(0; type = :DAW)
    w.name = "Horner's scheme"

    cx    = add_node!(w, DataNode(HConstF, spec_hconstf()))
    czero = add_node!(w, DataNode(HConstF, spec_hconstf()))
    setsettings!(w, cx,    Dict(:value => x))
    setsettings!(w, czero, Dict(:value => 0.0))

    ca = Int[]
    for c in coeffs
        id = add_node!(w, DataNode(HConstF, spec_hconstf()))
        setsettings!(w, id, Dict(:value => c))
        push!(ca, id)
    end

    bmul = Int[]; badd = Int[]; dmul = Int[]; dadd = Int[]
    bprev = ca[1]; dprev = czero

    for k in 2:length(coeffs)
        dm = add_node!(w, DataNode(HMul, spec_hmul()))    # d = d·x + b
        da = add_node!(w, DataNode(HAdd, spec_hadd()))
        add_connection!(w, dprev, :out, dm, :a)
        add_connection!(w, cx,    :out, dm, :b)
        add_connection!(w, dm,    :out, da, :a)
        add_connection!(w, bprev, :out, da, :b)
        push!(dmul, dm); push!(dadd, da); dprev = da

        bm = add_node!(w, DataNode(HMul, spec_hmul()))    # b = b·x + a[k]
        ba = add_node!(w, DataNode(HAdd, spec_hadd()))
        add_connection!(w, bprev, :out, bm, :a)
        add_connection!(w, cx,    :out, bm, :b)
        add_connection!(w, bm,    :out, ba, :a)
        add_connection!(w, ca[k], :out, ba, :b)
        push!(bmul, bm); push!(badd, ba); bprev = ba
    end

    res = add_node!(w, DataNode(HResult, spec_hresult()))
    add_connection!(w, bprev, :out, res, :value)
    add_connection!(w, dprev, :out, res, :derivative)

    (w = w, cx = cx, czero = czero, ca = ca, bmul = bmul, badd = badd,
     dmul = dmul, dadd = dadd, res = res, n = n)
end

function horner(coeffs::Vector{Float64}, x::Float64)
    g = build_horner(coeffs, x)
    scheduler!(g.w)
    (value = getdata(g.w, g.res, :value),
     derivative = getdata(g.w, g.res, :derivative), g = g)
end

# 2x³ − 3x² + x + 5 at x = 2
r = horner([2.0, -3.0, 1.0, 5.0], 2.0)
(value = r.value, derivative = r.derivative,
 nodes = length(r.g.w.nodes), connections = length(r.g.w.connections))
```

For degree `n` the graph has `5n + 4` nodes and `8n + 2` connections:

```@example horner
using Printf
for n in 0:6
    g = build_horner(Float64.(collect(1:(n + 1))), 2.0)
    @printf("degree %d: %2d nodes, %2d connections, %d stages per chain\n",
            n, length(g.w.nodes), length(g.w.connections), length(g.badd))
end
```

Every node runs exactly once, which is the `DAW` guarantee:

```@example horner
(all_once  = all(n -> n.state.exec_n == 1, values(r.g.w.nodes)),
 all_clean = all(n -> getstatus(n) === :clean, values(r.g.w.nodes)))
```

### Pull: only what the question needs

[`scheduler!`](@ref) computes the whole graph. [`execute!`](@ref) computes only
what the node you asked for depends on — so asking for the value does not touch
the derivative chain at all:

```@example horner
g = build_horner([2.0, -3.0, 1.0, 5.0], 2.0)
execute!(g.w, last(g.badd))

(value        = getdata(g.w, last(g.badd), :out),
 b_chain      = unique(getstatus(getnode(g.w, id)) for id in g.badd),
 d_chain      = unique(getstatus(getnode(g.w, id)) for id in g.dadd),
 d_executions = sum(getnode(g.w, id).state.exec_n for id in g.dmul),
 zero_source  = getnode(g.w, g.czero).state.exec_n)
```

Ask for the result afterwards and only the missing part is computed — the value
chain is already cached:

```@example horner
before = [getnode(g.w, id).state.exec_n for id in g.badd]
execute!(g.w, g.res)
(derivative = getdata(g.w, g.res, :derivative),
 b_chain_reran = [getnode(g.w, id).state.exec_n for id in g.badd] != before,
 d_chain_ran   = all(id -> getnode(g.w, id).state.exec_n == 1, g.dadd))
```

### Invalidation knows which coefficient you changed

This is what computing in pieces is *for*. The constant term enters only the
last `b` stage, so changing it dirties three nodes out of nineteen:

```@example horner
r = horner([2.0, -3.0, 1.0, 5.0], 2.0)
setsettings!(r.g.w, last(r.g.ca), Dict(:value => 99.0))

dirty = [id for (id, n) in r.g.w.nodes if getstatus(n) === :dirty]
(dirty_count = length(dirty), total = length(r.g.w.nodes),
 which = Set(dirty) == Set([last(r.g.ca), last(r.g.badd), r.g.res]))
```

```@example horner
execute!(r.g.w, r.g.res)
# the derivative does not depend on the constant term and was not recomputed
(value = getdata(r.g.w, r.g.res, :value),
 derivative = getdata(r.g.w, r.g.res, :derivative),
 derivative_chain_runs = unique(getnode(r.g.w, id).state.exec_n for id in r.g.dadd))
```

Changing `x`, by contrast, dirties everything except the sources:

```@example horner
r2 = horner([2.0, -3.0, 1.0, 5.0], 2.0)
setsettings!(r2.g.w, r2.g.cx, Dict(:value => 3.0))
clean = [id for (id, n) in r2.g.w.nodes if getstatus(n) === :clean]
(clean_count = length(clean),
 only_sources = Set(clean) == Set([r2.g.czero; r2.g.ca]))
```

### One node per operation means no fused multiply-add

The graph reproduces the textbook scheme bit for bit. It does **not** always
reproduce Julia's `evalpoly`, and the reason is worth knowing: `evalpoly`
computes each stage with `muladd`, one instruction with a single rounding. In
the graph the multiplication and the addition are *different nodes*, so there
is nothing to fuse.

```@example horner
coeffs = [1.0, -6.0, 15.0, -20.0, 15.0, -6.0, 1.0]   # (x-1)^6

separate(c, x) = (b = c[1]; for k in 2:length(c); b = b * x + c[k]; end; b)
fused(c, x)    = (b = c[1]; for k in 2:length(c); b = muladd(b, x, c[k]); end; b)

g = horner(copy(coeffs), 0.1)
(graph = g.value, separate = separate(coeffs, 0.1),
 fused = fused(coeffs, 0.1), evalpoly = evalpoly(0.1, reverse(coeffs)))
```

The divergence is rare — one case in forty-two over a spread of polynomials and
points — but it is not noise: it is the cost of decomposing an algorithm into
elementary nodes. Anything a compiler would have fused, a graph cannot.

### Things to watch

* **The degenerate first stage is a real node.** The derivative chain starts
  from `d = 0`, so its first multiplication computes `0 · x`. Unrolling a loop
  into structure means even a trivial iteration costs a node — and that node
  depends on nothing but `x`, so it stays `:clean` when any coefficient
  changes.

* **`DAW` resets before every run.** Two calls to [`scheduler!`](@ref) leave
  every `exec_n` at `1`, not `2`. To take advantage of the cache, call
  [`execute!`](@ref) on the node you want instead.

* **Cancellation is not the engine's problem.** Near a root of high
  multiplicity both Horner and naive summation lose everything; the graph
  faithfully reproduces whichever scheme you wired.
