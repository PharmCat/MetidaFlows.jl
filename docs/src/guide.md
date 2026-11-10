```@meta
CurrentModule = MetidaFlows
```

```@setup mfexample
using MetidaFlows, CSV, DataFrames
CSV_PATH = joinpath(pwd(), "data.csv")
```

# User guide

This page describes the execution model in detail. It assumes you have read the quick start example on the home page.

---

## Anatomy of a node

A node has two halves: a *declaration* that never changes and a *state* that the engine mutates.

| Part | Type | Contents |
|---|---|---|
| `spec` | [`NodeSpec`](@ref) | ports and settings keys - the contract |
| `properties` | [`NodeProperties`](@ref) | id, status, editor position |
| `settings` | `Dict{Symbol,Any}` | configuration values |
| `data` | `Dict{Symbol,Any}` | cached outputs, keyed by output port label |
| `state` | [`NodeState`](@ref) | ready ports, run id, per-run log |
| `input_buffer` | nested `Dict` | `input_buffer[port][connection id] = value` |

The spec is the single source of truth. [`setdata!`](@ref) refuses labels that
are not output ports, [`getinputdata`](@ref) refuses labels that are not input
ports, and connection validation refuses ports that do not exist at all.

Ports are declared with [`PortSpec`](@ref):

```julia
PortSpec("Input table", DataFrame, :table)                       # required SinglePort
PortSpec("Extra", Int, :extra, SinglePort(); required = false)   # optional
PortSpec("Values", Int, :values, MultiPort())                    # many-to-one
```

The `datatype` is used for connection type checking, `label` is the symbol you
use everywhere in code, and `required` controls whether the engine refuses to
run a node whose buffer is still empty.

Introspection helpers: [`haveinputs`](@ref), [`getportnumber`](@ref),
[`getporttype`](@ref), [`getportspec`](@ref), [`isportexist`](@ref),
[`ismultiport`](@ref), [`nodetypestr`](@ref).

---

## Building a graph

```julia
w  = Workflow(1)                      # Workflow{DAW}
id = add_node!(w, DataNode(MyNode, spec))
cid = add_connection!(w, parent_id, :out, child_id, :in)
```

[`add_connection!`](@ref) validates through
[`check_connection_validity`](@ref) and raises unless:

* both nodes exist,
* both ports exist in their specs,
* the target input port is free, or declared as a [`MultiPort`](@ref),
* the output datatype is a subtype of the input datatype.

A rejected connection consumes nothing. Identifiers come from monotonically
increasing counters, so **ids of deleted nodes and connections are never
reused** - after `delete_node!(w, 2)` the next node is `3`.

Two ordering rules are worth remembering:

* [`add_node!`](@ref) resets a node not in `:idle` or `:clean` state. 
Configure with [`setsettings!`](@ref) *after* adding.
* if the parent is already `:clean` when the connection is created, its output
  is copied into the child buffer immediately - no recomputation needed.

Topology queries: [`getnode`](@ref), [`getconnection`](@ref),
[`isnodeexist`](@ref), [`find_connections`](@ref),
[`getportconnections`](@ref), [`get_parents`](@ref), [`get_children`](@ref).

---

## Writing node behaviour

Behaviour is attached to a singleton [`AbstractNodeType`](@ref) subtype through
[`execute_unsafe!`](@ref):

```julia
struct Doubler <: AbstractNodeType end

function MetidaFlows.execute_unsafe!(node::DataNode{Doubler})
    x = getinputdata(node, :in)
    setdata!(node, :out, 2x)
    return [:out]          # ports produced by this call
end
```

The returned vector is the contract with the engine: only connections leaving
these ports are refreshed by [`push_buffer!`](@ref), and the vector is stored
as the `ready_ports` state. A node may legitimately return a subset of its
output ports.

Four optional hooks specialise validation; all default to `true`:

| Hook | When | Status on failure |
|---|---|---|
| [`validate_node`](@ref) | before execution, from [`execution_node_validation`](@ref) | `:invalid_node` |
| [`validate_settings`](@ref) | before execution | `:invalid_settings` |
| [`validate_result`](@ref) | after execution, before propagation | `:invalid_result` |
| [`setsettings_unsafe!`](@ref) | on settings assignment | - (customisation point) |

Because [`validate_result`](@ref) runs *before* [`push_buffer!`](@ref), a node
that fails result validation never publishes anything downstream.

---

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
| Order | topological, via [`makegraph`](@ref) | readiness queue |
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

---

## Many-to-one inputs

A [`MultiPort`](@ref) input accepts any number of connections. Values are
keyed by connection id, so parents never overwrite each other:

```julia
spec = NodeSpec("Collect",
    [PortSpec("values", Int, :ins, MultiPort())],
    [PortSpec("sum", Int, :out)])

function MetidaFlows.execute_unsafe!(node::DataNode{Collect})
    buffer = getinputdata(node, :ins)          # Dict{connection id, value}
    setdata!(node, :out, sum(values(buffer); init = 0))
    return [:out]
end
```

For a [`SinglePort`](@ref), [`getinputdata`](@ref) returns the single value, or
`nothing` if the buffer is empty. A specific connection can always be read with
`getinputdata(node, label, connection_id)`.

The keys are connection ids and nothing else, so a node reading a `MultiPort`
cannot tell which parent a value came from — the order in which the
connections were made is knowledge the node does not have. That makes
`MultiPort` the right tool for a variable number of **equivalent** inputs, a
sum or a minimum over however many producers are attached, and the wrong one
when the inputs mean different things: three named ports can report *which* of
them won, one `MultiPort` of three cannot. [Edit
distance](examples_edit_distance.md) builds both and compares them.

!!! warning "The dictionary is the buffer itself"
    For a `MultiPort`, [`getinputdata`](@ref) hands back `node.input_buffer`'s
    own dictionary, not a copy. Read it, iterate it, sum it - but do not
    `delete!` from it or assign into it, or the node is editing the engine's
    buffer. The same rule as for values, below.

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

## Serialization and schemas

Two different jobs share this part of the API:

* **saving and loading a workflow** — turning the graph into plain
  dictionaries and back, so it can be written to JSON, inspected and read
  again;
* **describing a node** — telling a user interface which settings the node
  accepts, how to render them and how to present the node itself.

The first is fixed: the engine knows what a graph is made of. The second is
open-ended, because only the node author knows what its settings mean, so the
engine provides two hooks and gets out of the way.

### Serializing a workflow

[`workflow_to_dict`](@ref) produces a JSON-ready snapshot. What goes in it is
chosen by two keywords, because a snapshot is asked to do two different jobs.

```julia
d = workflow_to_dict(w)                      # structure and settings values
d = workflow_to_dict(w; state = true)        # ... and the state of a running loop
d = workflow_to_dict(w; values = false)      # structure only
```

The default — structure plus the current setting *values* — is a workflow
someone else can load and run. Add `state = true` and it is a checkpoint of a
run in progress.

```julia
keys(workflow_to_dict(w))
# "format_version", "id", "name", "n_iter", "c_iter", "nodes", "connections",
# "incoming", "outgoing"
```

Three details are easy to trip over:

* `"nodes"` and `"connections"` are keyed by *stringified* ids, while
  `"incoming"` and `"outgoing"` keep integer node ids;
* inside a node, `"settings"` holds the settings **schema** and
  `"settings_values"` holds the **values**. The names are close and the
  contents are not related;
* `run_id`, the audit log and cached output *data* are never included. Cached
  data is not needed: a loaded workflow is `:dirty` and recomputes;
* `"incoming"` and `"outgoing"` are written for a reader and **ignored on
  load** — [`dict_to_workflow`](@ref) rebuilds both from `"connections"` with
  [`refreshind!`](@ref). Editing them in a file changes nothing.

Building blocks, usable on their own: [`node_to_dict`](@ref),
[`node_properties_to_dict`](@ref), [`spec_to_dict`](@ref),
[`portspec_to_dict`](@ref), [`connection_to_dict`](@ref),
[`settings_to_dict`](@ref), [`node_state_to_dict`](@ref).

### Loading a workflow

[`dict_to_workflow`](@ref) reads a snapshot back.

```julia
w = dict_to_workflow(d)
```

**Loading never executes anything.** A node type is not stored in the file —
the file only *names* it, and the name is looked up in
[`NODE_REGISTER`](@ref). The register is the list of what may be built, so
every node type in the snapshot has to be registered first:

```julia
register_node!(w)       # once per node type, from your own code
```

That registers every node type of the graph, once each, and returns the keys it
added. Several nodes of one type are not a repeated registration. A key that
was taken *before* the call is one, and then the flags apply:
`overwrite = true` to replace a spec that has changed, `skipmode = true` to keep
what is registered.

An unregistered type is an error, not a warning. The same rule holds one level
down: a type named inside a *value* (the element type of an array, say) is
looked up in a fixed table and never resolved, so a snapshot cannot name a type
the package does not already know.

What the file does **not** get to decide:

* the node *type* and its *spec* both come from the register, not from the
  snapshot. The `"spec"` section of a node is written for a human reader and
  for a graph editor; changing it changes nothing on load;
* setting keys that are not declared in the spec are ignored;
* every loaded node is `:dirty`, whatever status the file carries.

The last point has a consequence worth stating: if the spec in your code has
changed since the snapshot was taken — a port renamed, a port removed — the
*connections* that mention the old port no longer validate. By default that is
an error naming the port. With `check_connection_throw_error = false` those
connections are dropped instead, and a graph that silently lost an edge is a
graph that computes something else, so prefer the default.

### Checkpointing a run

A long iterative run can be stopped, written out and continued:

```julia
d = workflow_to_dict(w; state = true)       # ... write d to a file
w = dict_to_workflow(d)                     # ... read it back later
scheduler!(w; reset_mode = :soft)           # continue, do not start over
```

`reset_mode = :soft` is the part that matters. The default `:full` clears
feedback buffers, which is exactly the state that was just restored; `:soft`
keeps them and marks every node `:dirty`, so the run picks up from the loop
state instead of from the seed nodes.

Only the buffers of `:feedback` ports are saved, and that is sufficient rather
than an approximation. A normal input buffer is filled by its parent within
the same turn, and `isready` does not let a node run until all of its normal
parents are `:clean` — so re-running refills it. A feedback buffer is the only
value that crosses a turn boundary, because its producer sits downstream and
has not run yet when the turn begins. On the gradient-descent example, 2 of
the 39 non-empty buffer entries are feedback ones, and a run resumed from those
2 reproduces the uninterrupted run bit for bit.

Two things to expect when you resume:

* **the last turn is replayed.** A loop usually ends at a gate that publishes
  its terminal ports and does not write to the feedback port, so the buffer
  holds the state of the turn before. Resuming recomputes that turn;
* **`exec_n` starts from zero.** `reset!` zeroes the counter on any run, so it
  is not saved. An algorithm that needs to know its own iteration number
  carries that number through a feedback port, and that is saved.

### Values a snapshot can carry

Settings and feedback buffers hold user values, and a snapshot has to survive
the trip through a text format, where only `nothing`, `Bool`, `Int64`,
`Float64`, `String`, arrays and dictionaries exist. Everything else is written
as a tagged dictionary by [`value_to_dict`](@ref) and read back by
[`dict_to_value`](@ref):

| Julia                              | in the snapshot                           |
|:-----------------------------------|:------------------------------------------|
| `nothing`, `Bool`, `Int64`, `Float64`, `String` | as they are                  |
| `Symbol`, `Char`                   | `{"t": "Symbol", "v": "…"}`               |
| other `Integer`, `AbstractFloat`   | `{"t": "Int32", "v": 7}`                  |
| `Tuple`                            | `{"t": "Tuple", "v": [...]}`              |
| `AbstractVector`                   | `{"t": "Vector", "e": "Int64", "v": [...]}` |
| `AbstractDict` (`Symbol`/`String` keys) | `{"t": "Dict", "k": "Symbol", "v": {...}}` |

A value of any other type is an error naming the node and the setting, not a
silently dropped field. Two hooks let a node type carry its own:

```julia
function MetidaFlows.settings_to_dict_usermod!(d, node::DataNode{LoadCSVNode})
    d["file"] = string(node.settings[:file])      # a path, not the open file
    d
end

function MetidaFlows.dict_to_settings_usermod!(s, node::DataNode{LoadCSVNode}, d)
    haskey(d, "file") && (s[:file] = String(d["file"]))
    s
end
```

A feedback buffer needs no such hook for the element type of an array: the
port declares its datatype in the spec, and the restored value is converted to
it. A `Vector{Int}` that a text format flattened into a plain array comes back
as a `Vector{Int}`.

### What a schema is

A schema is the dictionary a graph editor reads to draw one node: its ports,
its settings form, its place in the node palette.

The engine fills in only what it can know by itself. Take a filtering node that
declares two settings:

```@example mfexample
using MetidaFlows: settings_schema, node_schema, getnode

struct FilterRows <: AbstractNodeType end

filter_spec = NodeSpec("Filter rows",
    [PortSpec("Table", DataFrame, :table)],
    [PortSpec("Table", DataFrame, :table)],
    [:column, :threshold])

settings_schema(DataNode(FilterRows, filter_spec))
```

`"settingslist"` is a copy of `spec.settings` — the keys the node understands,
and nothing more. It is enough to know *that* there are two settings, but not
enough to render a form: no types, no defaults, no labels.

[`node_schema`](@ref) adds the port specification:

```@example mfexample
sort(collect(keys(node_schema(DataNode(FilterRows, filter_spec)))))
```

Everything beyond that comes from the two hooks.

### Describing settings: `settings_schema_usermod!`

Specialize it on your node type and fill in `d`:

```@example mfexample
function MetidaFlows.settings_schema_usermod!(d, node::DataNode{FilterRows})
    d["schema"] = Dict{String, Any}(
        "column" => Dict{String, Any}(
            "type"        => "Symbol",
            "description" => "Column to compare",
            "required"    => true,
            "options"     => Symbol[]),
        "threshold" => Dict{String, Any}(
            "type"        => "Float64",
            "default"     => 0.0,
            "description" => "Keep rows whose value is greater than this",
            "required"    => true,
            "min"         => 0.0))
    return d
end

settings_schema(DataNode(FilterRows, filter_spec))["schema"]["threshold"]
```

The contract is short:

* `d` arrives already holding `"settingslist"`; add to it, don't rebuild it;
* the hook receives the node, so the schema may depend on its current state;
* **mutate `d`** — the return value is discarded (see *Things to watch*).

### Conventional keys

The engine never reads the contents of `"schema"`: it passes the dictionary
through untouched. The keys are therefore a contract between the node author
and the interface, not a format the package enforces. These are the ones worth
keeping to, because the rest of the ecosystem expects them:

| Key | Meaning |
|---|---|
| `"type"` | datatype of the value, as a string (`"Int"`, `"Symbol"`, `"Vector{Float64}"`) |
| `"default"` | value to offer when the setting is unset |
| `"description"` | one line for a label or tooltip |
| `"required"` | whether the node cannot run without it |
| `"options"` | allowed values, for a dropdown |
| `"min"`, `"max"` | bounds for a numeric input |
| `"pinned"` | show on the node body, not only in the settings panel |
| `"source"` | where the value comes from: `"upstream"`, `"user"`, `"none"` |

Validation is a separate matter: a schema tells the interface what to *offer*,
while [`validate_settings`](@ref) decides whether the node may run. Keep the
real check there — a value can always arrive without passing through a form.

### Options that come from upstream

The useful case is a setting whose choices are only known from the producer: a
column name that exists in the file the parent node will read. The engine
supplies the fact — [`getinputmeta`](@ref) — and the caller composes the form.

The producer describes its output through [`getmeta_unsafe`](@ref), reading
only the header:

```@example mfexample
struct ReadTable <: AbstractNodeType end

read_spec = NodeSpec("Read table", PortSpec[],
    [PortSpec("Table", DataFrame, :table)], [:file])

function MetidaFlows.execute_unsafe!(node::DataNode{ReadTable})
    setdata!(node, :table, DataFrame(CSV.File(node.settings[:file])))
    return [:table]
end

MetidaFlows.ismetasource(node::DataNode{ReadTable}, ::Symbol) = haskey(node.settings, :file)

function MetidaFlows.getmeta_unsafe(node::DataNode{ReadTable}, ::Symbol, inmeta)
    path = get(node.settings, :file, nothing)
    (path === nothing || !isfile(path)) && return nothing
    return (columns = propertynames(CSV.File(path; limit = 0)),)
end

# a row filter does not change the schema, so it passes the input description through
MetidaFlows.getmeta_unsafe(::DataNode{FilterRows}, ::Symbol, inmeta) = inmeta[:table]
nothing # hide
```

Filling the options is then three lines on the caller's side:

```@example mfexample
function filter_form(w, id)
    d = settings_schema(getnode(w, id))
    m = getinputmeta(w, id)[:table]
    m === nothing || (d["schema"]["column"]["options"] = m.columns)
    return d
end
nothing # hide
```

```@example mfexample
wf  = Workflow(1)
src = add_node!(wf, DataNode(ReadTable,  read_spec))
flt = add_node!(wf, DataNode(FilterRows, filter_spec))
add_connection!(wf, src, :table, flt, :table)

filter_form(wf, flt)["schema"]["column"]["options"]   # the source is not configured yet
```

```@example mfexample
setsettings!(wf, src, Dict(:file => CSV_PATH))

filter_form(wf, flt)["schema"]["column"]["options"]   # names taken from the file header
```

Nothing has been executed: the file was opened for its header only. An empty
list of options is an honest signal that the producer is not configured yet.

### Describing the node: `node_schema_usermod!`

The same pattern, one level up — everything about the node itself rather than
its settings. `d` arrives holding `"settings_schema"` and `"spec"`:

```@example mfexample
function MetidaFlows.node_schema_usermod!(d, node::DataNode{FilterRows})
    d["section"]     = "Tables"           # node palette section
    d["groupname"]   = "Filtering"        # group within that section
    d["color"]       = "#8b5cf6"
    d["icon"]        = "filter"
    d["description"] = "Keeps rows whose value in the chosen column exceeds a threshold."

    # the hook sees the node, so the caption may depend on its settings
    col = get(node.settings, :column, nothing)
    d["caption"] = col === nothing ? "not configured" : "filter on $(col)"
    return d
end

sort(collect(keys(node_schema(getnode(wf, flt))))) 
```

```@example mfexample
node_schema(getnode(wf, flt))["caption"]
```

```@example mfexample
setsettings!(wf, flt, Dict(:column => :length, :threshold => 100.0))

node_schema(getnode(wf, flt))["caption"]
```

Use this hook for presentation and grouping; use
`settings_schema_usermod!` for the form itself.

### Things to watch

* **The hook's return value is ignored.** Both hooks are called for their
  effect on `d`, and `settings_schema` / `node_schema` return the `d` they
  passed in. A hook that builds a fresh dictionary and returns it silently
  does nothing:

  ```julia
  # wrong: the dictionary is built, but d is untouched, so the result is lost
  function MetidaFlows.settings_schema_usermod!(d, node::DataNode{MyNode})
      return Dict("schema" => ...)
  end
  ```

  Write into `d` and return it, as in the examples above.

* **Functions do not survive JSON.** A `"validator" => x -> x >= 0` entry
  encodes as the string `"#2"` — no error, just a useless value. Express
  constraints declaratively (`"min"`, `"max"`, `"options"`) and keep the
  executable check in [`validate_settings`](@ref). Types are safer written as
  strings: `"type" => "Float64"` rather than `"type" => Float64`.

* **`node_to_dict`'s `"settings"` key holds the settings *schema*, not the
  current values.** The values live under `"settings_values"` and go through
  the value codec; the schema is what a form is drawn from.

* Both hooks are called on every `settings_schema` / `node_schema` call, so
  keep them cheap. Inspecting a file is fine; computing anything is not.

---

## A larger example

Loading a CSV file, converting it and summarising it:

```@example mfexample
using MetidaFlows, CSV, DataFrames
using MetidaFlows: Workflow, NodeSpec, PortSpec, DataNode, AbstractNodeType,
                   add_node!, add_connection!, setsettings!, scheduler!,
                   getdata, setdata!, getinputdata

struct LoadCSV     <: AbstractNodeType end
struct ToDataFrame <: AbstractNodeType end
struct Summarise   <: AbstractNodeType end

csv_spec = NodeSpec("Load CSV", PortSpec[],
    [PortSpec("CSV File", CSV.File, :csv)], [:file])

df_spec = NodeSpec("DataFrame",
    [PortSpec("CSV File", CSV.File, :csv)],
    [PortSpec("DataFrame", DataFrame, :dataframe)])

sum_spec = NodeSpec("Summary",
    [PortSpec("DataFrame", DataFrame, :dataframe)],
    [PortSpec("Row count", Int, :nrows)])

function MetidaFlows.execute_unsafe!(node::DataNode{LoadCSV})
    setdata!(node, :csv, CSV.File(node.settings[:file]))
    return [:csv]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ToDataFrame})
    setdata!(node, :dataframe, DataFrame(getinputdata(node, :csv)))
    return [:dataframe]
end

function MetidaFlows.execute_unsafe!(node::DataNode{Summarise})
    setdata!(node, :nrows, size(getinputdata(node, :dataframe), 1))
    return [:nrows]
end

w   = Workflow(0)
id1 = add_node!(w, DataNode(LoadCSV, csv_spec))
id2 = add_node!(w, DataNode(ToDataFrame, df_spec))
id3 = add_node!(w, DataNode(Summarise, sum_spec))

add_connection!(w, id1, :csv, id2, :csv)
add_connection!(w, id2, :dataframe, id3, :dataframe)

setsettings!(w, id1, Dict(:file => CSV_PATH))

scheduler!(w, throw_error = true)
getdata(w, id3, :nrows) # 3
```

Changing the file path invalidates the whole chain; executing `id3` again
recomputes all three nodes. Changing nothing and executing again recomputes
nothing.

---

## Things to keep in mind

* Settings are **merged**, not replaced: `setsettings!` only overwrites the
  keys you pass.
* Manual `execute!` with `execute_upstream = false` will not refresh stale
  parents; the node is simply rejected with `:invalid_node` if a required
  input is missing.

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