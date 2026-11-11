```@meta
CurrentModule = MetidaFlows
```

# API reference

The reference is split by subject, and within each page by **what you can rely
on**. Three levels, and the difference between them matters when you upgrade:

| level | where it is | the promise |
|:---|:---|:---|
| **exported** | `using MetidaFlows` puts it in scope | the public API in the narrow sense; it will not change or vanish without a major release |
| **public, not exported** | `MetidaFlows.name`, or `import MetidaFlows: name` | equally public - documented, and no silent changes - just not put in your namespace |
| **internal** | [Internals](api_internals.md) | may change or disappear in any release, patch releases included. Do not build on these |

So the rule is short: **if a name is on one of the subject pages below, it is
public. If it is on the Internals page, it is not.**

Twenty-seven names are exported. The list is deliberately small - you can build
a graph, run it and read the result with those alone:

```julia
using MetidaFlows                         # ровно этого хватает на весь граф

struct Double <: AbstractNodeType end
spec() = NodeSpec("Double", [PortSpec("In", Int, :in)], [PortSpec("Out", Int, :out)])

function MetidaFlows.execute_unsafe!(n::DataNode{Double})
    setdata!(n, :out, 2 * getinputdata(n, :in))
    return [:out]
end
```

That example also shows the one thing worth knowing about the second level.
[`execute_unsafe!`](@ref) is the most used name in the whole package - every
node implementation is a method of it - and it is deliberately **not**
exported, because you do not call it, you add a method to it. A method for
another module's function has to be written as `MetidaFlows.execute_unsafe!`
whatever the export list says; and if the name were in scope, writing
`function execute_unsafe!(...)` would quietly define an unrelated function in
your own module and the node would never run. Julia reports nothing in that
case. The same goes for every other hook: `validate_*`, `nodesettings`,
`getmeta_unsafe`, `initbuffer!` and the rest.

## Pages

* [Types](api_types.md) — the workflow, the node, ports, specifications,
  state, the container supertypes, the audit events
* [Graph and nodes](api_core.md) — building and editing a graph, the graph
  cache, invalidation, readiness, containers, the node register
* [Reading and writing a node](api_access.md) — getters and setters
* [Execution](api_execution.md) — `execute!`, both schedulers, stopping a run
* [Port metadata](api_meta.md) — `getmeta`, `getinputmeta` and their hooks
* [Serialization and schemas](api_serialization.md) — snapshots, the value
  codec, settings schemas
* [Internals](api_internals.md) — **not** public; here so the engine's own
  invariants are written down somewhere

## Index

```@index
```
