```@meta
CurrentModule = MetidaFlows
```

# Ports and cycles

Everything a port's declaration decides: how many connections it takes, what
its `kind` means to the schedulers, and the three rules a cyclic workflow has
to satisfy.

## Many-to-one inputs

A [`MultiPort`](@ref) input accepts any number of connections. Internally the
values are keyed by connection id, so parents never overwrite each other;
[`getinputdata`](@ref) hands them to the node as a `Vector`, **ordered by
ascending connection id** - that is, in the order the inputs were attached:

```julia
spec = NodeSpec("Collect",
    [PortSpec("values", Int, :ins, MultiPort())],
    [PortSpec("sum", Int, :out)])

function MetidaFlows.execute_unsafe!(node::DataNode{Collect})
    setdata!(node, :out, sum(getinputdata(node, :ins); init = 0))
    return [:out]
end
```

For a [`SinglePort`](@ref), [`getinputdata`](@ref) returns the single value, or
`nothing` if the buffer is empty. A specific connection can always be read with
`getinputdata(node, label, connection_id)`.

### Order is the node's handle on its producers

Connection ids come from a counter that only ever increases and never reuses a
number, so "ascending connection id" is exactly the order in which
`add_connection!` was called, and it stays that way for the life of the graph.
That order is what lets a node tell its inputs apart: position 1 is whatever
the graph author wired first.

```julia
function MetidaFlows.execute_unsafe!(node::DataNode{Pick})
    v = getinputdata(node, :ins)       # [diag, up, left] - the wiring order
    i = argmin(v)
    setdata!(node, :best,  v[i])
    setdata!(node, :which, (:diag, :up, :left)[i])
    return [:best, :which]
end
```

Two consequences worth knowing:

* Deleting a connection leaves a gap in the ids but does not reorder the
  survivors. Re-attaching a producer gives it a **new, larger** id, so it moves
  to the end of the vector.
* [`getinputmeta`](@ref) describes a `MultiPort` as a `Vector` in that same
  order, so a metadata rule lines up with the node body position for position.

When the node needs the connection itself rather than its position -- to look
up a meaning recorded at build time, say -- [`getinputconnections`](@ref)
returns the ids in the same order, and needs no [`Workflow`](@ref):

```julia
for (cid, v) in zip(getinputconnections(node, :ins), getinputdata(node, :ins))
    role = node.settings[:roles][cid]
end
```

Named ports remain the better tool when the inputs mean *fixed, different*
things: a spec of `:diag`, `:up`, `:left` says so in the interface, where a
`MultiPort` says only "any number of these". [Edit
distance](examples_edit_distance.md) builds both and compares them.

!!! note "The vector is yours"
    The vector is built fresh on every call, so a node may sort it, consume it
    or empty it without touching its own buffer. The values *inside* it are
    still shared - the rule below applies to them.

### A value you receive is not yours

A node's output is cached in the node and pushed into the buffers of its
consumers **by reference**. Nothing is copied, which is what makes passing a
large frame between nodes cheap - and what makes mutating a received value a
mistake that is not reported.

Measured on a three-node graph: a source publishing `[1, 2, 3]` into two
consumers, the first of which does `a = getinputdata(node, :in); a[1] += 100`
without copying:

```
источник отдал               [1, 2, 3]
mutating node returned       [101, 2, 3]
the producer's cache became  [101, 2, 3]
the second consumer's sum    106          (6 is correct)
```

Two separate things went wrong: the producer's cached output was overwritten,
so a later `getdata` on it reports a value it never produced, and the other
consumer computed on corrupted input. Neither raises.

So: **copy before you mutate**, or do not mutate.

```julia
a = copy(getinputdata(node, :in))      # now it is yours
a[1] += 100
setdata!(node, :out, a)
```

Mutating in place is safe only when the producer's port has exactly one
consumer and the producer's own cache is of no further interest - and the
engine has no way to tell you that is the case, so the rule is stated rather
than enforced. `get_children(model, id)` answers it from outside a node, if
you want to assert it in a test.

---

---

## Port kinds

Every [`PortSpec`](@ref) carries a `kind`, defaulting to `:normal`. The kind
does not change how data is stored or read — it changes how the schedulers
treat the connections attached to the port.

| `kind` | Applies to | Effect |
|---|---|---|
| `:normal` | input, output | the default: an ordinary data connection |
| `:feedback` | **input only** | closes a cycle; carries the value of the previous iteration |
| `:terminal` | output (by intent) | a slot for a result that is not meant to be connected |
| `:error` | input, output | reserved for error routing; must be `required = false` and its datatype must be a subtype of `Exception` |

Declaring `kind = :feedback` on an output port is rejected by the
[`NodeSpec`](@ref) constructor: a delay is a property of the consumer, not of
the producer.

Four places in the engine read the kind:

* [`isready`](@ref) waits only for producers connected through `:normal`
  ports — and, for a `required` one, also for that producer to have actually
  published to the port in question. Anything else is not waited for.
* [`execution_node_validation`](@ref) requires a filled input buffer only for
  `:normal` ports, so a feedback port may be empty on the first pass.
* cycle detection ([`makegraph`](@ref)) does not follow `:feedback` or
  `:error` edges, which is what lets a cyclic `ABW` graph exist at all — and
  also means an `:error` edge can close a cycle in a `DAW` graph without being
  rejected.
* [`getinputmeta`](@ref) and [`getmeta`](@ref) skip the same two kinds when
  walking upstream.

The `ABW` scheduler marks the whole downstream cone `:dirty` along `:normal`
edges and stops at `:feedback` ones. Buffering and serialization are identical
for all kinds.

### What a failure does to the rest of the run

When [`execute_unsafe!`](@ref) raises, [`execute!`](@ref) gives the node the
status `:failed`, appends an `:error` record to `workflow.log` and returns an
empty list of ready ports. **A failure stops exactly the dependent subtree.**
Nothing below the failed node executes — in either scheduler such a node is
skipped and ends the run `:dirty` — while branches that do not depend on it run
to completion as usual.

Skipping matters for more than tidiness. Input buffers are not cleared between
runs, they are overwritten as producers publish, so a consumer of a failed node
may still hold a value from an earlier run; the required-buffer check would
accept it and the node would report `:clean` with a result computed from stale
input. Both schedulers therefore consult [`isready`](@ref) before executing.

By default the run returns normally and the only trace is that log record, so
there are three ways to finish a run that had a failure:

```julia
scheduler!(w)                       # the failure is in w.log and in the statuses
scheduler!(w; throw_error = true)   # raise at the first failure, abandon the rest
scheduler!(w; strict = true)        # finish everything that can, then raise with the list
```

`throw_error` aborts the traversal where the failure happened, so whatever had
not run yet is lost — and *which* branches those are depends on the traversal
order, not on the dependency structure. `strict` has no such dependence: every
branch that can finish does, and the error then names every failed node at
once, with the workflow left in its post-run state for inspection.

To decide without raising, ask [`failed_nodes`](@ref) — it knows which statuses
count as a failure (`:failed` and the three `:invalid_*`) and which do not.
`:dirty` is not one of them: a node ends a run `:dirty` whenever it was not
recomputed, whether because an ancestor failed, because a gate took the other
branch, or because a cyclic workflow finished its last turn.

### Stopping a run early

A node can end the run itself, with [`request_stop!`](@ref), when it knows
there is nothing left worth computing — a search that found its answer, a
check that failed a precondition:

```julia
function MetidaFlows.execute_unsafe!(n::DataNode{Found})
    setdata!(n, :answer, getinputdata(n, :in))
    request_stop!(n)
    return [:answer]
end
```

What the node publishes is published as usual — the answer travels out through
a `:terminal` port in the same execution, and its children's buffers are
filled. What changes is that nothing more is executed: `ABW` stops serving the
queue, `DAW` leaves the traversal, and everything not reached ends the run
`:dirty`. A stop is **not** a failure, so [`failed_nodes`](@ref) stays empty
and `strict` does not raise; the scheduler appends an `:info` record to
`model.log` naming the node, and afterwards the node itself still answers
[`isstoprequested`](@ref), so `[id for (id, n) in w.nodes if
isstoprequested(n)]` says who stopped it.

**How much work this saves differs between the schedulers**, and the
difference is worth knowing before relying on it:

* in `ABW` the queue is served in the order producers finish, so a node that
  is reached early stops a great deal — on a stand of five independent
  branches, four of them ten nodes deep, stopping on the short branch leaves
  the overwhelming majority of the work undone;
* in `DAW` the order is topological and **not yours to choose**, so how much
  is saved is *unspecified*. An independent branch may sit entirely before the
  node that stops the run, in which case its work is already done. On the same
  five-branch stand one Julia version executed one of the forty-one work nodes
  before stopping and another executed all forty-one — the traversal order
  follows `makegraph`, which walks dictionaries. The only saving guaranteed by
  the graph is what lies **downstream** of the stopping node. For a search,
  use `ABW`.

The flag lives in the node's [`NodeState`](@ref) and [`reset!`](@ref) clears
it, so `:full` and `:soft` both start clean. `reset_mode = :none` does not call
`reset!` at all, so a stop requested by an earlier run is still set and the
next run ends on that node again — clear it with `empty!(node.state)` if that
is not what you want.

### Error routing with `:error` ports

All of the above is what happens to a failure the node did **not** anticipate.
An `:error` port is for one it did — and it is a **convention, not a
mechanism**: the engine never writes to such a port, and a raised exception is
not routed anywhere.

So a node that can fail catches its own failure and publishes it to its own
`:error` output port instead of the normal one:

```julia
function MetidaFlows.execute_unsafe!(node::DataNode{NStep})
    f, df = getinputdata(node, :f), getinputdata(node, :df)
    if abs(df) < getinputdata(node, :eps)
        setdata!(node, :err, NewtonStall(f, df))     # an :error output port
        return [:err]
    end
    setdata!(node, :out, f / df)
    return [:out]
end
```

Routing is then the ordinary selective publishing every gate uses: the
scheduler enqueues only the children of the ports the node returned. A handler
whose **only** input is an `:error` port therefore runs when, and only when,
the error fires — `isready` does not hold it back, but nothing enqueues it on a
normal turn either, so it stays `:dirty` and is never executed.

**An error path cannot rejoin the normal path.** Suppose the handler should
repair the step and let the turn continue. It would have to hand a value to the
gate through a normal input, and a normal input requires a `:clean` producer —
but on the failing turn the normal branch never ran, so its nodes are still
`:dirty` and the gate can never become ready. A feedback port on the loop head
is no way around it either: with `SinglePort` arity it is already taken by the
gate, and a `MultiPort` would accumulate values from both producers with
nothing to say which is fresher.

Error routing in MetidaFlows is therefore **stop with a diagnosis**, not
*recover and continue*. Recovery belongs to the caller: the handler publishes
what it knows — where it failed, at which iteration, and a point worth
restarting from — into `:terminal` ports, and whoever ran the graph decides.

Two things follow for a graph with an error path:

* **a finished run may leave nodes `:dirty` with stale data.** On a failing
  turn everything downstream of the failure keeps the values of the previous
  turn, so neither "all nodes are `:clean`" nor "the gate published a result"
  means the run succeeded. Read the handler's `:terminal` ports, or `exec_n`;
* **instrumentation inside the gate does not see the failing turn.** The gate
  does not run then, so a trace it collects stops one step short. The point of
  failure exists only in the exception the handler receives.

[Newton's method](examples_newton.md) is a worked example of all of this.

---

## Rule 1. Cycles are an `ABW` feature

[`makegraph`](@ref) builds the graph from **all** connections, whatever the
kind of the ports they attach to. [`scheduler!`](@ref) for a
[`DAW`](@ref) workflow rejects the result if it is cyclic:

```julia
scheduler!(w)   # ERROR: workflow is cyclic
```

This is deliberate. `DAW` guarantees that every node executes exactly once per
run in dependency order, and that guarantee has no meaning in a graph with a
cycle. A feedback edge does not change it: in a `DAW` workflow a
`:feedback` port is simply an input that is exempt from the required-buffer
check, and nothing more — there is no delay, no iteration, no second pass.

Use [`ABW`](@ref) for anything that has to iterate.

---

## Rule 2. A cyclic `ABW` workflow needs a seed node

The `ABW` scheduler starts from nodes that have **no input ports at all**:

```julia
for (id, node) in model.nodes
    if !haveinputs(node)
        push!(queue, id)
    end
end
```

A `:feedback` port is still an input port. A node whose only inputs are
feedback (or `:error`) ports is therefore *not* a starting point, and a loop
made only of such nodes never begins.

**Every cyclic workflow must contain at least one node with no input ports,
and the loop must be reachable from it through `:normal` connections.**

This is not merely a scheduling detail. A loop needs two things to be
well-defined: a delay, so that the cycle has a direction in time, and an
initial value, so that the first pass has something to compute with. The
`:feedback` port provides the first; the seed node provides the second. A
graph consisting only of a loop has neither a beginning nor initial data, and
there is nothing sensible for the scheduler to do with it.

In practice the seed node is the one that loads or generates the data — as
`LoadData` in the examples — and the loop body starts from its normal input on
the first pass:

```julia
previous = getinputdata(node, :previous)      # empty on the first pass
state = previous === nothing ?
    initial_state(getinputdata(node, :table)) :
    previous
```

### Diagnosing a loop that never started

A workflow that cannot be seeded is not an error: the queue is empty, the loop
body is never reached, and [`scheduler!`](@ref) returns `true` having executed
nothing.

Check the execution counters rather than the statuses:

```julia
scheduler!(w)

idle = [id for (id, node) in w.nodes if getstate(node, :exec_n) == 0]
```

If `idle` contains the whole loop, check that some node upstream of it has no
input ports. The same check catches a different mistake: a node that has
normal inputs but no incoming connection never becomes ready either, and never
runs.

`exec_n` is the right signal here and `getstatus` is not. In a cyclic
workflow a finished run legitimately leaves part of the graph `:dirty` - see
*Rule 3* - so "not `:clean`" does not mean "never ran".

---

## Rule 3. Inside a turn, a node waits for all of its normal ancestors

The `ABW` scheduler serves a FIFO queue, and [`isready`](@ref) lets a node run
once every producer on a `:normal` port is `:clean`. On its own that is not
enough for a loop: at the start of a turn the whole body is still `:clean`
**from the previous turn**, so a node could run on values that are one turn old.

What prevents it is step 4 of the scheduler. When a node publishes, the
scheduler marks `:dirty` not only its direct children but **everything
downstream of them**, following `:normal` edges
([`mark_dirty_downstream!`](@ref)). A node is therefore held back until every
one of its `:normal` ancestors has been recomputed during this turn.

This matters because without it the result would depend on the order in which
the connections were created. `model.outgoing` keeps connection ids in
insertion order, and that is the order the queue is served in, so a node with
a short edge from the loop head and a longer path to the same value could be
served before the long path caught up. Two workflows with identical nodes and
identical edges would then behave differently.

So you are free to wire a loop body the way the algorithm reads: each node
takes the inputs it needs, from whatever depth. There is no need to equalize
path lengths or to thread values through intermediate nodes.

A feedback edge is never followed by this invalidation: it means "next turn",
so marking through it would restart the body from the middle of a turn.

### Two consequences worth knowing

**A finished cyclic run leaves part of the graph `:dirty`.** On the last pass
the loop head marks the body dirty as usual, the gate then publishes only a
terminal port, and the body is never recomputed — correctly, because there was
nothing left to compute. So for a cyclic workflow "every node is `:clean`" is
not a completion signal; use `exec_n`, or the data on the terminal port.

**A full reset clears the loop state.** [`reset!`](@ref) with `soft = false`
— which is what `reset_mode = :full` uses — empties the buffers of `:feedback`
ports along with the cached output data. Without that a second
[`scheduler!`](@ref) call would find the last turn's state in the feedback
buffer and resume the previous run instead of starting a new one. `:soft` keeps
those buffers on purpose: that is how state is carried between runs.

`reset_mode = :none` is a third thing again, and not a no-op on a cycle:
[`execute!`](@ref) returns the stored `ready_ports` of a `:clean` node, the
scheduler propagates from them, and the children recompute on whatever the
buffers still hold. Use `:soft` to continue a loop and `:full` to start one.
