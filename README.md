# MetidaFlows.jl

A lightweight workflow engine for scientific and analytical pipelines in Julia.

`MetidaFlows` provides a node-based execution model for building reproducible data-processing workflows, analytical DAGs, and agent-based execution systems. It is designed around explicit typed ports, dependency propagation, incremental recomputation, and extensible node execution.

---

## About

`MetidaFlows` is a mini-framework focused on:

* typed node-based computation
* reproducible analytical pipelines
* incremental invalidation and recomputation
* lightweight and hackable architecture

---

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/PharmCat/MetidaFlows.jl")
```

---

# Core Concepts

## Workflow

A `Workflow` stores:

* nodes
* connections
* dependency graph indices

Two workflow execution modes are supported:

| Type  | Description                          |
| ----- | ------------------------------------ |
| `DAW` | Deterministic Data Analysis Workflow |
| `ABW` | Agent-Based Workflow                 |

---

# Roadmap

Planned features include:

* graph editor integration
* async execution
* distributed execution
* node persistence
* execution tracing
* execution profiling
* transactional invalidation
* workflow snapshots
* visualization utilities
* node metadata schemas
* execution events/hooks
