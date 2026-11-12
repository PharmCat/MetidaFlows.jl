```@meta
CurrentModule = MetidaFlows
```

# Internals

**Nothing on this page is part of the public API.** These are the engine's own
functions: they may change behaviour, change signature or disappear in any
release, including a patch release, and nothing announces it. They
are documented because the engine's own invariants are worth writing down - the
order in which the scheduler invalidates and publishes *is* the execution
model - not because anything outside the package should call them.

If you find yourself needing one of these, that is worth a report: it usually
means the public API is missing something.

## Graph, invalidation, readiness

```@docs
workflowtypestr
check_connection_validity
reset_status!
invalidate_unpublished!
invalidate_stale_optional!
invalidate_downstream!
mark_dirty_downstream!
invalidate_buffer!
execution_node_validation
push_buffer!
```

## Scheduling

```@docs
release_optional_blocked!
```

## Writing to a node

```@docs
setid!
setstatus!
setstate!
setreadyports!
setsettings_unsafe!
```
