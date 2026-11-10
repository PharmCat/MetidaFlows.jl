
"""
    getmeta_unsafe(node::AbstractDataNode, port::Symbol, inmeta)

Describe what the node will produce on output port `port`, **without
executing it**.

This is the extension point of metadata propagation, the configuration-time
counterpart of [`execute_unsafe!`](@ref). Like it, the method sees only the
node: `inmeta` carries the descriptions of the node's own input ports, keyed
by the node's own port labels, in exactly the shape [`getinputdata`](@ref)
uses:

- [`SinglePort`](@ref): the description, or `nothing` when the port is
  unconnected or the producer does not know;
- [`MultiPort`](@ref): a `Dict{connection id, description}`.

The default implementation returns `nothing`, meaning "unknown". The shape of
a description is a contract between nodes sharing a port datatype, not
something the engine defines.

# Rules
- Never pass a description through unchanged unless the node really preserves
  it. A node that renames or drops columns must describe its own result;
  returning the input description would propagate a lie downstream.
- This is not validation. `nothing` means "cannot tell", not "misconfigured" —
  checking that a configured column actually exists belongs in
  [`validate_settings`](@ref) and in the node body.
- Reading a little is fine, computing is not: parse a header, not a file.

# Example
```julia
# a source: reads the header only
function MetidaFlows.getmeta_unsafe(node::DataNode{ReadCSV}, ::Symbol, inmeta)
    path = get(node.settings, :file, nothing)
    (path === nothing || !isfile(path)) && return nothing
    return (columns = propertynames(CSV.File(path; limit = 0)),)
end

# a transparent node: rows are filtered, the schema is preserved
MetidaFlows.getmeta_unsafe(::DataNode{FilterRows}, ::Symbol, inmeta) = inmeta[:table]
```
"""
getmeta_unsafe(::AbstractDataNode, ::Symbol, inmeta) = nothing


"""
    getinputmeta(model::Workflow, id::Int) -> Dict{Symbol, Any}

Collect descriptions of every input port of node `id`, asking its producers
recursively.

Keys are the **input port labels of node `id`** — taken from the connections,
so a producer never needs to know which port of which consumer it feeds. Every
`:normal` input port is present in the result: an unconnected
[`SinglePort`](@ref) maps to `nothing`, an unconnected [`MultiPort`](@ref) to
an empty `Dict`.

Ports of kind `:feedback` and `:error` are skipped: a feedback edge closes a
cycle, and following it would not terminate.

`done` and `maxdepth` are threaded through to [`getmeta`](@ref): the first
keeps a common ancestor from being described twice within one call, the second
bounds the depth of the walk.

# Example
```julia
getinputmeta(w, mean_id)
# Dict{Symbol, Any}(:input_data => (columns = [:Subject, :Time, :Concentration],))
```
"""
function getinputmeta(model::Workflow, id::Int;
                            visited  = Set{Int}(),
                            done     = Dict{Tuple{Int, Symbol}, Any}(),                 # мемоизация
                            maxdepth::Int = 1000)
    node   = getnode(model, id)
    inmeta = Dict{Symbol, Any}()

    # каждый :normal-вход присутствует всегда, даже неподключённый
    for ps in node.spec.input_ports
        ps.kind == :normal || continue
        inmeta[ps.label] = ismultiport(ps) ? Dict{Int, Any}() : nothing                # заполняем словарь, ключ - порт
    end

    for cid in get(model.incoming, id, Int[])
        c  = getconnection(model, cid)                                                  # Получаем связь из workflow
        ps = getportspec(node, c.input_port, :input)                                    # Описание входного порта
        ps.kind == :normal || continue                                                 # отсекаем не normal 
        m  = getmeta(model, c.output_id, c.output_port; visited = visited, done = done, maxdepth = maxdepth)  # Получаем данные от РОДИТЕЛЯ
        if ismultiport(ps)
            inmeta[c.input_port][cid] = m                                               # ключ - id связи, как во входном буфере
        else
            inmeta[c.input_port] = m
        end
    end
    return inmeta
end


"""
    ismetasource(node::AbstractDataNode, port::Symbol) -> Bool

Declare that the node can describe `port` on its own, without asking its
producers. When it returns `true`, [`getmeta`](@ref) stops the upward walk at
this node and calls [`getmeta_unsafe`](@ref) with an **empty** `inmeta`.

The default is `false`, so a node describes its output from its inputs unless
it says otherwise.

The predicate may depend on the node state, which is the point: a node is
often a source of metadata only once it has been configured.

# Consistency
`ismetasource` and [`getmeta_unsafe`](@ref) are written together and must
agree. Reaching for `inmeta[:label]` in a branch declared as a metadata source
raises a `KeyError`, because the dictionary passed there is empty — the
mismatch is loud on purpose, as with [`validate_settings`](@ref) and
[`execute_unsafe!`](@ref).

The mirror half is as easy to get wrong: [`getmeta_unsafe`](@ref) is called on
the **not a source** branch too, and there the settings it would like may be
missing. A node that is a source only once configured therefore needs a method
that answers for *both* states - usually `nothing` for the unconfigured one:

```julia
MetidaFlows.ismetasource(n::DataNode{Range}, ::Symbol) =
    haskey(n.settings, :lo) && haskey(n.settings, :hi)

function MetidaFlows.getmeta_unsafe(n::DataNode{Range}, ::Symbol, inmeta)
    (haskey(n.settings, :lo) && haskey(n.settings, :hi)) || return nothing
    (lo = n.settings[:lo], hi = n.settings[:hi])
end
```

Without that guard an unconfigured node raises `KeyError` from inside the walk
instead of reporting "unknown", and the error surfaces far from its cause. Make
the method **total**, not merely consistent with the predicate.

# Example
```julia
# the schema is known only once the file path is set
MetidaFlows.ismetasource(node::DataNode{ReadCSV}, ::Symbol) = haskey(node.settings, :file)

# a node with an optional "schema from file" input
MetidaFlows.ismetasource(node::DataNode{Import}, ::Symbol) =
    !isempty(get(node.settings, :schema_file, ""))

function MetidaFlows.getmeta_unsafe(node::DataNode{Import}, ::Symbol, inmeta)
    haskey(node.settings, :schema_file) && return read_schema(node.settings[:schema_file])
    return inmeta[:table]                  # the branch where the node is NOT a metadata source
end
```
"""
ismetasource(::AbstractDataNode, ::Symbol)::Bool = false


"""
    getmeta(model::Workflow, id::Int, port::Symbol)

Describe what node `id` will produce on its output port `port`, without
executing anything.

Walks up the graph: the node's producers are asked first, their answers are
handed to [`getmeta_unsafe`](@ref) as `inmeta`. The walk stops at nodes
without incoming connections, and at any node for which
[`ismetasource`](@ref) returns `true`.

Returns `nothing` when the answer is unknown — because the node did not
implement [`getmeta_unsafe`](@ref), because a producer up the chain did not,
or because the required settings are not filled in yet.

# Arguments
- `maxdepth`: longest chain of nodes the walk may descend into before raising.
  Guards against a pathological graph exhausting the stack; a node declaring
  [`ismetasource`](@ref) ends the walk without consuming depth.

# Notes
- Within one call each `(node, output port)` pair is described **once**: a
  diamond does not compute its common ancestor twice. The memo lives for the
  duration of the call only, so nothing can go stale between calls — a file
  may change on disk, and the next call sees it.
- Nothing is cached **between** calls. Memoize inside the node if a source is
  expensive to inspect.
- A node declaring [`ismetasource`](@ref) cuts the walk short, so the branches
  above it are never visited.
- In a graph containing a cycle built from `:normal` edges the answer for a
  node inside the cycle depends on where the walk started. Such a graph is
  rejected by the [`DAW`](@ref) scheduler and never produced by [`ABW`](@ref),
  where cycles are closed by `:feedback` edges that this walk does not follow.
- `:feedback` and `:error` edges are not followed, so cyclic [`ABW`](@ref)
  workflows are safe. A cycle built from `:normal` edges only is detected as a
  back edge and yields `nothing` for the repeated node instead of recursing
  forever.

# Example
```julia
getmeta(w, csv_id, :table)      # (columns = [:Subject, :Formulation, :Time, :Concentration],)
```
"""
function getmeta(model::Workflow, id::Int, port::Symbol;
                  visited  = Set{Int}(),
                  done     = Dict{Tuple{Int, Symbol}, Any}(),                          # мемоизация
                  maxdepth::Int = 1000)
    key = (id, port)
    haskey(done, key) && return done[key]                                              # уже считали это тузел - взвращаем данные из done

    node = getnode(model, id)
    isportexist(node, port, :output) || error("Wrong port label: $(port) is not an output port of node $(id)")

    # нода объявила себя источником описания: подъёма не происходит
    if ismetasource(node, port)
        return done[key] = getmeta_unsafe(node, port, Dict{Symbol, Any}())          # Возвращаем то, что отдала "терминальная" нода
    end

    id in visited && return nothing          # обратное ребро: результат зависит от пути, в done не кладём

    length(visited) >= maxdepth && error(
        "Metadata traversal exceeded maxdepth = $(maxdepth) at node $(id). ")

    push!(visited, id)
    try
        inmeta = getinputmeta(model, id; visited = visited, done = done, maxdepth = maxdepth) # Продолжаем подниматься по уровню рекурсии выше 
        return done[key] = getmeta_unsafe(node, port, inmeta)                              # Дописываем в то что пришло от родительских нод свою информацию
    finally
        delete!(visited, id)                                                                  # множество хранит текущий путь, не всё пройденное
    end
end