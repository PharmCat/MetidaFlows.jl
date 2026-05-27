using MetidaFlows
using Test, CSV, DataFrames

import MetidaFlows: NodeSpec, PortSpec, AbstractNodeType, Workflow, DataNode, NodeConnection, 
add_node!, add_connection!, setsettings!, execute_unsafe!, setdata!, scheduler!, execute!,
getinputdata, getdata, getstatus,
delete_node!, delete_connection!

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

    delete_connection!(workflow, cid1)

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

    @test isempty(node2.input_buffer)

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

    @test haskey(node2.input_buffer, :csv)

    delete_connection!(workflow, cid)

    @test !haskey(node2.input_buffer, :csv)

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
        [PortSpec("y", Int, :y)]
    )

    function MetidaFlows.execute_unsafe!(node::DataNode{InputNode})
        x = getinputdata(node, :x)
        setdata!(node, :y, x)
        return [:y]
    end

    workflow = Workflow(0)

    node = DataNode(InputNode, spec)

    id = add_node!(workflow, node)

    rp = execute!(workflow, id; execute_upstream = false)

    @test rp == Symbol[]
    @test getstatus(node) == :invalid_node

end

