
# Main executing
# :clean, :dirty, :executing, :failed
"""
    execute!(model::Workflow, id::Int; settings::ExecuteSettings = ExecuteSettings(),
             throw_error::Bool = false)
 
Execute workflow node.
 
Main workflow execution entry point.
 
# Execution Stages
1. Initialize per-run execution state and logs.
2. Optionally detect recursive cyclic execution.
3. Skip execution for nodes already marked `:clean`.
4. Mark node as `:executing`.
5. Optionally execute upstream dependencies recursively.
6. Validate node structure and execution readiness.
7. Validate node settings.
8. Increment `exec_n` and execute node implementation via [`execute_unsafe!`](@ref).
9. Validate execution result.
10. Store execution state (`ready_ports`).
11. Propagate outputs downstream through input buffers.
12. Optionally invalidate downstream nodes.
13. Mark node as `:clean`.
 
# Arguments
- `settings`: per-call execution flags, see [`ExecuteSettings`](@ref).
- `throw_error`: rethrow an exception raised by [`execute_unsafe!`](@ref)
  after the node status and the log record have been written. With the
  default `false` the error is swallowed and reported through the status and
  `model.log`.
 
# Returns
Vector of output port labels (`Vector{Symbol}`) produced during execution, or
an empty vector when the node was skipped, rejected by validation or failed.
 
The vector is not copied: for a `:clean` node it is the stored `ready_ports`
state, and otherwise it is whatever [`execute_unsafe!`](@ref) returned. Treat
the result as read-only.
 
# Status after the call
`:clean` on success, otherwise `:invalid_node`, `:invalid_settings`,
`:invalid_result` or `:failed`.
 
# Example
```julia
execute!(w, id)                                                    # parents pulled in
execute!(w, id; settings = ExecuteSettings(; execute_upstream = false))
execute!(w, id; throw_error = true)
```
"""
function execute!(model::Workflow, id::Int; settings::ExecuteSettings = ExecuteSettings(), throw_error::Bool = false) 
    node =  getnode(model, id)

    if getstate(node, :execution_id) != model.run_id
        empty!(getstate(node, :log))
        setstate!(node, :execution_id, model.run_id)
    end

    if settings.check_cyclic
        # Это обнаружит цикл только при повторном заходе в тот же узел в рамках одного вызова. 
        # Не является настоящей защитой от циклов (реализовано в scheduler!)
        if getstatus(node) == :executing
            @warn "Ring detected"
            return Symbol[]
        end
    end
    #
    if getstatus(node) == :clean
        # clean node - no need for executing
        return getstate(node, :ready_ports)
    end
    #
    # need to catch errors...
    setstatus!(node, :executing)
    # Check and execute parent nodes
    # execute_upstream should bu use carefully
    if settings.execute_upstream
        if length(model.nodes) > 1000 @warn "A large number of nodes (nodes count = $(length(model.nodes))) can cause stack overflow." end
        parents = get_parents(model, id)
        for (k,p) in parents
            execute!(model, p; settings = settings)
        end
    end
    # Check is valid 
    if !execution_node_validation(node, settings.check_input_buffer)
        setstatus!(node, :invalid_node)
        return Symbol[]
    end
    if !validate_settings(node)
        setstatus!(node, :invalid_settings)
        return Symbol[]
    end
    # Execute node
    ready_ports = try 
        node.state.exec_n += 1
        execute_unsafe!(node)
    catch e
        setstatus!(node, :failed)
        # Log error
        push!(model.log, LogMsg(:error, "Node (id: $(getid(node))) execution failed: $(e)"))
        if throw_error
            rethrow(e)
        end
        return Symbol[]
    end
    # Post-execution validation
    if !validate_result(node)
        setstatus!(node, :invalid_result)
        return Symbol[]
    end
    # Save state ready_ports
    setreadyports!(node, ready_ports)
    # push outputs for each ready port
    push_buffer!(model, id)
    # Invalidate children
    if settings.invalidate_downstream
        children = get_children(model, id)
        for (op, c, ip) in children
            invalidate_downstream!(model, c)
        end
    end
    #
    setstatus!(node, :clean)
    return ready_ports # no probleb wit state because setstatus! copy ready_ports to state
end
"""
    execute_unsafe!(node::AbstractDataNode)
 
Low-level node execution interface.
 
This function contains node-specific execution logic. The default
implementation throws an error and must be specialized for every executable
node type.
 
Read inputs with [`getinputdata`](@ref), write results with
[`setdata!`](@ref) and return the vector of output port labels that were
produced. That vector is the contract with the engine: it is stored as the
`ready_ports` state and only connections leaving these ports are refreshed by
[`push_buffer!`](@ref). Returning a subset of the output ports is allowed.
 
# Example
```julia
struct Doubler <: AbstractNodeType end
 
function MetidaFlows.execute_unsafe!(node::DataNode{Doubler})
    x = getinputdata(node, :in)
    setdata!(node, :out, 2x)
    return [:out]
end
```
 
# Notes
Errors raised here are caught by [`execute!`](@ref), which marks the node
`:failed` and appends an `:error` record to `workflow.log`.
"""
function execute_unsafe!(node::AbstractDataNode)
    error("Node type undefined")
end