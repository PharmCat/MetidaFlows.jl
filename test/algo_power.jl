############################################################################
#
#  ЗООПАРК АЛГОРИТМОВ: БЫСТРОЕ ВОЗВЕДЕНИЕ В СТЕПЕНЬ ПО МОДУЛЮ
#
#  ГРАФ (11 узлов, 21 связь)
#
#   PConst(1) ─▶ head.init_result       ┌──▶ PIsZero (done: e == 0) ──┐
#   PConst(x) ─▶ head.init_base         │                             │
#   PConst(n) ─▶ head.init_exp          ├──▶ PIsOdd (odd: isodd e) ───┼─┐
#                                       │            │                │ │
#                        PowState ──────┤            ▼                │ │
#                        (result,       │      PowGuard ──▶ PMulMod   │ │
#                         base, exp)    │     (result, base)  (product)─┼─┤
#                             ▲         │                               │ │
#                             │         ├──▶ PMulMod (square: base²) ───┤ │
#                             │         └──▶ PHalf  (exp >> 1) ─────────┤ │
#   PConst(m) ─────────────────────────────▶ (оба PMulMod)              │ │
#                             │                                  PowGate ◀┘
#                             └────── :feedback ───────────────────┘  │
#                               (result, base, exp)                   ▼
#                                                                  :value
#
#
############################################################################

import MetidaFlows: PortSpec, DAW, ABW, getnode, getstatus, getportspec,
    get_children, setinputbuffer!, isready, reset!

# --------------------------------------------------------------------------
#  Эталон: тот же цикл обычным кодом, со счётчиками работы.
# --------------------------------------------------------------------------

function power_reference(x::Int, n::Int, m::Int)
    result = 1 % m
    base   = x % m
    e      = n
    muls   = 0      # умножений result*base
    sqrs   = 0      # возведений в квадрат
    turns  = 0
    while true
        turns += 1
        if e == 0
            return (value = result, muls = muls, sqrs = sqrs, turns = turns)
        end
        if isodd(e)
            result = (result * base) % m
            muls  += 1
        end
        base  = (base * base) % m
        sqrs += 1
        e     = e >> 1
    end
end

# ==========================================================================
#  Элементарные узлы
# ==========================================================================

struct PConst    <: AbstractNodeType end  # источник целой константы
struct PowState  <: AbstractNodeType end  # состояние цикла
struct PIsZero   <: AbstractNodeType end  # a == 0
struct PIsOdd    <: AbstractNodeType end  # isodd(a)
struct PowGuard  <: AbstractNodeType end  # сторож: проводит пару или молчит
struct PMulMod   <: AbstractNodeType end  # a * b % m
struct PMulModIf <: AbstractNodeType end  # a * b % m, только по признаку
struct PHalf     <: AbstractNodeType end  # a >> 1
struct PowGate   <: AbstractNodeType end  # ветвление витка
struct PowGateAll <: AbstractNodeType end # ворота для сравнения: выбирают по чётности

spec_pconst() = NodeSpec("P const", PortSpec[],
    [PortSpec("Out", Int, :out)], [:value])

spec_powstate() = NodeSpec("Pow state",
    [PortSpec("Initial result", Int, :init_result),
     PortSpec("Initial base",   Int, :init_base),
     PortSpec("Initial exp",    Int, :init_exp),
     PortSpec("Result",   Int, :result; kind = :feedback, required = false),
     PortSpec("Base",     Int, :base;   kind = :feedback, required = false),
     PortSpec("Exponent", Int, :exp;    kind = :feedback, required = false)],
    [PortSpec("Result",   Int, :result),
     PortSpec("Base",     Int, :base),
     PortSpec("Exponent", Int, :exp)])

spec_piszero() = NodeSpec("P is zero",
    [PortSpec("A", Int, :a)], [PortSpec("Out", Bool, :out)])
spec_pisodd() = NodeSpec("P is odd",
    [PortSpec("A", Int, :a)], [PortSpec("Out", Bool, :out)])
spec_phalf() = NodeSpec("P half",
    [PortSpec("A", Int, :a)], [PortSpec("Out", Int, :out)])

spec_pmulmod() = NodeSpec("P mul mod",
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b), PortSpec("M", Int, :m)],
    [PortSpec("Out", Int, :out)])

#  Умножение, которое делается только по признаку. Узел исполняется
#  всегда — дешёвая проверка флага, — а САМО УМНОЖЕНИЕ и публикация
#  происходят лишь на нечётном витке. Потребитель читает `nothing`.
spec_pmulmodif() = NodeSpec("P mul mod if",
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b), PortSpec("M", Int, :m),
     PortSpec("Pass", Bool, :pass)],
    [PortSpec("Out", Int, :out)])

#  СТОРОЖ. Проводит обе величины, которые нужны умножению, либо не
#  публикует ничего. Второе и означает «этого умножения на этом витке
#  нет»: узел умножения не попадает в очередь.
spec_powguard() = NodeSpec("Pow guard",
    [PortSpec("Result", Int,  :result),
     PortSpec("Base",   Int,  :base),
     PortSpec("Pass",   Bool, :pass)],
    [PortSpec("Result", Int, :result),
     PortSpec("Base",   Int, :base)])

#  Ворота. `:product` НЕОБЯЗАТЕЛЬНЫЙ: на чётном витке произведения нет,
#  и `nothing` здесь — не ошибка, а признак ветви.
spec_powgate() = NodeSpec("Pow gate",
    [PortSpec("Done",      Bool, :done),
     PortSpec("Result",    Int,  :result),
     PortSpec("Product",   Int,  :product; required = false),
     PortSpec("Base next", Int,  :base_next),
     PortSpec("Exp next",  Int,  :exp_next)],
    [PortSpec("Result",   Int, :result),
     PortSpec("Base",     Int, :base),
     PortSpec("Exponent", Int, :exp),
     PortSpec("Value",    Int, :value; kind = :terminal)])

#  Ворота варианта :always. Произведение приходит ВСЕГДА, поэтому выбор
#  делается по признаку чётности, а не по отсутствию значения. Нужны
#  только для сравнения в группе W5.
spec_powgateall() = NodeSpec("Pow gate all",
    [PortSpec("Done",      Bool, :done),
     PortSpec("Result",    Int,  :result),
     PortSpec("Product",   Int,  :product),
     PortSpec("Odd",       Bool, :odd),
     PortSpec("Base next", Int,  :base_next),
     PortSpec("Exp next",  Int,  :exp_next)],
    [PortSpec("Result",   Int, :result),
     PortSpec("Base",     Int, :base),
     PortSpec("Exponent", Int, :exp),
     PortSpec("Value",    Int, :value; kind = :terminal)])

# --- реализации -----------------------------------------------------------

MetidaFlows.execute_unsafe!(n::DataNode{PConst}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{PIsZero}) =
    (setdata!(n, :out, getinputdata(n, :a) == 0); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{PIsOdd}) =
    (setdata!(n, :out, isodd(getinputdata(n, :a))); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{PHalf}) =
    (setdata!(n, :out, getinputdata(n, :a) >> 1); [:out])

POW_MULS = Ref(0)                      # сколько раз исполнилось умножение
resetpow!() = (POW_MULS[] = 0)

function MetidaFlows.execute_unsafe!(node::DataNode{PMulMod})
    POW_MULS[] += 1
    a = getinputdata(node, :a); b = getinputdata(node, :b)
    setdata!(node, :out, (a * b) % getinputdata(node, :m))
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{PMulModIf})
    getinputdata(node, :pass) || return Symbol[]      # умножения не будет
    POW_MULS[] += 1
    a = getinputdata(node, :a); b = getinputdata(node, :b)
    setdata!(node, :out, (a * b) % getinputdata(node, :m))
    return [:out]
end

#  Вот всё короткое замыкание: пустой список готовых портов.
MetidaFlows.execute_unsafe!(node::DataNode{PowGuard}) =
    getinputdata(node, :pass) ?
        (setdata!(node, :result, getinputdata(node, :result));
         setdata!(node, :base,   getinputdata(node, :base));
         [:result, :base]) : Symbol[]

function MetidaFlows.execute_unsafe!(node::DataNode{PowGate})
    result = getinputdata(node, :result)
    if getinputdata(node, :done)
        setdata!(node, :value, result)
        return [:value]
    end
    product = getinputdata(node, :product)      # nothing на чётном витке
    setdata!(node, :result, isnothing(product) ? result : product)
    setdata!(node, :base,   getinputdata(node, :base_next))
    setdata!(node, :exp,    getinputdata(node, :exp_next))
    return [:result, :base, :exp]
end

function MetidaFlows.execute_unsafe!(node::DataNode{PowGateAll})
    result = getinputdata(node, :result)
    if getinputdata(node, :done)
        setdata!(node, :value, result)
        return [:value]
    end
    setdata!(node, :result,
             getinputdata(node, :odd) ? getinputdata(node, :product) : result)
    setdata!(node, :base, getinputdata(node, :base_next))
    setdata!(node, :exp,  getinputdata(node, :exp_next))
    return [:result, :base, :exp]
end

function MetidaFlows.execute_unsafe!(node::DataNode{PowState})
    back = getinputdata(node, :result)
    if back === nothing
        setdata!(node, :result, getinputdata(node, :init_result))
        setdata!(node, :base,   getinputdata(node, :init_base))
        setdata!(node, :exp,    getinputdata(node, :init_exp))
    else
        setdata!(node, :result, back)
        setdata!(node, :base,   getinputdata(node, :base))
        setdata!(node, :exp,    getinputdata(node, :exp))
    end
    return [:result, :base, :exp]
end

# ==========================================================================
#  Сборка графа
# ==========================================================================

"""
    build_power(x, n, m; mode = :conditional) -> NamedTuple

Граф быстрого возведения в степень по модулю. Режимы отличаются только
тем, как выражено «умножения на этом витке нет»:

* `:conditional` — узел умножения исполняется всегда, но умножает и
  публикует лишь по признаку. Ворота читают `nothing` и несут прежний
  `result`. Это рабочий вариант;
* `:always` — умножение считается каждый виток, ворота выбирают по
  признаку. Результат тот же, умножений больше (группа W5);
* `:guarded` — полный сторож перед умножением. В цикле НЕ РАБОТАЕТ, и
  группа W8 показывает почему: заглушённый узел остаётся `:dirty`, а
  `isready` ждёт `:clean` родителя даже для необязательного порта. С
  `scheduler!(w; release_optional = true)` работает, и экономит сверх
  умножения ещё и исполнение узла (группа W9).
"""
function build_power(x::Int, n::Int, m::Int; mode::Symbol = :conditional)
    mode in (:conditional, :always, :guarded) ||
        error("mode must be :conditional, :always or :guarded")
    w      = Workflow(0; type = :ABW)
    w.name = "Modular exponentiation"

    cone = add_node!(w, DataNode(PConst, spec_pconst()))
    cx   = add_node!(w, DataNode(PConst, spec_pconst()))
    cn   = add_node!(w, DataNode(PConst, spec_pconst()))
    cm   = add_node!(w, DataNode(PConst, spec_pconst()))
    setsettings!(w, cone, Dict(:value => 1 % m))
    setsettings!(w, cx,   Dict(:value => x % m))
    setsettings!(w, cn,   Dict(:value => n))
    setsettings!(w, cm,   Dict(:value => m))

    head = add_node!(w, DataNode(PowState, spec_powstate()))
    done = add_node!(w, DataNode(PIsZero,  spec_piszero()))
    odd  = add_node!(w, DataNode(PIsOdd,   spec_pisodd()))
    sqr  = add_node!(w, DataNode(PMulMod,  spec_pmulmod()))
    half = add_node!(w, DataNode(PHalf,    spec_phalf()))
    gate = mode === :always ?
        add_node!(w, DataNode(PowGateAll, spec_powgateall())) :
        add_node!(w, DataNode(PowGate,    spec_powgate()))
    prod = mode === :conditional ?
        add_node!(w, DataNode(PMulModIf, spec_pmulmodif())) :
        add_node!(w, DataNode(PMulMod,   spec_pmulmod()))
    guard = mode === :guarded ? add_node!(w, DataNode(PowGuard, spec_powguard())) : 0

    add_connection!(w, cone, :out, head, :init_result)
    add_connection!(w, cx,   :out, head, :init_base)
    add_connection!(w, cn,   :out, head, :init_exp)

    add_connection!(w, head, :exp, done, :a)
    add_connection!(w, head, :exp, odd,  :a)
    add_connection!(w, head, :exp, half, :a)

    if mode === :guarded
        #  Через сторожа идёт всё, что нужно умножению
        add_connection!(w, head, :result, guard, :result)
        add_connection!(w, head, :base,   guard, :base)
        add_connection!(w, odd,  :out,    guard, :pass)
        add_connection!(w, guard, :result, prod, :a)
        add_connection!(w, guard, :base,   prod, :b)
    else
        add_connection!(w, head, :result, prod, :a)
        add_connection!(w, head, :base,   prod, :b)
        mode === :conditional && add_connection!(w, odd, :out, prod, :pass)
    end
    add_connection!(w, cm, :out, prod, :m)

    add_connection!(w, head, :base, sqr, :a)
    add_connection!(w, head, :base, sqr, :b)
    add_connection!(w, cm,   :out,  sqr, :m)

    add_connection!(w, done, :out,    gate, :done)
    add_connection!(w, head, :result, gate, :result)
    mode === :always && add_connection!(w, odd, :out, gate, :odd)
    add_connection!(w, prod, :out,    gate, :product)
    add_connection!(w, sqr,  :out,    gate, :base_next)
    add_connection!(w, half, :out,    gate, :exp_next)

    add_connection!(w, gate, :result, head, :result)
    add_connection!(w, gate, :base,   head, :base)
    add_connection!(w, gate, :exp,    head, :exp)

    return (w = w, cone = cone, cx = cx, cn = cn, cm = cm, head = head,
            done = done, odd = odd, guard = guard, prod = prod, sqr = sqr,
            half = half, gate = gate, mode = mode)
end

"Посчитать степень графом. Возвращает значение, счётчики работы и граф."
function graph_power(x::Int, n::Int, m::Int; mode::Symbol = :conditional)
    resetpow!()
    g = build_power(x, n, m; mode = mode)
    scheduler!(g.w; maxiter = 1_000_000)
    sqrs = getnode(g.w, g.sqr).state.exec_n
    return (value = getdata(g.w, g.gate, :value),
            muls  = getnode(g.w, g.prod).state.exec_n,   # исполнений узла
            mulsdone = POW_MULS[] - sqrs,                 # настоящих умножений
            sqrs  = sqrs,
            turns = getnode(g.w, g.head).state.exec_n,
            mulcalls = POW_MULS[],
            g = g)
end

# ==========================================================================

@testset verbose = true "ВОЗВЕДЕНИЕ В СТЕПЕНЬ: КОРОТКОЕ ЗАМЫКАНИЕ        " begin

# --------------------------------------------------------------------------
@testset "W1. элементарные узлы по отдельности            " begin
    function run1(type, spec, inputs::Dict{Symbol, Any}; settings = Dict{Symbol, Any}())
        node = DataNode(type, spec; settings = settings)
        for (port, value) in inputs
            setinputbuffer!(node, port, 1, value)
        end
        node, MetidaFlows.execute_unsafe!(node)
    end

    n, p = run1(PConst, spec_pconst(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => 7))
    @test p == [:out] && getdata(n, :out) === 7

    n, _ = run1(PIsZero, spec_piszero(), Dict{Symbol, Any}(:a => 0))
    @test getdata(n, :out) === true
    n, _ = run1(PIsZero, spec_piszero(), Dict{Symbol, Any}(:a => 3))
    @test getdata(n, :out) === false
    n, _ = run1(PIsOdd, spec_pisodd(), Dict{Symbol, Any}(:a => 5))
    @test getdata(n, :out) === true
    n, _ = run1(PIsOdd, spec_pisodd(), Dict{Symbol, Any}(:a => 0))
    @test getdata(n, :out) === false
    n, _ = run1(PHalf, spec_phalf(), Dict{Symbol, Any}(:a => 5))
    @test getdata(n, :out) === 2

    resetpow!()
    n, _ = run1(PMulMod, spec_pmulmod(), Dict{Symbol, Any}(:a => 5, :b => 4, :m => 7))
    @test getdata(n, :out) === 6                      # 20 % 7
    @test POW_MULS[] == 1

    #  СТОРОЖ: открыт — публикует пару, закрыт — не публикует ничего
    n, p = run1(PowGuard, spec_powguard(),
                Dict{Symbol, Any}(:result => 3, :base => 4, :pass => true))
    @test p == [:result, :base]
    @test getdata(n, :result) === 3 && getdata(n, :base) === 4
    n, p = run1(PowGuard, spec_powguard(),
                Dict{Symbol, Any}(:result => 3, :base => 4, :pass => false))
    @test p == Symbol[]
    @test getdata(n, :result) === nothing
    @test getdata(n, :base)   === nothing

    #  ВОРОТА: три случая, и среди них отсутствующее произведение
    gbase = Dict{Symbol, Any}(:done => false, :result => 3, :product => 5,
                              :base_next => 2, :exp_next => 1)
    n, p = run1(PowGate, spec_powgate(), gbase)
    @test p == [:result, :base, :exp]
    @test getdata(n, :result) === 5                   # взято произведение
    n, _ = run1(PowGate, spec_powgate(), delete!(copy(gbase), :product))
    @test getdata(n, :result) === 3                   # произведения нет
    n, p = run1(PowGate, spec_powgate(),
                merge(gbase, Dict{Symbol, Any}(:done => true)))
    @test p == [:value] && getdata(n, :value) === 3

    #  порт :product действительно необязательный
    @test !getportspec(DataNode(PowGate, spec_powgate()), :product, :input).required
end

# --------------------------------------------------------------------------
@testset "W2. структура графа                            " begin
    g = build_power(3, 5, 7)
    @test length(g.w.nodes) == 11
    @test length(g.w.connections) == 21
    @test g.w isa Workflow{ABW}

    #  три обратных ребра, все из ворот в голову
    fb = [c for (_, c) in g.w.connections
          if getportspec(getnode(g.w, c.input_id), c.input_port, :input).kind == :feedback]
    @test length(fb) == 3
    @test all(c -> c.output_id == g.gate && c.input_id == g.head, fb)

    #  Умножение берёт признак у PIsOdd — вот и всё условие
    pin = [getconnection(g.w, c).output_id for c in g.w.incoming[g.prod]]
    @test Set(pin) == Set([g.head, g.cm, g.odd])
    #  возведение в квадрат признака не имеет: оно каждый виток
    sin_ = [getconnection(g.w, c).output_id for c in g.w.incoming[g.sqr]]
    @test Set(sin_) == Set([g.head, g.cm])
    #  порт :product у ворот необязательный — на нём стоит вся развязка
    @test !getportspec(getnode(g.w, g.gate), :product, :input).required

    #  вариант :always — то же, но без признака
    g2 = build_power(3, 5, 7; mode = :always)
    @test length(g2.w.nodes) == 11
    @test length(g2.w.connections) == 21
    pin2 = [getconnection(g2.w, c).output_id for c in g2.w.incoming[g2.prod]]
    @test Set(pin2) == Set([g2.head, g2.cm])
end

# --------------------------------------------------------------------------
@testset "W3. значение совпадает с powermod              " begin
    cases = ((3, 5, 7), (2, 10, 1000), (7, 0, 13), (5, 1, 13), (10, 20, 97),
             (123, 45, 1_000_003), (2, 64, 1_000_003), (99, 100, 101))
    for (x, n, m) in cases
        r = graph_power(x, n, m)
        @test r.value == powermod(x, n, m)
        ref = power_reference(x, n, m)
        @test r.value == ref.value
        @test r.turns == ref.turns
        @test r.mulsdone == ref.muls
        #  Квадратов на ОДИН больше, чем у императивного цикла: тот
        #  проверяет выход до возведения в квадрат, а здесь проверка в
        #  воротах, то есть в конце витка. Завершающий виток считает
        #  base² и ворота его выбрасывают — цена постпроверки.
        @test r.sqrs == ref.sqrs + 1
        @test r.sqrs == r.turns
    end

    #  показатель ноль — цикл не крутится вовсе
    r = graph_power(7, 0, 13)
    @test r.value == 1
    @test r.turns == 1 && r.mulsdone == 0
    @test r.sqrs == 1                                 # один выброшенный квадрат
end

# --------------------------------------------------------------------------
@testset "W4. умножений ровно столько, сколько единиц     " begin
    #  ГЛАВНОЕ ИЗМЕРЕНИЕ ФАЙЛА. Сторож закрыт на чётном витке, узел
    #  умножения не попадает в очередь и не исполняется.
    for n in (1, 2, 3, 5, 8, 15, 16, 31, 64, 100, 255, 256, 1000, 1023, 1024)
        r = graph_power(3, n, 1_000_003)
        @test r.value == powermod(3, n, 1_000_003)
        #  УМНОЖЕНИЙ столько, сколько единиц в показателе. Узел при этом
        #  исполняется каждый виток — он только проверяет признак.
        @test r.mulsdone == count_ones(n)
        #  витков — по одному на бит показателя плюс завершающий
        @test r.turns == (8 * sizeof(n) - leading_zeros(n)) + 1
        @test r.sqrs  == r.turns
        #  POW_MULS считает НАСТОЯЩИЕ умножения: произведений ровно
        #  count_ones(n), квадратов — по одному на виток
        @test r.mulcalls == count_ones(n) + r.sqrs
    end

    #  степень двойки — худший случай для наивного и лучший для этого:
    #  одно умножение на любой размер показателя
    for k in (4, 8, 16, 20)
        r = graph_power(3, 2^k, 1_000_003)
        @test r.mulsdone == 1
        @test r.sqrs == k + 2
    end
end

# --------------------------------------------------------------------------
@testset "W5. без условия результат тот же, работа вся    " begin
    #  Тот же алгоритм, но произведение считается каждый виток, а выбор
    #  ворота делают по признаку чётности. Результат совпадает, умножений
    #  больше — именно это и значит, что условное вычисление здесь не
    #  украшение.
    for n in (5, 15, 16, 100, 255, 256, 1024)
        on  = graph_power(3, n, 1_000_003)
        off = graph_power(3, n, 1_000_003; mode = :always)

        @test on.value == off.value == powermod(3, n, 1_000_003)
        @test on.turns == off.turns                        # витков столько же
        @test on.mulsdone  == count_ones(n)                # только единицы
        @test off.mulsdone == off.turns                    # каждый виток
        @test on.mulsdone <= off.mulsdone
    end

    #  на степени двойки разница наибольшая
    on  = graph_power(3, 1024, 1_000_003)
    off = graph_power(3, 1024, 1_000_003; mode = :always)
    @test on.mulsdone == 1
    @test off.mulsdone == 12
    #  узел умножения в обоих вариантах исполняется каждый виток: он
    #  дешёвый, экономится само умножение
    @test on.muls == off.muls == on.turns
end

# --------------------------------------------------------------------------
@testset "W6. что видно в графе на чётном витке          " begin
    #  Показатель 2 = 0b10: виток 1 чётный, виток 2 нечётный, виток 3
    #  завершающий (показатель ноль, то есть тоже чётный).
    r = graph_power(3, 2, 1_000_003)
    @test r.value == 9
    @test r.turns == 3
    @test r.mulsdone == 1 == count_ones(2)

    prod = getnode(r.g.w, r.g.prod)
    #  Узел умножения исполнялся КАЖДЫЙ виток — он только проверяет
    #  признак, — а умножил один раз.
    @test prod.state.exec_n == r.turns
    @test getstatus(prod) === :clean
    #  На завершающем витке он не публиковал: список готовых портов пуст
    @test isempty(MetidaFlows.getstate(prod, :ready_ports))
    #  и буфер произведения у ворот пуст — значения прошлого витка там
    #  нет, его снял invalidate_unpublished!
    @test isempty(getnode(r.g.w, r.g.gate).input_buffer[:product])
    @test getinputdata(getnode(r.g.w, r.g.gate), :product) === nothing

    #  ворота отработали каждый виток
    @test getnode(r.g.w, r.g.gate).state.exec_n == r.turns

    #  а на нечётном показателе всё наоборот: последний виток публикует
    r2 = graph_power(3, 1, 1_000_003)
    @test r2.value == 3
    @test r2.mulsdone == 1
end

# --------------------------------------------------------------------------
@testset "W7. сторож в ациклическом графе                " begin
    #  Тот же идиом на DAW, где обход доходит до охраняемого узла. Он всё
    #  равно не исполняется: `isready` видит, что производитель в его
    #  обязательный порт не публиковал.
    w  = Workflow(0; type = :DAW)
    cv = add_node!(w, DataNode(PConst, spec_pconst()))
    cb = add_node!(w, DataNode(PConst, spec_pconst()))
    cm = add_node!(w, DataNode(PConst, spec_pconst()))
    pz = add_node!(w, DataNode(PIsZero, spec_piszero()))   # признак: cv == 0
    gd = add_node!(w, DataNode(PowGuard, spec_powguard()))
    pr = add_node!(w, DataNode(PMulMod, spec_pmulmod()))
    setsettings!(w, cv, Dict(:value => 0))                 # ноль → признак true
    setsettings!(w, cb, Dict(:value => 4))
    setsettings!(w, cm, Dict(:value => 7))
    add_connection!(w, cv, :out, pz, :a)
    add_connection!(w, cv, :out, gd, :result)
    add_connection!(w, cb, :out, gd, :base)
    add_connection!(w, pz, :out, gd, :pass)
    add_connection!(w, gd, :result, pr, :a)
    add_connection!(w, gd, :base,   pr, :b)
    add_connection!(w, cm, :out,    pr, :m)

    resetpow!()
    scheduler!(w)
    @test getstatus(getnode(w, gd)) === :clean
    @test getdata(w, pr, :out) == 0                        # 0 * 4 % 7
    @test POW_MULS[] == 1

    #  закрываем сторожа: тот же граф, признак false
    setsettings!(w, cv, Dict(:value => 3))                 # 3 != 0 → false
    resetpow!()
    scheduler!(w)
    @test getstatus(getnode(w, gd)) === :clean
    @test getnode(w, pr).state.exec_n == 0                 # НЕ исполнялся
    @test getstatus(getnode(w, pr)) === :dirty             # не :invalid_node
    @test POW_MULS[] == 0
    @test getdata(w, pr, :out) === nothing
    @test !isready(w, pr)
    @test isempty(getnode(w, pr).input_buffer[:a])
end

# --------------------------------------------------------------------------
@testset "W8. тот же сторож в цикле ВСТАЁТ               " begin
    #  На DAW (W7) сторож работает, потому что охраняемый узел — тупик:
    #  его выход никому не нужен. В цикле он нужен воротам, и там тот же
    #  идиом ломается. Ровно поэтому в графе стоит `PMulModIf`, а не
    #  сторож: причина не вкусовая, и вот она, замеренная.
    #
    #  Цепочка: сторож на чётном витке не публикует → умножение не
    #  готово и НЕ ИСПОЛНЯЕТСЯ → остаётся `:dirty` → у ворот порт
    #  `:product` необязательный, но `isready` всё равно ждёт от его
    #  производителя `:clean` → ворота не готовы никогда.
    #
    #  Прогон при этом не висит и не падает: очередь просто пустеет.
    #  Граф молча встаёт без результата — поведение, которое снаружи
    #  неотличимо от «ещё считается». Лечится кваргом
    #  `release_optional = true`, см. группу W9.
    for (n, turns) in ((5, 2), (4, 1), (2, 1), (1024, 1))
        resetpow!()
        g = build_power(3, n, 1_000_003; mode = :guarded)
        scheduler!(g.w; maxiter = 10_000)

        @test getdata(g.w, g.gate, :value) === nothing       # результата нет
        @test getnode(g.w, g.head).state.exec_n == turns     # встал на 1-м чётном
        @test getstatus(getnode(g.w, g.guard)) === :clean    # сторож отработал
        @test getstatus(getnode(g.w, g.prod))  === :dirty    # умножение — нет
        @test getstatus(getnode(g.w, g.gate))  === :dirty
        @test !MetidaFlows.isready(g.w, g.gate)              # и не будет готово
    end

    #  n = 5: первый виток нечётный, сторож открыт, умножение прошло;
    #  встало только на втором витке.
    resetpow!()
    g = build_power(3, 5, 1_000_003; mode = :guarded)
    scheduler!(g.w; maxiter = 10_000)
    @test getnode(g.w, g.guard).state.exec_n == 2
    @test getnode(g.w, g.prod).state.exec_n  == 1

    #  Рабочий вариант на том же показателе досчитывается.
    @test graph_power(3, 5, 1_000_003).value == powermod(3, 5, 1_000_003)
end

# --------------------------------------------------------------------------
@testset "W9. сторож в цикле с release_optional          " begin
    #  Тот же сторожевой граф, что встал в W8, но планировщику разрешено
    #  выпускать узлы, которым мешают только необязательные порты. На
    #  затишье очереди это уже не догадка: раз очередь пуста, умножение
    #  само не исполнится никогда, и `nothing` у ворот — ответ.
    #
    #  И сторож оказывается ВЫГОДНЕЕ признака: он экономит не только
    #  умножение, но и исполнение узла. Сравнение ниже меряет оба.
    for n in (1, 2, 3, 4, 5, 15, 16, 100, 255, 1024)
        resetpow!()
        g = build_power(3, n, 1_000_003; mode = :guarded)
        scheduler!(g.w; maxiter = 100_000, release_optional = true)
        sqrs = getnode(g.w, g.sqr).state.exec_n

        @test getdata(g.w, g.gate, :value) == powermod(3, n, 1_000_003)
        @test getnode(g.w, g.head).state.exec_n == ndigits(n; base = 2) + 1
        #  умножений столько же, сколько у рабочего варианта
        @test POW_MULS[] - sqrs == count_ones(n)
        #  а ИСПОЛНЕНИЙ узла умножения — тоже столько, а не каждый виток
        @test getnode(g.w, g.prod).state.exec_n == count_ones(n)
        @test getstatus(getnode(g.w, g.gate)) === :clean
    end

    #  Прямое сравнение на степени двойки: признак против сторожа
    cond = graph_power(3, 1024, 1_000_003)
    resetpow!()
    gg = build_power(3, 1024, 1_000_003; mode = :guarded)
    scheduler!(gg.w; maxiter = 100_000, release_optional = true)
    @test getdata(gg.w, gg.gate, :value) == cond.value
    @test cond.muls == cond.turns == 12          # признак: узел считался каждый виток
    @test getnode(gg.w, gg.prod).state.exec_n == 1  # сторож: один раз
    @test cond.mulsdone == 1                     # умножение одно и там и там

    #  Флаг ничего не меняет в рабочем варианте: он никого не блокирует
    for n in (5, 100, 1024)
        a = graph_power(3, n, 1_000_003)
        resetpow!()
        g = build_power(3, n, 1_000_003)
        scheduler!(g.w; maxiter = 100_000, release_optional = true)
        sqrs = getnode(g.w, g.sqr).state.exec_n
        @test getdata(g.w, g.gate, :value) == a.value
        @test getnode(g.w, g.head).state.exec_n == a.turns
        @test POW_MULS[] - sqrs == a.mulsdone
        #  и в журнал ничего не писалось — выпускать было некого
        @test !any(m -> occursin("release_optional", m.message), g.w.log)
    end
end

end
