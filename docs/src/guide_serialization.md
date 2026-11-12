```@meta
CurrentModule = MetidaFlows
```

```@setup mfexample
using MetidaFlows, CSV, DataFrames
CSV_PATH = joinpath(pwd(), "data.csv")
```

# Serialization and schemas

A workflow as plain data: what a snapshot carries, what it deliberately does
not, and the schemas a graph editor reads to render a node.

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
