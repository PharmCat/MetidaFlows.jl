```@meta
CurrentModule = MetidaFlows
```

# Serialization and schemas

Snapshots of a workflow, the closed value codec, and the schemas a graph
editor reads.

## Public, not exported

Part of the public API, reached as `MetidaFlows.name` or brought in with
`import MetidaFlows: name`. They are documented, and a breaking change to one
of them moves the version exactly as a change to an exported name does. They
are simply not put in your namespace, either because you add methods to them,
because they are needed rarely, or because the name is too general to take
over.

```@docs
settings_schema
settings_schema_usermod!
node_schema
node_schema_usermod!
node_to_dict
node_properties_to_dict
spec_to_dict
portspec_to_dict
connection_to_dict
AUDIT_EVENT_NAMES
audit_event_to_dict
dict_to_audit_event
SNAPSHOT_FORMAT_VERSION
value_to_dict
dict_to_value
settings_to_dict
settings_to_dict_usermod!
dict_to_settings!
dict_to_settings_usermod!
node_state_to_dict
dict_to_node_state!
workflow_to_dict
dict_to_workflow
dict_to_node
dict_to_connection
dict_to_properties
dict_to_spec
```
