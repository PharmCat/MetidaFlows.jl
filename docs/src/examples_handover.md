```@meta
CurrentModule = MetidaFlows
```

## Working a table in place

A concentration table is loaded, cleaned of below-limit rows, converted from
ng/mL to pg/mL, and summarised. Three of those four steps only need to change
the table they were given, and the table is the biggest thing in the graph -
copying it at every step is the obvious waste, and modifying it without
copying is the obvious bug.

```
Load ──:table──▶ Trim BLQ ──:table──▶ ng/mL→pg/mL ──:table──▶ Summary
      handover            handover                  ordinary
```

This page builds that pipeline twice: once the way that corrupts its own
inputs, and once with ownership declared and taken. Everything below is run
when the documentation is built, so the numbers are the real ones.

### The bug, first

Nothing is copied on a connection: the value a node publishes, the value in
its own cache and the value in its consumer's buffer are **one object**. A
node that scales a column in place therefore edits what its producer believes
it published.

```@example mfho
using MetidaFlows, DataFrames
import MetidaFlows: setreadyports!, getexecn

struct Load    <: AbstractNodeType end
struct Convert <: AbstractNodeType end
struct Summary <: AbstractNodeType end

#  Детерминированная таблица: никакого rand, чтобы числа в документации не
#  зависели от версии Julia. 24 точки на субъекта, моноэкспоненциальный спад.
function conctable(nsubj::Int)
    times   = 0.5:0.5:12.0
    subject = repeat(1:nsubj, inner = length(times))
    time    = repeat(collect(times), outer = nsubj)
    conc    = @. exp(-0.45 * time) * (1 + 0.1 * (subject % 7))
    DataFrame(subject = subject, time = time, conc = conc)
end

load_spec = NodeSpec("Load", PortSpec[],
    [PortSpec("Table", DataFrame, :table)], [:subjects])

conv_spec = NodeSpec("ng/mL to pg/mL",
    [PortSpec("Table", DataFrame, :table)],
    [PortSpec("Table", DataFrame, :table)], [:factor])

summ_spec = NodeSpec("Summary",
    [PortSpec("Table", DataFrame, :table)],
    [PortSpec("Rows", Int,     :rows; kind = :terminal),
     PortSpec("Cmax", Float64, :cmax; kind = :terminal)])

MetidaFlows.execute_unsafe!(n::DataNode{Load}) =
    (setdata!(n, :table, conctable(n.settings[:subjects])); setreadyports!(n, :table))

function MetidaFlows.execute_unsafe!(n::DataNode{Convert})
    t = getinputdata(n, :table)        # прочитал чужое...
    t.conc .*= n.settings[:factor]     # ...и правит на месте
    setdata!(n, :table, t)
    return setreadyports!(n, :table)
end

function MetidaFlows.execute_unsafe!(n::DataNode{Summary})
    t = getinputdata(n, :table)
    setdata!(n, :rows, nrow(t))
    setdata!(n, :cmax, maximum(t.conc))
    return setreadyports!(n, :rows, :cmax)
end
nothing # hide
```

Three nodes, and an analyst who re-enters the same conversion factor between
runs - which marks the converter `:dirty` and leaves the loader `:clean`:

```@example mfho
w  = Workflow(1)
ld = add_node!(w, DataNode(Load,    load_spec))
cv = add_node!(w, DataNode(Convert, conv_spec))
sm = add_node!(w, DataNode(Summary, summ_spec))
add_connection!(w, ld, :table, cv, :table)
add_connection!(w, cv, :table, sm, :table)
setsettings!(w, ld, Dict(:subjects => 50))
setsettings!(w, cv, Dict(:factor   => 1000))

scheduler!(w)
cmax = [getdata(w, sm, :cmax)]
for _ in 1:2
    setsettings!(w, cv, Dict(:factor => 1000))   # тот же множитель
    scheduler!(w; reset_mode = :none)
    push!(cmax, getdata(w, sm, :cmax))
end
cmax
```

Cmax grows by a factor of a thousand per run. The loader never reran - it is
`:clean`, so it republished a cache the converter had already multiplied, and
multiplied it again:

```@example mfho
getstatus(w, ld), getexecn(w, ld)
```

`reset_mode = :full`, the default, hides this by marking every node `:dirty`,
so the loader rebuilds the table each time. It bites exactly in the two paths
whose purpose is not to recompute everything: `reset_mode = :none`, and an
[`execute!`](@ref) that pulls a `:clean` parent.

### Declaring the chain

Two ports change. The loader's output is declared `handover = true`, and so is
the input that takes it; the body uses
[`take!`](@ref take!(::AbstractDataNode, ::Symbol)) instead of
[`getinputdata`](@ref). Nothing else about the node changes.

```@example mfho
struct LoadH <: AbstractNodeType end
struct TrimH <: AbstractNodeType end
struct ConvH <: AbstractNodeType end

load_h = NodeSpec("Load", PortSpec[],
    [PortSpec("Table", DataFrame, :table; handover = true)], [:subjects])

trim_h = NodeSpec("Trim BLQ",
    [PortSpec("Table", DataFrame, :table; handover = true)],
    [PortSpec("Table", DataFrame, :table; handover = true)], [:lloq])

#  Выход обычный: дальше стоит сводка, она только читает. Объявлять то,
#  из чего никто не забирает, значит задаром получить ограничение
#  «ровно один потребитель».
conv_h = NodeSpec("ng/mL to pg/mL",
    [PortSpec("Table", DataFrame, :table; handover = true)],
    [PortSpec("Table", DataFrame, :table)], [:factor])

MetidaFlows.execute_unsafe!(n::DataNode{LoadH}) =
    (setdata!(n, :table, conctable(n.settings[:subjects])); setreadyports!(n, :table))

function MetidaFlows.execute_unsafe!(n::DataNode{TrimH})
    t = take!(n, :table)                              # теперь таблица наша
    filter!(:conc => >(n.settings[:lloq]), t)
    setdata!(n, :table, t)
    return setreadyports!(n, :table)
end

function MetidaFlows.execute_unsafe!(n::DataNode{ConvH})
    t = take!(n, :table)
    t.conc .*= n.settings[:factor]
    setdata!(n, :table, t)
    return setreadyports!(n, :table)
end

function pipeline(; subjects = 2000)
    w  = Workflow(1)
    ld = add_node!(w, DataNode(LoadH, load_h))
    tr = add_node!(w, DataNode(TrimH, trim_h))
    cv = add_node!(w, DataNode(ConvH, conv_h))
    sm = add_node!(w, DataNode(Summary, summ_spec))
    add_connection!(w, ld, :table, tr, :table)
    add_connection!(w, tr, :table, cv, :table)
    add_connection!(w, cv, :table, sm, :table)
    setsettings!(w, ld, Dict(:subjects => subjects))
    setsettings!(w, tr, Dict(:lloq     => 0.01))
    setsettings!(w, cv, Dict(:factor   => 1000))
    (w = w, ld = ld, tr = tr, cv = cv, sm = sm)
end
nothing # hide
```

The same sequence of runs now answers the same thing every time:

```@example mfho
g = pipeline()
scheduler!(g.w)
answers = [(getdata(g.w, g.sm, :rows), getdata(g.w, g.sm, :cmax))]
for _ in 1:2
    setsettings!(g.w, g.cv, Dict(:factor => 1000))
    scheduler!(g.w; reset_mode = :none)
    push!(answers, (getdata(g.w, g.sm, :rows), getdata(g.w, g.sm, :cmax)))
end
answers
```

### Reading the statuses

```@example mfho
[getstatus(g.w, i) for i in (g.ld, g.tr, g.cv, g.sm)]
```

Three different things are being said here, and the order matters:

* the loader and the trimmer are **`:released`** - somebody took what they
  produced. They have no cache for that port any more, so the next run
  recomputes them instead of republishing a table they no longer hold:

  ```@example mfho
  getdata(g.w, g.ld, :table)
  ```

* the converter is **`:clean`**, although its input is declared `handover` and
  it did call `take!`. The status describes what happened to *its* output, and
  nobody took that: the summary reads it the ordinary way. A `handover` output
  whose value nobody takes keeps its cache like any other;

* the summary is `:clean` because it ran and published.

So the status is set by the **consumer's** execution, not the producer's.
Declaring the ports is permission; `take!` is the transfer.

### What it saves

The honest comparison is against the version that does not corrupt anything -
that is, one that copies defensively at each step:

```@example mfho
struct TrimC <: AbstractNodeType end
struct ConvC <: AbstractNodeType end

trim_c = NodeSpec("Trim BLQ", [PortSpec("Table", DataFrame, :table)],
                              [PortSpec("Table", DataFrame, :table)], [:lloq])

function MetidaFlows.execute_unsafe!(n::DataNode{TrimC})
    t = copy(getinputdata(n, :table))          # защитная копия
    filter!(:conc => >(n.settings[:lloq]), t)
    setdata!(n, :table, t); return setreadyports!(n, :table)
end
function MetidaFlows.execute_unsafe!(n::DataNode{ConvC})
    t = copy(getinputdata(n, :table))          # и ещё одна
    t.conc .*= n.settings[:factor]
    setdata!(n, :table, t); return setreadyports!(n, :table)
end

function pipeline_copy(; subjects = 2000)
    w  = Workflow(1)
    ld = add_node!(w, DataNode(Load,    load_spec))
    tr = add_node!(w, DataNode(TrimC,   trim_c))
    cv = add_node!(w, DataNode(ConvC,   conv_spec))
    sm = add_node!(w, DataNode(Summary, summ_spec))
    add_connection!(w, ld, :table, tr, :table)
    add_connection!(w, tr, :table, cv, :table)
    add_connection!(w, cv, :table, sm, :table)
    setsettings!(w, ld, Dict(:subjects => subjects))
    setsettings!(w, tr, Dict(:lloq     => 0.01))
    setsettings!(w, cv, Dict(:factor   => 1000))
    (w = w, sm = sm)
end

mb(x) = round(x / 1024^2; digits = 2)
a = pipeline();      scheduler!(a.w); GC.gc()
held = @allocated scheduler!(a.w)
b = pipeline_copy(); scheduler!(b.w); GC.gc()
copied = @allocated scheduler!(b.w)
(handover = mb(held), copies = mb(copied), saved = mb(copied - held))
```

Both runs build the table from scratch - that is most of what the first figure
is - and both produce the same answer. The difference is the two defensive
copies, and it grows with every further step that touches the table, while the
handover version stays flat.

### Rules this example follows

* **Declare `handover` on both ports of the connection, and only where the
  consumer really takes.** The engine refuses a taking input fed by an
  ordinary output; it allows the reverse, so a handover output may feed a node
  that just reads;
* **a handover output takes exactly one connection**, refused at creation -
  a second consumer would receive a value the first is entitled to overwrite;
* **the chain ends where reading begins.** `Summary` is an ordinary consumer,
  and the node before it publishes on an ordinary port;
* **`take!` once, then own it.** After the call the buffer slot is empty and
  the node holds the only reference; `filter!`, `sort!` and `.*=` on it are
  then legal, and that is the whole point.

See [Working on data in place](@ref) in the execution guide for the rules
themselves, and [`PortSpec`](@ref) for the keyword.
