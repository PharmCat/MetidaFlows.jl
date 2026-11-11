############################################################################
#
#  ЗООПАРК АЛГОРИТМОВ: РАССТОЯНИЕ ЛЕВЕНШТЕЙНА (ДИНАМИЧЕСКОЕ ПРОГРАММИРОВАНИЕ)
#
#
############################################################################

import MetidaFlows: PortSpec, MultiPort, SinglePort, DAW, ABW, getnode,
    getconnection, nodetypestr, getportspec, getid, makegraph, get_children,
    get_parents, isportexist, ismultiport, setinputbuffer!, reset!,
    ExecuteSettings

# --------------------------------------------------------------------------
#  Эталон: та же рекуррента обычным кодом. Ничьи разрешаются в том же
#  порядке, что в узле: diag, затем up, затем left.
# --------------------------------------------------------------------------

function edit_reference(a::AbstractString, b::AbstractString)
    A = collect(a); B = collect(b)
    m, n = length(A), length(B)
    dp = zeros(Int, m + 1, n + 1)
    ch = fill(:base, m + 1, n + 1)
    for i in 0:m; dp[i + 1, 1] = i; end
    for j in 0:n; dp[1, j + 1] = j; end
    for i in 1:m, j in 1:n
        c    = A[i] == B[j] ? 0 : 1
        diag = dp[i, j]     + c
        up   = dp[i, j + 1] + 1
        left = dp[i + 1, j] + 1
        best = min(diag, up, left)
        dp[i + 1, j + 1] = best
        ch[i + 1, j + 1] = diag == best ? :diag : (up == best ? :up : :left)
    end
    return (distance = dp[m + 1, n + 1], table = dp, choice = ch, m = m, n = n)
end

#  Наивная рекурсия с подсчётом вызовов — для сравнения объёма работы.
function edit_naive(a::AbstractString, b::AbstractString)
    A = collect(a); B = collect(b)
    calls = Ref(0)
    function go(i, j)
        calls[] += 1
        i == 0 && return j
        j == 0 && return i
        c = A[i] == B[j] ? 0 : 1
        return min(go(i - 1, j - 1) + c, go(i - 1, j) + 1, go(i, j - 1) + 1)
    end
    d = go(length(A), length(B))
    return (distance = d, calls = calls[])
end

# ==========================================================================
#  Элементарные узлы
# ==========================================================================

struct EdConst     <: AbstractNodeType end  # источник целой константы
struct EdChar      <: AbstractNodeType end  # источник символа
struct EdSubCost   <: AbstractNodeType end  # цена замены: 0 или 1
struct EdStep      <: AbstractNodeType end  # from + cost
struct EdCell      <: AbstractNodeType end  # минимум трёх и направление
struct EdCellMulti <: AbstractNodeType end  # то же на MultiPort

spec_edconst() = NodeSpec("Ed const", PortSpec[],
    [PortSpec("Out", Int, :out)], [:value])

spec_edchar() = NodeSpec("Ed char", PortSpec[],
    [PortSpec("Out", Char, :out)], [:value])

spec_edsubcost() = NodeSpec("Ed sub cost",
    [PortSpec("A", Char, :a), PortSpec("B", Char, :b)],
    [PortSpec("Out", Int, :out)])

spec_edstep() = NodeSpec("Ed step",
    [PortSpec("From", Int, :from), PortSpec("Cost", Int, :cost)],
    [PortSpec("Out", Int, :out)])

#  Три предшественника в РАЗНЫХ портах: только поэтому клетка может
#  сказать, какое направление выиграло.
spec_edcell() = NodeSpec("Ed cell",
    [PortSpec("Diag", Int, :diag),
     PortSpec("Up",   Int, :up),
     PortSpec("Left", Int, :left)],
    [PortSpec("Cost",   Int,    :cost),
     PortSpec("Choice", Symbol, :choice; kind = :terminal)])

spec_edcellmulti() = NodeSpec("Ed cell multi",
    [PortSpec("Options", Int, :options, MultiPort())],
    [PortSpec("Cost", Int, :cost)])

MetidaFlows.execute_unsafe!(n::DataNode{EdConst}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{EdChar}) =
    (setdata!(n, :out, Char(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{EdSubCost}) =
    (setdata!(n, :out, getinputdata(n, :a) == getinputdata(n, :b) ? 0 : 1); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{EdStep}) =
    (setdata!(n, :out, getinputdata(n, :from) + getinputdata(n, :cost)); [:out])

function MetidaFlows.execute_unsafe!(node::DataNode{EdCell})
    diag = getinputdata(node, :diag)
    up   = getinputdata(node, :up)
    left = getinputdata(node, :left)
    best = min(diag, up, left)
    setdata!(node, :cost, best)
    setdata!(node, :choice, diag == best ? :diag : (up == best ? :up : :left))
    return [:cost, :choice]
end

#  MultiPort отдаёт сырой Dict{номер связи => значение}. Минимум берётся,
#  направление сообщить нечем.
function MetidaFlows.execute_unsafe!(node::DataNode{EdCellMulti})
    opts = getinputdata(node, :options)
    setdata!(node, :cost, minimum(values(opts)))
    return [:cost]
end

# ==========================================================================
#  Сборка графа
# ==========================================================================

"""
    build_edit_distance(a, b) -> NamedTuple

Граф расстояния Левенштейна: таблица подзадач развёрнута в узлы.
Возвращает workflow, матрицу `cell[i+1, j+1] = (id, порт)` для `i in 0:m`,
`j in 0:n`, узлы цены замены и источники символов.
"""
function build_edit_distance(a::AbstractString, b::AbstractString)
    A = collect(a); B = collect(b)
    m, n   = length(A), length(B)
    w      = Workflow(0; type = :DAW)
    w.name = "Edit distance"

    one = add_node!(w, DataNode(EdConst, spec_edconst()))
    setsettings!(w, one, Dict(:value => 1))

    ca = Int[]
    for ch in A
        id = add_node!(w, DataNode(EdChar, spec_edchar()))
        setsettings!(w, id, Dict(:value => ch))
        push!(ca, id)
    end
    cb = Int[]
    for ch in B
        id = add_node!(w, DataNode(EdChar, spec_edchar()))
        setsettings!(w, id, Dict(:value => ch))
        push!(cb, id)
    end

    #  Граница: dp[0][j] = j, dp[i][0] = i — узлы-константы.
    cell = Matrix{Tuple{Int, Symbol}}(undef, m + 1, n + 1)
    for j in 0:n
        id = add_node!(w, DataNode(EdConst, spec_edconst()))
        setsettings!(w, id, Dict(:value => j))
        cell[1, j + 1] = (id, :out)
    end
    for i in 1:m
        id = add_node!(w, DataNode(EdConst, spec_edconst()))
        setsettings!(w, id, Dict(:value => i))
        cell[i + 1, 1] = (id, :out)
    end

    sub  = Matrix{Int}(undef, max(m, 0), max(n, 0))
    step = Matrix{NTuple{3, Int}}(undef, max(m, 0), max(n, 0))

    for i in 1:m, j in 1:n
        sc = add_node!(w, DataNode(EdSubCost, spec_edsubcost()))
        add_connection!(w, ca[i], :out, sc, :a)
        add_connection!(w, cb[j], :out, sc, :b)
        sub[i, j] = sc

        pid, pport = cell[i, j + 1]                    # dp[i-1][j]
        up = add_node!(w, DataNode(EdStep, spec_edstep()))
        add_connection!(w, pid, pport, up,  :from)
        add_connection!(w, one, :out,  up,  :cost)

        pid, pport = cell[i + 1, j]                    # dp[i][j-1]
        lf = add_node!(w, DataNode(EdStep, spec_edstep()))
        add_connection!(w, pid, pport, lf,  :from)
        add_connection!(w, one, :out,  lf,  :cost)

        pid, pport = cell[i, j]                        # dp[i-1][j-1]
        dg = add_node!(w, DataNode(EdStep, spec_edstep()))
        add_connection!(w, pid, pport, dg,  :from)
        add_connection!(w, sc,  :out,  dg,  :cost)

        c = add_node!(w, DataNode(EdCell, spec_edcell()))
        add_connection!(w, dg, :out, c, :diag)
        add_connection!(w, up, :out, c, :up)
        add_connection!(w, lf, :out, c, :left)

        step[i, j] = (up, lf, dg)
        cell[i + 1, j + 1] = (c, :cost)
    end

    return (w = w, m = m, n = n, cell = cell, sub = sub, step = step,
            ca = ca, cb = cb, one = one, answer = cell[m + 1, n + 1])
end

"Посчитать расстояние графом. Возвращает расстояние, таблицу и граф."
function graph_edit(a::AbstractString, b::AbstractString)
    g = build_edit_distance(a, b)
    scheduler!(g.w)
    table = [getdata(g.w, g.cell[i, j]...) for i in 1:(g.m + 1), j in 1:(g.n + 1)]
    return (distance = getdata(g.w, g.answer...), table = table, g = g)
end

"Обратный ход по опубликованным направлениям — цикл вызывающего."
function edit_traceback(g)
    i, j  = g.m, g.n
    path  = Symbol[]
    while i > 0 && j > 0
        ch = getdata(g.w, first(g.cell[i + 1, j + 1]), :choice)
        push!(path, ch)
        ch === :diag && (i -= 1; j -= 1)
        ch === :up   && (i -= 1)
        ch === :left && (j -= 1)
    end
    append!(path, fill(:up,   i))      # остаток первого столбца
    append!(path, fill(:left, j))      # остаток первой строки
    return path
end

# ==========================================================================

@testset verbose = true "РАССТОЯНИЕ ЛЕВЕНШТЕЙНА (ДП НА DAW)               " begin

# --------------------------------------------------------------------------
@testset "E1. элементарные узлы по отдельности             " begin
    function run1(type, spec, inputs::Dict{Symbol, Any}; settings = Dict{Symbol, Any}())
        node = DataNode(type, spec; settings = settings)
        for (port, value) in inputs
            setinputbuffer!(node, port, 1, value)
        end
        node, MetidaFlows.execute_unsafe!(node)
    end

    n, p = run1(EdConst, spec_edconst(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => 4))
    @test p == [:out] && getdata(n, :out) === 4

    n, _ = run1(EdChar, spec_edchar(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => 'k'))
    @test getdata(n, :out) === 'k'

    n, _ = run1(EdSubCost, spec_edsubcost(), Dict{Symbol, Any}(:a => 'k', :b => 'k'))
    @test getdata(n, :out) === 0
    n, _ = run1(EdSubCost, spec_edsubcost(), Dict{Symbol, Any}(:a => 'k', :b => 's'))
    @test getdata(n, :out) === 1

    n, _ = run1(EdStep, spec_edstep(), Dict{Symbol, Any}(:from => 3, :cost => 1))
    @test getdata(n, :out) === 4

    #  клетка: минимум и направление, ничьи в порядке diag, up, left
    cases = ((3, 4, 5, 3, :diag), (5, 3, 4, 3, :up), (5, 4, 3, 3, :left),
             (3, 3, 4, 3, :diag), (4, 3, 3, 3, :up), (2, 2, 2, 2, :diag))
    for (d, u, l, best, which) in cases
        n, p = run1(EdCell, spec_edcell(),
                    Dict{Symbol, Any}(:diag => d, :up => u, :left => l))
        @test p == [:cost, :choice]
        @test getdata(n, :cost) === best
        @test getdata(n, :choice) === which
    end
    #  :choice терминальный — его не подключают
    @test getportspec(DataNode(EdCell, spec_edcell()), :choice, :output).kind === :terminal
end

# --------------------------------------------------------------------------
@testset "E2. таблица подзадач — это множество узлов       " begin
    for (a, b) in (("", ""), ("a", ""), ("", "ab"), ("ab", "cd"),
                   ("kit", "sit"), ("kitten", "sitting"))
        g    = build_edit_distance(a, b)
        m, n = length(a), length(b)
        @test (g.m, g.n) == (m, n)
        #  5 узлов на внутреннюю клетку, граница константами, плюс
        #  источники символов и единица
        @test length(g.w.nodes) == 5m * n + 2m + 2n + 2
        @test g.w isa Workflow{DAW}
        #  клеток в таблице ровно (m+1)(n+1)
        @test length(g.cell) == (m + 1) * (n + 1)
        #  ни одного обратного порта: цикла в ДП нет
        @test isempty([p for (_, node) in g.w.nodes
                       for p in node.spec.input_ports if p.kind == :feedback])
    end

    #  Связи целиком внутри клеток: 2 на цену замены, по 2 на каждый из
    #  трёх шагов (from и cost) и 3 в саму клетку — 11 на клетку. У
    #  границы, символов и единицы входов нет.
    for (a, b) in (("", ""), ("a", ""), ("ab", "cd"), ("kit", "sit"),
                   ("kitten", "sitting"))
        g = build_edit_distance(a, b)
        @test length(g.w.connections) == 11 * length(a) * length(b)
    end

    #  ВЕЕР: внутренняя клетка кормит три шага следующих клеток
    g = build_edit_distance("abcd", "abcd")
    for i in 1:3, j in 1:3
        id = first(g.cell[i + 1, j + 1])
        @test length(get_children(g.w, id)) == 3
    end
    #  правый нижний угол не кормит никого
    @test isempty(get_children(g.w, first(g.answer)))

    #  источник символа кормит всю свою строку таблицы
    g = build_edit_distance("kit", "sit")
    @test length(get_children(g.w, g.ca[1])) == 3      # три цены замены
    @test length(get_children(g.w, g.cb[2])) == 3
end

# --------------------------------------------------------------------------
@testset "E3. расстояние совпадает с эталоном             " begin
    pairs = (("kitten", "sitting"), ("", ""), ("abc", ""), ("", "abc"),
             ("abc", "abc"), ("abc", "abd"), ("flaw", "lawn"),
             ("intention", "execution"), ("aa", "aaa"), ("sunday", "saturday"))
    for (a, b) in pairs
        r = graph_edit(a, b)
        @test r.distance == edit_reference(a, b).distance
    end

    #  канонические значения
    @test graph_edit("kitten", "sitting").distance == 3
    @test graph_edit("flaw", "lawn").distance == 2
    @test graph_edit("intention", "execution").distance == 5
    @test graph_edit("sunday", "saturday").distance == 3
    @test graph_edit("abc", "abc").distance == 0
    @test graph_edit("abc", "").distance == 3
end

# --------------------------------------------------------------------------
@testset "E4. вся таблица верна, не только ответ          " begin
    #  Платёж ДП: правильны ВСЕ подзадачи, и их видно поклеточно.
    for (a, b) in (("kitten", "sitting"), ("flaw", "lawn"), ("abc", "abd"))
        r   = graph_edit(a, b)
        ref = edit_reference(a, b)
        @test size(r.table) == size(ref.table)
        @test r.table == ref.table
        #  и направления тоже
        for i in 1:r.g.m, j in 1:r.g.n
            @test getdata(r.g.w, first(r.g.cell[i + 1, j + 1]), :choice) ===
                  ref.choice[i + 1, j + 1]
        end
    end
end

# --------------------------------------------------------------------------
@testset "E5. мемоизация структурна                       " begin
    r = graph_edit("kitten", "sitting")
    #  каждый узел посчитан РОВНО ОДИН РАЗ — это и есть мемоизация
    @test all(n -> n.state.exec_n == 1, values(r.g.w.nodes))
    @test all(n -> getstatus(n) === :clean, values(r.g.w.nodes))

    #  сравнение объёма работы с наивной рекурсией на том же входе
    for (a, b) in (("kit", "sit"), ("flaw", "lawn"), ("kitten", "sitting"))
        nv  = edit_naive(a, b)
        r2  = graph_edit(a, b)
        cells = (length(a) + 1) * (length(b) + 1)
        @test nv.distance == r2.distance
        @test cells < nv.calls                      # подзадач меньше, чем вызовов
        #  узлов в графе всё равно линейно от числа клеток
        @test length(r2.g.w.nodes) < 6 * cells
    end

    #  насколько именно: на "kitten"/"sitting" вызовов на порядки больше
    nv = edit_naive("kitten", "sitting")
    @test nv.calls > 10_000
    @test (6 + 1) * (7 + 1) == 56                   # клеток всего 56
end

# --------------------------------------------------------------------------
@testset "E6. ленивость: считается подпрямоугольник        " begin
    #  Спросив внутреннюю клетку, считаем ровно то, от чего она зависит.
    g = build_edit_distance("kitten", "sitting")
    target = first(g.cell[3, 4])                    # dp[2][3]
    execute!(g.w, target)

    @test getdata(g.w, target, :cost) == edit_reference("kitten", "sitting").table[3, 4]
    #  посчитаны клетки подпрямоугольника 0..2 x 0..3
    for i in 0:2, j in 0:3
        @test getstatus(getnode(g.w, first(g.cell[i + 1, j + 1]))) === :clean
    end
    #  и ни одна клетка вне него
    outside = [(i, j) for i in 0:g.m, j in 0:g.n if i > 2 || j > 3]
    @test all(((i, j),) -> getstatus(getnode(g.w, first(g.cell[i + 1, j + 1]))) === :dirty,
              outside)
    @test getdata(g.w, g.answer...) === nothing

    #  символы, которые в подпрямоугольник не входят, не понадобились
    @test getnode(g.w, g.ca[3]).state.exec_n == 0
    @test getnode(g.w, g.cb[4]).state.exec_n == 0
    @test getnode(g.w, g.ca[1]).state.exec_n == 1

    #  теперь спросим ответ: досчитается только остальное
    before = getnode(g.w, target).state.exec_n
    execute!(g.w, first(g.answer))
    @test getdata(g.w, g.answer...) == 3
    @test getnode(g.w, target).state.exec_n == before   # уже посчитанное не пересчитано
end

# --------------------------------------------------------------------------
@testset "E7. инкрементальность: конус одного символа      " begin
    r = graph_edit("kitten", "sitting")
    g = r.g
    total = length(g.w.nodes)

    #  Меняем ТРЕТИЙ символ первой строки. Портится ровно то, что от него
    #  зависит: клетки строк >= 3 (в индексах таблицы — i+1 >= 4).
    setsettings!(g.w, g.ca[3], Dict(:value => 'X'))
    dirty = Set(id for (id, n) in g.w.nodes if getstatus(n) === :dirty)

    for i in 0:g.m, j in 0:g.n
        id = first(g.cell[i + 1, j + 1])
        if i >= 3 && j >= 1
            @test id in dirty
        else
            @test id ∉ dirty                       # граница и верхние строки целы
        end
    end
    #  граница не зависит от символов вообще
    @test all(j -> first(g.cell[1, j + 1]) ∉ dirty, 0:g.n)
    @test all(i -> first(g.cell[i + 1, 1]) ∉ dirty, 0:g.m)
    #  и это меньше, чем весь граф
    @test length(dirty) < total

    #  досчитываем и сверяем с эталоном для новой строки
    execute!(g.w, first(g.answer))
    @test getdata(g.w, g.answer...) == edit_reference("kiXten", "sitting").distance

    #  смена символа ПОСЛЕДНЕЙ строки портит только последнюю строку
    r2 = graph_edit("kitten", "sitting")
    setsettings!(r2.g.w, last(r2.g.ca), Dict(:value => 'Z'))
    dirty2 = Set(id for (id, n) in r2.g.w.nodes if getstatus(n) === :dirty)
    cells2 = [first(r2.g.cell[i + 1, j + 1]) for i in 0:r2.g.m, j in 0:r2.g.n
              if first(r2.g.cell[i + 1, j + 1]) in dirty2]
    @test length(cells2) == r2.g.n                  # ровно последняя строка
    execute!(r2.g.w, first(r2.g.answer))
    @test getdata(r2.g.w, r2.g.answer...) == edit_reference("kitteZ", "sitting").distance
end

# --------------------------------------------------------------------------
@testset "E8. обратный ход — цикл вызывающего             " begin
    #  Граф публикует направление каждой клетки, но пройти по ним не
    #  может: путь зависит от данных.
    for (a, b) in (("kitten", "sitting"), ("flaw", "lawn"), ("abc", "abd"),
                   ("abc", "abc"), ("sunday", "saturday"))
        r    = graph_edit(a, b)
        path = edit_traceback(r.g)
        ref  = edit_reference(a, b)

        #  путь приводит из (m,n) в (0,0)
        di = count(==(:up), path) + count(==(:diag), path)
        dj = count(==(:left), path) + count(==(:diag), path)
        @test di == r.g.m && dj == r.g.n

        #  шагов, меняющих цену, ровно столько, сколько стоит расстояние
        cost = 0
        i, j = r.g.m, r.g.n
        for ch in path
            if ch === :diag
                cost += ref.table[i, j] == ref.table[i + 1, j + 1] ? 0 : 1
                i -= 1; j -= 1
            elseif ch === :up
                cost += 1; i -= 1
            else
                cost += 1; j -= 1
            end
        end
        @test (i, j) == (0, 0)
        @test cost == ref.distance == r.distance
    end
end

# --------------------------------------------------------------------------
@testset "E9. MultiPort: минимум и направление по позиции  " begin
    #  Собираем клетку на MultiPort и сравниваем. Минимум тот же, а
    #  направление теперь выводится: getinputdata отдаёт значения в порядке
    #  подключения, то есть позиция и есть «диагональ / верх / слева».
    w  = Workflow(0; type = :DAW)
    s1 = add_node!(w, DataNode(EdConst, spec_edconst()))
    s2 = add_node!(w, DataNode(EdConst, spec_edconst()))
    s3 = add_node!(w, DataNode(EdConst, spec_edconst()))
    setsettings!(w, s1, Dict(:value => 5))
    setsettings!(w, s2, Dict(:value => 3))
    setsettings!(w, s3, Dict(:value => 4))
    mc = add_node!(w, DataNode(EdCellMulti, spec_edcellmulti()))
    c1 = add_connection!(w, s1, :out, mc, :options)
    c2 = add_connection!(w, s2, :out, mc, :options)
    c3 = add_connection!(w, s3, :out, mc, :options)
    @test ismultiport(getportspec(getnode(w, mc), :options, :input))
    scheduler!(w)
    @test getdata(w, mc, :cost) === 3

    #  вот что узел видит на входе: значения в порядке подключения
    opts = getinputdata(getnode(w, mc), :options)
    @test opts isa Vector
    @test opts == [5, 3, 4]                       # s1, s2, s3 — как подключали
    @test getinputconnections(getnode(w, mc), :options) == [c1, c2, c3]

    #  Направление теперь выводимо: позиция в векторе — это и есть порядок,
    #  в котором автор графа подключил diag/up/left. Раньше здесь стоял
    #  обратный тест: сказать было нечем.
    names = (:diag, :up, :left)
    @test names[argmin(opts)] === :up             # 3 — это s2, второй вход
    @test getdata(w, mc, :cost) == minimum(opts)

    #  и номера связей доступны узлу без модели, если нужна не позиция, а
    #  именно связь
    @test length(getinputconnections(getnode(w, mc), :options)) == 3
    @test getportspec(getnode(w, mc), :options, :input).label === :options
    @test length(getnode(w, mc).spec.input_ports) == 1

    #  у именованных портов это знание есть, и именно поэтому возможен
    #  :choice
    cell = DataNode(EdCell, spec_edcell())
    for (port, value) in (:diag => 5, :up => 3, :left => 4)
        setinputbuffer!(cell, port, 1, value)
    end
    MetidaFlows.execute_unsafe!(cell)
    @test getdata(cell, :cost) === 3
    @test getdata(cell, :choice) === :up
    @test length(spec_edcell().input_ports) == 3

    #  SinglePort на двух связях запрещён — для MultiPort это и нужно
    w2 = Workflow(0; type = :DAW)
    a  = add_node!(w2, DataNode(EdConst, spec_edconst()))
    b  = add_node!(w2, DataNode(EdConst, spec_edconst()))
    st = add_node!(w2, DataNode(EdStep, spec_edstep()))
    add_connection!(w2, a, :out, st, :from)
    @test_throws ErrorException add_connection!(w2, b, :out, st, :from)
end

end
