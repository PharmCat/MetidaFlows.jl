```@setup mfmeta
DATA_PATH = joinpath(pwd(), "data.csv")
CONC_PATH = joinpath(pwd(), "conc.csv")
```

## Querying settings before execution

A node often has to be configured with something only its producer knows. The
node that averages a column needs a column name; the column names live in a CSV
file that has not been read yet.

Two functions answer that without executing anything:

* [`exportmeta`](@ref) — what a node **will produce** on one of its output ports;
* [`getinputmeta`](@ref) — what **will arrive** at every input port of a node.

Both walk up the graph, asking each node to describe itself. What is done with
the answer — a dropdown in a graph editor, a validation message, a printed
summary — is left to the caller: the engine reports facts about the graph and
does not define how settings are presented.

```
ReadCSV ──:table──▶ Join ──:table──▶ MeanColumn
ReadCSV ──:table──▶
```

Two sources are joined, and the node at the end has to be told which column to
average — a column that only exists after the join.

### Node types and interfaces

```@example mfmeta
using MetidaFlows, CSV, DataFrames, Statistics
import MetidaFlows: exportmeta_unsafe, ismetasource

struct ReadCSV    <: AbstractNodeType end
struct JoinOn     <: AbstractNodeType end
struct MeanColumn <: AbstractNodeType end

read_spec = NodeSpec("Read CSV",
    PortSpec[],
    [PortSpec("Table", DataFrame, :table)],
    [:file])

join_spec = NodeSpec("Join",
    [PortSpec("Left",  DataFrame, :left),
     PortSpec("Right", DataFrame, :right)],
    [PortSpec("Table", DataFrame, :table)],
    [:on])

mean_spec = NodeSpec("Mean of column",
    [PortSpec("Table", DataFrame, :input_data)],
    [PortSpec("Mean", Float64, :mean; kind = :terminal)],
    [:column])
nothing # hide
```

### Execution

```@example mfmeta
function MetidaFlows.execute_unsafe!(node::DataNode{ReadCSV})
    setdata!(node, :table, DataFrame(CSV.File(node.settings[:file])))
    return [:table]
end

function MetidaFlows.execute_unsafe!(node::DataNode{JoinOn})
    l = getinputdata(node, :left)
    r = getinputdata(node, :right)
    setdata!(node, :table, innerjoin(l, r; on = node.settings[:on]))
    return [:table]
end

function MetidaFlows.execute_unsafe!(node::DataNode{MeanColumn})
    df = getinputdata(node, :input_data)
    setdata!(node, :mean, mean(df[!, node.settings[:column]]))
    return [:mean]
end
nothing # hide
```

### Metadata

Each node describes only itself. The source reads a header instead of a whole
file, and declares itself a metadata source so the walk stops there:

```@example mfmeta
MetidaFlows.ismetasource(node::DataNode{ReadCSV}, ::Symbol) = haskey(node.settings, :file)

function MetidaFlows.exportmeta_unsafe(node::DataNode{ReadCSV}, ::Symbol, inmeta)
    path = get(node.settings, :file, nothing)
    (path === nothing || !isfile(path)) && return nothing
    return (columns = propertynames(CSV.File(path; limit = 0)),)
end
nothing # hide
```

`JoinOn` changes the schema, so it describes the result instead of passing an
input description through — the key column appears once, not twice:

```@example mfmeta
function MetidaFlows.exportmeta_unsafe(node::DataNode{JoinOn}, ::Symbol, inmeta)
    l, r = inmeta[:left], inmeta[:right]
    (l === nothing || r === nothing) && return nothing
    on = get(node.settings, :on, nothing)
    on === nothing && return (columns = intersect(l.columns, r.columns),)
    return (columns = vcat(l.columns, setdiff(r.columns, [on])),)
end
nothing # hide
```

Before `:on` is chosen the node reports the columns the two tables have in
common — exactly the candidates for a join key. Once it is chosen, it reports
the real result schema.

`MeanColumn` produces a scalar, so there is nothing to describe and the default
`nothing` is correct. A node that does not implement
[`exportmeta_unsafe`](@ref) breaks the chain the same way: the caller offers no
completion rather than a wrong one.

---

### Building the graph

```@example mfmeta
w     = Workflow(1)
left  = add_node!(w, DataNode(ReadCSV,    read_spec))
right = add_node!(w, DataNode(ReadCSV,    read_spec))
join  = add_node!(w, DataNode(JoinOn,     join_spec))
avg   = add_node!(w, DataNode(MeanColumn, mean_spec))

add_connection!(w, left,  :table, join, :left)
add_connection!(w, right, :table, join, :right)
add_connection!(w, join,  :table, avg,  :input_data)
nothing # hide
```

Nothing has been executed and no source has been configured yet, so nothing is
known — `nothing` propagates instead of an error:

```@example mfmeta
getinputmeta(w, join)
```

Both keys are present even though neither producer can answer: an unconnected
or silent single port maps to `nothing`, so a caller can always index by port
label.

### Querying settings, step by step

Configure the sources — still without executing anything:

```@example mfmeta
setsettings!(w, left,  Dict(:file => DATA_PATH))
setsettings!(w, right, Dict(:file => CONC_PATH))

exportmeta(w, left, :table)
```

A source has no input ports, so [`getinputmeta`](@ref) would return an empty
dictionary for it — [`exportmeta`](@ref) is the way to ask what a node emits.

Now the join can be offered a list of usable keys. Deriving it is the caller's
job, and it is a one-liner over the input descriptions:

```@example mfmeta
function join_key_options(w, id)
    m = getinputmeta(w, id)
    l, r = m[:left], m[:right]
    (l === nothing || r === nothing) && return Symbol[]
    return intersect(l.columns, r.columns)
end

join_key_options(w, join)
```

Pick one of the offered values and ask the join what it will produce:

```@example mfmeta
setsettings!(w, join, Dict(:on => :id))

exportmeta(w, join, :table)
```

The last node offers the columns of the joined table. Here the description
arrives at an input port, so [`getinputmeta`](@ref) is the right call:

```@example mfmeta
function column_options(w, id, port)
    m = getinputmeta(w, id)[port]
    m === nothing ? Symbol[] : m.columns
end

column_options(w, avg, :input_data)
```

```@example mfmeta
setsettings!(w, avg, Dict(:column => :Concentration))
nothing # hide
```

Only now is anything computed:

```@example mfmeta
scheduler!(w)
getdata(w, avg, :mean)
```

---

### Which function to call

|  | [`exportmeta`](@ref) | [`getinputmeta`](@ref) |
|---|---|---|
| Answers | what node `id` emits on `port` | what arrives at every input port of node `id` |
| Keyed by | one output port label | the node's own input port labels |
| Use for | sources, nodes with several outputs, previewing a configured result | filling a settings form from upstream |
| On a node without input ports | works | returns an empty dictionary |

`getinputmeta` is [`exportmeta`](@ref) applied to every incoming connection,
arranged by input port label — so a producer never learns which port of which
consumer it feeds, and two producers of the same type cannot be confused.

### Notes

* Metadata is computed on request and never stored, so it cannot go stale — if
  a file changes on disk, the next query sees it. Within a single call each
  node is described once, so a diamond does not describe a shared ancestor
  twice.
* [`ismetasource`](@ref) stops the upward walk at a node that can answer on its
  own; without it the walk continues to the top of the graph. `maxdepth`
  (1000 by default) bounds it in any case.
* Ports of kind `:feedback` are never followed, so metadata queries terminate
  on cyclic `ABW` workflows as well.
* The shape of a description — here a `NamedTuple` with a `columns` field — is
  a contract between nodes sharing a port datatype. The engine does not define
  it, and neither does it define how the result is turned into a settings form.
