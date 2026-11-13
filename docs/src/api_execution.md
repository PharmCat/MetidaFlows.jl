```@meta
CurrentModule = MetidaFlows
```

# Execution

Executing a single node, both schedulers, and what a failure or a stop does to
the rest of a run.

## Exported

Available after `using MetidaFlows`. These are the public API in the narrow
sense: the names you cannot build or run a graph without.

```@docs
execute!
failed_nodes
check_failed_nodes
scheduler!
```

## Public, not exported

Part of the public API, reached as `MetidaFlows.name` or brought in with
`import MetidaFlows: name`. They are documented, and a breaking change to one
of them moves the version exactly as a change to an exported name does. They
are simply not put in your namespace, either because you add methods to them,
because they are needed rarely, or because the name is too general to take
over.

```@docs
execute_unsafe!
```
