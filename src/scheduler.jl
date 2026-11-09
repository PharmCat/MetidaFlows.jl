
# --------------------------------------------------------
# Scheduler functions
# --------------------------------------------------------

"""
    scheduler!(model::Workflow{DAW}; reset_mode::Symbol = :full,
               throw_error::Bool = false)
 
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
  node that raises instead of recording the failure.
 
# Notes
- Nodes are executed at most once per scheduler run.
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
function scheduler!(model::Workflow{DAW}; reset_mode::Symbol = :full, throw_error::Bool = false)
    g = makegraph(model)
    if is_cyclic(g) error("workflow is cyclic") end
    if reset_mode ∉ (:full, :soft, :none) error("Wrong reset mode: $reset_mode , only :full, :soft, :none availabel.") end
    soft_reset = false
    # change to thread safe
    model.run_id = rand(UInt64)
    if reset_mode == :soft soft_reset = true end
    if reset_mode != :none reset!(model; soft = soft_reset) end

    order = topological_sort(g)
    for id in order
        execute!(model, id; settings = ExecuteSettings(;execute_upstream = false, invalidate_downstream = false, check_cyclic = false), throw_error = throw_error) 
    end
    return true
end
"""
    scheduler!(model::Workflow{ABW}; reset_mode::Symbol = :full, maxiter = 1000,
               throw_error::Bool = false, throw_warn::Bool = true)
 
Execute workflow using queue-based agent/event scheduling.
 
Intended for dynamic, agent-based and **iterative** workflows. Unlike
[`DAW`](@ref), this scheduler accepts cyclic graphs, and a node may execute
several times during one call.
 
# Execution Steps
1. Generate a new workflow `run_id` and apply `reset_mode`.
2. Seed the queue with every node that has no input ports.
3. Pop a node and execute it when [`isready`](@ref) reports that every
   producer connected through a `:normal` port is `:clean`; otherwise drop it -
   a producer finishing later re-queues it.
4. For every port the execution produced, mark the child **and everything
   downstream of it** `:dirty` - see [`mark_dirty_downstream!`](@ref) - and
   enqueue the child.
 
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
- `throw_error`: forwarded to [`execute!`](@ref).
- `throw_warn`: warn when the seed queue is empty. Nothing is executed in that
  case and the nodes stay `:dirty`, which is otherwise silent.
 
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
function scheduler!(model::Workflow{ABW}; reset_mode::Symbol = :full, maxiter = 1000, throw_error::Bool = false, throw_warn::Bool = true)
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
    while length(queue) > 0
        if iter > maxiter
            error("max iterations reached ($(maxiter)): $(length(queue)) node(s) still queued, " *
                  "next is node $(first(queue)). Raise `maxiter` for a long iteration, " *
                  "or check that some node stops publishing into the loop.")
        end
        id = popfirst!(queue)
        delete!(queued, id)
        if isready(model, id)
            #execute_upstream=false
            #invalidate_downstream=false 
            #check_cyclic=false
            #check_input_buffer=false
            ready_ports = execute!(model, id; settings = ExecuteSettings(false), throw_error = throw_error)
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
        end
        iter += 1
    end
    return true
end