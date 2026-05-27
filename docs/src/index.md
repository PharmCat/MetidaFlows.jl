```@meta
CurrentModule = MetidaFlows
```

# MetidaFlows

A lightweight experimental workflow engine for Julia

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

## Core idea

A workflow in MetidaFlows consists of:

* **Nodes** — units of computation
* **Ports** — typed inputs and outputs
* **Connections** — edges between ports
* **Schedulers** — execution strategies

Instead of hidden execution magic, everything is explicit:

* execution is driven by a scheduler
* data is passed through typed ports
* invalidation is propagated through the graph

---

## Key features (current)

* Typed node system via Julia multiple dispatch
* Directed graph workflow model
* Strict connection validation (including type checking)
* Two execution modes:

  * **DAW** (deterministic DAG execution)
  * **ABW** (queue-based / agent-style execution, experimental)
* Incremental execution and invalidation propagation
* Node state tracking (`:idle`, `:dirty`, `:clean`, etc.)
* Input buffering system
* Hooks for validation and execution lifecycle
* Basic serialization utilities

---

## Minimal example

```julia
using MetidaFlows
using CSV, DataFrames

struct CSVNode <: AbstractNodeType end
struct DataFrameNode <: AbstractNodeType end

csv_spec = NodeSpec(
    "Load CSV",
    PortSpec[],
    [PortSpec("CSV File", CSV.File, :csv)],
    [:file]
)

df_spec = NodeSpec(
    "DataFrame",
    [PortSpec("CSV File", CSV.File, :csv)],
    [PortSpec("DataFrame", DataFrame, :dataframe)]
)

function MetidaFlows.execute_unsafe!(node::DataNode{CSVNode})
    csv = CSV.File(node.settings[:file])
    setdata!(node, :csv, csv)
    return [:csv]
end

function MetidaFlows.execute_unsafe!(node::DataNode{DataFrameNode})
    csv = getinputdata(node, :csv)
    setdata!(node, :dataframe, DataFrame(csv))
    return [:dataframe]
end

workflow = Workflow(0)

id1 = add_node!(workflow, DataNode(CSVNode, csv_spec))
id2 = add_node!(workflow, DataNode(DataFrameNode, df_spec))

add_connection!(workflow, id1, :csv, id2, :csv)

setsettings!(workflow, id1, Dict(:file => "data.csv"))

scheduler!(workflow)

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


Documentation for [MetidaFlows](https://github.com/PharmCat/MetidaFlows.jl).

```@index
```

```@autodocs
Modules = [MetidaFlows]
```
