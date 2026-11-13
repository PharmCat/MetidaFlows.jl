```@meta
CurrentModule = MetidaFlows
```

# Reading and writing a node

Getters and setters. Most take a node, which [`getnode`](@ref) gives you from
an identifier; the ones that are asked for often take a workflow and an
identifier as well.

## Exported

Available after `using MetidaFlows`. These are the public API in the narrow
sense: the names you cannot build or run a graph without.

```@docs
getnode
getstatus
getdata
getinputdata
getinputconnections
setdata!
setsettings!
```

## Public, not exported

Part of the public API, reached as `MetidaFlows.name` or brought in with
`import MetidaFlows: name`. They are documented, and a breaking change to one
of them moves the version exactly as a change to an exported name does. They
are simply not put in your namespace, either because you add methods to them,
because they are needed rarely, or because the name is too general to take
over.

```@docs
getconnection
getid
getposition
getstate
getexecn
getportnumber
getporttype
getportspec
buffersingle
bufferkeys
buffervalues
getportconnections
get_parents
get_children
setposition!
setinputbuffer!
```
