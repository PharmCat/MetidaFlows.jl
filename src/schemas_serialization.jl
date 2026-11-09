# STRUCT TO DICT FOR JSON
# --------------------------------------------------------
"""
    settings_schema(node::AbstractDataNode) -> Dict

Description of the node settings for a user interface.

The engine fills in `"settingslist"` — a copy of `spec.settings`, that is the
keys the node understands — and then calls [`settings_schema_usermod!`](@ref),
where a node type adds types, defaults, labels and allowed values.

# Example
```julia
settings_schema(DataNode(FilterRows, filter_spec))
# Dict{String, Any}("settingslist" => [:column, :threshold])
```

See also [`node_schema`](@ref) for the node as a whole.
"""
function settings_schema(node::AbstractDataNode)
    d  = Dict{String, Any}()
    d["settingslist"] = copy(node.spec.settings)
    settings_schema_usermod!(d, node::AbstractDataNode)
    return d
end
"""
    settings_schema_usermod!(d, node::AbstractDataNode)

Describe the settings of a node type, so an interface can render a form for
them. Specialize it per node type; the default does nothing.

`d` arrives already holding `"settingslist"`. Add to it — by convention under
the key `"schema"`, one entry per setting.

**Mutate `d`: the return value is discarded.** A method that builds a fresh
dictionary and returns it has no effect.

The engine never reads the contents of `"schema"` and passes it through
untouched, so the keys below are a convention shared with the interface rather
than a format the package enforces: `"type"`, `"default"`, `"description"`,
`"required"`, `"options"`, `"min"`, `"max"`, `"pinned"` (show on the node body),
`"source"` (`"upstream"`, `"user"`, `"none"`).

# Example
```julia
function MetidaFlows.settings_schema_usermod!(d, node::DataNode{FilterRows})
    d["schema"] = Dict{String, Any}(
        "column" => Dict{String, Any}(
            "type"        => "Symbol",
            "description" => "Column to compare",
            "required"    => true,
            "options"     => Symbol[]),
        "threshold" => Dict{String, Any}(
            "type"        => "Float64",
            "default"     => 0.0,
            "description" => "Keep rows whose value is greater than this",
            "required"    => true,
            "min"         => 0.0))
    return d
end
```

The method receives the node, so the description may depend on its current
settings. For choices that only a producer knows — the columns of a file the
parent node will read — combine the schema with [`getinputmeta`](@ref) on the
caller's side.

# Notes
- Keep the executable check in [`validate_settings`](@ref): a schema says what
  an interface should offer, not whether the node may run.
- Prefer JSON-safe values. A function encodes as a meaningless string, and a
  `Type` is safer written as `"Float64"` than as `Float64`.
"""
function settings_schema_usermod!(d, node::AbstractDataNode)
    return d
end
"""
    node_schema(node::AbstractDataNode) -> Dict

Description of a whole node for a user interface: its ports and its settings
form.

The engine fills in `"spec"` ([`spec_to_dict`](@ref)) and `"settings_schema"`
([`settings_schema`](@ref)), and then calls [`node_schema_usermod!`](@ref),
where a node type adds presentation data.

# Example
```julia
sort(collect(keys(node_schema(DataNode(FilterRows, filter_spec)))))
# ["settings_schema", "spec"]
```
"""
function node_schema(node::AbstractDataNode)
    d  = Dict{String, Any}()
    d["settings_schema"] = settings_schema(node)
    d["spec"]            = spec_to_dict(node.spec)
    node_schema_usermod!(d, node::AbstractDataNode)
    return d
end
"""
    node_schema_usermod!(d, node::AbstractDataNode)

Describe the node itself — where it belongs in a node palette and how it is
presented. Specialize it per node type; the default does nothing.

`d` arrives already holding `"spec"` and `"settings_schema"`.

**Mutate `d`: the return value is discarded.**

Use this for presentation and grouping, and
[`settings_schema_usermod!`](@ref) for the settings form.

# Example
```julia
function MetidaFlows.node_schema_usermod!(d, node::DataNode{FilterRows})
    d["section"]     = "Tables"           # node palette section
    d["groupname"]   = "Filtering"        # group within that section
    d["color"]       = "#8b5cf6"
    d["icon"]        = "filter"
    d["description"] = "Keeps rows whose value exceeds a threshold."

    # the method sees the node, so the caption may depend on its settings
    col = get(node.settings, :column, nothing)
    d["caption"] = col === nothing ? "not configured" : "filter on \$(col)"
    return d
end
```
"""
function node_schema_usermod!(d, node::AbstractDataNode)
    return d
end
"""
    node_to_dict(node::AbstractDataNode; specs::Bool = true, settings::Bool = true) -> Dict
 
Convert node to JSON-serializable dictionary.
 
Keys: `"id"`, `"properties"`, `"status"`, plus `"spec"` when `specs` is set
and `"settings"` when `settings` is set.
 
# Notes
The `"settings"` entry holds the settings *schema* produced by
[`settings_schema`](@ref), not the current setting values.
"""
function node_to_dict(node::AbstractDataNode; specs::Bool = true, settings::Bool = true)
    d                 = Dict{String, Any}()
    d["id"]           = getid(node)
    d["type"]         = nodetypestr(node)
    d["properties"]   = node_properties_to_dict(node.properties)
    if specs
        d["spec"]     = spec_to_dict(node.spec)
    end
    d["status"]       = getstatus(node)
    if settings
        d["settings"] = settings_schema(node)
    end
    return d
end
"""
    node_properties_to_dict(np::NodeProperties) -> Dict

Convert node properties to JSON-serializable dictionary.
"""
function node_properties_to_dict(np::NodeProperties)
    d            = Dict{String, Any}()
    d["id"]       = np.id
    d["status"]   = np.status
    d["position"] = np.position
    return d
end
"""
    spec_to_dict(spec::NodeSpec) -> Dict

Convert NodeSpec to dictionary representation.
"""
function spec_to_dict(spec::NodeSpec)
    d                 = Dict{String, Any}()
    d["name"]         = spec.name
    d["input_ports"]  = [portspec_to_dict(i) for i in spec.input_ports]
    d["output_ports"] = [portspec_to_dict(i) for i in spec.output_ports]
    d["settings"]     = copy(spec.settings)
    return d
end
"""
    portspec_to_dict(ps::PortSpec)
 
Convert port specification to JSON-serializable dictionary.
 
Keys: `"name"`, `"label"`, `"datatype"`, `"required"`, `"kind"`, `"type"`.
 
`"label"`, `"datatype"` and `"kind"` are stringified; `"type"` holds the port
arity as `"SinglePort"` or `"MultiPort"`.
"""
function portspec_to_dict(ps::PortSpec)
    d             = Dict{String, Any}()
    d["name"]     = ps.name
    d["label"]    = string(ps.label)
    d["datatype"] = string(ps.datatype)
    d["required"] = ps.required
    d["kind"]     = string(ps.kind)
    d["type"]     = portspec_to_dict_type(ps)
    return d
end
function portspec_to_dict_type(ps::PortSpec{MultiPort})
    return "MultiPort"
end
function portspec_to_dict_type(ps::PortSpec{SinglePort})
    return "SinglePort"
end
"""
    connection_to_dict(conn::NodeConnection) -> Dict

Convert connection to dictionary representation.
"""
function connection_to_dict(nc::NodeConnection)
    d               = Dict{String, Union{Int, Symbol}}()
    d["output_id"]   = nc.output_id
    d["output_port"] = nc.output_port
    d["input_id"]    = nc.input_id
    d["input_port"]  = nc.input_port
    return d
end
"""
    workflow_to_dict(w::Workflow) -> Dict
 
Convert workflow to dictionary representation, ready to be serialized to JSON.
 
Keys: `"id"`, `"name"`, `"n_iter"`, `"c_iter"`, `"nodes"`, `"connections"`,
`"incoming"`, `"outgoing"`.
 
# Notes
- `"nodes"` and `"connections"` are keyed by *stringified* identifiers, while
  `"incoming"` and `"outgoing"` keep integer node ids.
- Execution state - `run_id`, logs, cached output data, `exec_n`, the contents
  of input buffers and settings *values* - is not included, so the result
  describes structure only. `"settings"` inside a node holds the settings
  SCHEMA ([`settings_schema`](@ref)), not the values.
- A workflow restored from this dictionary cannot run until its settings are
  set again, and a cyclic one cannot be resumed: the state of the last turn
  lives in the buffer of a `:feedback` port. See [`dict_to_workflow`](@ref).
"""
function workflow_to_dict(w::Workflow)
    d                = Dict{String, Any}()
    d["id"]          = w.id
    d["type"]        = workflowtypestr(w)
    d["name"]        = w.name
    d["n_iter"]      = w.n_iter
    n                = Dict{String, Dict}()
    for (k,v) in w.nodes
        n[string(k)] = node_to_dict(v)
    end
    d["nodes"]       = n
    d["c_iter"]      = w.c_iter
    c               = Dict{String, Dict}()
    for (k,v) in w.connections
        c[string(k)] = connection_to_dict(v)
    end
    d["connections"] = c
    i               = Dict{Int, Vector}()
    for (k,v) in w.incoming
        i[k] = copy(v)
    end
    d["incoming"]    = i
    o               = Dict{Int, Vector}()
    for (k, v) in w.outgoing
        o[k] = copy(v)
    end
    d["outgoing"]    = o
    return d
end

"""
    dict_to_workflow(d::Dict{String}; check_connection::Bool = true,
                     check_connection_throw_error::Bool = true) -> Workflow

Rebuild a workflow from a dictionary produced by [`workflow_to_dict`](@ref).

Node types come from [`NODE_REGISTER`](@ref): a snapshot names a type with
[`nodetypestr`](@ref), and a name that is not registered raises, naming it.
Nothing in the dictionary is evaluated or resolved as a Julia name - the
specification comes from the register, not from the file - so loading an
untrusted snapshot cannot execute anything. Loading never runs a node either.

Node keys must match the `"id"` inside their `"properties"`, ids must be
unique, and `n_iter` is raised to cover every id in use, so the next
[`add_node!`](@ref) cannot overwrite a restored node.

# What is restored, and what is not
Restored: the workflow type and name, the nodes with their types,
specifications and positions, the connections, and the `incoming`/`outgoing`
indices (rebuilt by [`refreshind!`](@ref) rather than read from the file).

**Not** restored: setting *values*, the contents of input buffers, cached
output data, `exec_n`, and the log. Every node comes back `:dirty`.

A loaded workflow therefore **cannot run as it stands**: nodes that read
`node.settings` fail. And a cyclic workflow cannot be resumed, because the
state of the last turn lives in the buffer of a `:feedback` port, which is not
part of a snapshot. See *Serialization* in the guide.

# Connections
With `check_connection` every connection goes through
[`check_connection_validity`](@ref), which rejects a port that is not in the
specification, a reference to a node that is not in the snapshot, and
mismatched port datatypes. With `check_connection_throw_error = false` such a
connection is dropped instead of raising, and the workflow loads without it.

!!! warning "The single-port check does not fire here"
    [`check_connection_validity`](@ref) looks for an occupied port in
    `model.incoming`, and that index is only filled by [`refreshind!`](@ref)
    after the loop over connections. A snapshot holding two connections into
    the same `SinglePort` is therefore loaded, although
    [`add_connection!`](@ref) would reject it.
"""
function dict_to_workflow(d::Dict{String}; check_connection::Bool = true, check_connection_throw_error::Bool = true)
    haskey(d, "id") || error("No `id` field")
    haskey(d, "type") || error("No `type` field")
    if d["type"] ∉ ("DAW", "ABW") error("Unknown type") end

    w = Workflow(d["id"]; type = Symbol(d["type"]))
    w.name     = d["name"]

    for (k, n) in d["nodes"]
        node = dict_to_node(n)
        id   = node.properties.id
        parse(Int, k) == id || error("Node key $(k) does not match the id $(id) inside it")
        haskey(w.nodes, id) && error("Duplicate node id: $(id)")
        w.nodes[id] = node
    end
    w.n_iter = max(d["n_iter"], isempty(w.nodes) ? 0 : maximum(keys(w.nodes)))

    w.c_iter = d["c_iter"]
    for (k, c) in d["connections"]
        id     =  parse(Int, k)
        con    = dict_to_connection(c)
        if check_connection 
            ccv = check_connection_validity(w, con; throw_error = check_connection_throw_error)
            ccv || continue
        end
        w.connections[id] = con
        push!(get!(w.incoming, con.input_id, Int[]), id)
        push!(get!(w.outgoing, con.output_id, Int[]), id)
    end
    # w.audit_log # technical debt
    refreshind!(w)
    return w
end

"""
    dict_to_node(d::Dict{String}; usermode = false) -> DataNode

Rebuild one node from its dictionary.

The node type and the specification come from [`NODE_REGISTER`](@ref) by the
`"type"` key of the dictionary. The node is created `:dirty` whatever status
the snapshot holds: cached output data is not part of a snapshot, so a node
must not claim to be up to date without it. Setting values are not restored
either - the node starts with empty settings.

`usermode` is accepted for a future path where the specification is rebuilt by
[`dict_to_spec`](@ref) instead of being taken from the register, which a node
with settings-dependent ports needs. It is not wired up yet.
"""
function dict_to_node(d::Dict{String}; usermode = false)
    id                = d["id"] 
    properties        = dict_to_properties(d["properties"])
    properties.status = :dirty
    typestr           = d["type"]
    type, spec        = getregnodeinfo(typestr)
    return DataNode(type, properties, spec; settings = Dict{Symbol, Any}(), data = Dict{Symbol, Any}(), state = NodeState(), input_buffer = Dict{Symbol, Dict{Int, Any}}())
end

"""
    dict_to_connection(d::Dict{String}) -> NodeConnection

Rebuild one connection. Port labels are accepted both as `Symbol` - what
[`connection_to_dict`](@ref) writes - and as the strings a JSON reader returns.
"""
function dict_to_connection(d::Dict{String})
    sym(x) = x isa Symbol ? x : Symbol(x)
    return NodeConnection(Int(d["output_id"]), sym(d["output_port"]),
                          Int(d["input_id"]),  sym(d["input_port"]))
end

"""
    dict_to_properties(d::Dict{String}) -> NodeProperties

Rebuild node properties. Accepts both what [`node_properties_to_dict`](@ref)
writes (a `Symbol` status, a `Tuple` position) and what survives a JSON round
trip (a string status, a two-element array).
"""
function dict_to_properties(d::Dict{String})
    status = d["status"] isa Symbol ? d["status"] : Symbol(d["status"])
    p      = d["position"]
    return NodeProperties(Int(d["id"]), status, (Int(p[1]), Int(p[2])))
end

"""
    dict_to_spec(d::Dict{String}) -> NodeSpec

Rebuild a node specification from a dictionary. Not defined by default: a
specification normally comes from [`NODE_REGISTER`](@ref). Define it for a node
type whose ports depend on its settings.
"""
dict_to_spec(d) = error("Define `dict_to_spec(d::Dict{String})::NodeSpec` function to use user serialization mode.")


