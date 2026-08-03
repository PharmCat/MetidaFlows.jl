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
        "Guide" => "guide.md",
        "Examples" => [
            "AWB cycle" => "examples_abw_cycle.md",
            "AWB two node cycle" => "examples_abw_two_node.md",
        ],
        "API" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/PharmCat/MetidaFlows.jl",
    devbranch="main",
)
