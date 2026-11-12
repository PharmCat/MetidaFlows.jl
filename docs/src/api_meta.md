```@meta
CurrentModule = MetidaFlows
```

# Port metadata

What a port will carry, worked out without executing anything: see the
[guide](guide.md) for the rules a node declares.

## Exported

Available after `using MetidaFlows`. These are the public API in the narrow
sense: the names you cannot build or run a graph without.

```@docs
getinputmeta
getmeta
```

## Public, not exported

Part of the public API, reached as `MetidaFlows.name` or brought in with
`import MetidaFlows: name`. They are documented, and a breaking change to one
of them moves the version exactly as a change to an exported name does. They
are simply not put in your namespace, either because you add methods to them,
because they are needed rarely, or because the name is too general to take
over.

```@docs
getmeta_unsafe
ismetasource
MetaRuleError
```
