#  Отрисовка графа workflow для документации: GraphPlot + Compose.
#
#  Подключается из примеров так:
#      include(joinpath(pkgdir(MetidaFlows), "docs", "plotgraph.jl"))
#      plotworkflow(w)
#
#  Весь раздел «Drawing a workflow» в guide.md описывает именно этот файл,
#  поэтому правки здесь и там идут вместе.

using GraphPlot, Compose
import MetidaFlows: Workflow, getnode, getstatus, getportspec
#  Через псевдоним, а не import: имена src/dst/nv/edges слишком общие, чтобы
#  вносить их в модуль пользователя. В примерах документации `src` — это
#  вектор, и импорт молча уводил вызовы не туда.
const G = MetidaFlows.NamedGraphs.Graphs

"Node fill by execution status."
const STATUS_COLOR = Dict(
    :idle             => "#cfd8dc",
    :dirty            => "#ffd54f",
    :clean            => "#81c784",
    :executing        => "#64b5f6",
    :failed           => "#e57373",
    :invalid_node     => "#ce93d8",
    :invalid_settings => "#ce93d8",
    :invalid_result   => "#ce93d8",
)

"Edge stroke by the kind of the input port it enters."
const EDGE_COLOR = Dict(
    :normal   => "#78909c",
    :feedback => "#ef6c00",
    :error    => "#c62828",
    :terminal => "#b0bec5",
)

"""
    to_simple(w) -> (g, ids, pos, kinds)

The workflow's graph as a `SimpleDiGraph`, the node ids in vertex order, and
the kind of every edge. GraphPlot cannot draw the `NamedDiGraph` that
[`makegraph`](@ref) returns, and the mapping is needed anyway to line labels
and colours up with vertices.
"""
function to_simple(w::Workflow)
    ids = sort!(collect(keys(w.nodes)))
    pos = Dict(id => i for (i, id) in enumerate(ids))
    g = G.SimpleDiGraph(length(ids))
    kinds = Dict{Tuple{Int, Int}, Symbol}()
    for (_, c) in w.connections
        s, d = pos[c.output_id], pos[c.input_id]
        G.add_edge!(g, s, d)
        k = getportspec(getnode(w, c.input_id), c.input_port, :input).kind
        #  две связи между той же парой узлов — одно ребро; оттенок берём у
        #  более приметной, иначе обратное ребро потеряется под обычным
        prev = get(kinds, (s, d), :normal)
        kinds[(s, d)] = (k == :normal && prev != :normal) ? prev : k
    end
    (g = g, ids = ids, pos = pos, kinds = kinds)
end

"""
    layered_xy(s) -> (x, y)

Left-to-right layered layout: a node's layer is the longest path to it, and
within a layer nodes are ordered by the mean position of their parents.

Layers are computed over the `:normal` edges only. A `:feedback` edge is what
closes a cycle, so counting it would mean no layering exists at all; left out,
every workflow - cyclic or not - gets the same left-to-right reading, and the
feedback edge is visible as the one arc that goes back.
"""
function layered_xy(s)
    g, kinds = s.g, s.kinds
    forward = [(G.src(e), G.dst(e)) for e in G.edges(g)
               if get(kinds, (G.src(e), G.dst(e)), :normal) !== :feedback && G.src(e) != G.dst(e)]
    layer = zeros(Int, G.nv(g))
    for _ in 1:G.nv(g)
        moved = false
        for (u, v) in forward
            if layer[v] < layer[u] + 1
                layer[v] = layer[u] + 1; moved = true
            end
        end
        moved || break
    end
    #  Источники притягиваем вправо: узел без входов встаёт не в нулевой
    #  слой, а прямо перед первым своим потребителем. Иначе все константы
    #  графа сваливаются в один левый столбец, а рёбра от них тянутся через
    #  весь рисунок — на решётке расстояния Левенштейна это и было главной
    #  причиной пересечений.
    succs = Dict(v => Int[] for v in 1:G.nv(g))
    indeg = zeros(Int, G.nv(g))
    for (u, v) in forward; push!(succs[u], v); indeg[v] += 1; end
    for v in 1:G.nv(g)
        indeg[v] == 0 && !isempty(succs[v]) || continue
        layer[v] = minimum(layer[u] for u in succs[v]) - 1
    end
    shift = minimum(layer)
    shift < 0 && (layer .-= shift)

    byl = Dict{Int, Vector{Int}}()
    for v in 1:G.nv(g); push!(get!(byl, layer[v], Int[]), v); end
    maxl = maximum(keys(byl))
    order = Dict(l => sort(vs) for (l, vs) in byl)

    #  Барицентр: узел встаёт напротив середины своих предков. Два прохода
    #  слева направо убирают большую часть пересечений, и родственные узлы
    #  перестают расходиться по разным краям рисунка.
    parents = Dict(v => Int[] for v in 1:G.nv(g))
    for (u, v) in forward; push!(parents[v], u); end
    rank = Dict{Int, Float64}()
    for _ in 1:2
        for l in 0:maxl, (k, v) in enumerate(order[l]); rank[v] = float(k); end
        for l in 1:maxl
            vs = order[l]
            key = v -> isempty(parents[v]) ? float(length(vs)) / 2 :
                       sum(get(rank, u, 0.0) for u in parents[v]) / length(parents[v])
            order[l] = sort(vs; by = v -> (key(v), v))
        end
    end

    x = zeros(Float64, G.nv(g)); y = zeros(Float64, G.nv(g))
    widest = maximum(length, values(order))
    for l in 0:maxl
        vs = order[l]; n = length(vs)
        for (k, v) in enumerate(vs)
            x[v] = maxl == 0 ? 0.0 : 2l / maxl - 1
            y[v] = (widest - 1) / 2 - (k - 1) - (widest - n) / 2
        end
    end
    (x, y)
end

_countmap(v) = (d = Dict{eltype(v), Int}(); for x in v; d[x] = get(d, x, 0) + 1; end; d)

"""
    plotsize(w) -> (width, height)

A canvas that fits the graph: width from the number of layers, height from the
widest one. The aspect is capped at 3:1 - on a flatter canvas Compose squeezes
the vertical offsets while keeping the nodes round, and the labels end up on
top of them.
"""
function plotsize(w::Workflow)
    x, _ = layered_xy(to_simple(w))
    nlayers = length(unique(round.(x; digits = 6)))
    widest  = maximum(values(_countmap(round.(x; digits = 6))))
    wd = clamp(7 + 3.0 * (nlayers - 1), 9, 30)
    ht = clamp(5 + 2.6 * (widest - 1), 6, 22)
    (wd * 1cm, max(ht, wd / 3) * 1cm)
end

"""
    WorkflowPlot

A drawing that renders as SVG and nothing else.

Compose offers both SVG and PNG, and the PNG path needs Cairo and Fontconfig -
two binary dependencies the documentation does not otherwise want. Offering
only SVG settles the choice, and vector output is the better one for a graph
anyway.
"""
struct WorkflowPlot
    ctx::Any
    size::Tuple{Any, Any}
    nodes::Int
    edges::Int
end
Base.show(io::IO, ::MIME"image/svg+xml", p::WorkflowPlot) = draw(SVG(io, p.size...), p.ctx)
Base.showable(::MIME"image/svg+xml", ::WorkflowPlot) = true
#  Короткое текстовое представление обязательно: без него печатается дамп
#  дерева Compose, и он уходит в поисковый индекс документации — 45 КиБ на
#  каждый рисунок.
Base.show(io::IO, p::WorkflowPlot) =
    print(io, "WorkflowPlot(", p.nodes, " nodes, ", p.edges, " edges)")
Base.show(io::IO, ::MIME"text/plain", p::WorkflowPlot) = show(io, p)

"""
    plotworkflow(w; label = :id_name, size = plotsize(w), nodesize = 1.0, pad = 10mm)

Draw a workflow: **node colour is its status**, **edge colour is the kind of
the input port it enters** (grey `:normal`, orange `:feedback`, red
`:error`), and the layout is layered left to right.

`label` is `:id_name` (default), `:id` or `:name` - use `:id` once the graph
has more than a dozen nodes.
"""
function plotworkflow(w::Workflow; label::Symbol = :id_name, size = plotsize(w),
                      nodesize::Real = 1.0, pad = 10mm)
    s = to_simple(w)
    ids = s.ids
    labels = label === :id   ? string.(ids) :
             label === :name ? [getnode(w, i).spec.name for i in ids] :
             ["$(i) $(getnode(w, i).spec.name)" for i in ids]
    fillc = [get(STATUS_COLOR, getstatus(w, i), "#cfd8dc") for i in ids]
    edgec = [get(EDGE_COLOR, get(s.kinds, (G.src(e), G.dst(e)), :normal), "#78909c")
             for e in G.edges(s.g)]
    x, y = layered_xy(s)
    #  Подпись ставится над узлом смещением по вертикали, а Compose тянет
    #  единичный квадрат на весь холст: на широком холсте вертикальные
    #  отступы сжимаются, круги же остаются круглыми, и подпись наезжает на
    #  узел. Компенсируем соотношением сторон.
    aspect = size[1].value / size[2].value
    labeldist = 2.2 * max(1.0, aspect)
    p = gplot(s.g, x, y;
              nodelabel = labels, nodefillc = fillc, edgestrokec = edgec,
              nodestrokec = "#37474f", nodestrokelw = 0.8,
              nodelabelsize = 1.2, nodelabeldist = labeldist, nodelabelangleoffset = π / 2,
              NODESIZE = nodesize * 0.25 / sqrt(G.nv(s.g)), EDGELINEWIDTH = 1.0,
              arrowlengthfrac = 0.08,
              #  Все рёбра дугами, а не только петли: GraphPlot раздаёт один и
              #  тот же вектор цветов прямым рёбрам и дугам, поэтому при
              #  линейных рёбрах петля красится цветом ПЕРВОГО ребра графа.
              linetype = "curve", outangle = π / 14,
              plot_size = size, pad = pad)
    #  Координаты растягиваются в [-1, 1] по каждой оси, а если все значения
    #  по оси равны — ставится 0.5 вместо 0. Для цепочки это сдвигает рисунок
    #  на четверть холста вниз; возвращаем на место.
    dx = allequal(x) ? -0.5 / 2.4 : 0.0
    dy = allequal(y) ? -0.5 / 2.4 : 0.0
    WorkflowPlot((dx == 0 && dy == 0) ? p : compose(context(dx, dy, 1, 1), p),
                 size, G.nv(s.g), G.ne(s.g))
end
