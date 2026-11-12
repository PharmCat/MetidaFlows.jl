```@meta
CurrentModule = MetidaFlows
```

# Logs

Three separate records, each with its own purpose and its own switch: the
graph change log, the engine log and a node's own log.

## The graph change log

`Workflow.audit_log` records the **edits** made to a graph, in order. Recording
is off by default and turned on through [`SETTINGS`](@ref), which holds the
engine's logging settings for the whole process:

```@example audit
using MetidaFlows
import MetidaFlows: PortSpec

struct Src <: AbstractNodeType end
struct Add <: AbstractNodeType end
spec_src() = NodeSpec("Src", PortSpec[], [PortSpec("Out", Int, :out)], [:v])
spec_add() = NodeSpec("Add", [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
                             [PortSpec("Out", Int, :out)])

MetidaFlows.SETTINGS[:audit] = true

w = Workflow(0; type = :DAW)
a = add_node!(w, DataNode(Src, spec_src()))
b = add_node!(w, DataNode(Src, spec_src()))
s = add_node!(w, DataNode(Add, spec_add()))
setsettings!(w, a, Dict(:v => 2))
ca = add_connection!(w, a, :out, s, :a)
cb = add_connection!(w, b, :out, s, :b)
delete_node!(w, b)

foreach(println, w.audit_log)
```

Five events, one per mutator that takes a `Workflow`:
[`NodeAdded`](@ref), [`NodeDeleted`](@ref), [`ConnectionAdded`](@ref),
[`ConnectionDeleted`](@ref), [`SettingsChanged`](@ref). Cascades fall out of
the mutators rather than needing an event of their own: `delete_node!` removes
the node's connections through `delete_connection!`, so the log above shows the
`ConnectionDeleted` records and then the `NodeDeleted`.

That set is also the log's **boundary**: [`setid!`](@ref) and
[`setposition!`](@ref) are handed a node and no model, so dragging a node
around an editor is not an edit this log can see.

What it deliberately does not do:

* **It is not an undo stack.** `SettingsChanged` carries which keys changed,
  not their values before and after - otherwise every value a user ever typed
  would be copied into the log and from there into every snapshot.
* **It is not a trace of execution.** Running a graph is not an edit, and a run
  leaves `audit_log` untouched. Per-run messages live in `NodeState.log` and
  `Workflow.log`.
* **It is not timestamped.** The order of the vector is the sequence, and it
  comes out the same on every machine. For the same reason `SettingsChanged`
  sorts its keys: they arrive in a `Dict`, whose iteration order is not the
  order they were written.

### Why it is off by default

The log grows for the life of the workflow and travels into snapshots. Measured
on a square grid of nodes, roughly three records per node - a 17×17 grid gives
289 nodes, 512 connections and 834 records. Building that graph with recording
on costs about 4.5 % more memory, which is modest; the snapshot of it is
**27-29 % larger**, which is not. A script that assembles hundreds of nodes
has no use for either.

A snapshot carries the key `"audit_log"` only when the log is non-empty, so a
default snapshot is byte for byte what it was before 0.3.0 and the format
version does not move. Loading a snapshot that *does* carry the key restores
the log and turns recording back on, because such a file came from a workflow
that was keeping one.

The table is read on every write, so recording can start at any point - what
happened before that is simply not in the log:

```julia
MetidaFlows.SETTINGS[:audit] = true
```

Because the settings belong to the process and not to a workflow, two graphs
open at once cannot differ, and code that changes one has to put it back. The
package's own test suite does exactly that, through a `withsettings` helper
with a `try`/`finally`, or a test that needs recording would change what every
later test sees.

## The engine log

`Workflow.log` is the other log, and it holds [`LogMsg`](@ref) records the
engine writes: a node whose execution failed, a run stopped by
[`request_stop!`](@ref), a `release_optional` relaxation. It is **on** by
default - that is what the engine has always done - and switched by the same
table:

```julia
MetidaFlows.SETTINGS[:logging] = false
```

Nothing clears it between runs, so without a bound it would grow for as long as
the workflow lives - and there is one pattern where that bites: a graph
**re-run repeatedly while it fails**, which is what an editor does while its
settings are being fixed, writes a message per failing node per run.

So a log is bounded. `:log_limit` is how many messages it keeps, and at the
limit the oldest is dropped to make room:

```julia
MetidaFlows.SETTINGS[:log_limit] = 50    # держать последние 50
MetidaFlows.SETTINGS[:log_limit] = 0     # без предела
MetidaFlows.SETTINGS[:logging]   = false # не записывать вовсе
empty!(w.log)                            # и в любом случае можно чистить самому
```

The default is 1000. Measured on that failing graph, with the
default limit: at 1 000 runs the log holds 1 000 records, and at 20 000 runs it
still holds 1 000 - the workflow settles near 214 KB instead of climbing past
2.2 MB. The log's own retained size reaches 98 KB and does not move over a
million writes.

A log at its limit is therefore *possibly truncated*, and
`length(w.log) == SETTINGS[:log_limit]` is the only signal of that - the number of dropped messages is not
kept. Raise the limit, or set it to `0`, when the whole history matters.

!!! warning "The change log is not bounded, and that is deliberate"
    `audit_log` has no limit and never evicts. A log answers "what happened
    recently", and dropping its oldest entries costs little; an edit history
    answers "what did this graph go through", and one with holes in it answers
    that with a maybe. So the audit log is all or nothing: `:audit` off, or
    every record.

Turning the engine log off costs no diagnostics that the graph does not already
carry: a failed node is `:failed` and [`failed_nodes`](@ref) finds it either
way. The log adds the message, not the fact.

## A node's own log

`node.state[:log]` is the log a node writes **about itself, for whoever is
looking at that node** - "read 1 240 rows", "3 values dropped", "converged
after 11 iterations". Nothing in the engine writes there;
[`execute_unsafe!`](@ref) is handed only the node, which is exactly what this
needs:

```@example nodelog
using MetidaFlows
import MetidaFlows: PortSpec, log!, getstate, getnode

struct Count <: AbstractNodeType end
spec_count() = NodeSpec("Count", PortSpec[], [PortSpec("Out", Int, :out)], [:n])

function MetidaFlows.execute_unsafe!(n::DataNode{Count})
    k = Int(n.settings[:n])
    log!(n, :info, "counting to $(k)")
    s = sum(1:k)
    log!(n, :info, "sum is $(s)")
    setdata!(n, :out, s)
    return [:out]
end

w  = Workflow(0; type = :DAW)
id = add_node!(w, DataNode(Count, spec_count()))
setsettings!(w, id, Dict(:n => 4))
scheduler!(w)

[(m.level, m.message) for m in getstate(getnode(w, id), :log)]
```

Because the node's own code is the only thing that writes it, there is no
on/off switch here - not calling [`log!`](@ref) *is* the switch. It is bounded
by the same `:log_limit`, which is what makes logging from inside a cycle safe:
a node that writes a line on every turn of a 100 000-turn loop still holds the
last `:log_limit` records.

It is cleared with the rest of the node's state - `reset!(node)`,
`empty!(node.state)` - and **not** by `reset!(model)`, so a node's messages
survive a re-run of the workflow.

---
