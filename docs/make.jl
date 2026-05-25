using MetidaFlows
using Documenter

DocMeta.setdocmeta!(MetidaFlows, :DocTestSetup, :(using MetidaFlows); recursive=true)

makedocs(;
    modules=[MetidaFlows],
    authors="Vladimir Arnautov",
    sitename="MetidaFlows.jl",
    format=Documenter.HTML(;
        canonical="https://PharmCat.github.io/MetidaFlows.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/PharmCat/MetidaFlows.jl",
    devbranch="main",
)
