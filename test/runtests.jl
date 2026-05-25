using MetidaFlows
using Test, CSV, DataFrames

import MetidaFlows: NodeSpec, PortSpec, AbstractNodeType, Workflow, DataNode, NodeConnection, 
add_node!, add_connection!, setsettings!, execute_unsafe!, setdata!, scheduler!, execute!,
getinputdata, getdata,
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
