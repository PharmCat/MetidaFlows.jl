# =========================================================================
#  ЗАМЕНА УЗЛА НА МЕСТЕ
#
#  `Base.replace!(model, node, id)` ставит другой узел под тем же
#  идентификатором, сохраняя все связи, их идентификаторы и посчитанное у
#  тех узлов, которых замена не касается. Это то, чего нельзя получить
#  через `delete_node!` + `add_node!`: там связи исчезают вместе с узлом.
#
#  Общие части: `isportexist`, `getportspec`, `getporttype`, `ismultiport`,
#  `invalidate_buffer!`, `invalidate_downstream!`, `audit!` (MetidaFlows.jl),
#  `setinputbuffer!` (setters.jl), `getstate`, `getdata` (getters.jl).
# =========================================================================
replside(model::Workflow, new::AbstractDataNode, id::Int, side_id::Int) =
    side_id == id ? new : getnode(model, side_id)

function check_replacement(model::Workflow, new::AbstractDataNode, id::Int,
                           throw_warn::Bool)
    inc = get(model.incoming, id, Int[])
    out = get(model.outgoing, id, Int[])

    #  Проход первый: все метки, которые упоминают связи, должны быть на
    #  новом узле.
    for cid in inc
        l = model.connections[cid].input_port
        isportexist(new, l, :input) ||
            error("Replacement for node $(id) has no input port $(l), which connection $(cid) feeds")
    end
    for cid in out
        l = model.connections[cid].output_port
        isportexist(new, l, :output) ||
            error("Replacement for node $(id) has no output port $(l), which connection $(cid) leaves from")
    end

    #  Сколько связей придёт на каждую входную метку и уйдёт с каждой
    #  выходной. 
    incount  = Dict{Symbol, Int}()
    outcount = Dict{Symbol, Int}()
    for cid in inc
        l = model.connections[cid].input_port
        incount[l] = get(incount, l, 0) + 1
    end
    for cid in out
        l = model.connections[cid].output_port
        outcount[l] = get(outcount, l, 0) + 1
    end

    #  Проход второй: типы, передача владения, арность, терминальность.
    for cid in inc
        c        = model.connections[cid]
        l        = c.input_port
        ps       = getportspec(new, l, :input)
        parent   = replside(model, new, id, c.output_id)
        out_spec = getportspec(parent, c.output_port, :output)

        getporttype(parent, c.output_port, :output) <: getporttype(new, l, :input) ||
            error("Type mismatch on connection $(cid): $(getporttype(parent, c.output_port, :output)) from port $(c.output_port) of node $(c.output_id) is not a subtype of $(getporttype(new, l, :input)) expected by input port $(l) of the replacement for node $(id)")

        ps.handover && !out_spec.handover &&
            error("Input port $(l) of the replacement for node $(id) takes ownership and can only be fed by a handover output port; $(c.output_port) of node $(c.output_id) is not one")

        if !ismultiport(ps) && incount[l] > 1
            error("Input port $(l) of the replacement for node $(id) is a SinglePort, but $(incount[l]) connections feed it; declare it MultiPort() or delete the extra connections first")
        end
    end

    for cid in out
        c       = model.connections[cid]
        l       = c.output_port
        ps      = getportspec(new, l, :output)
        child   = replside(model, new, id, c.input_id)
        in_spec = getportspec(child, c.input_port, :input)

        getporttype(new, l, :output) <: getporttype(child, c.input_port, :input) ||
            error("Type mismatch on connection $(cid): $(getporttype(new, l, :output)) from output port $(l) of the replacement for node $(id) is not a subtype of $(getporttype(child, c.input_port, :input)) expected by port $(c.input_port) of node $(c.input_id)")

        if ps.handover && outcount[l] > 1
            error("Output port $(l) of the replacement for node $(id) hands its value over, but $(outcount[l]) connections leave it; a handover port allows exactly one")
        end

        #  То же правило с другой стороны: потребитель, который забирает
        #  владение, не может остаться на обычном выходе.
        in_spec.handover && !ps.handover &&
            error("Port $(c.input_port) of node $(c.input_id) takes ownership and can only be fed by a handover output port; $(l) of the replacement for node $(id) is not one")

        ps.kind == :terminal && throw_warn &&
            @warn "Output port $(l) of the replacement for node $(id) is terminal and should not be connected"
    end
    return nothing
end

#  Перенос настроек старого узла на новый. Зовётся ДО подмены, поэтому его
#  отказ не требует откатывать граф.
#
#  Ключи, которых у старого узла нет, у нового остаются: это перенос, а не
#  замена целиком. Контейнер настроек может быть и `Dict`, и структурой
#  (`AbstractNodeFields`).
#
function transfer_settings!(new::AbstractDataNode, old::AbstractDataNode)
    new === old && return new
    for k in collect(keys(old.settings))
        try
            new.settings[k] = old.settings[k]
        catch e
            error("Settings of node $(getid(old)) do not fit the replacement at key `:$(k)`: $(sprint(showerror, e))")
        end
    end
    return new
end

#  Наполнение входных буферов нового узла тем, что родители уже
#  опубликовали. Правило взято у движка (`push_buffer_from!`): значение
#  берётся, только если родитель `:clean` И порт есть в его `ready_ports`.
#  Поэтому непубликованный порт не кладёт в буфер `nothing`, а `:released`
#  родитель пропускается.
function pull_buffers!(model::Workflow, new::N, id::Int) where N <: AbstractDataNode
    for cid in get(model.incoming, id, Int[])
        con    = model.connections[cid]
        parent = getnode(model, con.output_id)
        getstatus(parent) === :clean || continue
        con.output_port in getstate(parent, :ready_ports) || continue
        setinputbuffer!(new, con.input_port, cid, getdata(parent, con.output_port))
    end
    return new
end

"""
    replace!(model::Workflow, node::AbstractDataNode, id::Int; throw_warn = true) -> AbstractDataNode

Put `node` into the workflow under the identifier `id`, keeping every
connection, and return the node that was displaced.

This is what `delete_node!` followed by `add_node!` cannot do: deleting a node
deletes its connections, so the wiring - and the connection identifiers that
order a [`MultiPort`](@ref) - would have to be rebuilt. Here the graph keeps
its shape and only the node at that one identifier changes, so the nodes the
replacement does not reach keep their cached results and their `:clean` status.

# What is checked, and all of it before anything is written

Every connection that touches `id` must still be valid with the new node in
place, by the same rules [`add_connection!`](@ref) applies when a connection is
created:

- the port each connection names **exists** on the replacement, on the right
  side;
- **datatypes line up**: the producer's output type is a subtype of the
  consumer's input type, in both directions;
- a **`handover` output** that is connected has **exactly one** connection, and
  a **`handover` input** is fed only by a `handover` output - checked from both
  sides, so neither a taking consumer nor a handing producer can be left paired
  with an ordinary port;
- an input port that is **not** a `MultiPort` has **exactly one** incoming
  connection;
- a `:terminal` output that is connected warns, as it does at creation
  (`throw_warn = false` silences it).

A node connected to itself - a `:feedback` loop - is checked with the
replacement on **both** sides of that connection, which is what it will be.

# Order of operations

1. the checks above;
2. the old node's settings are written onto the replacement, key by key -
   keys the old node does not have are left as the replacement brought them.
   This happens **before** the swap, so a settings container that refuses a
   key (a typed container missing a field, a field of another type) fails with
   the graph still untouched;
3. the replacement takes the identifier and the place in the workflow, and is
   marked `:dirty` - always, whatever it arrived as;
4. its input buffers are filled from parents that have already published -
   `:clean` and the port among their `ready_ports` - so the replacement can
   run without recomputing anything above it;
5. the consumers below are invalidated: each child's buffer slot fed from
   `id` is cleared and the invalidation propagates;
6. `model.ver` is raised and the change is recorded in the change log.

Should anything in steps 3-5 throw, the old node goes back and `model.ver`
returns to what it was. An invalidation that had already propagated is left
alone: a node marked `:dirty` only costs a recomputation.

# The replacement always ends up `:dirty`

Whatever the node arrived as, it is marked `:dirty`: the replacement has not
run *here*, and results it may be carrying from somewhere else belong to other
settings and another graph. So a replacement always recomputes on the next run,
and so does everything below it. `mark_dirty!` also drops its `data` and its
`ready_ports`, so nothing it brought with it can be published as if this graph
had produced it.

What survives is the part that makes the replacement cheap: the **input**
buffers are filled from parents that already published, so the nodes *above*
are not recomputed. That is the whole point of replacing in place.

The change log gets a [`NodeReplaced`](@ref)`(id, type, previous)` record, so
one line says what became what. That record exists only in snapshot format 3
and later.

# Example

```julia
new = DataNode(FasterFilter, filter_spec())
old = replace!(w, new, 7)            # node 7 is now FasterFilter, wiring intact
scheduler!(w; reset_mode = :none)    # only node 7 and below recompute
```

See also [`add_node!`](@ref), [`delete_node!`](@ref), [`add_connection!`](@ref).
"""
function Base.replace!(model::Workflow, node::AbstractDataNode, id::Int;
                       throw_warn::Bool = true)
    isnodeexist(model, id) || error("Node $(id) doesn't exist")
    old = getnode(model, id)

    #  Один объект под двумя идентификаторами не допустимо
    if node !== old
        for (k, n) in model.nodes
            n === node && error("This node object is already in the workflow under id $(k); replace! needs a node that is not in the graph")
        end
    end

    check_replacement(model, node, id, throw_warn)
    transfer_settings!(node, old)

    ver = model.ver
    try
        setid!(node, id)
        model.nodes[id] = node
        #  замена в любом случае инвалидируется 
        mark_dirty!(node)
        pull_buffers!(model, node, id)
        #  Инвалидация потомков, а не `invalidate_downstream!(model, id)`
        for cid in get(model.outgoing, id, Int[])
            con   = model.connections[cid]
            child = getnode(model, con.input_id)
            invalidate_buffer!(child, con.input_port, cid)
            invalidate_downstream!(model, con.input_id)
        end
        model.ver += 1
        audit!(model, NodeReplaced(id, nodetypestr(node), nodetypestr(old)))
    catch
        model.nodes[id] = old
        setid!(old, id)
        model.ver = ver
        rethrow()
    end
    return old
end
