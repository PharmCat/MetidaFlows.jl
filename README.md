# MetidaFlows.jl

A lightweight workflow engine for scientific and analytical pipelines in Julia.

`MetidaFlows` provides a node-based execution model for building reproducible data-processing workflows, analytical DAGs, and agent-based execution systems. It is designed around explicit typed ports, dependency propagation, incremental recomputation, and extensible node execution.

Docs:

* [![Latest docs](https://img.shields.io/badge/docs-latest-blue.svg)](https://pharmcat.github.io/MetidaFlows.jl/dev/)
* [![Stable docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://pharmcat.github.io/MetidaFlows.jl/stable/)
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
