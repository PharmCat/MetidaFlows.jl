```@meta
CurrentModule = MetidaFlows
```
```@setup mfexample
using MetidaFlows, CSV, DataFrames
CSV_PATH = joinpath(pwd(), "data.csv")
PKCSV_PATH = joinpath(pwd(), "conc.csv")
```

# MetidaFlows

A dataflow engine for Julia: a computation described as a graph of typed nodes
and recomputed incrementally.

---

**MetidaFlows.jl** is an early-stage project for building typed, graph-based execution workflows in Julia.
It is currently under active development and **not yet stable for production use**.

The goal of the project is to explore how a workflow system can be expressed
through Julia's type system and multiple dispatch. The execution model stays
explicit and minimal: what runs, when, and what is dropped between runs are all
things the caller can name.

---

## ⚠️ Project status

This package is **experimental**.

* APIs are subject to change without notice
* internal execution semantics are still evolving
* some subsystems are incomplete or in prototype state
* backward compatibility is not guaranteed

You should expect breaking changes while the architecture stabilizes.

---

## Installation

```julia
using Pkg
Pkg.add("MetidaFlows")
```

Or straight from the repository, for the development version:

```julia
using Pkg
Pkg.add(url = "https://github.com/PharmCat/MetidaFlows.jl")
```

---

## Core idea

A workflow in MetidaFlows consists of:

| Concept | Type | Role |
|---|---|---|
| Workflow | [`Workflow`](@ref) | owns nodes, connections and the dependency indices |
| Node | [`DataNode`](@ref) | a unit of computation plus its cached results |
| Behaviour | [`AbstractNodeType`](@ref) | tag the execution logic dispatches on |
| Interface | [`NodeSpec`](@ref), [`PortSpec`](@ref) | declared ports and settings keys |
| Edge | [`NodeConnection`](@ref) | typed link between an output and an input port |
| Scheduler | [`scheduler!`](@ref) | executes the whole graph, [`DAW`](@ref) or [`ABW`](@ref) |

Instead of hidden execution magic, everything is explicit:

* execution is driven by a scheduler
* data is passed through typed ports
* invalidation is propagated through the graph

---

## Current features

* typed node system built on multiple dispatch
* directed graph model with strict connection validation, including type checking
* two execution models: [`DAW`](@ref) (topological) and [`ABW`](@ref) (queue based, experimental)
* incremental execution: a node whose result still stands republishes instead
  of running, and what is dropped between runs is one keyword - see
  [`RESET_LEVELS`](@ref)
* invalidation propagated downstream on every settings or topology change
* node status tracking (`:idle`, `:dirty`, `:clean`, `:released`, `:executing`,
  `:failed`, `:invalid_*`)
* per-connection input buffering, including many-to-one [`MultiPort`](@ref) inputs
* ownership transfer on a declared port pair: a consumer may
  [`take!`](@ref take!(::AbstractDataNode, ::Symbol)) a value and work on it in
  place, with no defensive copying
* a node can be swapped for another under the same identifier, wiring intact -
  [`replace!`](@ref replace!(::Workflow, ::AbstractDataNode, ::Int)),
  [`replacespec!`](@ref), [`replaceport!`](@ref)
* validation hooks: [`validate_node`](@ref), [`validate_settings`](@ref), [`validate_result`](@ref)
* port metadata worked out without executing anything: [`getmeta`](@ref)
* dictionary serialization of workflows, nodes and schemas, with a versioned
  snapshot format that executes nothing on load, and a graph change log

---

## Minimal example

```@example mfexample
using MetidaFlows
using CSV, DataFrames

# CSV node type
struct CSVNode <: AbstractNodeType end
# DataFrame node type
struct DataFrameNode <: AbstractNodeType end

# Make node specification for CSV node
csv_spec = NodeSpec(
    "Load CSV",
    PortSpec[],
    [PortSpec("CSV File", CSV.File, :csv)],
    [:file]
)
# Make node specification for DataFrame node
df_spec = NodeSpec(
    "DataFrame",
    [PortSpec("CSV File", CSV.File, :csv)],
    [PortSpec("DataFrame", DataFrame, :dataframe)]
)
# What the CSV node does: load a CSV file
function MetidaFlows.execute_unsafe!(node::DataNode{CSVNode})
    csv = CSV.File(node.settings[:file])
    setdata!(node, :csv, csv)
    return [:csv]
end
# What the DataFrame node does: make a DataFrame from the CSV
function MetidaFlows.execute_unsafe!(node::DataNode{DataFrameNode})
    csv = getinputdata(node, :csv)
    setdata!(node, :dataframe, DataFrame(csv))
    return [:dataframe]
end
# Make Workflow
workflow = Workflow(0)

# Make and add CSV node
id1 = add_node!(workflow, DataNode(CSVNode, csv_spec))
# Make and add DataFrame node
id2 = add_node!(workflow, DataNode(DataFrameNode, df_spec))
# Add connection 
add_connection!(workflow, id1, :csv, id2, :csv)
# Set the setting of the CSV node (file path), assuming `CSV_PATH` exists
setsettings!(workflow, id1, Dict(:file => CSV_PATH))
# Run workflow
scheduler!(workflow, throw_error = true)
# Get result from DataFrame (from output port :dataframe)
df = getdata(workflow, id2, :dataframe)
# 
println("DataFrame: ", df)
```

---

## Design goals

This project is guided by a few principles:

* explicit execution model (no hidden state machines)
* composability via small typed primitives
* extensibility through multiple dispatch
* clear separation between:

  * structure (graph)
  * execution (scheduler)
  * behaviour (nodes)
* support for both deterministic and dynamic workflows

---

## Planned direction

The architecture is still evolving, and the package is pre-1.0: exported names
are still moving, and each minor release notes what broke. Where it goes next
is driven by the feedback below.

---

## Contributing & feedback

Feedback is especially welcome on:

* execution semantics
* scheduler design
* invalidation model
* API ergonomics
* real-world workflow use cases

The project is intentionally in an exploratory phase, so design discussions are highly valuable at this stage.
