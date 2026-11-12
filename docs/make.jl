using MetidaFlows
using Documenter

DocMeta.setdocmeta!(MetidaFlows, :DocTestSetup, :(using MetidaFlows); recursive=true)

makedocs(;
    modules=[MetidaFlows],
    authors="Vladimir Arnautov",
    sitename="MetidaFlows.jl",
    debug = true,
    format=Documenter.HTML(;
        canonical="https://PharmCat.github.io/MetidaFlows.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Guide" => [
            "User guide" => "guide.md",
            "Execution model" => "guide_execution.md",
            "Ports and cycles" => "guide_ports.md",
            "Serialization and schemas" => "guide_serialization.md",
            "Logs" => "guide_logs.md",
        ],
        "Typed containers" => "typed_containers.md",
        "Examples" => [
            "AWB cycle" => "examples_abw_cycle.md",
            "AWB two node cycle" => "examples_abw_two_node.md",
            "Querying settings" => "examples_settings_query.md",
            "Bubble sort as a graph" => "examples_bubble_sort.md",
            "Insertion sort: nested loops" => "examples_insertion_sort.md",
            "Gradient descent on a graph" => "examples_gradient_descent.md",
            "Newton's method and :error ports" => "examples_newton.md",
            "Horner's scheme on DAW" => "examples_horner.md",
            "Edit distance: dynamic programming" => "examples_edit_distance.md",
            "Interval arithmetic: metadata" => "examples_intervals.md",
            "Modular exponentiation: skipping work" => "examples_power.md",
        ],
        "API" => [
            "Overview" => "api.md",
            "Types" => "api_types.md",
            "Graph and nodes" => "api_core.md",
            "Reading and writing a node" => "api_access.md",
            "Execution" => "api_execution.md",
            "Port metadata" => "api_meta.md",
            "Serialization and schemas" => "api_serialization.md",
        ],
    ],
)

deploydocs(;
    repo="github.com/PharmCat/MetidaFlows.jl",
    devbranch="main",
)
