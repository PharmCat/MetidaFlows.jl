############################################################################
#
#  ЗООПАРК АЛГОРИТМОВ: СХЕМА ГОРНЕРА (DAW, РАЗВЁРНУТЫЙ ЦИКЛ)
#
#
############################################################################

import MetidaFlows: PortSpec, DAW, ABW, getnode, getconnection, nodetypestr,
    getportspec, getid, makegraph, get_children, get_parents, setinputbuffer!,
    reset!, mark_dirty!, invalidate_downstream!, ExecuteSettings

# --------------------------------------------------------------------------
#  Эталон: та же схема обычным кодом, порядок операций повторён, чтобы
#  сравнение шло побитово. Коэффициенты от старшего к младшему.
# --------------------------------------------------------------------------

function horner_reference(coeffs::Vector{Float64}, x::Float64)
    b = coeffs[1]
    d = 0.0
    for k in 2:length(coeffs)
        d = d * x + b
        b = b * x + coeffs[k]
    end
    return (value = b, derivative = d)
end

#  Наивная сумма — для сравнения точности, не для графа.
naive_poly(coeffs::Vector{Float64}, x::Float64) =
    sum(c * x^(length(coeffs) - k) for (k, c) in enumerate(coeffs))

# ==========================================================================
#  Элементарные узлы
# ==========================================================================

struct HConstF <: AbstractNodeType end  # источник Float64
struct HMul    <: AbstractNodeType end  # a · b
struct HAdd    <: AbstractNodeType end  # a + b
struct HResult <: AbstractNodeType end  # сбор результата

spec_hconstf() = NodeSpec("H const float", PortSpec[],
    [PortSpec("Out", Float64, :out)], [:value])

h_binary() = NodeSpec("H binary",
    [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
    [PortSpec("Out", Float64, :out)])

spec_hmul() = NodeSpec("H mul",
    [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
    [PortSpec("Out", Float64, :out)])
spec_hadd() = NodeSpec("H add",
    [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
    [PortSpec("Out", Float64, :out)])

#  Единственный узел с терминальными портами: см. заголовок, иначе
#  пометить конец цепочки нечем.
spec_hresult() = NodeSpec("H result",
    [PortSpec("Value",      Float64, :value),
     PortSpec("Derivative", Float64, :derivative)],
    [PortSpec("Value",      Float64, :value;      kind = :terminal),
     PortSpec("Derivative", Float64, :derivative; kind = :terminal)])

MetidaFlows.execute_unsafe!(n::DataNode{HConstF}) =
    (setdata!(n, :out, Float64(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{HMul}) =
    (setdata!(n, :out, getinputdata(n, :a) * getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{HAdd}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])
function MetidaFlows.execute_unsafe!(node::DataNode{HResult})
    setdata!(node, :value,      getinputdata(node, :value))
    setdata!(node, :derivative, getinputdata(node, :derivative))
    return [:value, :derivative]
end

# ==========================================================================
#  Сборка графа
# ==========================================================================

"""
    build_horner(coeffs, x) -> NamedTuple

Граф схемы Горнера для многочлена с коэффициентами `coeffs` (от старшего
к младшему) в точке `x`. Цикл развёрнут: на каждую степень своя пара
узлов. Считает значение и производную.

Возвращает workflow, идентификаторы источников и по-ступенчатые
идентификаторы обеих цепочек.
"""
function build_horner(coeffs::Vector{Float64}, x::Float64)
    n      = length(coeffs) - 1          # степень
    w      = Workflow(0; type = :DAW)
    w.name = "Horner's scheme"

    cx    = add_node!(w, DataNode(HConstF, spec_hconstf()))
    czero = add_node!(w, DataNode(HConstF, spec_hconstf()))
    setsettings!(w, cx,    Dict(:value => x))
    setsettings!(w, czero, Dict(:value => 0.0))

    ca = Int[]
    for c in coeffs
        id = add_node!(w, DataNode(HConstF, spec_hconstf()))
        setsettings!(w, id, Dict(:value => c))
        push!(ca, id)
    end

    #  b — значение, d — производная. Начало цепочек: b = a[n], d = 0.
    bmul = Int[]; badd = Int[]; dmul = Int[]; dadd = Int[]
    bprev = ca[1]; bport = :out
    dprev = czero; dport = :out

    for k in 2:length(coeffs)
        #  d = d · x + b  (b ЕЩЁ не обновлено на этой ступени)
        dm = add_node!(w, DataNode(HMul, spec_hmul()))
        da = add_node!(w, DataNode(HAdd, spec_hadd()))
        add_connection!(w, dprev, dport, dm, :a)
        add_connection!(w, cx,    :out,  dm, :b)
        add_connection!(w, dm,    :out,  da, :a)
        add_connection!(w, bprev, bport, da, :b)
        push!(dmul, dm); push!(dadd, da)
        dprev = da; dport = :out

        #  b = b · x + a[k]
        bm = add_node!(w, DataNode(HMul, spec_hmul()))
        ba = add_node!(w, DataNode(HAdd, spec_hadd()))
        add_connection!(w, bprev, bport, bm, :a)
        add_connection!(w, cx,    :out,  bm, :b)
        add_connection!(w, bm,    :out,  ba, :a)
        add_connection!(w, ca[k], :out,  ba, :b)
        push!(bmul, bm); push!(badd, ba)
        bprev = ba; bport = :out
    end

    res = add_node!(w, DataNode(HResult, spec_hresult()))
    add_connection!(w, bprev, bport, res, :value)
    add_connection!(w, dprev, dport, res, :derivative)

    return (w = w, cx = cx, czero = czero, ca = ca, bmul = bmul, badd = badd,
            dmul = dmul, dadd = dadd, res = res, n = n)
end

"Посчитать многочлен графом. Возвращает значение, производную и граф."
function graph_horner(coeffs::Vector{Float64}, x::Float64)
    g = build_horner(coeffs, x)
    scheduler!(g.w)
    return (value      = getdata(g.w, g.res, :value),
            derivative = getdata(g.w, g.res, :derivative),
            g          = g)
end

# ==========================================================================

@testset verbose = true "СХЕМА ГОРНЕРА (DAW)                              " begin

# --------------------------------------------------------------------------
@testset "H1. элементарные узлы по отдельности             " begin
    function run1(type, spec, inputs::Dict{Symbol, Any}; settings = Dict{Symbol, Any}())
        node = DataNode(type, spec; settings = settings)
        for (port, value) in inputs
            setinputbuffer!(node, port, 1, value)
        end
        node, MetidaFlows.execute_unsafe!(node)
    end

    n, p = run1(HConstF, spec_hconstf(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => -1.5))
    @test p == [:out] && getdata(n, :out) === -1.5
    #  целое в настройке приводится к Float64
    n, _ = run1(HConstF, spec_hconstf(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => 3))
    @test getdata(n, :out) === 3.0

    n, _ = run1(HMul, spec_hmul(), Dict{Symbol, Any}(:a => 2.0, :b => 3.0))
    @test getdata(n, :out) === 6.0
    n, _ = run1(HAdd, spec_hadd(), Dict{Symbol, Any}(:a => 2.0, :b => 3.0))
    @test getdata(n, :out) === 5.0

    n, p = run1(HResult, spec_hresult(),
                Dict{Symbol, Any}(:value => 7.0, :derivative => 4.0))
    @test p == [:value, :derivative]
    @test getdata(n, :value) === 7.0 && getdata(n, :derivative) === 4.0
    @test all(ps -> ps.kind === :terminal, spec_hresult().output_ports)
end

# --------------------------------------------------------------------------
@testset "H2. граф растёт со степенью                      " begin
    #  ГЛАВНОЕ ОТЛИЧИЕ ОТ ABW: размер графа несёт размер задачи.
    for n in 0:6
        coeffs = Float64.(collect(1:(n + 1)))
        g = build_horner(coeffs, 2.0)
        @test g.n == n
        @test length(g.w.nodes) == 5n + 4
        @test length(g.bmul) == n && length(g.badd) == n
        @test length(g.dmul) == n && length(g.dadd) == n
        @test g.w isa Workflow{DAW}
        #  ни одного обратного порта в графе
        @test isempty([p for (_, node) in g.w.nodes
                       for p in node.spec.input_ports if p.kind == :feedback])
    end

    #  связи: 4 на ступень b, 4 на ступень d, плюс 2 в результат
    for n in 0:6
        g = build_horner(Float64.(collect(1:(n + 1))), 2.0)
        @test length(g.w.connections) == 8n + 2
    end

    #  РОМБ на каждой ступени: выход b уходит двум потребителям
    g = build_horner([1.0, 2.0, 3.0, 4.0], 2.0)
    for (k, ba) in enumerate(g.badd[1:end-1])
        kids = get_children(g.w, ba)
        @test length(kids) == 2
        @test Set(c for (_, c, _) in kids) == Set([g.bmul[k + 1], g.dadd[k + 1]])
    end
    #  x раздаётся во все умножения обеих цепочек
    @test length(get_children(g.w, g.cx)) == 2 * g.n
end

# --------------------------------------------------------------------------
@testset "H3. значение совпадает со схемой побитово        " begin
    cases = ([2.0, -3.0, 1.0],                       # 2x² − 3x + 1
             [1.0],                                   # константа
             [1.0, 0.0],                              # x
             [1.0, -6.0, 15.0, -20.0, 15.0, -6.0, 1.0],   # (x−1)^6
             [0.5, 0.0, -2.0, 7.0],
             [1e10, 1.0, 1e-10])
    for coeffs in cases, x in (0.0, 1.0, -1.0, 2.5, 0.1, -7.25, 1e5)
        r = graph_horner(copy(coeffs), x)
        @test r.value === horner_reference(coeffs, x).value
    end

    #  А ВОТ С `evalpoly` ГРАФ СОВПАДАЕТ НЕ ВСЕГДА, и причина не в
    #  порядке операций, а в их числе: `evalpoly` считает каждую ступень
    #  через `muladd`, то есть одной командой со единственным
    #  округлением. В графе умножение и сложение — РАЗНЫЕ УЗЛЫ, сращивать
    #  нечего, и там, где округления расходятся, расходится и результат.
    #  Это цена разложения алгоритма на элементарные узлы.
    fused(c, x) = (b = c[1]; for k in 2:length(c); b = muladd(b, x, c[k]); end; b)
    diverged = 0
    total    = 0
    for coeffs in cases, x in (0.0, 1.0, -1.0, 2.5, 0.1, -7.25, 1e5)
        total += 1
        r = graph_horner(copy(coeffs), x)
        #  сращённая схема — это ровно `evalpoly`
        @test fused(coeffs, x) === evalpoly(x, reverse(coeffs))
        r.value === evalpoly(x, reverse(coeffs)) || (diverged += 1)
    end
    @test total == 42
    @test diverged == 1                   # расхождение редкое, но есть

    #  вот этот случай: (x−1)^6 при x = 0.1
    pal = [1.0, -6.0, 15.0, -20.0, 15.0, -6.0, 1.0]
    r = graph_horner(copy(pal), 0.1)
    @test r.value === 0.531441
    @test evalpoly(0.1, reverse(pal)) === 0.5314409999999999
    @test r.value !== evalpoly(0.1, reverse(pal))
end

# --------------------------------------------------------------------------
@testset "H4. производная из той же схемы                  " begin
    for coeffs in ([2.0, -3.0, 1.0], [1.0, -6.0, 15.0, -20.0, 15.0, -6.0, 1.0],
                   [0.5, 0.0, -2.0, 7.0], [3.0], [4.0, 1.0])
        for x in (0.0, 1.0, -1.0, 2.5, 0.1)
            r   = graph_horner(copy(coeffs), x)
            ref = horner_reference(coeffs, x)
            @test r.derivative === ref.derivative
        end
    end

    #  производная верна по существу: сравним с коэффициентами p'
    for coeffs in ([2.0, -3.0, 1.0], [0.5, 0.0, -2.0, 7.0])
        n  = length(coeffs) - 1
        dc = [coeffs[k] * (n - k + 1) for k in 1:n]      # старший → младший
        for x in (0.0, 1.0, -1.0, 2.5)
            r = graph_horner(copy(coeffs), x)
            @test isapprox(r.derivative, evalpoly(x, reverse(dc)); atol = 1e-12)
        end
    end

    #  у константы производная ноль, и первая ступень d тривиальна
    r = graph_horner([3.0], 5.0)
    @test r.value === 3.0 && r.derivative === 0.0
    r = graph_horner([4.0, 1.0], 5.0)          # 4x + 1
    @test r.value === 21.0 && r.derivative === 4.0
    #  первая ступень цепочки d считает 0·x + a[n] — узел есть, работа
    #  вырожденная: это цена разворачивания цикла в структуру
    @test getdata(r.g.w, first(r.g.dmul), :out) === 0.0
    @test getdata(r.g.w, first(r.g.dadd), :out) === 4.0
end

# --------------------------------------------------------------------------
@testset "H5. DAW: каждый узел ровно один раз              " begin
    r = graph_horner([1.0, -6.0, 15.0, -20.0, 15.0, -6.0, 1.0], 1.5)
    @test all(n -> n.state.exec_n == 1, values(r.g.w.nodes))
    @test all(n -> getstatus(n) === :clean, values(r.g.w.nodes))

    #  повторный прогон: DAW сбрасывает всё и считает заново
    scheduler!(r.g.w)
    @test all(n -> n.state.exec_n == 1, values(r.g.w.nodes))   # сброс обнулил
    @test getdata(r.g.w, r.g.res, :value) ===
          horner_reference([1.0, -6.0, 15.0, -20.0, 15.0, -6.0, 1.0], 1.5).value

    #  порядок вынужден структурой: ступень k не может считаться раньше k−1
    for k in 2:length(r.g.badd)
        @test (:a, r.g.bmul[k]) in [(p, i) for (p, i) in get_parents(r.g.w, r.g.bmul[k])
                                    if i == r.g.badd[k - 1]] ||
              r.g.badd[k - 1] in [i for (_, i) in get_parents(r.g.w, r.g.bmul[k])]
    end
end

# --------------------------------------------------------------------------
@testset "H6. тяга: считается только нужное                " begin
    #  scheduler! считает весь граф; execute! — только то, что нужно
    #  спрошенному узлу. Попросим ЗНАЧЕНИЕ, минуя узел результата.
    g = build_horner([2.0, -3.0, 1.0, 5.0], 2.0)
    last_b = last(g.badd)
    execute!(g.w, last_b)

    @test getdata(g.w, last_b, :out) ===
          horner_reference([2.0, -3.0, 1.0, 5.0], 2.0).value
    #  цепочка значения посчитана целиком
    @test all(id -> getstatus(getnode(g.w, id)) === :clean, g.badd)
    @test all(id -> getstatus(getnode(g.w, id)) === :clean, g.bmul)
    #  а цепочка производной НЕ ТРОНУТА
    @test all(id -> getstatus(getnode(g.w, id)) === :dirty, g.dadd)
    @test all(id -> getnode(g.w, id).state.exec_n == 0, g.dmul)
    @test getstatus(getnode(g.w, g.res)) === :dirty
    @test getdata(g.w, g.res, :value) === nothing
    #  источник нуля не понадобился
    @test getnode(g.w, g.czero).state.exec_n == 0

    #  теперь спросим результат: досчитается только недостающее
    before = Dict(id => getnode(g.w, id).state.exec_n for id in g.badd)
    execute!(g.w, g.res)
    @test getdata(g.w, g.res, :value) ===
          horner_reference([2.0, -3.0, 1.0, 5.0], 2.0).value
    @test getdata(g.w, g.res, :derivative) ===
          horner_reference([2.0, -3.0, 1.0, 5.0], 2.0).derivative
    #  цепочка значения второй раз не считалась — результат был в кеше
    @test all(id -> getnode(g.w, id).state.exec_n == before[id], g.badd)
    @test all(id -> getnode(g.w, id).state.exec_n == 1, g.dadd)
end

# --------------------------------------------------------------------------
@testset "H7. точная инвалидация по коэффициенту           " begin
    coeffs = [2.0, -3.0, 1.0, 5.0]
    r = graph_horner(copy(coeffs), 2.0)
    g = r.g
    total = length(g.w.nodes)

    #  Свободный член входит в ПОСЛЕДНЮЮ ступень b: портится только она,
    #  узел результата и больше ничего.
    setsettings!(g.w, last(g.ca), Dict(:value => 99.0))
    dirty = [id for (id, n) in g.w.nodes if getstatus(n) === :dirty]
    @test Set(dirty) == Set([last(g.ca), last(g.badd), g.res])
    @test length(dirty) == 3 < total

    execute!(g.w, g.res)
    newc = copy(coeffs); newc[end] = 99.0
    @test getdata(g.w, g.res, :value) === horner_reference(newc, 2.0).value
    #  производная от свободного члена не зависит — и не пересчитывалась
    @test getdata(g.w, g.res, :derivative) === horner_reference(coeffs, 2.0).derivative
    @test all(id -> getnode(g.w, id).state.exec_n == 1, g.dadd)

    #  СТАРШИЙ коэффициент входит в самое начало обеих цепочек: чистыми
    #  остаются только источники, которые от него не зависят
    r2 = graph_horner(copy(coeffs), 2.0)
    setsettings!(r2.g.w, first(r2.g.ca), Dict(:value => 7.0))
    clean2 = [id for (id, n) in r2.g.w.nodes if getstatus(n) === :clean]
    #  Чистыми остаются источники, не зависящие от старшего
    #  коэффициента, И ПЕРВАЯ СТУПЕНЬ ЦЕПОЧКИ d: она считает 0·x, то
    #  есть не зависит ни от одного коэффициента вообще.
    @test Set(clean2) == Set([r2.g.cx; r2.g.czero; r2.g.ca[2:end]; first(r2.g.dmul)])
    @test r2.g.res ∉ clean2
    @test all(id -> getstatus(getnode(r2.g.w, id)) === :dirty,
              [r2.g.bmul; r2.g.badd; r2.g.dadd; r2.g.dmul[2:end]])
    execute!(r2.g.w, r2.g.res)
    newtop = copy(coeffs); newtop[1] = 7.0
    @test getdata(r2.g.w, r2.g.res, :value) === horner_reference(newtop, 2.0).value

    #  СМЕНА x портит всё, кроме источников
    r3 = graph_horner(copy(coeffs), 2.0)
    setsettings!(r3.g.w, r3.g.cx, Dict(:value => 3.0))
    clean3 = [id for (id, n) in r3.g.w.nodes if getstatus(n) === :clean]
    @test Set(clean3) == Set([r3.g.czero; r3.g.ca])
    execute!(r3.g.w, r3.g.res)
    @test getdata(r3.g.w, r3.g.res, :value) === horner_reference(coeffs, 3.0).value
    @test getdata(r3.g.w, r3.g.res, :derivative) ===
          horner_reference(coeffs, 3.0).derivative
end

# --------------------------------------------------------------------------
@testset "H8. вырожденные многочлены                      " begin
    #  степень 0: ступеней нет, граф это четыре источника и результат
    g = build_horner([7.0], 3.0)
    @test length(g.w.nodes) == 4
    @test isempty(g.bmul) && isempty(g.dmul)
    scheduler!(g.w)
    @test getdata(g.w, g.res, :value) === 7.0
    @test getdata(g.w, g.res, :derivative) === 0.0

    #  нулевые коэффициенты считаются как все прочие
    r = graph_horner([0.0, 0.0, 0.0], 5.0)
    @test r.value === 0.0 && r.derivative === 0.0

    #  x = 0: значение равно свободному члену, производная — первому
    coeffs = [2.0, -3.0, 1.0, 5.0]
    r = graph_horner(copy(coeffs), 0.0)
    @test r.value === 5.0
    @test r.derivative === 1.0

    #  знак нуля не теряется там, где его нет
    r = graph_horner([1.0, 0.0], -0.0)
    @test r.value === horner_reference([1.0, 0.0], -0.0).value
end

# --------------------------------------------------------------------------
@testset "H9. Горнер против наивной суммы                  " begin
    #  Численный факт, не свойство движка. (x−1)^6 около единицы —
    #  классическое сокращение: истинное значение порядка 1e-18…1e-30, а
    #  обе схемы работают с числами порядка единицы и теряют ВСЁ.
    coeffs = [1.0, -6.0, 15.0, -20.0, 15.0, -6.0, 1.0]
    xs     = (1.0 + 1e-3, 1.0 + 1e-4, 1.0 + 1e-5, 1.0 - 1e-4)

    for x in xs
        r = graph_horner(copy(coeffs), x)
        @test r.value === horner_reference(coeffs, x).value    # граф = схема
        @test r.value !== naive_poly(coeffs, x)                # схемы разошлись
        #  обе дают мусор того же порядка, что машинный эпсилон
        @test abs(r.value) < 1e-14
        @test abs(naive_poly(coeffs, x)) < 1e-13
        #  а истина на много порядков меньше
        @test (x - 1.0)^6 < 1e-17
    end

    #  Горнер держится ближе к нулю, кроме случая, где наивная сумма
    #  случайно попадает в точный нуль — то есть «Горнер точнее» здесь
    #  не теорема, а наблюдение
    closer = count(x -> abs(graph_horner(copy(coeffs), x).value) <
                        abs(naive_poly(coeffs, x)), xs)
    @test closer == 3
    @test naive_poly(coeffs, 1.0 - 1e-4) === 0.0
    @test abs(graph_horner(copy(coeffs), 1.0 - 1e-4).value) > 0.0

    #  там, где сокращения нет, обе схемы дают одно и то же
    plain = [2.0, -3.0, 1.0]
    for x in (2.0, 10.0, 0.5)
        @test graph_horner(copy(plain), x).value === naive_poly(plain, x)
    end
end

end
