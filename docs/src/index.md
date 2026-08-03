```@meta
CurrentModule = MetidaFlows
```
```@setup mfexample
using MetidaFlows, CSV, DataFrames
const CSV_PATH = joinpath(pwd(), "src", "data.csv")
const PKCSV_PATH = joinpath(pwd(), "src", "conc.csv")
```

# MetidaFlows

A lightweight, node-based workflow engine for scientific and analytical pipelines in Julia.

---

**MetidaFlows.jl** is an early-stage project for building typed, graph-based execution workflows in Julia.
It is currently under active development and **not yet stable for production use**.

The goal of the project is to explore how workflow systems can be expressed naturally using Julia’s type system and multiple dispatch, while keeping the core execution model explicit and minimal.

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
Pkg.add(url = "https://github.com/PharmCat/MetidaFlows.jl")
```

```julia
using Pkg
Pkg.add("MetidaFlows")
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
* incremental execution: a `:clean` node is never recomputed
* invalidation propagated downstream on every settings or topology change
* node status tracking (`:idle`, `:dirty`, `:clean`, `:executing`, `:failed`, `:invalid_*`)
* per-connection input buffering, including many-to-one [`MultiPort`](@ref) inputs
* validation hooks: [`validate_node`](@ref), [`validate_settings`](@ref), [`validate_result`](@ref)
* dictionary serialization of workflows, nodes and schemas

---

## Minimal example

```@example mfexample
using MetidaFlows

import MetidaFlows: Workflow, NodeSpec, PortSpec, DataNode, AbstractNodeType,
                   add_node!, add_connection!, setsettings!, scheduler!,
                   getdata, setdata!, getinputdata

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
# What CSV node do: load CSV File
function MetidaFlows.execute_unsafe!(node::DataNode{CSVNode})
    csv = CSV.File(node.settings[:file])
    setdata!(node, :csv, csv)
    return [:csv]
end
# What DataFrame node do: make DataFrame from CSV
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
# Set settinf for CSV node (file path), asume file `CSV_PATH` exists
setsettings!(workflow, id1, Dict(:file => CSV_PATH))
# Run workflow
scheduler!(workflow)
# Get result from DataFrame (from output port :dataframe)
df = getdata(workflow, id2, :dataframe)
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
  * behavior (nodes)
* support for both deterministic and dynamic workflows

---

## Planned direction

The architecture is still evolving. Current exploration areas include:

* improved logging and audit system
* caching and checkpointing strategies

---

## Contributing & feedback

Feedback is especially welcome on:

* execution semantics
* scheduler design
* invalidation model
* API ergonomics
* real-world workflow use cases

The project is intentionally in an exploratory phase, so design discussions are highly valuable at this stage.
