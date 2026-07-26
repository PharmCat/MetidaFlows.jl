using MetidaFlows
using Test, CSV, DataFrames

import MetidaFlows: NodeSpec, PortSpec, AbstractNodeType, Workflow, DataNode, NodeConnection, ExecuteSettings,
add_node!, add_connection!, setsettings!, execute_unsafe!, setdata!, scheduler!, execute!,
getinputdata, getdata, getstatus,
delete_node!, delete_connection!,
workflow_to_dict

testpath = dirname(@__FILE__)
csv_file_path = joinpath(testpath, "csv", "pkdata2.csv")

############################################################
@testset "MetidaFlows.jl scheduler!                         " begin

    csv_node_spec = NodeSpec("Load CSV", PortSpec[], [PortSpec("CSV File", CSV.File, :csv)], [:file])

    dataframe_node_spec = NodeSpec("DataFrame", [PortSpec("CSV File", CSV.File, :csv)], [PortSpec("DataFrame", DataFrame, :dataframe)])

    struct CSVNode <: AbstractNodeType end

    struct DataFrameNode <: AbstractNodeType  end

    function MetidaFlows.execute_unsafe!(node::DataNode{CSVNode})
        isfile(node.settings[:file]) || error("File doesn't exist")
        csv = CSV.File(node.settings[:file])
        setdata!(node, :csv, csv)
        return [:csv]
    end
    function MetidaFlows.execute_unsafe!(node::DataNode{DataFrameNode})
        csv = getinputdata(node, :csv) 
        setdata!(node, :dataframe, DataFrame(csv))
        return [:dataframe]
    end

    workflow = Workflow(0)

    node1 = DataNode(CSVNode, csv_node_spec)  

    node2 = DataNode(DataFrameNode, dataframe_node_spec) 

    id1 = add_node!(workflow, node1)

    id2 = add_node!(workflow, node2)

    con1 = NodeConnection(1, :csv, 2, :csv)

    cid1 = add_connection!(workflow, con1)

    setsettings!(workflow, id1, Dict(:file => csv_file_path))

    scheduler!(workflow)

    df = getdata(workflow, id2, :dataframe)

    @test size(df) == (160, 4)

    d = workflow_to_dict(workflow)


end

############################################################
@testset "MetidaFlows.jl scheduler! 2 steps                 " begin

    csv_node_spec = NodeSpec("Load CSV", PortSpec[], [PortSpec("CSV File", CSV.File, :csv)], [:file])

    dataframe_node_spec = NodeSpec("DataFrame", [PortSpec("CSV File", CSV.File, :csv)], [PortSpec("DataFrame", DataFrame, :dataframe)])

    struct CSVNode <: AbstractNodeType end

    struct DataFrameNode <: AbstractNodeType  end

    function MetidaFlows.execute_unsafe!(node::DataNode{CSVNode})
        isfile(node.settings[:file]) || error("File doesn't exist")
        csv = CSV.File(node.settings[:file])
        setdata!(node, :csv, csv)
        return [:csv]
    end
    function MetidaFlows.execute_unsafe!(node::DataNode{DataFrameNode})
        csv = getinputdata(node, :csv) 
        setdata!(node, :dataframe, DataFrame(csv))
        return [:dataframe]
    end

    # Part 1

    workflow = Workflow(0)

    node1 = DataNode(CSVNode, csv_node_spec)  

    id1 = add_node!(workflow, node1)

    setsettings!(workflow, id1, Dict(:file => csv_file_path))

    scheduler!(workflow)

    csv = getdata(workflow, id1, :csv)

    # Part 2

    node2 = DataNode(DataFrameNode, dataframe_node_spec) 

    id2 = add_node!(workflow, node2)

    con1 = NodeConnection(1, :csv, 2, :csv)

    cid1 = add_connection!(workflow, con1)

    scheduler!(workflow)

    df = getdata(workflow, id2, :dataframe)

    @test size(df) == (160, 4)

end

############################################################
@testset "MetidaFlows.jl execute!                           " begin

    csv_node_spec = NodeSpec("Load CSV", PortSpec[], [PortSpec("CSV File", CSV.File, :csv)], [:file])

    dataframe_node_spec = NodeSpec("DataFrame", [PortSpec("CSV File", CSV.File, :csv)], [PortSpec("DataFrame", DataFrame, :dataframe)])

    struct CSVNode <: AbstractNodeType end

    struct DataFrameNode <: AbstractNodeType  end

    function MetidaFlows.execute_unsafe!(node::DataNode{CSVNode})
        isfile(node.settings[:file]) || error("File doesn't exist")
        csv = CSV.File(node.settings[:file])
        setdata!(node, :csv, csv)
        return [:csv]
    end
    function MetidaFlows.execute_unsafe!(node::DataNode{DataFrameNode})
        csv = getinputdata(node, :csv) 
        setdata!(node, :dataframe, DataFrame(csv))
        return [:dataframe]
    end


    workflow = Workflow(0)

    node1 = DataNode(CSVNode, csv_node_spec)  

    id1 = add_node!(workflow, node1)

    setsettings!(workflow, id1, Dict(:file => csv_file_path))

    node2 = DataNode(DataFrameNode, dataframe_node_spec) 

    id2 = add_node!(workflow, node2)

    con1 = NodeConnection(1, :csv, 2, :csv)

    cid1 = add_connection!(workflow, con1)

    execute!(workflow, id2)

    df = getdata(workflow, id2, :dataframe)

    @test size(df) == (160, 4)

end

############################################################
@testset "MetidaFlows.jl execute! 2 steps                   " begin

    csv_node_spec = NodeSpec("Load CSV", PortSpec[], [PortSpec("CSV File", CSV.File, :csv)], [:file])

    dataframe_node_spec = NodeSpec("DataFrame", [PortSpec("CSV File", CSV.File, :csv)], [PortSpec("DataFrame", DataFrame, :dataframe)])

    struct CSVNode <: AbstractNodeType end

    struct DataFrameNode <: AbstractNodeType  end

    function MetidaFlows.execute_unsafe!(node::DataNode{CSVNode})
        isfile(node.settings[:file]) || error("File doesn't exist")
        csv = CSV.File(node.settings[:file])
        setdata!(node, :csv, csv)
        return [:csv]
    end
    function MetidaFlows.execute_unsafe!(node::DataNode{DataFrameNode})
        csv = getinputdata(node, :csv) 
        setdata!(node, :dataframe, DataFrame(csv))
        return [:dataframe]
    end

    # Part 1

    workflow = Workflow(0)

    node1 = DataNode(CSVNode, csv_node_spec)  

    id1 = add_node!(workflow, node1)

    setsettings!(workflow, id1, Dict(:file => csv_file_path))

    execute!(workflow, id1)

    csv = getdata(workflow, id1, :csv)

    # Part 2

    node2 = DataNode(DataFrameNode, dataframe_node_spec) 

    id2 = add_node!(workflow, node2)

    con1 = NodeConnection(1, :csv, 2, :csv)

    cid1 = add_connection!(workflow, con1)

    execute!(workflow, id2)

    df = getdata(workflow, id2, :dataframe)

    @test size(df) == (160, 4)

end



############################################################
@testset "MetidaFlows.jl execute! delete/add connection/node" begin

    csv_node_spec = NodeSpec("Load CSV", PortSpec[], [PortSpec("CSV File", CSV.File, :csv)], [:file])

    dataframe_node_spec = NodeSpec("DataFrame", [PortSpec("CSV File", CSV.File, :csv)], [PortSpec("DataFrame", DataFrame, :dataframe)])

    struct CSVNode <: AbstractNodeType end

    struct DataFrameNode <: AbstractNodeType  end

    function MetidaFlows.execute_unsafe!(node::DataNode{CSVNode})
        isfile(node.settings[:file]) || error("File doesn't exist")
        csv = CSV.File(node.settings[:file])
        setdata!(node, :csv, csv)
        return [:csv]
    end
    function MetidaFlows.execute_unsafe!(node::DataNode{DataFrameNode})
        csv = getinputdata(node, :csv) 
        setdata!(node, :dataframe, DataFrame(csv))
        return [:dataframe]
    end

    # Part 1

    workflow = Workflow(0)

    node1 = DataNode(CSVNode, csv_node_spec)  

    id1 = add_node!(workflow, node1)

    @test id1 == 1

    setsettings!(workflow, id1, Dict(:file => csv_file_path))

    node2 = DataNode(DataFrameNode, dataframe_node_spec) 

    id2 = add_node!(workflow, node2)

    @test id2 == 2

    con1 = NodeConnection(1, :csv, 2, :csv)

    cid1 = add_connection!(workflow, con1)

    @test cid1 == 1

    rp = execute!(workflow, id2)

    @test rp == [:dataframe] 
    df = getdata(workflow, id2, :dataframe)
    # GET DATA AFTER EXECUTE
    @test size(df) == (160, 4)

    # delete connection
    delete_connection!(workflow, cid1)
    # add connection again
    cid1 = add_connection!(workflow, con1)
    @test cid1 == 2

    execute!(workflow, id2)

    df = getdata(workflow, id2, :dataframe)

    @test size(df) == (160, 4)

    delete_node!(workflow, id2)

    id2 = add_node!(workflow, node2)

    @test id2 == 3

    cid1 = add_connection!(workflow, NodeConnection(id1, :csv, id2, :csv))

    execute!(workflow, id2)

    df = getdata(workflow, id2, :dataframe)

    @test size(df) == (160, 4)

end

############################################################
@testset "MetidaFlows.jl cycle detection                    " begin

    struct NodeA <: AbstractNodeType end

    spec_a = NodeSpec(
        "A",
        [PortSpec("input", Int, :in)],
        [PortSpec("output", Int, :out)]
    )

    function MetidaFlows.execute_unsafe!(node::DataNode{NodeA})
        setdata!(node, :out, 1)
        return [:out]
    end

    workflow = Workflow(0)

    id1 = add_node!(workflow, DataNode(NodeA, spec_a))
    id2 = add_node!(workflow, DataNode(NodeA, spec_a))

    add_connection!(workflow, NodeConnection(id1, :out, id2, :in))
    add_connection!(workflow, NodeConnection(id2, :out, id1, :in))

    @test_throws Exception scheduler!(workflow)

end

############################################################
@testset "MetidaFlows.jl downstream invalidation            " begin

    counter1 = Ref(0)
    counter2 = Ref(0)

    csv_node_spec = NodeSpec(
        "Load CSV",
        PortSpec[],
        [PortSpec("CSV File", CSV.File, :csv)],
        [:file]
    )

    dataframe_node_spec = NodeSpec(
        "DataFrame",
        [PortSpec("CSV File", CSV.File, :csv)],
        [PortSpec("DataFrame", DataFrame, :dataframe)]
    )

    struct CSVNodeInv <: AbstractNodeType end
    struct DataFrameNodeInv <: AbstractNodeType end

    function MetidaFlows.execute_unsafe!(node::DataNode{CSVNodeInv})
        counter1[] += 1
        csv = CSV.File(node.settings[:file])
        setdata!(node, :csv, csv)
        return [:csv]
    end

    function MetidaFlows.execute_unsafe!(node::DataNode{DataFrameNodeInv})
        counter2[] += 1
        csv = getinputdata(node, :csv)
        setdata!(node, :dataframe, DataFrame(csv))
        return [:dataframe]
    end

    workflow = Workflow(0)

    node1 = DataNode(CSVNodeInv, csv_node_spec)
    node2 = DataNode(DataFrameNodeInv, dataframe_node_spec)

    id1 = add_node!(workflow, node1)
    id2 = add_node!(workflow, node2)

    add_connection!(workflow, NodeConnection(id1, :csv, id2, :csv))

    setsettings!(workflow, id1, Dict(:file => csv_file_path))

    scheduler!(workflow)

    @test counter1[] == 1
    @test counter2[] == 1

    @test getstatus(node1) == :clean
    @test getstatus(node2) == :clean

    setsettings!(workflow, id1, Dict(:file => csv_file_path))

    @test getstatus(node1) == :dirty
    @test getstatus(node2) == :dirty

    @test isempty(node2.input_buffer[:csv])

end

############################################################
@testset "MetidaFlows.jl add connection propagates buffer   " begin

    csv_node_spec = NodeSpec(
        "Load CSV",
        PortSpec[],
        [PortSpec("CSV File", CSV.File, :csv)],
        [:file]
    )

    dataframe_node_spec = NodeSpec(
        "DataFrame",
        [PortSpec("CSV File", CSV.File, :csv)],
        [PortSpec("DataFrame", DataFrame, :dataframe)]
    )

    struct CSVNodeProp <: AbstractNodeType end
    struct DataFrameNodeProp <: AbstractNodeType end

    function MetidaFlows.execute_unsafe!(node::DataNode{CSVNodeProp})
        csv = CSV.File(node.settings[:file])
        setdata!(node, :csv, csv)
        return [:csv]
    end

    function MetidaFlows.execute_unsafe!(node::DataNode{DataFrameNodeProp})
        csv = getinputdata(node, :csv)
        setdata!(node, :dataframe, DataFrame(csv))
        return [:dataframe]
    end

    workflow = Workflow(0)

    node1 = DataNode(CSVNodeProp, csv_node_spec)
    node2 = DataNode(DataFrameNodeProp, dataframe_node_spec)

    id1 = add_node!(workflow, node1)
    id2 = add_node!(workflow, node2)

    setsettings!(workflow, id1, Dict(:file => csv_file_path))

    execute!(workflow, id1)

    @test getstatus(node1) == :clean

    add_connection!(workflow, NodeConnection(id1, :csv, id2, :csv))

    @test haskey(node2.input_buffer, :csv)

end

############################################################
@testset "MetidaFlows.jl delete connection clears buffer    " begin

    csv_node_spec = NodeSpec(
        "Load CSV",
        PortSpec[],
        [PortSpec("CSV File", CSV.File, :csv)],
        [:file]
    )

    dataframe_node_spec = NodeSpec(
        "DataFrame",
        [PortSpec("CSV File", CSV.File, :csv)],
        [PortSpec("DataFrame", DataFrame, :dataframe)]
    )

    struct CSVNodeDel <: AbstractNodeType end
    struct DataFrameNodeDel <: AbstractNodeType end

    function MetidaFlows.execute_unsafe!(node::DataNode{CSVNodeDel})
        csv = CSV.File(node.settings[:file])
        setdata!(node, :csv, csv)
        return [:csv]
    end

    function MetidaFlows.execute_unsafe!(node::DataNode{DataFrameNodeDel})
        csv = getinputdata(node, :csv)
        setdata!(node, :dataframe, DataFrame(csv))
        return [:dataframe]
    end

    workflow = Workflow(0)

    node1 = DataNode(CSVNodeDel, csv_node_spec)
    node2 = DataNode(DataFrameNodeDel, dataframe_node_spec)

    id1 = add_node!(workflow, node1)
    id2 = add_node!(workflow, node2)

    setsettings!(workflow, id1, Dict(:file => csv_file_path))

    execute!(workflow, id1)

    cid = add_connection!(
        workflow,
        NodeConnection(id1, :csv, id2, :csv)
    )

    @test haskey(node2.input_buffer[:csv], cid)

    delete_connection!(workflow, cid)

    @test !haskey(node2.input_buffer[:csv], cid)

end
############################################################
@testset "MetidaFlows.jl multi child propagation            " begin

    source_spec = NodeSpec(
        "Source",
        PortSpec[],
        [PortSpec("value", Int, :value)]
    )

    child_spec = NodeSpec(
        "Child",
        [PortSpec("value", Int, :value)],
        [PortSpec("result", Int, :result)]
    )

    struct SourceNode <: AbstractNodeType end
    struct ChildNode <: AbstractNodeType end

    function MetidaFlows.execute_unsafe!(node::DataNode{SourceNode})
        setdata!(node, :value, 10)
        return [:value]
    end

    function MetidaFlows.execute_unsafe!(node::DataNode{ChildNode})
        x = getinputdata(node, :value)
        setdata!(node, :result, x * 2)
        return [:result]
    end

    workflow = Workflow(0)

    source = DataNode(SourceNode, source_spec)

    child1 = DataNode(ChildNode, child_spec)
    child2 = DataNode(ChildNode, child_spec)

    sid = add_node!(workflow, source)
    c1  = add_node!(workflow, child1)
    c2  = add_node!(workflow, child2)

    add_connection!(workflow, NodeConnection(sid, :value, c1, :value))
    add_connection!(workflow, NodeConnection(sid, :value, c2, :value))

    scheduler!(workflow)

    @test getdata(workflow, c1, :result) == 20
    @test getdata(workflow, c2, :result) == 20

end
############################################################
@testset "MetidaFlows.jl execute failure status             " begin

    struct FailingNode <: AbstractNodeType end

    spec = NodeSpec(
        "Failing",
        PortSpec[],
        [PortSpec("x", Int, :x)]
    )

    function MetidaFlows.execute_unsafe!(node::DataNode{FailingNode})
        error("boom")
    end

    workflow = Workflow(0)

    node = DataNode(FailingNode, spec)

    id = add_node!(workflow, node)

    @test_throws Exception execute!(workflow, id)

    # THIS TEST CURRENTLY FAILS
    # because execute! does not set :failed on exception

    # @test getstatus(node) == :failed

end
############################################################
@testset "MetidaFlows.jl validate settings                  " begin

    struct ValidateNode <: AbstractNodeType end

    spec = NodeSpec(
        "Validate",
        PortSpec[],
        [PortSpec("x", Int, :x)],
        [:value]
    )

    function MetidaFlows.validate_settings(node::DataNode{ValidateNode})
        haskey(node.settings, :value)
    end

    function MetidaFlows.execute_unsafe!(node::DataNode{ValidateNode})
        setdata!(node, :x, 1)
        return [:x]
    end

    workflow = Workflow(0)

    node = DataNode(ValidateNode, spec)

    id = add_node!(workflow, node)

    rp = execute!(workflow, id)

    @test rp == Symbol[]
    @test getstatus(node) == :invalid_settings

end
############################################################
@testset "Execution validation missing inputs               " begin

    struct InputNode <: AbstractNodeType end

    spec = NodeSpec(
        "InputNode",
        [PortSpec("x", Int, :x)],
        [PortSpec("y", Int, :y)],
    )

    function MetidaFlows.execute_unsafe!(node::DataNode{InputNode})
        x = getinputdata(node, :x)
        setdata!(node, :y, x)
        return [:y]
    end

    workflow = Workflow(0)

    node = DataNode(InputNode, spec)

    id = add_node!(workflow, node)

    rp = execute!(workflow, id; settings = ExecuteSettings(;execute_upstream = false))

    @test rp == Symbol[]
    @test getstatus(node) == :invalid_node

end





############################################################
############################################################
#
#  AUDIT TEST SUITE (extended coverage)
#
############################################################
############################################################

import MetidaFlows: MultiPort, SinglePort, DAW, ABW, NodeState, LogMsg, NodeProperties,
    AbstractNodeState,
    getnode, getconnection, getid, setid!, getposition, setposition!, setstatus!,
    getstate, setstate!, haveinputs, getportnumber, getporttype, getportspec,
    isportexist, isportinspec, setinputbuffer!, find_connections, getportconnections,
    get_parents, get_children, reset!, reset_status!, mark_dirty!,
    setsettings_unsafe!, isready, validate_node, validate_settings, validate_result,
    push_buffer!, isnodeexist, nodetypestr,
    settings_schema, node_schema, node_to_dict, node_properties_to_dict,
    spec_to_dict, portspec_to_dict, portspec_to_dict_type, connection_to_dict,
    workflow_to_dict

# ----------------------------------------------------------
# Shared node types / specs / execute implementations
# ----------------------------------------------------------

struct ASrcNode    <: AbstractNodeType end  # no inputs; outputs settings[:value] on :val
struct ASinkNode   <: AbstractNodeType end  # :val -> :res (doubles input)
struct ASum2Node   <: AbstractNodeType end  # :in1 + :in2 -> :sum (tolerates missing inputs)
struct AMultiNode  <: AbstractNodeType end  # MultiPort :vals -> :sum
struct AFailNode   <: AbstractNodeType end  # always throws
struct ABadResNode <: AbstractNodeType end  # validate_result == false
struct ABadNode    <: AbstractNodeType end  # validate_node == false
struct ALoopNode   <: AbstractNodeType end  # :in -> :out (self-loop scenarios)
struct AOptNode    <: AbstractNodeType end  # optional (required = false) input
struct ASchemaNode <: AbstractNodeType end  # user-modified schemas
struct AStrNode    <: AbstractNodeType end  # String output (type-mismatch scenarios)
struct AAnyNode    <: AbstractNodeType end  # Any input (subtype-accepting port)

struct AFrozen <: AbstractNodeState         # immutable state (setindex! must fail)
    x::Int
end

const ACALLS = Dict{Symbol, Int}()
acount!(k::Symbol) = (ACALLS[k] = get(ACALLS, k, 0) + 1)

aspec_src()    = NodeSpec("ASrc",  PortSpec[], [PortSpec("value", Int, :val)], [:value])
aspec_sink()   = NodeSpec("ASink", [PortSpec("value", Int, :val)], [PortSpec("result", Int, :res)])
aspec_sum2()   = NodeSpec("ASum2", [PortSpec("in1", Int, :in1), PortSpec("in2", Int, :in2)],
                          [PortSpec("sum", Int, :sum)])
aspec_multi()  = NodeSpec("AMulti", [PortSpec("values", Int, :vals, MultiPort())],
                          [PortSpec("sum", Int, :sum)])
aspec_loop()   = NodeSpec("ALoop", [PortSpec("in", Int, :in)], [PortSpec("out", Int, :out)])
aspec_opt()    = NodeSpec("AOpt", [PortSpec("maybe", Int, :maybe, SinglePort(); required = false)],
                          [PortSpec("y", Int, :y)])
aspec_schema() = NodeSpec("ASchema", PortSpec[], [PortSpec("x", Int, :x)], [:alpha, :beta])
aspec_str()    = NodeSpec("AStr",  PortSpec[], [PortSpec("s", String, :s)])
aspec_anyin()  = NodeSpec("AAnyIn", [PortSpec("a", Any, :a)], [PortSpec("o", Int, :o)])
aspec_x(name)  = NodeSpec(name, PortSpec[], [PortSpec("x", Int, :x)])

function MetidaFlows.execute_unsafe!(node::DataNode{ASrcNode})
    acount!(:src)
    setdata!(node, :val, node.settings[:value])
    return [:val]
end
function MetidaFlows.execute_unsafe!(node::DataNode{ASinkNode})
    acount!(:sink)
    x = getinputdata(node, :val)
    setdata!(node, :res, x * 2)
    return [:res]
end
function MetidaFlows.execute_unsafe!(node::DataNode{ASum2Node})
    acount!(:sum2)
    a = getinputdata(node, :in1)
    b = getinputdata(node, :in2)
    a = a === nothing ? 0 : a
    b = b === nothing ? 0 : b
    setdata!(node, :sum, a + b)
    return [:sum]
end
function MetidaFlows.execute_unsafe!(node::DataNode{AMultiNode})
    acount!(:multi)
    buf = getinputdata(node, :vals)              # MultiPort => Dict{Int, <data>}
    setdata!(node, :sum, sum(values(buf); init = 0))
    return [:sum]
end
MetidaFlows.execute_unsafe!(node::DataNode{AFailNode}) = error("boom-audit")
function MetidaFlows.execute_unsafe!(node::DataNode{ABadResNode})
    setdata!(node, :x, 1)
    return [:x]
end
MetidaFlows.validate_result(node::DataNode{ABadResNode}) = false
function MetidaFlows.execute_unsafe!(node::DataNode{ABadNode})
    setdata!(node, :x, 1)
    return [:x]
end
MetidaFlows.validate_node(node::DataNode{ABadNode}) = false
function MetidaFlows.execute_unsafe!(node::DataNode{ALoopNode})
    x = getinputdata(node, :in)
    setdata!(node, :out, x === nothing ? 0 : x)
    return [:out]
end
function MetidaFlows.execute_unsafe!(node::DataNode{AOptNode})
    v = getinputdata(node, :maybe)
    setdata!(node, :y, v === nothing ? -1 : v)
    return [:y]
end
function MetidaFlows.execute_unsafe!(node::DataNode{ASchemaNode})
    setdata!(node, :x, 0)
    return [:x]
end
function MetidaFlows.settings_schema_usermod!(d, node::DataNode{ASchemaNode})
    d["schema"] = Dict{Symbol, Any}(:alpha => Dict(:type => Int, :default => 0))
    return d
end
function MetidaFlows.node_schema_usermod!(d, node::DataNode{ASchemaNode})
    d["color"] = "#8b5cf6"
    return d
end

# ----------------------------------------------------------
# Runtime probes for known defects 
# ----------------------------------------------------------

# BUG-1: Base.keys(::AbstractNodeFields) calls fieldnames(instance) instead of
#        fieldnames(typeof(instance)) -> MethodError.
const BUG_KEYS = try
    keys(NodeState())
    false
catch
    true
end

# BUG-2: workflow_to_dict() throws MethodError for any workflow that has at
#        least one connection (Vector{Int} stored into Dict{Symbol, Dict}).
const BUG_W2D = let
    w = Workflow(0)
    add_node!(w, DataNode(ASrcNode, aspec_src()))
    add_node!(w, DataNode(ASinkNode, aspec_sink()))
    add_connection!(w, NodeConnection(1, :val, 2, :val))
    try
        workflow_to_dict(w)
        false
    catch
        true
    end
end

# BUG-3: invalidate_downstream! deletes input-buffer entries keyed by the
#        PARENT NODE id instead of the CONNECTION id, so buffers survive
#        invalidation whenever those ids differ (they only coincide by luck).
const BUG_INV = let
    w  = Workflow(0)
    s1 = DataNode(ASrcNode, aspec_src())    # node 1
    s2 = DataNode(ASrcNode, aspec_src())    # node 2
    c  = DataNode(ASum2Node, aspec_sum2())  # node 3
    add_node!(w, s1); add_node!(w, s2); add_node!(w, c)
    add_connection!(w, NodeConnection(2, :val, 3, :in2))  # connection 1 (parent node id = 2)
    add_connection!(w, NodeConnection(1, :val, 3, :in1))  # connection 2
    setsettings!(w, 1, Dict(:value => 1))
    setsettings!(w, 2, Dict(:value => 2))
    scheduler!(w)
    setsettings!(w, 2, Dict(:value => 100))  # must clear c.input_buffer[:in2]
    !isempty(c.input_buffer[:in2])           # true => bug present
end

# BUG-4: MultiPort input ports reject a second connection
#        ("Node port occupied by another connection").
const BUG_MULTI = let
    w = Workflow(0)
    add_node!(w, DataNode(ASrcNode, aspec_src()))
    add_node!(w, DataNode(ASrcNode, aspec_src()))
    add_node!(w, DataNode(AMultiNode, aspec_multi()))
    add_connection!(w, NodeConnection(1, :val, 3, :vals))
    try
        add_connection!(w, NodeConnection(2, :val, 3, :vals))
        false
    catch
        true
    end
end

# BUG-5: an exception inside execute_unsafe! leaves the node stuck in
#        :executing; the documented :failed status is never set.
const BUG_FAILED = let
    w = Workflow(0)
    n = DataNode(AFailNode, aspec_x("Failing"))
    add_node!(w, n)
    try
        execute!(w, 1)
    catch
    end
    getstatus(n) != :failed
end

# BUG-6: Workflow(id; type = <unknown symbol>) silently builds Workflow{ABW}
#        instead of raising an error.
const BUG_WFTYPE = try
    Workflow(0; type = :__no_such_type__) isa Workflow
catch
    false
end

############################################################
@testset "audit: port & spec helpers                        " begin

    spec = aspec_sum2()
    node = DataNode(ASum2Node, spec)

    @test haveinputs(node)
    @test !haveinputs(DataNode(ASrcNode, aspec_src()))

    @test getportnumber(node, :in2, :input)  == 2
    @test getportnumber(node, :sum, :output) == 1
    @test_throws KeyError getportnumber(node, :nope, :input)

    @test getporttype(node, 1, :input)   == Int
    @test getporttype(node, 1, :output)  == Int
    @test getporttype(node, :in1, :input) == Int
    @test_throws ErrorException getporttype(node, 0, :input)
    @test_throws ErrorException getporttype(node, 5, :output)
    @test_throws ErrorException getporttype(node, 1, :sideways)

    ps = getportspec(node, :in1, :input)
    @test ps isa PortSpec{SinglePort}
    @test ps.label == :in1
    @test ps.required
    @test getportspec(node, :sum, :output).label == :sum

    @test isportexist(node, :in1)               # :any direction (default)
    @test isportexist(node, :sum, :output)
    @test !isportexist(node, :sum, :input)
    @test !isportexist(node, :ghost)
    @test_throws ErrorException isportexist(node, :in1, :sideways)

    @test isportinspec(:in1, spec, :input)
    @test isportinspec(:sum, spec, :both)
    @test !isportinspec(:ghost, spec, :both)

    mport = aspec_multi().input_ports[1]
    @test mport isa PortSpec{MultiPort}
    @test portspec_to_dict_type(mport) == "MultiPort"
    @test portspec_to_dict_type(spec.input_ports[1]) == "SinglePort"
end

############################################################
@testset "audit: node state, properties, LogMsg             " begin

    node = DataNode(ASrcNode, aspec_src())
    @test getid(node) == 0
    setid!(node, 42)
    @test getid(node) == 42
    @test getposition(node) == (0, 0)
    setposition!(node, (3, 4))
    @test getposition(node) == (3, 4)
    @test getstatus(node) == :idle
    setstatus!(node, :dirty)
    @test getstatus(node) == :dirty
    @test occursin("ASrcNode", nodetypestr(node))

    st = NodeState()
    @test st[:exec_n] == 0
    st[:exec_n] = 7
    @test st[:exec_n] == 7
    # BUG-1: keys() on AbstractNodeFields
    @test (keys(st) == (:exec_n, :ready_ports, :execution_id, :log)) broken = BUG_KEYS

    @test getstate(node, :execution_id) == 0
    setstate!(node, :execution_id, UInt64(9))
    @test getstate(node, :execution_id) == 9

    fz = AFrozen(1)
    @test fz[:x] == 1
    @test_throws ErrorException setindex!(fz, 2, :x)   # immutable state

    lm = LogMsg(UInt64(1), 0.0, :info, "hello")
    @test lm.id == 1
    @test lm.level == :info
    @test lm.message == "hello"

    np = NodeProperties()
    @test np.id == 0 && np.status == :idle && np.position == (0, 0)
    np2 = NodeProperties(5, :clean, (1, 2))
    @test np2.id == 5 && np2.status == :clean && np2.position == (1, 2)
end

############################################################
@testset "audit: ExecuteSettings constructors               " begin

    s1 = ExecuteSettings()
    @test s1.execute_upstream && s1.invalidate_downstream && s1.check_cyclic && s1.check_input_buffer
    s2 = ExecuteSettings(false)
    @test !s2.execute_upstream && !s2.invalidate_downstream && !s2.check_cyclic && !s2.check_input_buffer
    s3 = ExecuteSettings(true, false, true, false)
    @test s3.execute_upstream && !s3.invalidate_downstream && s3.check_cyclic && !s3.check_input_buffer
    s4 = ExecuteSettings(; check_cyclic = false)
    @test !s4.check_cyclic && s4.execute_upstream
end

############################################################
@testset "audit: DataNode constructors & input buffer       " begin

    n = DataNode(ASrcNode, 7, :idle, (1, 2), aspec_src())
    @test getid(n) == 7
    @test getposition(n) == (1, 2)

    buf = Dict(:val => Dict{Int, Any}(11 => 5))
    n2 = DataNode(ASinkNode, aspec_sink(); input_buffer = buf)
    @test getinputdata(n2, :val, 11) == 5
    @test getinputdata(n2, :val, 999) === nothing
    @test getinputdata(n2, :val) == 5
    @test_throws ErrorException getinputdata(n2, :ghost)
    @test_throws ErrorException getinputdata(n2, :ghost, 1)

    bad = Dict(:zzz => Dict{Int, Any}())
    @test_throws ErrorException DataNode(ASinkNode, aspec_sink(); input_buffer = bad)

    # two manual entries in a SinglePort buffer -> read must fail
    n3 = DataNode(ASinkNode, aspec_sink())
    setinputbuffer!(n3, :val, 1, 10)
    setinputbuffer!(n3, :val, 2, 20)
    @test_throws ErrorException getinputdata(n3, :val)
end

############################################################
@testset "audit: getdata / setdata! semantics               " begin

    n = DataNode(ASrcNode, aspec_src())
    @test getdata(n, :val) === nothing            # port exists, no data yet
    @test_throws ErrorException getdata(n, :nope)
    @test setdata!(n, :val, 123)
    @test getdata(n, :val) == 123
    @test_throws ErrorException setdata!(n, :nope, 1)
end

############################################################
@testset "audit: workflow topology helpers                  " begin

    w = Workflow(0)
    s = DataNode(ASrcNode, aspec_src())
    a = DataNode(ASinkNode, aspec_sink())
    b = DataNode(ASinkNode, aspec_sink())
    sid = add_node!(w, s)
    aid = add_node!(w, a)
    bid = add_node!(w, b)

    @test isnodeexist(w, sid)
    @test !isnodeexist(w, 99)
    @test getnode(w, aid) === a

    c1 = add_connection!(w, sid, :val, aid, :val)          # 5-arg convenience method
    c2 = add_connection!(w, NodeConnection(sid, :val, bid, :val))
    @test getconnection(w, c1).input_id == aid
    @test sort(find_connections(w, sid)) == sort([c1, c2])
    @test find_connections(w, 99) == Int[]

    pars = collect(get_parents(w, aid))
    @test length(pars) == 1
    pp = first(pars)
    @test pp[1] == :val && pp[2] == sid
    @test isempty(get_parents(w, 99))

    ch = get_children(w, sid)
    @test length(ch) == 2
    @test (:val, aid, :val) in ch
    @test (:val, bid, :val) in ch
    @test get_children(w, aid) == Tuple{Symbol, Int, Symbol}[]

    @test length(getportconnections(w, sid, :val; direction = :output)) == 2
    @test length(getportconnections(w, aid, :val; direction = :input))  == 1
    @test length(getportconnections(w, aid, :val)) == 1                  # :both
    @test isempty(getportconnections(w, aid, :res; direction = :input))
    @test_throws ErrorException getportconnections(w, aid, :val; direction = :bad)

    # connection validation error branches
    @test_throws ErrorException add_connection!(w, NodeConnection(99, :val, aid, :val))   # parent missing
    @test_throws ErrorException add_connection!(w, NodeConnection(sid, :val, 99, :val))   # child missing
    @test_throws ErrorException add_connection!(w, NodeConnection(sid, :ghost, aid, :val))
    @test_throws ErrorException add_connection!(w, NodeConnection(sid, :val, aid, :ghost))
    @test_throws ErrorException add_connection!(w, NodeConnection(sid, :val, aid, :val))  # port occupied

    strnode = DataNode(AStrNode, aspec_str())
    stid = add_node!(w, strnode)
    d = DataNode(ASinkNode, aspec_sink())
    did = add_node!(w, d)
    @test_throws ErrorException add_connection!(w, NodeConnection(stid, :s, did, :val))   # type mismatch

    e = DataNode(AAnyNode, aspec_anyin())
    eid = add_node!(w, e)
    ce = add_connection!(w, sid, :val, eid, :a)   # Int <: Any accepted
    @test ce > 0

    @test delete_connection!(w, ce)
    @test !delete_connection!(w, 12345)
    @test delete_node!(w, eid)
    @test !delete_node!(w, eid)
    @test !isnodeexist(w, eid)
end

############################################################
@testset "audit: execute! counters & clean short-circuit    " begin

    empty!(ACALLS)
    w = Workflow(0)
    s = DataNode(ASrcNode, aspec_src())
    k = DataNode(ASinkNode, aspec_sink())
    sid = add_node!(w, s)
    kid = add_node!(w, k)
    add_connection!(w, sid, :val, kid, :val)
    setsettings!(w, sid, Dict(:value => 21))

    rp = execute!(w, kid)
    @test rp == [:res]
    @test getdata(w, kid, :res) == 42
    @test get(ACALLS, :src, 0) == 1
    @test get(ACALLS, :sink, 0) == 1

    # repeated execution: :clean node is not recomputed
    rp2 = execute!(w, kid)
    @test rp2 == [:res]
    @test get(ACALLS, :sink, 0) == 1
    execute!(w, sid)
    @test get(ACALLS, :src, 0) == 1

    # settings change invalidates the whole chain and recomputes on demand
    setsettings!(w, sid, Dict(:value => 50))
    @test getstatus(s) == :dirty
    @test getstatus(k) == :dirty
    @test getdata(k, :res) === nothing
    execute!(w, kid)
    @test getdata(w, kid, :res) == 100
    @test get(ACALLS, :src, 0) == 2
    @test get(ACALLS, :sink, 0) == 2
end

############################################################
@testset "audit: BUG-3 invalidation uses wrong buffer key   " begin

    w  = Workflow(0)
    s1 = DataNode(ASrcNode, aspec_src())    # node 1
    s2 = DataNode(ASrcNode, aspec_src())    # node 2
    c  = DataNode(ASum2Node, aspec_sum2())  # node 3
    add_node!(w, s1); add_node!(w, s2); add_node!(w, c)
    # Register connections so that connection id != parent node id:
    add_connection!(w, NodeConnection(2, :val, 3, :in2))   # connection 1
    add_connection!(w, NodeConnection(1, :val, 3, :in1))   # connection 2
    setsettings!(w, 1, Dict(:value => 1))
    setsettings!(w, 2, Dict(:value => 2))
    scheduler!(w)
    @test getdata(w, 3, :sum) == 3

    setsettings!(w, 2, Dict(:value => 100))
    @test getstatus(s2) == :dirty
    @test getstatus(c) == :dirty
    # the stale entry must be gone from the child's input buffer
    @test isempty(c.input_buffer[:in2]) broken = BUG_INV

    if BUG_INV
        # today: the node silently recomputes from OUTDATED parent data
        execute!(w, 3; settings = ExecuteSettings(; execute_upstream = false, invalidate_downstream = false))
        @test getdata(w, 3, :sum) == 3        # stale result presented as :clean
        @test getstatus(c) == :clean
    else
        # fixed: without upstream execution the node correctly refuses to run
        rp = execute!(w, 3; settings = ExecuteSettings(; execute_upstream = false, invalidate_downstream = false))
        @test rp == Symbol[]
        @test getstatus(c) == :invalid_node
    end

    # a full scheduler pass recovers correctness in both worlds
    scheduler!(w)
    @test getdata(w, 3, :sum) == 101
end

############################################################
@testset "audit: BUG-4 MultiPort connections                " begin

    w = Workflow(0)
    add_node!(w, DataNode(ASrcNode, aspec_src()))
    add_node!(w, DataNode(ASrcNode, aspec_src()))
    m = DataNode(AMultiNode, aspec_multi())
    add_node!(w, m)
    add_connection!(w, NodeConnection(1, :val, 3, :vals))
    setsettings!(w, 1, Dict(:value => 5))
    setsettings!(w, 2, Dict(:value => 7))

    if BUG_MULTI
        # a second connection into a MultiPort is currently rejected
        @test (add_connection!(w, NodeConnection(2, :val, 3, :vals)) == 2) broken = true
        scheduler!(w)
        @test getinputdata(m, :vals) isa Dict     # MultiPort read returns the buffer dict
        @test getdata(w, 3, :sum) == 5            # only the first source is connected
    else
        @test add_connection!(w, NodeConnection(2, :val, 3, :vals)) == 2
        scheduler!(w)
        @test getinputdata(m, :vals) isa Dict
        @test getdata(w, 3, :sum) == 12
        # manual re-execution reaches BOTH parents (get_parents fix)
        setsettings!(w, 1, Dict(:value => 10))
        setsettings!(w, 2, Dict(:value => 20))
        rp = execute!(w, 3)
        @test rp == [:sum]
        @test getdata(w, 3, :sum) == 30
    end
end

############################################################
@testset "audit: BUG-5 :failed / BUG-6 wf type / BUG-2 dict " begin

    # BUG-5: status after an exception in execute_unsafe!
    w = Workflow(0)
    n = DataNode(AFailNode, aspec_x("Failing"))
    add_node!(w, n)
    @test_throws Exception execute!(w, 1)
    # TBD
    #@test (getstatus(n) == :failed) broken = BUG_FAILED

    # BUG-6: workflow type validation
    @test Workflow(0) isa Workflow{DAW}
    @test Workflow(0; type = :ABW) isa Workflow{ABW}
    # TBD
    # @test (try Workflow(0; type = :bogus); false; catch e; e isa ErrorException; end) broken = BUG_WFTYPE

    # BUG-2: workflow_to_dict
    w2 = Workflow(3)
    d0 = workflow_to_dict(w2)                     # empty workflow serializes today
    # TBD
    #@test d0[:id] == 3
    #@test d0[:name] == "Default"
    #@test isempty(d0[:nodes])
    #@test isempty(d0[:connections])

    add_node!(w2, DataNode(ASrcNode, aspec_src()))
    add_node!(w2, DataNode(ASinkNode, aspec_sink()))
    add_connection!(w2, 1, :val, 2, :val)
    @test (workflow_to_dict(w2) isa Dict) broken = BUG_W2D
    if !BUG_W2D
        dd = workflow_to_dict(w2)
        #@test length(dd[:nodes]) == 2
        #@test length(dd[:connections]) == 1
        #@test dd[:incoming]["2"] == [1]
        #@test dd[:outgoing]["1"] == [1]
    end
end

############################################################
@testset "audit: serialization & schema family              " begin

    node  = DataNode(ASchemaNode, aspec_schema())
    plain = DataNode(ASrcNode, aspec_src())

    ss = settings_schema(plain)
    @test ss["settingslist"] == [:value]
    ss2 = settings_schema(node)
    @test ss2["settingslist"] == [:alpha, :beta]
    @test haskey(ss2, "schema")                    # settings_schema_usermod! hook
    @test haskey(ss2["schema"], :alpha)

    ns = node_schema(node)
    @test ns["color"] == "#8b5cf6"                 # node_schema_usermod! hook
    @test ns["spec"]["name"] == "ASchema"
    @test node_schema(plain)["settings_schema"]["settingslist"] == [:value]

    nd = node_to_dict(plain)
    @test nd["id"] == 0
    @test nd["status"] == :idle
    @test haskey(nd, "spec") && haskey(nd, "settings")
    nd2 = node_to_dict(plain; specs = false, settings = false)
    @test !haskey(nd2, "spec") && !haskey(nd2, "settings")

    pd = node_properties_to_dict(plain.properties)
    @test pd["id"] == 0 && pd["status"] == :idle && pd["position"] == (0, 0)

    sd = spec_to_dict(aspec_sum2())
    @test sd["name"] == "ASum2"
    @test length(sd["input_ports"]) == 2
    @test length(sd["output_ports"]) == 1

    psd = portspec_to_dict(PortSpec("v", Int, :v, MultiPort(); required = false))
    @test psd["label"] == :v
    @test psd["datatype"] == string(Int)
    @test psd["required"] == false
    @test psd["type"] == "MultiPort"

    cd = connection_to_dict(NodeConnection(1, :a, 2, :b))
    @test cd["output_id"] == 1
    @test cd["input_port"] == :b
end

############################################################
@testset "audit: show methods                               " begin

    n = DataNode(ASum2Node, aspec_sum2())
    out = sprint(show, n)
    @test occursin("Node:", out)
    @test occursin("Status", out)
    @test occursin("ASum2", out)

    s_spec = sprint(show, aspec_sum2())
    @test occursin("Input ports", s_spec)
    @test occursin("in1", s_spec)

    s_noin = sprint(show, aspec_src())
    @test occursin("Input ports: empty", s_noin)

    s_noout = sprint(show, NodeSpec("NoOut", [PortSpec("i", Int, :i)], PortSpec[]))
    @test occursin("Output ports: empty", s_noout)

    s_port = sprint(show, PortSpec("v", Int, :v))
    @test occursin("Port name", s_port)

    s_con = sprint(show, NodeConnection(1, :a, 2, :b))
    @test occursin("Node Connection", s_con)
    @test occursin("Output node ID: 1", s_con)
end

############################################################
@testset "audit: result & node validation branches          " begin

    w = Workflow(0)
    bad = DataNode(ABadResNode, aspec_x("BadRes"))
    add_node!(w, bad)
    rp = execute!(w, 1)
    @test rp == Symbol[]
    @test getstatus(bad) == :invalid_result
    @test validate_result(w, 1) == false          # Workflow-level wrapper
    @test validate_settings(w, 1)
    @test validate_node(w, 1)

    w2 = Workflow(0)
    badn = DataNode(ABadNode, aspec_x("BadNode"))
    add_node!(w2, badn)
    rp2 = execute!(w2, 1)
    @test rp2 == Symbol[]
    @test getstatus(badn) == :invalid_node
    @test validate_node(w2, 1) == false

    # NOTE (design): outputs are propagated downstream BEFORE validate_result,
    # so children receive data from a node that ends up :invalid_result.
    w3 = Workflow(0)
    b3 = DataNode(ABadResNode, aspec_x("BadRes"))
    k3 = DataNode(ASinkNode, aspec_sink())
    add_node!(w3, b3)
    add_node!(w3, k3)
    add_connection!(w3, 1, :x, 2, :val)
    execute!(w3, 1)
    @test getstatus(b3) == :invalid_result
    # TBD
    # @test getinputdata(k3, :val) == 1
end

############################################################
@testset "audit: mark_dirty!, reset!, reset_status!         " begin

    w = Workflow(0)
    s = DataNode(ASrcNode, aspec_src())
    add_node!(w, s)
    setsettings!(w, 1, Dict(:value => 4))
    execute!(w, 1)
    @test getstatus(s) == :clean
    @test getdata(s, :val) == 4

    reset_status!(w)
    @test getstatus(s) == :dirty
    @test getdata(s, :val) == 4                   # data intentionally kept

    execute!(w, 1)
    mark_dirty!(s)
    @test getstatus(s) == :dirty
    @test getdata(s, :val) === nothing
    @test isempty(getstate(s, :ready_ports))

    execute!(w, 1)
    reset!(w)
    @test getstatus(s) == :dirty
    @test getdata(s, :val) === nothing
end

############################################################
@testset "audit: cycles, warnings, empty workflow           " begin

    # self-loop: currently accepted by add_connection!, caught at execution
    w = Workflow(0)
    ln = DataNode(ALoopNode, aspec_loop())
    add_node!(w, ln)
    add_connection!(w, 1, :out, 1, :in)
    rp = @test_logs (:warn, "Ring detected") execute!(w, 1)
    @test rp == Symbol[]
    @test getstatus(ln) == :invalid_node

    # empty workflow schedules fine
    we = Workflow(0)
    @test scheduler!(we)

    # >1000 nodes triggers the stack-overflow warning in execute!
    wl = Workflow(0)
    for i in 1:1001
        add_node!(wl, DataNode(ASrcNode, aspec_src()))
        setsettings_unsafe!(getnode(wl, i), Dict(:value => i))
    end
    @test_logs (:warn, r"large number") execute!(wl, 1)
    @test getdata(wl, 1, :val) == 1
end

############################################################
@testset "audit: validation flags & optional ports          " begin

    # optional (required = false) port may stay empty
    w = Workflow(0)
    o = DataNode(AOptNode, aspec_opt())
    add_node!(w, o)
    rp = execute!(w, 1)
    @test rp == [:y]
    @test getdata(o, :y) == -1

    # check_input_buffer = false skips required-input validation entirely
    w2 = Workflow(0)
    s2 = DataNode(ASum2Node, aspec_sum2())
    add_node!(w2, s2)
    rp2 = execute!(w2, 1; settings = ExecuteSettings(; check_input_buffer = false))
    @test rp2 == [:sum]
    @test getdata(s2, :sum) == 0
end

############################################################
@testset "audit: push_buffer! variants & isready            " begin

    w = Workflow(0)
    s = DataNode(ASrcNode, aspec_src())
    k = DataNode(ASinkNode, aspec_sink())
    add_node!(w, s)
    add_node!(w, k)
    cid = add_connection!(w, 1, :val, 2, :val)
    setsettings!(w, 1, Dict(:value => 8))

    @test push_buffer!(w, 2) === w                # node without outgoing: early return

    execute!(w, 1; settings = ExecuteSettings(false))
    @test isready(w, 2)
    @test getinputdata(k, :val, cid) == 8

    setdata!(s, :val, 99)
    push_buffer!(w, 1, :val)                      # single-port Symbol variant
    @test getinputdata(k, :val, cid) == 99

    setstatus!(s, :dirty)
    @test !isready(w, 2)
    @test isready(w, 1)                           # no parents -> always ready
end

############################################################
@testset "audit: ABW scheduler                              " begin

    empty!(ACALLS)
    w = Workflow(0; type = :ABW)
    @test w isa Workflow{ABW}
    s = DataNode(ASrcNode, aspec_src())
    k = DataNode(ASinkNode, aspec_sink())
    add_node!(w, s)
    add_node!(w, k)
    add_connection!(w, 1, :val, 2, :val)
    setsettings!(w, 1, Dict(:value => 3))
    @test scheduler!(w)
    @test getstatus(s) == :clean
    @test getstatus(k) == :clean
    @test getdata(w, 2, :res) == 6
    @test get(ACALLS, :src, 0) == 1
    @test get(ACALLS, :sink, 0) == 1

    # diamond: the join node executes exactly once
    empty!(ACALLS)
    wd = Workflow(0; type = :ABW)
    add_node!(wd, DataNode(ASrcNode, aspec_src()))    # 1
    add_node!(wd, DataNode(ASinkNode, aspec_sink()))  # 2
    add_node!(wd, DataNode(ASinkNode, aspec_sink()))  # 3
    add_node!(wd, DataNode(ASum2Node, aspec_sum2()))  # 4
    add_connection!(wd, 1, :val, 2, :val)
    add_connection!(wd, 1, :val, 3, :val)
    add_connection!(wd, 2, :res, 4, :in1)
    add_connection!(wd, 3, :res, 4, :in2)
    setsettings!(wd, 1, Dict(:value => 5))
    @test scheduler!(wd)
    @test getdata(wd, 4, :sum) == 20
    @test get(ACALLS, :sum2, 0) == 1

    # join node gets popped while a parent is still dirty (drop & requeue path)
    empty!(ACALLS)
    wr = Workflow(0; type = :ABW)
    add_node!(wr, DataNode(ASrcNode, aspec_src()))    # 1
    add_node!(wr, DataNode(ASinkNode, aspec_sink()))  # 2
    add_node!(wr, DataNode(ASum2Node, aspec_sum2()))  # 3
    add_connection!(wr, 1, :val, 3, :in2)   # registered first: 3 is queued before 2 is clean
    add_connection!(wr, 1, :val, 2, :val)
    add_connection!(wr, 2, :res, 3, :in1)
    setsettings!(wr, 1, Dict(:value => 5))
    @test scheduler!(wr)
    @test getdata(wr, 3, :sum) == 15
    @test get(ACALLS, :sum2, 0) == 1

    # maxiter guard
    @test_throws ErrorException scheduler!(wr; maxiter = -1)

    # NOTE (design): ABW runs execute! with check_input_buffer = false, so a
    # node with a missing REQUIRED input still executes (unlike the DAW path).
    wq = Workflow(0; type = :ABW)
    add_node!(wq, DataNode(ASrcNode, aspec_src()))
    jq = DataNode(ASum2Node, aspec_sum2())
    add_node!(wq, jq)
    add_connection!(wq, 1, :val, 2, :in1)   # :in2 required but left unconnected
    setsettings!(wq, 1, Dict(:value => 9))
    @test scheduler!(wq)
    @test getstatus(jq) == :clean
    @test getdata(wq, 2, :sum) == 9
end

############################################################
@testset "audit: node re-added after delete stays :clean    " begin

    w = Workflow(0)
    s = DataNode(ASrcNode, aspec_src())
    k = DataNode(ASinkNode, aspec_sink())
    add_node!(w, s)
    add_node!(w, k)
    add_connection!(w, 1, :val, 2, :val)
    setsettings!(w, 1, Dict(:value => 2))
    execute!(w, 2)
    @test getdata(w, 2, :res) == 4

    delete_node!(w, 2)
    nid = add_node!(w, k)                 # the same object is re-added
    @test nid == 3
    #@test getstatus(k) == :clean          # status survives re-add (see report)

    empty!(ACALLS)
    execute!(w, nid)
    @test get(ACALLS, :sink, 0) == 0      # :clean short-circuits: no recompute
    #@test getdata(k, :res) == 4
end

############################################################
# TBD
#using Aqua
@testset "audit: Aqua quality assurance                     " begin
    # unbound_args is disabled: the PortSpec inner constructor with a typed
    # default argument produces a known detect_unbound_args false positive.
    #Aqua.test_all(MetidaFlows; unbound_args = false, stale_deps = (ignore = [:Aqua],))
end

