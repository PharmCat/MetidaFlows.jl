############################################################################
#
#  ЗООПАРК АЛГОРИТМОВ: ИНТЕРВАЛЬНАЯ АРИФМЕТИКА (МЕТАДАННЫЕ ПОРТОВ)
#
#  Назначение: единственный алгоритм зоопарка, который считается НЕ
#  планировщиком. Он считается обходом метаданных — `getmeta` — и ни один
#  узел при этом не исполняется.
#
############################################################################

import MetidaFlows: PortSpec, DAW, getnode, getstatus, getmeta, getinputmeta,
    ismetasource, getmeta_unsafe, getconnection

# ==========================================================================
#  Узлы: обычное арифметическое выражение
# ==========================================================================

struct IvConst <: AbstractNodeType end   # константа или диапазон
struct IvAdd   <: AbstractNodeType end
struct IvSub   <: AbstractNodeType end
struct IvMul   <: AbstractNodeType end
struct IvDiv   <: AbstractNodeType end
struct IvNeg   <: AbstractNodeType end
struct IvOut   <: AbstractNodeType end   # сбор результата, терминальный порт

#  `:value` нужен прогону, `:lo`/`:hi` — обходу метаданных. Оба объявлены в
#  спеке: настройка, которой в спеке нет, не попадёт ни в схему, ни в снимок.
spec_ivconst() = NodeSpec("Iv const", PortSpec[],
    [PortSpec("Out", Float64, :out)], [:value, :lo, :hi])
spec_ivbin(name) = NodeSpec(name,
    [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
    [PortSpec("Out", Float64, :out)])
spec_ivneg() = NodeSpec("Iv neg", [PortSpec("A", Float64, :a)],
    [PortSpec("Out", Float64, :out)])
spec_ivout() = NodeSpec("Iv out", [PortSpec("In", Float64, :in)],
    [PortSpec("Out", Float64, :out; kind = :terminal)])

# --- обычная семантика: значения ------------------------------------------

MetidaFlows.execute_unsafe!(n::DataNode{IvConst}) =
    (setdata!(n, :out, Float64(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvAdd}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvSub}) =
    (setdata!(n, :out, getinputdata(n, :a) - getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvMul}) =
    (setdata!(n, :out, getinputdata(n, :a) * getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvDiv}) =
    (setdata!(n, :out, getinputdata(n, :a) / getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvNeg}) =
    (setdata!(n, :out, -getinputdata(n, :a)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{IvOut}) =
    (setdata!(n, :out, getinputdata(n, :in)); [:out])

# ==========================================================================
#  ВТОРАЯ СЕМАНТИКА ТОГО ЖЕ ГРАФА: интервалы, без исполнения
# ==========================================================================

#  Сколько раз движок позвал наше правило — для замера мемоизации (G7).
IV_CALLS = Ref(0)

#  Константа описывает себя сама, но только когда диапазон задан: пока его
#  нет, узел не источник, и подъём идёт дальше (а выше ничего нет).
MetidaFlows.ismetasource(n::DataNode{IvConst}, ::Symbol) =
    haskey(n.settings, :lo) && haskey(n.settings, :hi)

#  ТОТАЛЬНЫЙ: зовётся и на ветке «источник», и на ветке «не источник».
function MetidaFlows.getmeta_unsafe(n::DataNode{IvConst}, ::Symbol, inmeta)
    IV_CALLS[] += 1
    (haskey(n.settings, :lo) && haskey(n.settings, :hi)) || return nothing
    return (lo = Float64(n.settings[:lo]), hi = Float64(n.settings[:hi]))
end

"Оба операнда правила, или `nothing`, если хоть один неизвестен."
function ivboth(inmeta)
    a = inmeta[:a]; b = inmeta[:b]
    (isnothing(a) || isnothing(b)) && return nothing
    return (a, b)
end

function MetidaFlows.getmeta_unsafe(n::DataNode{IvAdd}, ::Symbol, inmeta)
    IV_CALLS[] += 1
    p = ivboth(inmeta); isnothing(p) && return nothing
    a, b = p
    return (lo = a.lo + b.lo, hi = a.hi + b.hi)
end
function MetidaFlows.getmeta_unsafe(n::DataNode{IvSub}, ::Symbol, inmeta)
    IV_CALLS[] += 1
    p = ivboth(inmeta); isnothing(p) && return nothing
    a, b = p
    #  Вычитание переворачивает концы вычитаемого: a.lo − b.hi, а не b.lo.
    return (lo = a.lo - b.hi, hi = a.hi - b.lo)
end
function MetidaFlows.getmeta_unsafe(n::DataNode{IvMul}, ::Symbol, inmeta)
    IV_CALLS[] += 1
    p = ivboth(inmeta); isnothing(p) && return nothing
    a, b = p
    #  Умножение не монотонно по знакам: минимум и максимум из всех четырёх
    #  произведений концов, иначе [−2,1]·[−3,4] посчитается неверно.
    q = (a.lo * b.lo, a.lo * b.hi, a.hi * b.lo, a.hi * b.hi)
    return (lo = minimum(q), hi = maximum(q))
end
function MetidaFlows.getmeta_unsafe(n::DataNode{IvDiv}, ::Symbol, inmeta)
    IV_CALLS[] += 1
    p = ivboth(inmeta); isnothing(p) && return nothing
    a, b = p
    #  Вот ради этой строки механизм и нужен: отказ ДО того, как тронуты
    #  данные. Если делитель может оказаться нулём, считать нечего.
    b.lo <= 0 <= b.hi &&
        error("Division by an interval containing zero: [$(b.lo), $(b.hi)]")
    q = (a.lo / b.lo, a.lo / b.hi, a.hi / b.lo, a.hi / b.hi)
    return (lo = minimum(q), hi = maximum(q))
end
function MetidaFlows.getmeta_unsafe(n::DataNode{IvNeg}, ::Symbol, inmeta)
    IV_CALLS[] += 1
    a = inmeta[:a]; isnothing(a) && return nothing
    return (lo = -a.hi, hi = -a.lo)
end
function MetidaFlows.getmeta_unsafe(n::DataNode{IvOut}, ::Symbol, inmeta)
    IV_CALLS[] += 1
    return inmeta[:in]
end

# ==========================================================================
#  Графы
# ==========================================================================

"""
    build_expr(; xlo, xhi, ylo, yhi, shift) -> NamedTuple

Граф выражения `f(x, y) = (x · y + x) / (y − shift)`. Выход `x` идёт ДВУМ
потребителям — умножению и сложению, — то есть это ромб, и на нём видна
консервативность интервалов (группа G7).

`:value` у констант задан серединой диапазона, чтобы граф можно было и
посчитать, не трогая настройки.
"""
function build_expr(; xlo = 1.0, xhi = 3.0, ylo = 4.0, yhi = 5.0, shift = 2.0)
    w      = Workflow(0; type = :DAW)
    w.name = "Interval arithmetic"

    cx = add_node!(w, DataNode(IvConst, spec_ivconst()))
    cy = add_node!(w, DataNode(IvConst, spec_ivconst()))
    ck = add_node!(w, DataNode(IvConst, spec_ivconst()))
    setsettings!(w, cx, Dict(:value => (xlo + xhi) / 2, :lo => xlo, :hi => xhi))
    setsettings!(w, cy, Dict(:value => (ylo + yhi) / 2, :lo => ylo, :hi => yhi))
    setsettings!(w, ck, Dict(:value => shift, :lo => shift, :hi => shift))

    mul = add_node!(w, DataNode(IvMul, spec_ivbin("Iv mul")))
    add = add_node!(w, DataNode(IvAdd, spec_ivbin("Iv add")))
    sub = add_node!(w, DataNode(IvSub, spec_ivbin("Iv sub")))
    div = add_node!(w, DataNode(IvDiv, spec_ivbin("Iv div")))
    out = add_node!(w, DataNode(IvOut, spec_ivout()))

    add_connection!(w, cx,  :out, mul, :a)
    add_connection!(w, cy,  :out, mul, :b)
    add_connection!(w, mul, :out, add, :a)
    add_connection!(w, cx,  :out, add, :b)      # ← второй приход x: ромб
    add_connection!(w, cy,  :out, sub, :a)
    add_connection!(w, ck,  :out, sub, :b)
    add_connection!(w, add, :out, div, :a)
    add_connection!(w, sub, :out, div, :b)
    add_connection!(w, div, :out, out, :in)

    (w = w, cx = cx, cy = cy, ck = ck, mul = mul, add = add, sub = sub,
     div = div, out = out)
end

"Посчитать выражение настоящим прогоном при конкретных x и y."
function eval_expr!(g, xv::Float64, yv::Float64)
    setsettings!(g.w, g.cx, Dict(:value => xv))
    setsettings!(g.w, g.cy, Dict(:value => yv))
    scheduler!(g.w)
    getdata(g.w, g.out, :out)
end

"Эталон: та же интервальная арифметика обычным кодом, без графа."
function ref_expr(xlo, xhi, ylo, yhi, shift)
    mul = extrema((xlo*ylo, xlo*yhi, xhi*ylo, xhi*yhi))
    add = (mul[1] + xlo, mul[2] + xhi)
    sub = (ylo - shift, yhi - shift)
    (sub[1] <= 0 <= sub[2]) && return nothing
    q = (add[1]/sub[1], add[1]/sub[2], add[2]/sub[1], add[2]/sub[2])
    return (lo = minimum(q), hi = maximum(q))
end

"""
    build_poly(coeffs; xlo, xhi) -> NamedTuple

Схема Горнера на тех же узлах: `P(x) = ((a3·x + a2)·x + a1)·x + a0`, где
`coeffs = [a3, a2, a1, a0]`. Нужна, чтобы задать вопрос «какие границы у
многочлена на отрезке» и получить ответ без прогона (группа G8).
"""
function build_poly(coeffs::Vector{Float64}; xlo = -1.0, xhi = 2.0)
    w      = Workflow(0; type = :DAW)
    w.name = "Polynomial bounds"
    cx = add_node!(w, DataNode(IvConst, spec_ivconst()))
    setsettings!(w, cx, Dict(:value => (xlo + xhi) / 2, :lo => xlo, :hi => xhi))

    prev = add_node!(w, DataNode(IvConst, spec_ivconst()))
    setsettings!(w, prev, Dict(:value => coeffs[1], :lo => coeffs[1], :hi => coeffs[1]))
    muls = Int[]; adds = Int[]
    for k in 2:length(coeffs)
        ca = add_node!(w, DataNode(IvConst, spec_ivconst()))
        setsettings!(w, ca, Dict(:value => coeffs[k], :lo => coeffs[k], :hi => coeffs[k]))
        m = add_node!(w, DataNode(IvMul, spec_ivbin("Iv mul")))
        a = add_node!(w, DataNode(IvAdd, spec_ivbin("Iv add")))
        add_connection!(w, prev, :out, m, :a)
        add_connection!(w, cx,   :out, m, :b)
        add_connection!(w, m,    :out, a, :a)
        add_connection!(w, ca,   :out, a, :b)
        push!(muls, m); push!(adds, a)
        prev = a
    end
    out = add_node!(w, DataNode(IvOut, spec_ivout()))
    add_connection!(w, prev, :out, out, :in)
    (w = w, cx = cx, out = out, muls = muls, adds = adds)
end

"Посчитать многочлен настоящим прогоном при конкретном x."
function eval_poly!(g, xv::Float64)
    setsettings!(g.w, g.cx, Dict(:value => xv))
    scheduler!(g.w)
    getdata(g.w, g.out, :out)
end

# ==========================================================================

@testset verbose = true "ИНТЕРВАЛЬНАЯ АРИФМЕТИКА (МЕТАДАННЫЕ)            " begin

# --------------------------------------------------------------------------
@testset "G1. правила по отдельности                      " begin
    #  Каждое правило проверяется на графе из трёх узлов: две константы с
    #  диапазонами и операция. Ответ берётся обходом, не прогоном.
    function rule(T, name, alo, ahi, blo, bhi)
        w = Workflow(0; type = :DAW)
        a = add_node!(w, DataNode(IvConst, spec_ivconst()))
        b = add_node!(w, DataNode(IvConst, spec_ivconst()))
        setsettings!(w, a, Dict(:value => alo, :lo => alo, :hi => ahi))
        setsettings!(w, b, Dict(:value => blo, :lo => blo, :hi => bhi))
        o = add_node!(w, DataNode(T, spec_ivbin(name)))
        add_connection!(w, a, :out, o, :a)
        add_connection!(w, b, :out, o, :b)
        getmeta(w, o, :out)
    end

    @test rule(IvAdd, "add", 1.0, 2.0, 10.0, 20.0) == (lo = 11.0, hi = 22.0)
    #  Вычитание: a.lo − b.hi, а не a.lo − b.lo
    @test rule(IvSub, "sub", 1.0, 2.0, 10.0, 20.0) == (lo = -19.0, hi = -8.0)
    #  Умножение разнознаковых: правильный ответ даёт только перебор концов
    @test rule(IvMul, "mul", -2.0, 1.0, -3.0, 4.0) == (lo = -8.0, hi = 6.0)
    @test rule(IvMul, "mul",  2.0, 3.0,  4.0, 5.0) == (lo = 8.0,  hi = 15.0)
    #  Деление, когда нуль вне делителя
    @test rule(IvDiv, "div", 1.0, 2.0,  4.0, 5.0) ==
          (lo = 1.0/5.0, hi = 2.0/4.0)
    #  и отказ, когда внутри. Ответ берётся обходом, поэтому отказ приходит
    #  обёрнутым: обход называет узел и порт, исходный текст внутри.
    @test_throws MetidaFlows.MetaRuleError rule(IvDiv, "div", 1.0, 2.0, -1.0, 3.0)
    @test occursin("containing zero",
        try; rule(IvDiv, "div", 1.0, 2.0, -1.0, 3.0); catch e; sprint(showerror, e); end)

    #  Унарное отрицание переворачивает концы
    w = Workflow(0; type = :DAW)
    a = add_node!(w, DataNode(IvConst, spec_ivconst()))
    setsettings!(w, a, Dict(:value => 1.0, :lo => 1.0, :hi => 4.0))
    ng = add_node!(w, DataNode(IvNeg, spec_ivneg()))
    add_connection!(w, a, :out, ng, :a)
    @test getmeta(w, ng, :out) == (lo = -4.0, hi = -1.0)

    #  Вырожденный интервал (точное число) остаётся точным
    @test rule(IvAdd, "add", 2.0, 2.0, 3.0, 3.0) == (lo = 5.0, hi = 5.0)
end

# --------------------------------------------------------------------------
@testset "G2. структура графа                             " begin
    g = build_expr()
    @test length(g.w.nodes) == 8
    @test length(g.w.connections) == 9
    @test g.w isa Workflow{DAW}

    #  Ромб: выход x идёт ДВУМ потребителям
    consumers = [(c.input_id, c.input_port) for (_, c) in g.w.connections
                 if c.output_id == g.cx]
    @test length(consumers) == 2
    @test Set(consumers) == Set([(g.mul, :a), (g.add, :b)])

    #  Выход — терминальный порт, у него нет потребителей
    @test MetidaFlows.getportspec(getnode(g.w, g.out), :out, :output).kind === :terminal
    @test isempty([c for (_, c) in g.w.connections if c.output_id == g.out])

    #  Все константы объявили себя источниками метаданных
    for id in (g.cx, g.cy, g.ck)
        @test ismetasource(getnode(g.w, id), :out)
    end
    #  а операции — нет, они описывают себя из входов
    for id in (g.mul, g.add, g.sub, g.div, g.out)
        @test !ismetasource(getnode(g.w, id), :out)
    end
end

# --------------------------------------------------------------------------
@testset "G3. оценка без исполнения                       " begin
    g = build_expr()
    pred = getmeta(g.w, g.out, :out)

    #  ГЛАВНОЕ: ответ есть, а работы не сделано
    @test pred == (lo = 5.0/3.0, hi = 9.0)
    @test all(n -> n.state.exec_n == 0, values(g.w.nodes))
    @test !any(n -> getstatus(n) === :clean, values(g.w.nodes))
    @test all(n -> isempty(n.data), values(g.w.nodes))
    @test g.w.run_id == 0                      # планировщик не запускался

    #  Тот же ответ, посчитанный обычным кодом без графа
    @test pred == ref_expr(1.0, 3.0, 4.0, 5.0, 2.0)

    #  Промежуточные порты описываются так же
    @test getmeta(g.w, g.mul, :out) == (lo = 4.0,  hi = 15.0)
    @test getmeta(g.w, g.add, :out) == (lo = 5.0,  hi = 18.0)
    @test getmeta(g.w, g.sub, :out) == (lo = 2.0,  hi = 3.0)
    #  и после всех этих вопросов узлы по-прежнему не исполнялись
    @test all(n -> n.state.exec_n == 0, values(g.w.nodes))

    #  getinputmeta видит входы узла по ЕГО ярлыкам
    im = getinputmeta(g.w, g.div)
    @test Set(keys(im)) == Set([:a, :b])
    @test im[:a] == (lo = 5.0, hi = 18.0)
    @test im[:b] == (lo = 2.0, hi = 3.0)
end

# --------------------------------------------------------------------------
@testset "G4. содержание: выборка попадает в интервал      " begin
    g    = build_expr()
    pred = getmeta(g.w, g.out, :out)

    #  Настоящие прогоны на одном и том же графе: меняем настройки и
    #  пересчитываем. Выборка — СЕТКА, а не случайные числа: поток ГПСЧ
    #  между версиями Julia меняется, а тест должен давать те же точки
    #  везде. Сетка вдобавок накрывает углы, где и лежат экстремумы.
    function sweep!(g, pred, m)
        lo, hi, inside, total = Inf, -Inf, 0, 0
        for i in 0:m, j in 0:m
            xv = 1.0 + 2.0 * i / m
            yv = 4.0 + 1.0 * j / m
            v  = eval_expr!(g, xv, yv)
            lo = min(lo, v); hi = max(hi, v)
            total += 1
            pred.lo <= v <= pred.hi && (inside += 1)
        end
        (lo = lo, hi = hi, inside = inside, total = total)
    end

    s = sweep!(g, pred, 44)              # 45 × 45 = 2025 точек
    #  Ни одного промаха: оценка обязана содержать результат
    @test s.total == 2025
    @test s.inside == s.total
    @test pred.lo <= s.lo && s.hi <= pred.hi
    #  И она ШИРЕ фактического разброса — интервалы консервативны
    @test pred.hi - pred.lo > s.hi - s.lo
    #  НИ ОДНА из предсказанных границ не достигается, и это не огрех
    #  реализации, а второй ромб: y стоит и в числителе, и в знаменателе.
    #  f(x,y) = x·(y+1)/(y−2) растёт по x и падает по y, значит настоящий
    #  максимум в углу (3, 4), а настоящий минимум — в углу (1, 5).
    @test isapprox(eval_expr!(g, 3.0, 4.0), 7.5; rtol = 1e-12)   # не 9.0
    @test isapprox(eval_expr!(g, 1.0, 5.0), 2.0; rtol = 1e-12)   # не 5/3
    @test isapprox(s.hi, 7.5; rtol = 1e-12)
    @test isapprox(s.lo, 2.0; rtol = 1e-12)
    #  Предсказание строго шире с ОБЕИХ сторон
    @test pred.lo < s.lo && s.hi < pred.hi
    #  Предсказанный максимум 9 требовал бы y = 5 в числителе и y = 4 в
    #  знаменателе одновременно — для метаданных это два независимых y.
    @test isapprox(pred.hi, 9.0; rtol = 1e-12)
    @test isapprox(pred.lo, 5/3; rtol = 1e-12)
end

# --------------------------------------------------------------------------
@testset "G5. отказ до исполнения                         " begin
    #  Делитель y − 2 при y ∈ [1, 5] пересекает нуль
    g = build_expr(ylo = 1.0, yhi = 5.0)
    @test getmeta(g.w, g.sub, :out) == (lo = -1.0, hi = 3.0)
    #  Отказ приходит из правила, поэтому обход называет узел и порт, а
    #  исходное сообщение остаётся внутри: искать причину не по стеку.
    @test_throws MetidaFlows.MetaRuleError getmeta(g.w, g.out, :out)
    err = try; getmeta(g.w, g.out, :out); catch e; e; end
    @test err.id == g.div
    @test occursin("containing zero", sprint(showerror, err))
    #  и ни один узел при этом не исполнялся
    @test all(n -> n.state.exec_n == 0, values(g.w.nodes))
    @test g.w.run_id == 0

    #  Отказ оправдан: при y = 2 настоящий прогон даёт бесконечность
    v = eval_expr!(g, 2.0, 2.0)
    @test isinf(v)
    #  Эталон обычным кодом отвечает так же — нечего считать
    @test ref_expr(1.0, 3.0, 1.0, 5.0, 2.0) === nothing

    #  Сузили диапазон так, что нуля больше нет — оценка снова есть
    g2 = build_expr(ylo = 2.5, yhi = 5.0)
    @test getmeta(g2.w, g2.out, :out) isa NamedTuple
end

# --------------------------------------------------------------------------
@testset "G6. незнание и тотальность правила              " begin
    g = build_expr()
    #  Снимаем диапазон у y: узел перестаёт быть источником метаданных
    yn = getnode(g.w, g.cy)
    delete!(yn.settings, :lo); delete!(yn.settings, :hi)
    @test !ismetasource(yn, :out)

    #  ТОТАЛЬНОСТЬ: правило зовётся на ветке «не источник», и обязано
    #  вернуть nothing, а не упасть KeyError на отсутствующей настройке.
    @test getmeta(g.w, g.cy, :out) === nothing

    #  И незнание поднимается до конца выражения
    @test getmeta(g.w, g.mul, :out) === nothing
    @test getmeta(g.w, g.out, :out) === nothing
    #  но ветвь, не зависящая от y, по-прежнему описана
    @test getmeta(g.w, g.cx, :out) == (lo = 1.0, hi = 3.0)

    #  Вернули диапазон — ответ вернулся
    setsettings!(g.w, g.cy, Dict(:lo => 4.0, :hi => 5.0))
    @test getmeta(g.w, g.out, :out) == (lo = 5.0/3.0, hi = 9.0)

    #  Узел без правила вовсе: описания нет ни у него, ни ниже по потоку
    w = Workflow(0; type = :DAW)
    a = add_node!(w, DataNode(IvConst, spec_ivconst()))
    setsettings!(w, a, Dict(:value => 1.0, :lo => 1.0, :hi => 2.0))
    #  AddNode из test_algorithms.jl правила метаданных не имеет
    nk = add_node!(w, DataNode(IvOut, spec_ivout()))
    add_connection!(w, a, :out, nk, :in)
    @test getmeta(w, nk, :out) == (lo = 1.0, hi = 2.0)
end

# --------------------------------------------------------------------------
@testset "G7. ромб: консервативно и один раз              " begin
    #  x − x при x ∈ [0, 1]: предсказание [−1, 1], фактически всегда 0.
    #  Метаданные не отслеживают тождество операндов, поэтому два прихода
    #  одного x для них независимы. Это проблема зависимости, не ошибка.
    w  = Workflow(0; type = :DAW)
    cx = add_node!(w, DataNode(IvConst, spec_ivconst()))
    setsettings!(w, cx, Dict(:value => 0.5, :lo => 0.0, :hi => 1.0))
    sb = add_node!(w, DataNode(IvSub, spec_ivbin("Iv sub")))
    ou = add_node!(w, DataNode(IvOut, spec_ivout()))
    add_connection!(w, cx, :out, sb, :a)
    add_connection!(w, cx, :out, sb, :b)       # тот же узел в оба входа
    add_connection!(w, sb, :out, ou, :in)

    @test getmeta(w, ou, :out) == (lo = -1.0, hi = 1.0)
    scheduler!(w)
    @test getdata(w, ou, :out) == 0.0          # и так при ЛЮБОМ x
    for xv in (0.0, 0.25, 0.5, 0.75, 1.0)
        setsettings!(w, cx, Dict(:value => xv))
        scheduler!(w)
        @test getdata(w, ou, :out) == 0.0
    end

    #  МЕМОИЗАЦИЯ: общий предок ромба описывается один раз за вызов.
    g = build_expr()
    IV_CALLS[] = 0
    getmeta(g.w, g.out, :out)
    #  8 узлов, 8 вызовов правила — ни одного повторного, хотя и x, и y
    #  нужны каждый двум потребителям
    @test IV_CALLS[] == length(g.w.nodes) == 8
    #  Между вызовами ничего не кешируется: второй обход считает заново
    IV_CALLS[] = 0
    getmeta(g.w, g.out, :out)
    @test IV_CALLS[] == 8
end

# --------------------------------------------------------------------------
@testset "G8. границы многочлена на отрезке               " begin
    #  Те же правила на графе схемы Горнера: вопрос «каковы границы P(x)
    #  при x ∈ [a, b]» получает ответ без единого исполнения.
    coeffs = [1.0, -6.0, 11.0, -6.0]          # (x−1)(x−2)(x−3), [a3,a2,a1,a0]
    g = build_poly(coeffs; xlo = 0.0, xhi = 4.0)
    pred = getmeta(g.w, g.out, :out)
    @test pred isa NamedTuple
    @test all(n -> n.state.exec_n == 0, values(g.w.nodes))

    #  Эталон: та же интервальная схема Горнера обычным кодом
    function ref_poly(coeffs, xlo, xhi)
        lo, hi = coeffs[1], coeffs[1]
        for k in 2:length(coeffs)
            q = (lo*xlo, lo*xhi, hi*xlo, hi*xhi)
            lo, hi = minimum(q) + coeffs[k], maximum(q) + coeffs[k]
        end
        (lo = lo, hi = hi)
    end
    @test pred == ref_poly(coeffs, 0.0, 4.0)

    #  Содержание: ни одна точка сетки не выходит за границы
    function sweep_poly!(g, pred, m, xlo, xhi)
        lo, hi, inside = Inf, -Inf, 0
        for i in 0:m
            xv = xlo + (xhi - xlo) * i / m
            v  = eval_poly!(g, xv)
            lo = min(lo, v); hi = max(hi, v)
            pred.lo <= v <= pred.hi && (inside += 1)
        end
        (lo = lo, hi = hi, inside = inside, total = m + 1)
    end
    s = sweep_poly!(g, pred, 2000, 0.0, 4.0)
    @test s.inside == s.total == 2001
    @test pred.lo <= s.lo && s.hi <= pred.hi

    #  Вырожденный отрезок: оценка становится точной
    g1 = build_poly(coeffs; xlo = 2.5, xhi = 2.5)
    p1 = getmeta(g1.w, g1.out, :out)
    @test isapprox(p1.lo, p1.hi; atol = 1e-12)
    @test isapprox(p1.lo, eval_poly!(g1, 2.5); rtol = 1e-12)

    #  Чем шире отрезок, тем шире оценка — и никогда наоборот
    widths = Float64[]
    for (a, b) in ((2.0, 2.0), (1.5, 2.5), (1.0, 3.0), (0.0, 4.0))
        p = getmeta(build_poly(coeffs; xlo = a, xhi = b).w,
                    build_poly(coeffs; xlo = a, xhi = b).out, :out)
        push!(widths, p.hi - p.lo)
    end
    @test issorted(widths)

    #  Размер графа: 3 узла на ступень (коэффициент, умножение, сложение),
    #  плюс константа x, плюс старший коэффициент, плюс сбор
    @test length(g.w.nodes) == 3 * (length(coeffs) - 1) + 3
end

end
