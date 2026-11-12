```@meta
CurrentModule = MetidaFlows
```

# Types

The workflow, the node and everything a node is made of: ports,
specifications, properties, state, the container supertypes and the audit
events.

## Exported

Available after `using MetidaFlows`. These are the public API in the narrow
sense: the names you cannot build or run a graph without.

```@docs
AbstractNodeType
ExecuteSettings
MultiPort
PortSpec
NodeSpec
NodeConnection
DataNode
Workflow
```

## Public, not exported

Part of the public API, reached as `MetidaFlows.name` or brought in with
`import MetidaFlows: name`. They are documented, and a breaking change to one
of them moves the version exactly as a change to an exported name does. They
are simply not put in your namespace, either because you add methods to them,
because they are needed rarely, or because the name is too general to take
over.

```@docs
AbstractDataNode
AbstractAuditEvent
NodeAdded
NodeDeleted
ConnectionAdded
ConnectionDeleted
SettingsChanged
WorkFlowType
DAW
ABW
LogMsg
AbstractNodeFields
AbstractNodeSettings
AbstractNodeData
AbstractNodeState
AbstractNodeInputBuffer
SETTINGS
NodeState
AbstractPortType
SinglePort
PortBuffer
NodeProperties
NODE_REGISTER
GraphCache
```
