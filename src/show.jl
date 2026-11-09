# --------------------------------------------------------
# SHOW functions
# --------------------------------------------------------
function show(io::IO, n::AbstractDataNode)
    println(io, "Node:")
    println(io, "  ID: ", getid(n))
    println(io, "  Status: ", getstatus(n))
    println(io, "  spec:")
    println(io, n.spec)
    print(io, "  Settings:", n.settings)
end
#
function show(io::IO, n::NodeSpec)
    println(io, "     Name: ", n.name)
    print(io, "     Input ports: ")
    if length(n.input_ports) == 0 
        println(io, "empty")
    else
        println(io, "")
        for (i,p) in enumerate(n.input_ports)
            print(io, "        #$i ", p)
        end
    end
    print(io, "     Output ports: ",)
    if length(n.output_ports) == 0 
        println(io, "empty")
    else
        println(io, "")
        for (i,p) in enumerate(n.output_ports)
            print(io, "        #$i ", p)
        end
    end
    println(io, "     Available settings: ", n.settings)
end
#
function show(io::IO, n::PortSpec)
    println(io, "Port name: $(n.name); label: \"$(n.label)\"; datatype: $(n.datatype) ($(n.required ? "required" : "optional"), $(n.kind)).")
end
#
function show(io::IO, c::T) where T <: NodeConnection
    println(io, "Node Connection:")
    println(io, "  Output node ID: ", c.output_id, " (Output port: ", c.output_port , ")")
    print(io, "  Input node ID: ", c.input_id, " (Input port: ", c.input_port, ")")
end
# --------------------------------------------------------