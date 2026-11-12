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
function node_to_dict(node::AbstractDataNode; specs::Bool = true, settings::Bool = true,
                      values::Bool = true, state::Bool = false)
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
    if values
        d["settings_values"] = settings_to_dict(node)
    end
    if state
        d["state"] = node_state_to_dict(node)
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
    d               = Dict{String, Any}()
    d["output_id"]   = nc.output_id
    d["output_port"] = nc.output_port
    d["input_id"]    = nc.input_id
    d["input_port"]  = nc.input_port
    return d
end

# ==========================================================================
#  Audit codec
#
#  Журнал правок графа — набор СОБЫТИЙ ЗАКРЫТ. Имя события из файла
#  сверяется с этим перечнем и ни во что не разрешается: каждая ветка ниже
#  конструирует свой тип явно, по своим полям. Тот же принцип, что в
#  `VALUE_TYPES` и `NODE_REGISTER` — загрузка снимка не должна уметь
#  создать то, чего пакет не предусмотрел.
# ==========================================================================

"""
    AUDIT_EVENT_NAMES

The names [`audit_event_to_dict`](@ref) writes and
[`dict_to_audit_event`](@ref) accepts. A closed set: a name outside it is an
error, and nothing read from a file is resolved to a type.
"""
const AUDIT_EVENT_NAMES = ("NodeAdded", "NodeDeleted", "ConnectionAdded",
                           "ConnectionDeleted", "SettingsChanged")

"""
    audit_event_to_dict(e::AbstractAuditEvent) -> Dict{String, Any}

One record of the graph change log as a JSON-serializable dictionary, tagged by
`"event"` with one of [`AUDIT_EVENT_NAMES`](@ref).

Port labels and setting keys are written as plain strings rather than through
the value codec: a change log is read by people as often as by programs, and
`"a"` says as much as `{"t": "Symbol", "v": "a"}`.

See also [`dict_to_audit_event`](@ref).
"""
audit_event_to_dict(e::NodeAdded) =
    Dict{String, Any}("event" => "NodeAdded", "id" => e.id, "type" => e.type)
audit_event_to_dict(e::NodeDeleted) =
    Dict{String, Any}("event" => "NodeDeleted", "id" => e.id)
audit_event_to_dict(e::ConnectionAdded) =
    Dict{String, Any}("event" => "ConnectionAdded", "id" => e.id,
                      "output_id" => e.output_id, "output_port" => String(e.output_port),
                      "input_id"  => e.input_id,  "input_port"  => String(e.input_port))
audit_event_to_dict(e::ConnectionDeleted) =
    Dict{String, Any}("event" => "ConnectionDeleted", "id" => e.id)
audit_event_to_dict(e::SettingsChanged) =
    Dict{String, Any}("event" => "SettingsChanged", "id" => e.id,
                      "keys" => String[String(k) for k in e.keys])

"""
    dict_to_audit_event(d::Dict{String}) -> AbstractAuditEvent

Rebuild one change-log record from the dictionary
[`audit_event_to_dict`](@ref) produced.

`d["event"]` must be one of [`AUDIT_EVENT_NAMES`](@ref); each is constructed
explicitly from its own fields, so a file cannot name a type to build or a
field to fill. Port labels and setting keys are accepted as `String` or
`Symbol`, like the rest of the loader.
"""
function dict_to_audit_event(d::Dict{String})
    haskey(d, "event") || error("Audit record has no `event` key")
    name = d["event"]
    sym(x) = x isa Symbol ? x : Symbol(x)
    if     name == "NodeAdded"         return NodeAdded(Int(d["id"]), String(d["type"]))
    elseif name == "NodeDeleted"       return NodeDeleted(Int(d["id"]))
    elseif name == "ConnectionAdded"   return ConnectionAdded(Int(d["id"]),
                                              Int(d["output_id"]), sym(d["output_port"]),
                                              Int(d["input_id"]),  sym(d["input_port"]))
    elseif name == "ConnectionDeleted" return ConnectionDeleted(Int(d["id"]))
    elseif name == "SettingsChanged"   return SettingsChanged(Int(d["id"]),
                                              Symbol[sym(k) for k in d["keys"]])
    end
    error("Unknown audit event `$(name)`; the snapshot format knows only " *
          join(AUDIT_EVENT_NAMES, ", "))
end
# ==========================================================================
#  Value codec
#
#  Settings and feedback buffers hold user values, and a snapshot has to
#  survive a round trip through a text format (JSON, YAML, TOML), where only
#  `nothing`, `Bool`, `Int64`, `Float64`, `String`, arrays and dictionaries
#  exist. Anything else is written as a tagged dictionary.
#
#  A tag is looked up in `VALUE_TYPES` and never resolved from the file: a
#  snapshot can only name a type this table already holds. No `eval`, no
#  `getfield` — loading a workflow must not be able to run anything.
# ==========================================================================

"""
    SNAPSHOT_FORMAT_VERSION

The snapshot format this version of the package writes, and the newest it
reads.

[`workflow_to_dict`](@ref) stamps it into every snapshot under
`"format_version"`, and [`dict_to_workflow`](@ref) refuses a file whose stamp
is **higher** than this number: a format from the future may mean things this
code does not know. A lower stamp, and a file with no stamp at all, are read as
the formats they are.

So a snapshot travels forward between versions, never backward.
"""
const SNAPSHOT_FORMAT_VERSION = 1

const VALUE_TYPES = Dict{String, Type}(
    "Any"     => Any,     "Bool"    => Bool,
    "Int64"   => Int64,   "Int32"   => Int32,   "Int16"   => Int16,  "Int8"  => Int8,
    "UInt64"  => UInt64,  "UInt32"  => UInt32,  "UInt16"  => UInt16, "UInt8" => UInt8,
    "Float64" => Float64, "Float32" => Float32, "Float16" => Float16,
    "String"  => String,  "Symbol"  => Symbol,  "Char"    => Char)

"""
    value_to_dict(x)

Write a single value in a form a text format can carry.

`nothing`, `Bool`, `Int64`, `Float64` and `String` are returned as they are.
Everything else becomes a dictionary with a `"t"` type tag: `Symbol`, `Char`,
`Tuple`, `Vector` (with an `"e"` element type tag), `Dict` (with a `"k"` key
type tag) and the numeric types listed in `VALUE_TYPES`.

A value of any other type raises an error naming the type. Define
[`settings_to_dict_usermod!`](@ref) for the node type to serialize it
yourself.

See also [`dict_to_value`](@ref).
"""
value_to_dict(x::Nothing) = nothing
value_to_dict(x::Bool)    = x
value_to_dict(x::Int64)   = x
value_to_dict(x::Float64) = x
value_to_dict(x::String)  = x
value_to_dict(x::Symbol)  = Dict{String, Any}("t" => "Symbol", "v" => String(x))
value_to_dict(x::Char)    = Dict{String, Any}("t" => "Char",   "v" => string(x))
value_to_dict(x::Tuple)   = Dict{String, Any}("t" => "Tuple",
                                "v" => Any[value_to_dict(v) for v in x])
function value_to_dict(x::Union{Integer, AbstractFloat})
    t = string(typeof(x))
    haskey(VALUE_TYPES, t) || error("No `value_to_dict` method for type $(typeof(x))")
    Dict{String, Any}("t" => t, "v" => x isa Integer ? Int64(x) : Float64(x))
end
function value_to_dict(x::AbstractVector)
    e = string(eltype(x))
    haskey(VALUE_TYPES, e) || (e = "Any")
    Dict{String, Any}("t" => "Vector", "e" => e,
                      "v" => Any[value_to_dict(v) for v in x])
end
function value_to_dict(x::AbstractDict)
    v = Dict{String, Any}()
    for (k, e) in x
        k isa Union{Symbol, AbstractString} ||
            error("A dictionary can be serialized only with Symbol or String keys, got $(typeof(k))")
        v[String(k)] = value_to_dict(e)
    end
    Dict{String, Any}("t" => "Dict",
                      "k" => keytype(x) <: Symbol ? "Symbol" : "String", "v" => v)
end
value_to_dict(x) = error("No `value_to_dict` method for type $(typeof(x))")

"""
    dict_to_value(x)

Read back a value written by [`value_to_dict`](@ref).

A tagged dictionary is rebuilt through the `VALUE_TYPES` table, so an unknown
tag raises an error instead of being resolved: a type named in a file is never
turned into a type object.
"""
dict_to_value(x::Nothing)        = nothing
dict_to_value(x::Bool)           = x
dict_to_value(x::Integer)        = Int64(x)
dict_to_value(x::AbstractFloat)  = Float64(x)
dict_to_value(x::AbstractString) = String(x)
dict_to_value(x::Symbol)         = x
dict_to_value(x::AbstractVector) = Any[dict_to_value(v) for v in x]
function dict_to_value(d::AbstractDict)
    haskey(d, "t") || error("A tagged value needs a `t` field")
    t = d["t"] isa Symbol ? String(d["t"]) : d["t"]
    t == "Symbol" && return Symbol(d["v"])
    t == "Char"   && return first(String(d["v"]))
    t == "Tuple"  && return Tuple(dict_to_value(v) for v in d["v"])
    if t == "Vector"
        e = get(d, "e", "Any")
        T = get(VALUE_TYPES, e, nothing)
        isnothing(T) && error("Unknown element type tag $(repr(e))")
        return T[dict_to_value(v) for v in d["v"]]
    end
    if t == "Dict"
        K = get(d, "k", "String") == "Symbol" ? Symbol : String
        r = Dict{K, Any}()
        for (k, v) in d["v"]
            r[K(k)] = dict_to_value(v)
        end
        return r
    end
    T = get(VALUE_TYPES, t, nothing)
    isnothing(T) && error("Unknown value type tag $(repr(t))")
    return convert(T, d["v"])
end

"""
    settings_to_dict(node::AbstractDataNode)

Settings **values** of a node, keyed by setting name.

Only the keys declared in `node.spec.settings` are written; values go through
[`value_to_dict`](@ref). The function then calls
[`settings_to_dict_usermod!`](@ref), which a node type can specialize to write
a value the codec cannot.

This is not the settings *schema* — see [`settings_schema`](@ref) for that.

See also [`dict_to_settings!`](@ref).
"""
function settings_to_dict(node::AbstractDataNode)
    d = Dict{String, Any}()
    for k in node.spec.settings
        haskey(node.settings, k) || continue
        try
            d[String(k)] = value_to_dict(node.settings[k])
        catch e
            error("Node $(getid(node)) setting `:$(k)`: $(sprint(showerror, e))")
        end
    end
    settings_to_dict_usermod!(d, node)
    return d
end

"""
    settings_to_dict_usermod!(d, node::AbstractDataNode)

User hook of [`settings_to_dict`](@ref). The default method returns `d`
unchanged; specialize it on the node type to write a setting the value codec
cannot carry.

```julia
function MetidaFlows.settings_to_dict_usermod!(d, node::DataNode{FilterRows})
    d["frame"] = describe_my_frame(node.settings[:frame])
    d
end
```
"""
settings_to_dict_usermod!(d, node::AbstractDataNode) = d

"""
    dict_to_settings!(node::AbstractDataNode, d)

Put settings values from `d` into `node`.

Only the keys declared in `node.spec.settings` are read, so a file cannot
inject a setting the node does not know. Values go through
[`dict_to_value`](@ref), then [`dict_to_settings_usermod!`](@ref) is called,
and the result is written with `setsettings_unsafe!` — the node is `:dirty`
right after loading, so there is nothing to invalidate.

See also [`settings_to_dict`](@ref).
"""
function dict_to_settings!(node::AbstractDataNode, d)
    s = Dict{Symbol, Any}()
    for k in node.spec.settings
        ks = String(k)
        haskey(d, ks) || continue
        try
            s[k] = dict_to_value(d[ks])
        catch e
            error("Node $(getid(node)) setting `:$(k)`: $(sprint(showerror, e))")
        end
    end
    dict_to_settings_usermod!(s, node, d)
    setsettings_unsafe!(node, s)
    return node
end

"""
    dict_to_settings_usermod!(s, node::AbstractDataNode, d)

User hook of [`dict_to_settings!`](@ref): `s` is the settings dictionary being
built, `d` is the dictionary read from the file. The default method returns `s`
unchanged. Specialize it on the node type to read back what
[`settings_to_dict_usermod!`](@ref) wrote.
"""
dict_to_settings_usermod!(s, node::AbstractDataNode, d) = s

"""
    node_state_to_dict(node::AbstractDataNode)

Execution state of a node that a later run cannot recompute: the contents of
its `:feedback` input buffers, keyed by port label and then by connection id.

Normal input buffers are **not** written. A normal buffer is filled by its
parent within the same turn, and `isready` does not let a node run until every
normal parent is `:clean`, so re-running refills it. A feedback buffer is the
only value that crosses a turn boundary: its producer sits downstream and has
not run yet when the turn begins.

`exec_n` is not written either, because `reset!` zeroes it on any resumed run.
An algorithm that needs its own iteration counter carries it through a
feedback port, and that counter is saved here.

See also [`dict_to_node_state!`](@ref).
"""
function node_state_to_dict(node::AbstractDataNode)
    b = Dict{String, Any}()
    for ps in node.spec.input_ports
        ps.kind == :feedback || continue
        buf = node.input_buffer[ps.label]
        isempty(buf) && continue
        e = Dict{String, Any}()
        for (con, v) in buf
            try
                e[string(con)] = value_to_dict(v)
            catch err
                error("Node $(getid(node)) feedback port `:$(ps.label)`: " *
                      sprint(showerror, err))
            end
        end
        b[String(ps.label)] = e
    end
    return Dict{String, Any}("feedback_buffer" => b)
end

"""
    dict_to_node_state!(node::AbstractDataNode, d)

Put feedback buffer contents from `d` back into `node`.

Each value is converted to the datatype the port declares in the registered
spec, which both restores a concrete element type a text format had flattened
(`Vector{Int}` from a plain array) and checks the value against the port. A
port that is missing from the spec, or is not of kind `:feedback`, is an error.

See also [`node_state_to_dict`](@ref).
"""
function dict_to_node_state!(node::AbstractDataNode, d)
    for (port, buf) in get(d, "feedback_buffer", Dict{String, Any}())
        label = Symbol(port)
        isportexist(node, label, :input) ||
            error("Node $(getid(node)) has no input port `:$(label)`")
        getportspec(node, label, :input).kind == :feedback ||
            error("Input port `:$(label)` of node $(getid(node)) is not a feedback port")
        T = getporttype(node, label, :input)
        for (con, v) in buf
            value = dict_to_value(v)
            setinputbuffer!(node, label, parse(Int, con),
                            isnothing(value) ? nothing : convert(T, value))
        end
    end
    return node
end

"""
    workflow_to_dict(w::Workflow; values::Bool = true, state::Bool = false) -> Dict
 
Convert workflow to dictionary representation, ready to be serialized to JSON.
 
Keys: `"format_version"`, `"id"`, `"name"`, `"n_iter"`, `"c_iter"`, `"nodes"`,
`"connections"`, `"incoming"`, `"outgoing"`.
 
`values` writes the current settings values of every node, so the result is a
workflow that can be loaded and run. `state` adds the contents of `:feedback`
input buffers, which turns the result into a checkpoint of a run in progress -
see [`node_state_to_dict`](@ref) and resume with `reset_mode = :soft`.
 
# Notes
- `"nodes"` and `"connections"` are keyed by *stringified* identifiers, while
  `"incoming"` and `"outgoing"` keep integer node ids.
- Inside a node, `"settings"` holds the settings *schema*
  ([`settings_schema`](@ref)) and `"settings_values"` holds the *values*
  ([`settings_to_dict`](@ref)).
- `run_id`, logs and cached output data are never included. Cached data is not
  needed: a loaded node is `:dirty` and recomputes.
"""
function workflow_to_dict(w::Workflow; values::Bool = true, state::Bool = false)
    d                = Dict{String, Any}()
    d["format_version"] = SNAPSHOT_FORMAT_VERSION
    d["id"]          = w.id
    d["type"]        = workflowtypestr(w)
    d["name"]        = w.name
    d["n_iter"]      = w.n_iter
    n                = Dict{String, Dict}()
    for (k,v) in w.nodes
        n[string(k)] = node_to_dict(v; values = values, state = state)
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
    #  Журнал пишется только когда он не пуст, то есть когда `audit` включали.
    #  По умолчанию снимок остаётся таким же, каким был, — ключа просто нет,
    #  и `format_version` поднимать не за что.
    if !isempty(w.audit_log)
        d["audit_log"] = [audit_event_to_dict(e) for e in w.audit_log]
    end
    return d
end

"""
    dict_to_workflow(d::Dict{String}; usermode::Bool = false,
                     check_connection::Bool = true,
                     check_connection_throw_error::Bool = true) -> Workflow

Rebuild a workflow from the dictionary [`workflow_to_dict`](@ref) produced.

Every node type named in `d` must be registered first ([`register_node!`](@ref)):
the file names a type, the register decides whether it may be built. **Loading
executes nothing** - no user code runs, and no type is resolved from a string.

Settings values and feedback buffer contents are restored when the file carries
them; see [`dict_to_node`](@ref). Statuses are not: every loaded node is
`:dirty`, so a loaded workflow recomputes. To continue an interrupted run
instead of starting it over, call `scheduler!(w; reset_mode = :soft)`.

`usermode` is passed to [`dict_to_node`](@ref). `check_connection` runs
[`check_connection_validity`](@ref) on every connection, and
`check_connection_throw_error` decides whether a connection that does not
validate is an error (the default) or is silently dropped - a graph that lost
an edge computes something else, so prefer the error.

# Notes
- Every node key must match the `"id"` inside its `"properties"`, and ids must
  be unique; either mismatch raises, naming the key.
- `n_iter` and `c_iter` are raised to the largest id actually loaded, so the
  next [`add_node!`](@ref) or [`add_connection!`](@ref) cannot overwrite
  something the file brought in.
- A snapshot with a `"format_version"` newer than `SNAPSHOT_FORMAT_VERSION` is
  refused; one without the key is read as version 1.
"""
function dict_to_workflow(d::Dict{String}; usermode::Bool = false,
                          check_connection::Bool = true, check_connection_throw_error::Bool = true)
    haskey(d, "id") || error("No `id` field")
    haskey(d, "type") || error("No `type` field")
    if d["type"] ∉ ("DAW", "ABW") error("Unknown type") end
    #  A file without a version is a pre-versioned snapshot, read as 1. A
    #  newer one is refused: its meaning is not known here.
    fv = get(d, "format_version", 1)
    (fv isa Integer && fv <= SNAPSHOT_FORMAT_VERSION) ||
        error("Unsupported snapshot format version $(repr(fv)); " *
              "this version reads up to $(SNAPSHOT_FORMAT_VERSION)")

    w = Workflow(d["id"]; type = Symbol(d["type"]))
    w.name     = d["name"]

    for (k, n) in d["nodes"]
        node = dict_to_node(n; usermode = usermode)
        id   = node.properties.id
        parse(Int, k) == id || error("Node key $(k) does not match the id $(id) inside it")
        haskey(w.nodes, id) && error("Duplicate node id: $(id)")
        w.nodes[id] = node
    end
    w.n_iter = max(d["n_iter"], isempty(w.nodes) ? 0 : maximum(keys(w.nodes)))

    for (k, c) in d["connections"]
        id     =  parse(Int, k)
        con    = dict_to_connection(c)
        if check_connection
            ccv = check_connection_validity(w, con; throw_error = check_connection_throw_error)
            ccv || continue
        end
        w.connections[id] = con
        #  Index as we go: check_connection_validity reads model.incoming to
        #  see whether a SinglePort is already taken, and that check is blind
        #  while the index is empty. refreshind! below rebuilds it anyway.
        push!(get!(w.incoming, con.input_id,  Int[]), id)
        push!(get!(w.outgoing, con.output_id, Int[]), id)
    end
    #  Same clamp as n_iter above: a connection id from the file must never be
    #  handed out again, or the next add_connection! overwrites a loaded edge.
    w.c_iter = max(d["c_iter"], isempty(w.connections) ? 0 : maximum(keys(w.connections)))
    #  Журнал правок восстанавливается, если он в файле есть: это данные, и
    #  они принадлежат графу. А пишутся ли ДАЛЬШЕ новые правки — решает
    #  `SETTINGS[:audit]`, настройка процесса, и снимок её не меняет: файл не
    #  вправе переключать режим работы пакета.
    if haskey(d, "audit_log")
        for e in d["audit_log"]
            push!(w.audit_log, dict_to_audit_event(e))
        end
    end
    refreshind!(w)
    w.ver += 1
    return w
end

"""
    dict_to_node(d::Dict{String}; usermode = false) -> DataNode

Rebuild one node from the dictionary [`node_to_dict`](@ref) produced.

The node *type* and its *spec* come from [`NODE_REGISTER`](@ref), looked up by
the `"type"` string; the `"spec"` section of the file is not used. Settings
values (`"settings_values"`) and feedback buffers (`"state"`) are restored when
present - see [`dict_to_settings!`](@ref) and [`dict_to_node_state!`](@ref).
The node comes back `:dirty` whatever status the file carries, and without
cached output data.

Its containers come from [`nodesettings`](@ref), [`nodedata`](@ref),
[`nodestate`](@ref) and [`nodebuffer`](@ref), so a node built from typed
structs is loaded as the same typed node rather than falling back to `Dict`s.
Nothing about the containers is read from the file: like the type and the spec,
they are decided by the running code.

With `usermode = true` the spec is rebuilt from the file by `dict_to_spec`,
which you define yourself; the type still comes from the register. This lets a
snapshot carry a spec the register does not have.
"""
function dict_to_node(d::Dict{String}; usermode = false)
    properties        = dict_to_properties(d["properties"])
    properties.status = :dirty
    d["id"] == properties.id ||
        error("Node `id` $(d["id"]) does not match `properties.id` $(properties.id)")
    typestr           = d["type"]
    #  The node type always comes from the register: a snapshot names a type,
    #  it never defines one. In user mode the *spec* is rebuilt from the file
    #  by `dict_to_spec`, so a snapshot can carry a spec the register lacks.
    type, spec        = getregnodeinfo(typestr)
    usermode && (spec = dict_to_spec(d["spec"]))
    #  Контейнеры берутся из точек расширения, а не из литералов
    node = DataNode(type, properties, spec)
    haskey(d, "settings_values") && dict_to_settings!(node, d["settings_values"])
    haskey(d, "state")           && dict_to_node_state!(node, d["state"])
    return node
end

"""
    dict_to_connection(d::Dict{String}) -> NodeConnection

Rebuild one connection from the dictionary [`connection_to_dict`](@ref)
produced. Port labels are accepted as `Symbol` or as `String`, so a dictionary
that has been through a text format reads back unchanged.

The connection is not validated here; [`dict_to_workflow`](@ref) does that.
"""
function dict_to_connection(d::Dict{String})
    sym(x) = x isa Symbol ? x : Symbol(x)
    return NodeConnection(Int(d["output_id"]), sym(d["output_port"]),
                          Int(d["input_id"]),  sym(d["input_port"]))
end

"""
    dict_to_properties(d::Dict{String}) -> NodeProperties

Rebuild node properties from the dictionary
[`node_properties_to_dict`](@ref) produced. `"status"` is accepted as `Symbol`
or `String` and `"position"` as a tuple or a two-element array, so a dictionary
that has been through a text format reads back unchanged.
"""
function dict_to_properties(d::Dict{String})
    status = d["status"] isa Symbol ? d["status"] : Symbol(d["status"])
    p      = d["position"]
    return NodeProperties(Int(d["id"]), status, (Int(p[1]), Int(p[2])))
end

"""
    dict_to_spec(d::Dict{String}) -> NodeSpec

User-defined inverse of [`spec_to_dict`](@ref), used only by
[`dict_to_node`](@ref) with `usermode = true`. The package ships no method: a
spec is normally taken from [`NODE_REGISTER`](@ref), which is what keeps a
snapshot from describing a node the running code does not have.

Define it if you need snapshots to carry specs:

```julia
function MetidaFlows.dict_to_spec(d::Dict{String})
    NodeSpec(d["name"], my_ports(d["input_ports"]), my_ports(d["output_ports"]),
             Symbol.(d["settings"]))
end
```

Resolve nothing from the file into a type or a function: a snapshot is data.
"""
dict_to_spec(d) = error("Define `dict_to_spec(d::Dict{String})::NodeSpec` function to use user serialization mode.")


