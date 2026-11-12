```@meta
CurrentModule = MetidaFlows
```

# Execution model

How a node moves between statuses, what invalidation does and does not
recompute, and what each of the two schedulers guarantees. The
[user guide](guide.md) introduces the pieces; this page is the model they
follow.

## Statuses and the execution lifecycle

| Status | Meaning |
|---|---|
| `:idle` | freshly created, never executed, no settings applied |
| `:dirty` | needs (re)computation |
| `:executing` | currently running - also used to detect re-entry |
| `:clean` | up to date, outputs cached |
| `:failed` | [`execute_unsafe!`](@ref) raised |
| `:invalid_node` | structure or required inputs missing |
| `:invalid_settings` | [`validate_settings`](@ref) returned `false` |
| `:invalid_result` | [`validate_result`](@ref) returned `false` |

[`execute!`](@ref) walks these stages:

1. reset the per-run node log if the run changed;
2. detect re-entry (`check_cyclic`) and warn instead of recursing forever;
3. return immediately if the node is already `:clean`;
4. mark `:executing`;
5. execute parents recursively (`execute_upstream`);
6. validate structure, required inputs (`check_input_buffer`) and settings;
7. call [`execute_unsafe!`](@ref);
8. validate the result;
9. store `ready_ports` and push outputs into the child buffers;
10. invalidate children (`invalidate_downstream`);
11. mark `:clean`.

The four flags in parentheses come from [`ExecuteSettings`](@ref):

```julia
execute!(w, id)                                                   # all flags on
execute!(w, id; settings = ExecuteSettings(; execute_upstream = false))
execute!(w, id; settings = ExecuteSettings(false))                # all flags off
```

`execute!` returns the vector of ports produced, or an empty vector when the
node was rejected or failed - so an empty result is a signal to inspect
[`getstatus`](@ref).

---

## Invalidation and caching

Caching is what makes incremental recomputation work: a `:clean` node returns
its stored `ready_ports` without calling [`execute_unsafe!`](@ref) again.
Everything that could make a cached result wrong therefore has to mark nodes
`:dirty`.

[`invalidate_downstream!`](@ref) is the propagation primitive. Starting at a
node it marks it `:dirty`, drops its cached outputs, deletes the child buffer
entry belonging to each outgoing connection and recurses. Traversal stops at
nodes that are already `:dirty`, since their subtree was invalidated earlier.

It is triggered by [`setsettings!`](@ref), [`add_connection!`](@ref),
[`delete_connection!`](@ref) and by [`execute!`](@ref) itself.

Three reset levels are available:

| Function | Status | Cached outputs | Settings, buffers, logs |
|---|---|---|---|
| [`reset_status!`](@ref) | `:dirty` | kept | kept |
| [`mark_dirty!`](@ref), [`reset!`](@ref) on a workflow | `:dirty` | cleared | kept |
| [`reset!`](@ref) on a node | `:idle` | cleared | cleared |

Low-level buffer access - [`setinputbuffer!`](@ref),
[`invalidate_buffer!`](@ref), [`push_buffer!`](@ref) - is available when you
drive execution manually, but note that writing a buffer by hand bypasses
invalidation.

### A port that was not published to

A node need not publish every output port, and every gate in this package
relies on that. The question is what the consumer of a port that was *not*
published to sees — and the answer has to be "nothing", not "whatever was
there last turn". [`execute!`](@ref) therefore calls
[`invalidate_unpublished!`](@ref) right after [`push_buffer!`](@ref): the
consumer buffers of `:normal` connections leaving an unpublished port are
cleared.

`:feedback` connections are left alone, because their buffers *are* the state
of a loop — a gate that ends a run publishes only its `:terminal` ports, and
the loop head's feedback buffers have to survive that. `:error` connections
are left alone too: they latch a diagnosis until a handler reads it.

### Conditional evaluation

A graph has no short-circuit *inside* a turn: both operands of a condition are
nodes, and both are computed — [insertion
sort](examples_insertion_sort.md) shows what that costs. But a computation can
be made conditional, in two ways, and both rest on a producer publishing
nothing:

**Through `nothing`.** The consumer declares the guarded port
`required = false` and branches on its absence:

```julia
spec = NodeSpec("Maybe",
    [PortSpec("P", Int, :p; required = false), PortSpec("Q", Int, :q)],
    [PortSpec("Out", Int, :out)])

function MetidaFlows.execute_unsafe!(n::DataNode{Maybe})
    p = getinputdata(n, :p)
    setdata!(n, :out, isnothing(p) ? getinputdata(n, :q) : p)
    return [:out]
end
```

The node still runs; what it does changes. This is the cheap form, and the one
to use when the guarded work is a choice rather than an expense.

**Through a guard.** Route everything the guarded subgraph needs through one
node that either passes it on or publishes nothing:

```julia
MetidaFlows.execute_unsafe!(n::DataNode{Guard}) =
    getinputdata(n, :pass) ?
        (setdata!(n, :value, getinputdata(n, :value)); [:value]) : Symbol[]
```

Then the guarded node has no fed input at all: in `ABW` nothing enqueues it
and in `DAW` it is not ready, so in both it ends the run `:dirty`, never
executed. This is the form that actually *saves* the work — at the price of
relaying, and on two conditions: the guarded node must have no other producer
that keeps publishing, and **nothing may consume its output** unless the run
is told to release such a consumer. By default a consumer of a node that never
runs waits for a producer that stays `:dirty`, and waits forever — even
through an optional port, because waiting is about the producer's *status*, not
about the value. So the guard form suits a dead end: a `:terminal` port, a side
effect, a branch whose result is read out of band. To merge a guarded branch
back in, see
[`release_optional`](@ref Releasing-a-node-blocked-only-by-an-optional-port)
below.

When the result has to come back into the computation — into a loop state, or
a merge — the other way is to put the conditional *inside* the node that does
the expensive work:

```julia
function MetidaFlows.execute_unsafe!(n::DataNode{MulIf})
    getinputdata(n, :pass) || return Symbol[]      # the multiplication is skipped
    setdata!(n, :out, getinputdata(n, :a) * getinputdata(n, :b))
    return [:out]
end
```

The node runs — which costs a flag check — and the operation does not. Its
consumer reads `nothing` and knows the work was skipped.
[Modular exponentiation](examples_power.md) is built this way and measures what
it saves.

!!! note "Why the wait cannot simply be dropped"
    It is tempting to let [`isready`](@ref) not wait for the producer of an
    optional port at all. It is not sound in `ABW`: the queue order is not the
    author's to choose, so a consumer could run *before* the producer decides,
    read `nothing`, and be wrong on a turn where the value was coming.
    Measured on the exponentiation graph, `3^5 mod 7` comes out as `1` instead
    of `5`, with no multiplication performed at all. The wait is what makes
    "the producer published nothing" distinguishable from "the producer has not
    run yet". What *can* be dropped is the wait for a producer that has already
    had its chance to run, which is what `release_optional` does, below.

Those two cases are what `required` distinguishes, and both schedulers now
answer them the same way:

| the port | what happens |
|:---|:---|
| `required`, producer published nothing | not ready — the node does not run, stays `:dirty` |
| `required`, **no connection at all** | a structural error — `:invalid_node`, see [`execution_node_validation`](@ref) |
| `required = false`, no value for any reason | the node runs and reads `nothing` |

The middle row used to differ: `ABW` did not consult `required` at all, so it
ran the node and handed its body `nothing`.

### Releasing a node blocked only by an optional port

The last row of that table is about a port with no value. It says nothing about
*when* a run may conclude there is none — and by default a run concludes it
only when the producer ran and stayed silent. A producer that was never
executed at all leaves its consumer waiting, which is what confines the guard
form to dead ends.

`release_optional`, off by default on both schedulers, adds the missing
conclusion. A node held back **only** by `required = false` ports is run,
reading `nothing` there:

```julia
scheduler!(w; release_optional = true)
```

The flag is not "stop waiting". It is "stop waiting *where the producer has
already had its chance*", and each scheduler has exactly one place that
guarantees that:

| scheduler | the guarantee |
|:---|:---|
| `DAW` | topological order — when the traversal reaches the consumer, its producer has already run, failed, or been skipped |
| `ABW` | an empty queue — nothing will execute again by itself, so a producer that is not `:clean` now never will be |

So in `ABW` the ordinary turn still waits, and the release happens only when
the queue has run dry, after which the queue is served again; see
[`release_optional_blocked!`](@ref). A `required` port never releases a node.

Releasing is half of it. The other half is that the consumer's buffer may still
hold an earlier turn's value: [`invalidate_unpublished!`](@ref) covers a
producer that ran and published nothing, but nothing clears the buffer of a
producer that did not run — [`mark_dirty_downstream!`](@ref) deliberately
leaves input buffers alone, because in a cycle they are the loop state. So a
released node has its stale optional buffers dropped first, by
[`invalidate_stale_optional!`](@ref). Measured on a guarded accumulator loop:
without that step the sum comes out 26 instead of 18, because the previous
turn's value is added a second time.

What the flag buys is a conditional **branch** rather than a conditional
operation — a guarded subgraph whose result merges back in:

```julia
scheduler!(w)                              # the consumer waits forever: no result, no error
scheduler!(w; release_optional = true)     # the branch is skipped and the merge happens
```

On the [exponentiation graph](examples_power.md) the guard form then becomes
the cheaper of the two idioms: for `n = 1024` the multiplication node is
executed **once** instead of on all 12 turns, and the answer is the same. What
it costs is that "no value" now also covers "the producer failed", so a failure
upstream of an optional port becomes a `nothing` the consumer must handle
rather than a node that does not run. That is why it is opt-in.

---

## Schedulers

```julia
scheduler!(w)                    # DAW
scheduler!(w; maxiter = 5000)    # ABW
```

|  | [`DAW`](@ref) | [`ABW`](@ref) |
|---|---|---|
| Order | topological, via [`topological_sort`](@ref topological_sort(::Workflow)) | readiness queue |
| Cycles | rejected before execution | not detected up front |
| Per run | [`reset!`](@ref): statuses and cached outputs | statuses only |
| Required inputs | enforced | **not** enforced (`ExecuteSettings(false)`) |
| Nodes executed | every node, once | only nodes reachable from input-free nodes |

Both return `true` when the traversal finishes. That is *not* a success flag:
individual nodes may still end up `:failed` or `:invalid_*`, so check
[`getstatus`](@ref) when correctness matters.

In `ABW`, a node popped while a parent is still `:dirty` is dropped and
re-queued later by that parent; [`isready`](@ref) implements the check. A node
that has input ports but no incoming connection never becomes ready and stays
`:dirty`.

### The graph is built once per edit, not once per run

A `DAW` run needs three things from the structure - the graph, the answer to
"is it cyclic", and a topological order - and none of them change between runs
of an unedited workflow. Each is computed when asked for and cached in
`model.graph` (see [`GraphCache`](@ref)), keyed by `model.ver`: a counter of
**structural** edits. Repeated runs of an unedited workflow therefore do no
graph work at all. An `ABW` run needs none of the three, so it is unaffected
either way.

The three readers are [`makegraph`](@ref),
[`is_cyclic`](@ref is_cyclic(::Workflow)) and
[`topological_sort`](@ref topological_sort(::Workflow)), and each returns the
**shared** value the workflow holds, so treat all three results as read-only.
Copy the graph before modifying one: a vertex added to the cached graph leaves
the workflow describing a graph it does not have, and nothing reports it.

### Edit a graph through the four editing functions

[`add_node!`](@ref), [`delete_node!`](@ref), [`add_connection!`](@ref) and
[`delete_connection!`](@ref) raise `model.ver`, and that is the whole mechanism
that tells the cache it is out of date. Nothing else raises it - settings,
data, buffers, statuses and a run leave it alone, because none of them can
change the graph.

**Writing into `model.nodes` or `model.connections` directly is not
supported.** Those fields are reachable and nothing stops it, but `ver` stays
where it was and the cache goes on answering from the structure it saw last.
For a workflow assembled that way from new, that is the empty graph it was
born with, and every symptom is silent:

```julia
w = Workflow(0; type = :DAW)
for (id, node) in other.nodes; w.nodes[id] = node; end        # ТАК НЕ НАДО
for (id, con)  in other.connections; w.connections[id] = con; end

makegraph(w)      # граф без вершин
is_cyclic(w)      # false — даже если цикл есть
scheduler!(w)     # true, не исполнив ни одного узла
```

Build it with the editing functions instead:

```julia
w = Workflow(0; type = :DAW)
a = add_node!(w, DataNode(MyNode, spec))
b = add_node!(w, DataNode(MyNode, spec))
add_connection!(w, a, :out, b, :in)
```

Two cases where that is not quite enough, and what to do instead:

* **copying a workflow**, where the identifiers of the original have to
  survive. [`add_node!`](@ref) hands out its own from `n_iter` and cannot
  reproduce them, so go through the snapshot codec -
  [`workflow_to_dict`](@ref) then [`dict_to_workflow`](@ref). It keeps the
  identifiers, rebuilds the indices and leaves the version right.
* **a direct write you cannot avoid.** Raise the version yourself, in the same
  breath, and remember that [`refreshind!`](@ref) rebuilds the indices only:

```julia
w.connections[id] = con
refreshind!(w)              # индексы
w.ver += 1                  # кеш графа
```

---
