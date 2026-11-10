## Documentation for [MetidaFlows](https://github.com/PharmCat/MetidaFlows.jl).

The reference is split by subject. Everything exported by the package is in
[Graph and nodes](api_core.md) and the two pages after it; the rest is public
but not exported.

* [Types](api_types.md) — the workflow, the node, ports, specifications,
  state, the container supertypes
* [Graph and nodes](api_core.md) — building a graph, invalidation, readiness,
  containers, the node register
* [Reading and writing a node](api_access.md) — getters and setters
* [Execution](api_execution.md) — `execute!`, both schedulers, stopping a run
* [Port metadata](api_meta.md) — `getmeta`, `getinputmeta` and their hooks
* [Serialization and schemas](api_serialization.md) — snapshots, the value
  codec, settings schemas

```@index
```
