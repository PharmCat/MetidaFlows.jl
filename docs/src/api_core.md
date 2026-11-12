```@meta
CurrentModule = MetidaFlows
```

# Graph and nodes

Building and editing a graph, the graph cache, invalidation, readiness, the
node containers and the node register.

## Exported

Available after `using MetidaFlows`. These are the public API in the narrow
sense: the names you cannot build or run a graph without.

```@docs
isportexist
add_connection!
delete_connection!
add_node!
delete_node!
isnodeexist
```

## Public, not exported

Part of the public API, reached as `MetidaFlows.name` or brought in with
`import MetidaFlows: name`. They are documented, and a breaking change to one
of them moves the version exactly as a change to an exported name does. They
are simply not put in your namespace, either because you add methods to them,
because they are needed rarely, or because the name is too general to take
over.

```@docs
empty!(::NodeState)
initbuffer!
nodebuffer
nodedata
nodesettings
nodestate
register_node!
unregister_node!
getregnodeinfo
isregistered
unregister_all!
log!
audit!
nodetypestr
haveinputs
isportinspec
ismultiport
find_connections
refreshind!
reset!
mark_dirty!
request_stop!
isstoprequested
isready
validate_node
validate_settings
validate_result
makegraph
is_cyclic(::Workflow)
topological_sort(::Workflow)
```
