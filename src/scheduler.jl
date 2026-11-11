
# --------------------------------------------------------
# Scheduler functions
# --------------------------------------------------------

"""
    failed_nodes(model::Workflow) -> Vector{Pair{Int, Symbol}}

Nodes a run refused to execute, as `id => status` pairs ordered by id.

A node counts as failed when its status is `:failed` - its
[`execute_unsafe!`](@ref) raised - or one of `:invalid_node`,
`:invalid_settings`, `:invalid_result`, where a validation step refused it.
The result is empty when every node the run attempted finished.

`:dirty` is **not** a failure. A node downstream of a failure ends the run
`:dirty` because it was never attempted, and so does a node below a branch
a gate did not take, or the body of a cyclic workflow after its last turn.
Those are consequences; the cause is in this list.

See also [`check_failed_nodes`](@ref), [`getstatus`](@ref).
"""
function failed_nodes(model::Workflow)
    bad = Pair{Int, Symbol}[]
    for (id, node) in model.nodes
        st = getstatus(node)
        st in (:failed, :invalid_node, :invalid_settings, :invalid_result) || continue
        push!(bad, id => st)
    end
    sort!(bad; by = first)
    return bad
end

"""
    check_failed_nodes(model::Workflow; throw_error::Bool = true) -> Bool

`true` when [`failed_nodes`](@ref) is empty.

With `throw_error` - the default - a non-empty list raises instead, naming
every node and its status; what each one raised is in `model.log`. Without it
the function only reports, returning `false`.

This is what `scheduler!(model; strict = true)` calls once the traversal is
over, and it works by hand after an ordinary run just as well:

```julia
scheduler!(w)            # let everything that can finish, finish
check_failed_nodes(w)    # then fail with the list
```
"""
function check_failed_nodes(model::Workflow; throw_error::Bool = true)
    bad = failed_nodes(model)
    isempty(bad) && return true
    throw_error || return false
    error("$(length(bad)) node(s) did not execute: " *
          join(("node $(id) ($(st))" for (id, st) in bad), ", ") *
          ". See `workflow.log` for what each one raised.")
end

"""
    scheduler!(model::Workflow{DAW}; reset_mode::Symbol = :full,
               throw_error::Bool = false, strict::Bool = false,
               release_optional::Bool = false)
 
Execute entire data analysis workflow (DAW) using topological ordering.
 
This scheduler is designed for deterministic acyclic data-analysis workflows.
 
# Execution Steps
1. Build workflow graph.
2. Validate graph acyclicity.
3. Generate new workflow `run_id`.
4. Apply `reset_mode`.
5. Execute nodes in topological order.
 
# Arguments
- `reset_mode`: `:full` (default) invalidates every node via [`reset!`](@ref)
  and drops cached output data; `:soft` only marks nodes `:dirty` and keeps
  the cache; `:none` leaves statuses untouched, so nodes that are already
  `:clean` are not recomputed. Any other value raises an error.
- `throw_error`: forwarded to [`execute!`](@ref); aborts the run on the first
  node that raises instead of recording the failure, which also leaves every
  node after it in the order unexecuted.
- `strict`: once the traversal is over, raise if any node failed - see
  [`check_failed_nodes`](@ref). Unlike `throw_error` this lets every branch
  that can finish, finish, and then reports every failure at once; the
  workflow is left in its post-run state. `throw_error` wins: if it raised,
  this check is never reached.
- `release_optional`: run a node that is held back **only** by a `required =
  false` port, reading `nothing` there instead of skipping it. Off by default.
  In topological order a producer that is not `:clean` when its consumer comes
  up has already had its turn - it failed, or a gate above it did not take its
  branch - so there is nothing left to wait for, and this is what makes
  `required = false` mean on a run what it says on the port. Any earlier run's
  value left in that buffer is dropped first, see
  [`invalidate_stale_optional!`](@ref). A `required` port still holds the node
  back. Without the flag such a consumer ends the run `:dirty`.

# Notes
- Nodes are executed at most once per scheduler run.
- A node that calls [`request_stop!`](@ref) ends the traversal: everything
  still ahead in the order is left `:dirty`. A stop is not a failure, so
  `strict` does not raise on it.
- A node is skipped when [`isready`](@ref) reports that a producer connected
  through a `:normal` port is not `:clean`. In an acyclic graph traversed in
  topological order that happens only below a node that failed, and skipping
  is what keeps such a node from reading an input buffer still holding a value
  from an earlier run - which `check_input_buffer` would accept. A skipped
  node ends the run `:dirty`, as it does in [`ABW`](@ref).
- Upstream execution and downstream invalidation are disabled
  because execution order is already guaranteed by topology.
- Required input ports are enforced (`check_input_buffer` stays on).
- Cyclic workflows are rejected before execution starts, including cycles
  closed by a `:feedback` port - see [`makegraph`](@ref). In a `DAW` workflow
  the only effect of `kind = :feedback` is that the port is exempt from the
  required-buffer check; there is no delay and no second pass.
 
# Returns
`true` when the traversal completed. This is not a success flag: individual
nodes may still end up `:failed` or `:invalid_*`, so check [`getstatus`](@ref)
when it matters.
 
# Example
```julia
scheduler!(workflow)
result = getdata(workflow, output_id, :result)
```
"""
function scheduler!(model::Workflow{DAW}; reset_mode::Symbol = :full, throw_error::Bool = false, strict::Bool = false, release_optional::Bool = false)
    #g = makegraph(model)
    if is_cyclic(model) error("workflow is cyclic") end
    if reset_mode ∉ (:full, :soft, :none) error("Wrong reset mode: $reset_mode , only :full, :soft, :none availabel.") end
    soft_reset = false
    # change to thread safe
    model.run_id = rand(UInt64)
    if reset_mode == :soft soft_reset = true end
    if reset_mode != :none reset!(model; soft = soft_reset) end

    order = topological_sort(model)
    for id in order
        #  A node whose producer failed must not be executed
        if !isready(model, id)
            #  Узел не готов. Если блокируют его ТОЛЬКО необязательные
            #  порты, то в топологическом порядке их производители свой
            #  шанс уже использовали: значения не будет никогда, и
            #  `nothing` — законный ответ, а не «еще не посчитано».
            #  Проверка стоит здесь, а не выше: на готовом узле лишнего
            #  обхода связей не делается.
            release_optional || continue
            isready(model, id; wait_optional = false) || continue
            invalidate_stale_optional!(model, id)
        end
        execute!(model, id; settings = ExecuteSettings(;execute_upstream = false, invalidate_downstream = false, check_cyclic = false), throw_error = throw_error)
        #  Узел поднимает флаг остановки: обход прекращается, остальные узлы порядка  :dirty.
        if isstoprequested(getnode(model, id))
            log!(model, LogMsg(:info, "Run stopped by node (id: $(id))"))
            break
        end
    end
    strict && check_failed_nodes(model)
    return true
end
"""
    release_optional_blocked!(model::Workflow, queue::Vector{Int},
                              queued::Set{Int}, released::Set{Int}) -> Int

Enqueue every `:dirty` node that [`isready`](@ref) refuses **only** because of
an optional port, and return how many were released.

Called by [`scheduler!`](@ref) on an [`ABW`](@ref) workflow with
`release_optional = true`, and only when the queue has run dry. That moment is
the guarantee the relaxation needs: an empty queue means nothing will execute
again by itself, so a producer that is not `:clean` now will never be, and its
optional consumers can be told so instead of waiting for it forever.

An id is recorded in `released`, which is what tells the queue loop to serve
that node under the relaxed rule once - the loop re-checks readiness when it
pops a node, and the ordinary rule would refuse it again and release it again
forever. Its stale optional buffers are cleared at that point, by
[`invalidate_stale_optional!`](@ref). Nodes are queued in id order, so a run
does not depend on `model.nodes` iteration order.

A node blocked by a `required` port is never released: that is a missing value
the node declared it cannot work without.
"""
function release_optional_blocked!(model::Workflow, queue::Vector{Int}, queued::Set{Int}, released::Set{Int})
    ids = Int[]
    for (nid, node) in model.nodes
        getstatus(node) == :dirty || continue
        isready(model, nid) && continue                       # не заблокирован — вернёт обычный путь
        isready(model, nid; wait_optional = false) || continue # блокирует обязательный порт
        push!(ids, nid)
    end
    isempty(ids) && return 0
    sort!(ids)   # порядок обхода Dict машинно-зависим, порядок выпуска — нет
    for nid in ids
        push!(released, nid)
        if !(nid in queued)
            push!(queue, nid)
            push!(queued, nid)
        end
    end
    return length(ids)
end

"""
    scheduler!(model::Workflow{ABW}; reset_mode::Symbol = :full, maxiter = 1000,
               throw_error::Bool = false, throw_warn::Bool = true,
               strict::Bool = false, release_optional::Bool = false)
 
Execute workflow using queue-based agent/event scheduling.
 
Intended for dynamic, agent-based and **iterative** workflows. Unlike
[`DAW`](@ref), this scheduler accepts cyclic graphs, and a node may execute
several times during one call.
 
# Execution Steps
1. Generate a new workflow `run_id` and apply `reset_mode`.
2. Seed the queue with every node that has no input ports.
3. Pop a node and execute it when [`isready`](@ref) reports that every
   producer connected through a `:normal` port is `:clean`; otherwise drop it -
   a producer finishing later re-queues it. Stop serving the queue if the node
   called [`request_stop!`](@ref).
4. For every port the execution produced, mark the child **and everything
   downstream of it** `:dirty` - see [`mark_dirty_downstream!`](@ref) - and
   enqueue the child.
5. Enqueue, without marking, the children attached to `:normal` connections
   leaving a port the execution did **not** produce: no value is coming for
   them, and a consumer whose port is optional is ready to run with `nothing`.
   Without this step such a consumer would depend on whether it happened to be
   dropped from the queue before its producer went silent - a node that
   publishes nothing enqueues nobody, so nothing would bring it back.
 
Required input ports are enforced, as in [`DAW`](@ref): a node whose
`required` `:normal` port has no value at all is refused with `:invalid_node`
instead of being run on nothing. See [`execution_node_validation`](@ref).
 
# Arguments
- `reset_mode`: `:full` (default) invalidates every node via [`reset!`](@ref),
  drops cached output data and **clears the buffers of `:feedback` ports**, so
  a cyclic workflow starts a new run instead of resuming the previous one;
  `:soft` only marks nodes `:dirty` and keeps both the cache and the loop
  state, which is how state is carried between runs; `:none` leaves statuses
  untouched, so `:clean` nodes are not recomputed. Any other value raises an
  error.

  `:none` is not a no-op on a cyclic workflow. [`execute!`](@ref) returns the
  stored `ready_ports` of a `:clean` node, step 4 propagates from them, and the
  children recompute - on the buffers left over from the previous run. Use
  `:soft` to continue a loop and `:full` to start one.
- `maxiter`: maximum number of scheduler iterations before aborting execution.
  For a cyclic workflow this is the backstop against a loop that never
  converges.
- `throw_error`: forwarded to [`execute!`](@ref). Aborts the run on the first
  node that raises, which also leaves every branch that had not run yet
  unexecuted.
- `strict`: once the traversal is over, raise if any node failed - see
  [`check_failed_nodes`](@ref). Unlike `throw_error` this lets everything that
  can finish, finish, and then reports every failure at once; the workflow is
  left in its post-run state, so it can be inspected after the error is
  caught. `throw_error` wins: if it raised, this check is never reached.
- `throw_warn`: warn when the seed queue is empty. Nothing is executed in that
  case and the nodes stay `:dirty`, which is otherwise silent.
- `release_optional`: when the queue runs dry, release the nodes that
  [`isready`](@ref) holds back **only** because of a `required = false` port -
  see [`release_optional_blocked!`](@ref) - and go on serving the queue. Off by
  default. The empty queue is what makes it sound: until then a producer that
  is not `:clean` may still be about to run, and reading `nothing` from its
  port would be wrong rather than conditional. This is what lets a whole
  branch be skipped and the result merged back afterwards: without it a
  consumer waits for a producer that was itself never executed, and the run
  stops mid-loop with no result and no error. One `:info` record is appended
  to `model.log` the first time a run releases anything.

# Cycles
A cycle must be closed by a connection entering a port declared with
`kind = :feedback`; see [`PortSpec`](@ref). Two properties make the loop run:
 
- [`isready`](@ref) does not wait for the producer of a feedback edge, so the
  cycle has a defined entry point;
- step 4 marks children `:dirty` **unconditionally**, so a node that already
  ran during this call runs again instead of short-circuiting on `:clean`
  inside [`execute!`](@ref);
- step 4 marks the whole downstream cone, not only the direct children, so a
  node is held back until every one of its `:normal` ancestors has been
  recomputed during the turn. Without it the result would depend on the order
  in which the connections were created, because that order is the order the
  queue is served in.

One consequence of marking the cone: a node below a branch that was not taken
during the last turn - everything after a gate that closed the loop, for
instance - ends the run `:dirty` rather than `:clean`, because it genuinely was
not recomputed. "Every node is `:clean`" is therefore not a completion signal
for a cyclic workflow.
 
The loop ends when a node publishes nothing that has a consumer - by returning
an empty vector of ready ports, or by publishing only unconnected or
`:terminal` ports. The queue then drains.
 
Every cyclic workflow needs at least one node with **no input ports**: a
`:feedback` port is still an input port, so a loop on its own is never seeded
and never starts. See [`haveinputs`](@ref).
 
# Notes
- Nodes are executed with `ExecuteSettings(false)`, so required input ports
  are **not** enforced here, unlike the [`DAW`](@ref) path.
- A node with input ports but without incoming connections never becomes
  ready and stays `:dirty`.
 
# Returns
`true` when the queue is drained.
 
# Example
```julia
scheduler!(w)                             # full reset, one pass or one loop
scheduler!(w; reset_mode = :soft)         # keep cached results between runs
scheduler!(w; maxiter = 10_000)           # long-running iteration
scheduler!(w; throw_warn = false)         # a deliberately unseeded graph
```
"""
function scheduler!(model::Workflow{ABW}; reset_mode::Symbol = :full, maxiter = 1000, throw_error::Bool = false, throw_warn::Bool = true, strict::Bool = false, release_optional::Bool = false)
    if reset_mode ∉ (:full, :soft, :none) error("Wrong reset mode: $reset_mode , only :full, :soft, :none availabel.") end
    soft_reset = false
    # change to thread safe
    model.run_id = rand(UInt64)
    if reset_mode == :soft soft_reset = true end
    if reset_mode != :none reset!(model; soft = soft_reset) end

    queued = Set{Int}() # Ноды которые уже добавлены - не реализовано
    queue = Int[]
    #
    for (id, node) in model.nodes
        if !haveinputs(node)
            push!(queue, id)
            push!(queued, id)
        end
    end
    if throw_warn && length(queue) == 0 @warn "No nodes in queue..." end
    # execute
    iter = 0
    announced = false
    released = Set{Int}()   # выпущенные на затишье: ослабление действует на один съём
    while true
        if isempty(queue)
            #  Очередь пуста — обычный прогон на этом кончается. С
            #  `release_optional` сперва проверяем, не встал ли он на
            #  узлах, которым мешают только необязательные порты: пустая
            #  очередь и есть доказательство, что их производители уже
            #  не отработают.
            release_optional || break
            n = release_optional_blocked!(model, queue, queued, released)
            n == 0 && break
            if !announced
                #  Один раз за прогон: иначе на длинном цикле запись
                #  в лог на каждый виток.
                log!(model, LogMsg(:info,
                    "Released $(n) node(s) blocked only by optional inputs (release_optional = true)"))
                announced = true
            end
        end
        if iter > maxiter
            error("max iterations reached ($(maxiter)): $(length(queue)) node(s) still queued, " *
                  "next is node $(first(queue)). Raise `maxiter` for a long iteration, " *
                  "or check that some node stops publishing into the loop.")
        end
        id = popfirst!(queue)
        delete!(queued, id)
        #  Ослабление действует ровно на один съём того узла, который
        #  выпустил проход по затишью. Иначе узел, снова попавший в
        #  очередь обычным путём, считался бы по ослабленному правилу —
        #  то есть мог бы прочитать `nothing` там, где значение ещё шло.
        relaxed = id in released
        if relaxed
            delete!(released, id)
            #  Производитель необязательного порта не отработал: что
            #  лежит в буфере — значение прошлого витка, а не ответ.
            invalidate_stale_optional!(model, id)
        end
        if isready(model, id; wait_optional = !relaxed)
            #  Не ExecuteSettings(false): он выключил бы и проверку
            #  заполненности обязательных входов, то есть флаг
            #  `required` в ABW не значил бы ничего. Порядок и
            #  инвалидацию ведёт сам планировщик, их и выключаем.
            ready_ports = execute!(model, id;
                settings = ExecuteSettings(; execute_upstream = false,
                                             invalidate_downstream = false,
                                             check_cyclic = false),
                throw_error = throw_error)
            #  Узел попросил остановиться. Опубликованное им уже лежит в буферах потомков, в очередь  не попадают.
            if isstoprequested(getnode(model, id))
                log!(model, LogMsg(:info, "Run stopped by node (id: $(id))"))
                break
            end
            for port in ready_ports
                cons = getportconnections(model, id, port; direction = :output)
                for con in cons
                    #  Помечаем :dirty потомка И весь его конус вниз по обычным рёбрам (данные в буферах не трогаем)
                    mark_dirty_downstream!(model, con.input_id)
                    # добавляем только если нет в очереди
                    if !(con.input_id in queued)
                        push!(queue, con.input_id)
                        push!(queued, con.input_id)
                    end
                end
            end
            #  Потомки портов, в которые узел НЕ публиковал, тоже должны
            #  попасть в очередь. Значения им не будет никогда, и если
            #  порт необязательный, узел готов считаться с `nothing` —
            #  на этом стоит условное вычисление. Без этого он зависел бы
            #  от того, выбросили ли его из очереди ДО того, как родитель
            #  замолчал: не-готовый узел здесь отбрасывается, а вернуть
            #  его могла только публикация, которой не будет.
            #  :dirty не помечаем — новых данных узел не получил.
            #  Обратные и :error рёбра пропускаем: первые замкнули бы
            #  цикл навсегда, вторые защёлкивают диагноз.
            for cid in get(model.outgoing, id, Int[])
                con = model.connections[cid]
                con.output_port in ready_ports && continue
                child = getnode(model, con.input_id)
                getportspec(child, con.input_port, :input).kind == :normal || continue
                if !(con.input_id in queued)
                    push!(queue, con.input_id)
                    push!(queued, con.input_id)
                end
            end
        end
        iter += 1
    end
    strict && check_failed_nodes(model)
    return true
end