############################################################################
#
#  ЗООПАРК АЛГОРИТМОВ: ГРАДИЕНТНЫЙ СПУСК
#
#  РАСКЛАДКА ЕСТЕСТВЕННАЯ, БЕЗ РЕЛЬСОВ
#
#
#  ГРАФ
#
#   ConstFloat(x0) ─┐                     ┌─▶ AddFloat(x,h) ─▶ Sub ─▶ Mul ─┐
#   ConstInt(0) ────┼─▶ DescentState ─────┤      (x+h)        (−c)   (²)   │
#                   │        ▲            └─▶ SubFloat(x,h) ─▶ Sub ─▶ Mul ─┤
#                   │        │                  (x−h)         (−c)   (²)   │
#   ConstFloat(h) ──┼────────┼───▶ AddFloat(h,h) ─────┐                    │
#                   │        │                        │      SubFloat(fp,fm)
#                   │        │                        └──────▶ DivFloat ──▶ grad
#                   │        │                                              │
#   ConstFloat(rate)┼────────┼──────────────────▶ MulFloat(rate, grad) ─────┤
#                   │        │                           │                  │
#                   │        │                     SubFloat(x, step) ─▶ x'  │
#                   │        │                                              ▼
#   ConstFloat(tol) ┼────────┼──────────────────▶ LessFloat ◀── AbsFloat(grad)
#                   │        │                        │
#   ConstInt(1) ────┼────────┼──▶ AddInt(iter,1) ─▶ NotLessInt ◀── ConstInt(max)
#                   │        │          │                │
#                   │        │          │           OrBool(conv, exh)
#                   │        │          ▼                ▼
#                   │        └── :feedback ───── DescentGate ──▶ :minimum
#                   │                                         ──▶ :iterations
#                   └─────────────────────────────────────────  ──▶ :reason
#
############################################################################

import MetidaFlows: PortSpec, SinglePort, DAW, ABW, NodeState, NodeProperties,
    getnode, getconnection, nodetypestr, getstate, getportspec, getporttype,
    getid, makegraph, get_parents, get_children, isportexist, haveinputs,
    setinputbuffer!, delete_connection!, reset!

# --------------------------------------------------------------------------
#  Инструментовка: след точек по итерациям. Ворота видят x' на каждом
#  витке, поэтому длина следа равна числу итераций.
# --------------------------------------------------------------------------

DESCENT_TRACE = Float64[]
tracedescent!(x) = push!(DESCENT_TRACE, x)
resetdescent!()  = empty!(DESCENT_TRACE)

# --------------------------------------------------------------------------
#  Эталон. Порядок операций повторён ОДИН В ОДИН, чтобы след сравнивался
#  побитово, а не с допуском.
# --------------------------------------------------------------------------

function descent_reference(; x0, rate, tol, h, c, maxiter, scale = 1.0)
    objective(y) = scale * ((y - c) * (y - c))
    x     = x0
    iter  = 0
    trace = Float64[]
    while true
        fp   = objective(x + h)
        fm   = objective(x - h)
        grad = (fp - fm) / (h + h)
        x    = x - rate * grad
        iter = iter + 1
        push!(trace, x)
        conv = abs(grad) < tol
        exh  = iter >= maxiter
        if conv || exh
            return (x = x, iter = iter,
                    reason = conv ? :converged : :exhausted, trace = trace)
        end
    end
end

# ==========================================================================
#  Элементарные узлы. Арифметика универсальная, специфичны для алгоритма
#  только голова цикла и ворота.
# ==========================================================================

struct ConstFloat   <: AbstractNodeType end  # источник вещественной константы
struct ConstInt     <: AbstractNodeType end  # источник целой константы
struct DescentState <: AbstractNodeType end  # состояние цикла (x, iter)
struct AddFloat     <: AbstractNodeType end  # a + b
struct SubFloat     <: AbstractNodeType end  # a − b
struct MulFloat     <: AbstractNodeType end  # a · b
struct DivFloat     <: AbstractNodeType end  # a / b
struct AbsFloat     <: AbstractNodeType end  # |a|
struct LessFloat    <: AbstractNodeType end  # a < b
struct AddInt       <: AbstractNodeType end  # a + b, целые
struct NotLessInt   <: AbstractNodeType end  # a >= b, целые
struct OrBool       <: AbstractNodeType end  # a || b
struct DescentGate  <: AbstractNodeType end  # ветвление: виток или результат

# --- спецификации ---------------------------------------------------------

spec_constfloat() = NodeSpec("Const float", PortSpec[],
    [PortSpec("Value", Float64, :out)], [:value])

spec_constint() = NodeSpec("Const int", PortSpec[],
    [PortSpec("Value", Int, :out)], [:value])

# Обычные входы — начальная точка и начальный счётчик; обратные несут
# состояние прошлой итерации и не required, потому что на первом витке их
# буферы пусты.
spec_descentstate() = NodeSpec("Descent state",
    [PortSpec("Initial x",    Float64, :init_x),
     PortSpec("Initial iter", Int,     :init_iter),
     PortSpec("X",            Float64, :x;    kind = :feedback, required = false),
     PortSpec("Iteration",    Int,     :iter; kind = :feedback, required = false)],
    [PortSpec("X",         Float64, :x),
     PortSpec("Iteration", Int,     :iter)])

binary_float(name, out) = NodeSpec(name,
    [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
    [PortSpec("Out", out, :out)])

spec_addfloat()   = binary_float("Add float", Float64)
spec_subfloat()   = binary_float("Sub float", Float64)
spec_mulfloat()   = binary_float("Mul float", Float64)
spec_divfloat()   = binary_float("Div float", Float64)
spec_lessfloat()  = binary_float("Less float", Bool)

spec_absfloat() = NodeSpec("Abs float",
    [PortSpec("A", Float64, :a)], [PortSpec("Out", Float64, :out)])

spec_addint() = NodeSpec("Add int",
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
    [PortSpec("Out", Int, :out)])

spec_notlessint() = NodeSpec("Not less int",
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
    [PortSpec("Out", Bool, :out)])

spec_orbool() = NodeSpec("Or bool",
    [PortSpec("A", Bool, :a), PortSpec("B", Bool, :b)],
    [PortSpec("Out", Bool, :out)])

# Ворота выбирают из трёх исходов: ещё виток, сошлось, исчерпано. Причина
# останова выходит отдельным терминальным портом.
spec_descentgate() = NodeSpec("Descent gate",
    [PortSpec("Stop",      Bool,    :stop),
     PortSpec("Converged", Bool,    :converged),
     PortSpec("X",         Float64, :x),
     PortSpec("Iteration", Int,     :iter)],
    [PortSpec("X",          Float64, :x),
     PortSpec("Iteration",  Int,     :iter),
     PortSpec("Minimum",    Float64, :minimum;    kind = :terminal),
     PortSpec("Iterations", Int,     :iterations; kind = :terminal),
     PortSpec("Reason",     Symbol,  :reason;     kind = :terminal)])

# --- реализации -----------------------------------------------------------

MetidaFlows.execute_unsafe!(n::DataNode{ConstFloat}) =
    (setdata!(n, :out, Float64(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{ConstInt}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])

MetidaFlows.execute_unsafe!(n::DataNode{AddFloat}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{SubFloat}) =
    (setdata!(n, :out, getinputdata(n, :a) - getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{MulFloat}) =
    (setdata!(n, :out, getinputdata(n, :a) * getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{DivFloat}) =
    (setdata!(n, :out, getinputdata(n, :a) / getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{AbsFloat}) =
    (setdata!(n, :out, abs(getinputdata(n, :a))); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{LessFloat}) =
    (setdata!(n, :out, getinputdata(n, :a) < getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{AddInt}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{NotLessInt}) =
    (setdata!(n, :out, getinputdata(n, :a) >= getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{OrBool}) =
    (setdata!(n, :out, getinputdata(n, :a) || getinputdata(n, :b)); [:out])

function MetidaFlows.execute_unsafe!(node::DataNode{DescentState})
    back = getinputdata(node, :x)
    if back === nothing                       # первая итерация
        setdata!(node, :x,    getinputdata(node, :init_x))
        setdata!(node, :iter, getinputdata(node, :init_iter))
    else                                      # состояние прошлой итерации
        setdata!(node, :x,    back)
        setdata!(node, :iter, getinputdata(node, :iter))
    end
    return [:x, :iter]
end

function MetidaFlows.execute_unsafe!(node::DataNode{DescentGate})
    x    = getinputdata(node, :x)
    iter = getinputdata(node, :iter)
    tracedescent!(x)                          # инструментовка теста
    if !getinputdata(node, :stop)
        setdata!(node, :x,    x)
        setdata!(node, :iter, iter)
        return [:x, :iter]                    # ещё итерация
    end
    setdata!(node, :minimum,    x)
    setdata!(node, :iterations, iter)
    setdata!(node, :reason, getinputdata(node, :converged) ? :converged : :exhausted)
    return [:minimum, :iterations, :reason]
end

# ==========================================================================
#  Сборка графа
# ==========================================================================

"""
    build_descent(; x0, rate, tol, h, c, maxiter) -> NamedTuple

Граф одномерного градиентного спуска по `f(y) = (y − c)^2` с центральной
разностью. Возвращает workflow и идентификаторы узлов.
"""
function build_descent(; x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5,
                         c = 3.0, maxiter = 1000)
    w = Workflow(0; type = :ABW)
    w.name = "Gradient descent"

    cx0   = add_node!(w, DataNode(ConstFloat, spec_constfloat()))
    crate = add_node!(w, DataNode(ConstFloat, spec_constfloat()))
    ctol  = add_node!(w, DataNode(ConstFloat, spec_constfloat()))
    ch    = add_node!(w, DataNode(ConstFloat, spec_constfloat()))
    cc    = add_node!(w, DataNode(ConstFloat, spec_constfloat()))
    ci0   = add_node!(w, DataNode(ConstInt,   spec_constint()))
    cone  = add_node!(w, DataNode(ConstInt,   spec_constint()))
    cmax  = add_node!(w, DataNode(ConstInt,   spec_constint()))

    head  = add_node!(w, DataNode(DescentState, spec_descentstate()))

    xp    = add_node!(w, DataNode(AddFloat, spec_addfloat()))   # x + h
    xm    = add_node!(w, DataNode(SubFloat, spec_subfloat()))   # x − h
    dp    = add_node!(w, DataNode(SubFloat, spec_subfloat()))   # (x+h) − c
    fp    = add_node!(w, DataNode(MulFloat, spec_mulfloat()))   # dp · dp
    dm    = add_node!(w, DataNode(SubFloat, spec_subfloat()))   # (x−h) − c
    fm    = add_node!(w, DataNode(MulFloat, spec_mulfloat()))   # dm · dm
    twoh  = add_node!(w, DataNode(AddFloat, spec_addfloat()))   # h + h
    diff  = add_node!(w, DataNode(SubFloat, spec_subfloat()))   # fp − fm
    grad  = add_node!(w, DataNode(DivFloat, spec_divfloat()))   # diff / 2h
    step  = add_node!(w, DataNode(MulFloat, spec_mulfloat()))   # rate · grad
    nextx = add_node!(w, DataNode(SubFloat, spec_subfloat()))   # x − step
    agrad = add_node!(w, DataNode(AbsFloat, spec_absfloat()))   # |grad|
    conv  = add_node!(w, DataNode(LessFloat, spec_lessfloat())) # |grad| < tol
    nexti = add_node!(w, DataNode(AddInt,    spec_addint()))    # iter + 1
    exh   = add_node!(w, DataNode(NotLessInt, spec_notlessint()))  # iter' >= max
    stop  = add_node!(w, DataNode(OrBool,    spec_orbool()))    # conv || exh
    gate  = add_node!(w, DataNode(DescentGate, spec_descentgate()))

    # начальные значения
    add_connection!(w, cx0, :out, head, :init_x)
    add_connection!(w, ci0, :out, head, :init_iter)

    # две точки для центральной разности
    add_connection!(w, head, :x,  xp, :a); add_connection!(w, ch, :out, xp, :b)
    add_connection!(w, head, :x,  xm, :a); add_connection!(w, ch, :out, xm, :b)

    # цель, два экземпляра одного подграфа: f(y) = (y − c)^2
    add_connection!(w, xp, :out, dp, :a);  add_connection!(w, cc, :out, dp, :b)
    add_connection!(w, dp, :out, fp, :a);  add_connection!(w, dp, :out, fp, :b)
    add_connection!(w, xm, :out, dm, :a);  add_connection!(w, cc, :out, dm, :b)
    add_connection!(w, dm, :out, fm, :a);  add_connection!(w, dm, :out, fm, :b)

    # градиент: (f(x+h) − f(x−h)) / (h + h)
    add_connection!(w, ch,   :out, twoh, :a); add_connection!(w, ch, :out, twoh, :b)
    add_connection!(w, fp,   :out, diff, :a); add_connection!(w, fm, :out, diff, :b)
    add_connection!(w, diff, :out, grad, :a); add_connection!(w, twoh, :out, grad, :b)

    # шаг
    add_connection!(w, crate, :out, step, :a); add_connection!(w, grad, :out, step, :b)
    add_connection!(w, head,  :x, nextx, :a);  add_connection!(w, step, :out, nextx, :b)

    # условия останова
    add_connection!(w, grad,  :out, agrad, :a)
    add_connection!(w, agrad, :out, conv,  :a); add_connection!(w, ctol, :out, conv, :b)
    add_connection!(w, head,  :iter, nexti, :a); add_connection!(w, cone, :out, nexti, :b)
    add_connection!(w, nexti, :out, exh, :a);   add_connection!(w, cmax, :out, exh, :b)
    add_connection!(w, conv,  :out, stop, :a);  add_connection!(w, exh,  :out, stop, :b)

    # ворота и обратные рёбра
    add_connection!(w, stop,  :out, gate, :stop)
    add_connection!(w, conv,  :out, gate, :converged)
    add_connection!(w, nextx, :out, gate, :x)
    add_connection!(w, nexti, :out, gate, :iter)
    add_connection!(w, gate, :x,    head, :x)
    add_connection!(w, gate, :iter, head, :iter)

    setsettings!(w, cx0,   Dict(:value => x0))
    setsettings!(w, crate, Dict(:value => rate))
    setsettings!(w, ctol,  Dict(:value => tol))
    setsettings!(w, ch,    Dict(:value => h))
    setsettings!(w, cc,    Dict(:value => c))
    setsettings!(w, ci0,   Dict(:value => 0))
    setsettings!(w, cone,  Dict(:value => 1))
    setsettings!(w, cmax,  Dict(:value => maxiter))

    return (w = w, cx0 = cx0, crate = crate, ctol = ctol, ch = ch, cc = cc,
            ci0 = ci0, cone = cone, cmax = cmax, head = head,
            xp = xp, xm = xm, dp = dp, fp = fp, dm = dm, fm = fm,
            twoh = twoh, diff = diff, grad = grad, step = step, nextx = nextx,
            agrad = agrad, conv = conv, nexti = nexti, exh = exh, stop = stop,
            gate = gate)
end

"Прогнать спуск графом. Возвращает результат, число итераций, причину и граф."
function graph_descent(; maxiter = 1000, kw...)
    resetdescent!()
    g = build_descent(; maxiter = maxiter, kw...)
    scheduler!(g.w; maxiter = 200_000)
    return (x      = getdata(g.w, g.gate, :minimum),
            iter   = getdata(g.w, g.gate, :iterations),
            reason = getdata(g.w, g.gate, :reason),
            g      = g)
end

# ==========================================================================

@testset verbose = true "ГРАДИЕНТНЫЙ СПУСК                                " begin

# --------------------------------------------------------------------------
@testset "D1. элементарные узлы по отдельности             " begin
    function run1(type, spec, inputs::Dict{Symbol, Any}; settings = Dict{Symbol, Any}())
        node = DataNode(type, spec; settings = settings)
        for (port, value) in inputs
            setinputbuffer!(node, port, 1, value)
        end
        return node, MetidaFlows.execute_unsafe!(node)
    end

    n, p = run1(ConstFloat, spec_constfloat(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => 2.5))
    @test p == [:out]
    @test getdata(n, :out) === 2.5
    # целое в настройке приводится к Float64
    n, _ = run1(ConstFloat, spec_constfloat(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => 3))
    @test getdata(n, :out) === 3.0

    n, _ = run1(ConstInt, spec_constint(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => 7))
    @test getdata(n, :out) === 7

    # арифметика
    for (type, spec, a, b, expected) in (
            (AddFloat, spec_addfloat(), 2.0,  0.5,  2.5),
            (SubFloat, spec_subfloat(), 2.0,  0.5,  1.5),
            (MulFloat, spec_mulfloat(), 2.0,  0.5,  1.0),
            (DivFloat, spec_divfloat(), 2.0,  0.5,  4.0))
        n, _ = run1(type, spec, Dict{Symbol, Any}(:a => a, :b => b))
        @test getdata(n, :out) === expected
    end

    n, _ = run1(AbsFloat, spec_absfloat(), Dict{Symbol, Any}(:a => -3.25))
    @test getdata(n, :out) === 3.25
    n, _ = run1(AbsFloat, spec_absfloat(), Dict{Symbol, Any}(:a => 3.25))
    @test getdata(n, :out) === 3.25

    # сравнение вещественных
    for (a, b, expected) in ((1.0, 2.0, true), (2.0, 1.0, false), (1.0, 1.0, false))
        n, _ = run1(LessFloat, spec_lessfloat(), Dict{Symbol, Any}(:a => a, :b => b))
        @test getdata(n, :out) === expected
    end

    n, _ = run1(AddInt, spec_addint(), Dict{Symbol, Any}(:a => 4, :b => 1))
    @test getdata(n, :out) === 5

    for (a, b, expected) in ((4, 5, false), (5, 5, true), (6, 5, true))
        n, _ = run1(NotLessInt, spec_notlessint(), Dict{Symbol, Any}(:a => a, :b => b))
        @test getdata(n, :out) === expected
    end

    for (a, b, expected) in ((false, false, false), (true, false, true),
                             (false, true, true),   (true, true, true))
        n, _ = run1(OrBool, spec_orbool(), Dict{Symbol, Any}(:a => a, :b => b))
        @test getdata(n, :out) === expected
    end

    # голова: пустой обратный буфер -> начальные значения
    n, p = run1(DescentState, spec_descentstate(),
                Dict{Symbol, Any}(:init_x => 1.5, :init_iter => 0))
    @test sort(p) == sort([:x, :iter])
    @test getdata(n, :x) === 1.5
    @test getdata(n, :iter) === 0
    # заполненный -> состояние прошлой итерации
    n, _ = run1(DescentState, spec_descentstate(),
                Dict{Symbol, Any}(:init_x => 1.5, :init_iter => 0,
                                  :x => 2.75, :iter => 9))
    @test getdata(n, :x) === 2.75
    @test getdata(n, :iter) === 9

    # ворота: три исхода
    resetdescent!()
    n, p = run1(DescentGate, spec_descentgate(),
                Dict{Symbol, Any}(:stop => false, :converged => false,
                                  :x => 1.25, :iter => 3))
    @test sort(p) == sort([:x, :iter])
    @test getdata(n, :minimum) === nothing
    @test DESCENT_TRACE == [1.25]                 # ворота видят x' каждый виток

    resetdescent!()
    n, p = run1(DescentGate, spec_descentgate(),
                Dict{Symbol, Any}(:stop => true, :converged => true,
                                  :x => 3.0, :iter => 70))
    @test sort(p) == sort([:minimum, :iterations, :reason])
    @test getdata(n, :minimum)    === 3.0
    @test getdata(n, :iterations) === 70
    @test getdata(n, :reason)     === :converged

    n, _ = run1(DescentGate, spec_descentgate(),
                Dict{Symbol, Any}(:stop => true, :converged => false,
                                  :x => 1.0, :iter => 10))
    @test getdata(n, :reason) === :exhausted
    resetdescent!()
end

# --------------------------------------------------------------------------
@testset "D2. структура графа                             " begin
    g = build_descent()

    @test g.w isa Workflow{ABW}
    @test g.w.name == "Gradient descent"
    @test length(g.w.nodes) == 26
    @test length(g.w.connections) == 39

    # засевается восемью константами: только у них нет входных портов
    seeds = sort([id for (id, n) in g.w.nodes if !haveinputs(n)])
    @test seeds == sort([g.cx0, g.crate, g.ctol, g.ch, g.cc, g.ci0, g.cone, g.cmax])

    # цикл замкнут двумя обратными рёбрами, оба из ворот в голову
    feedback = [c for c in values(g.w.connections)
                if getportspec(getnode(g.w, c.input_id), c.input_port, :input).kind == :feedback]
    @test length(feedback) == 2
    @test all(c -> c.output_id == g.gate && c.input_id == g.head, feedback)
    @test sort([c.input_port for c in feedback]) == [:iter, :x]

    # три терминальных порта, ни один не подключён
    for port in (:minimum, :iterations, :reason)
        @test getportspec(getnode(g.w, g.gate), port, :output).kind == :terminal
        @test isempty([c for c in values(g.w.connections)
                       if c.output_id == g.gate && c.output_port == port])
    end

    # ЦЕЛЬ — ПОДГРАФ, И ЕГО ДВА ЭКЗЕМПЛЯРА. Возведение в квадрат это один
    # MulFloat, оба входа которого приходят от одного узла.
    @test sort(get_parents(g.w, g.fp)) == [(:a, g.dp), (:b, g.dp)]
    @test sort(get_parents(g.w, g.fm)) == [(:a, g.dm), (:b, g.dm)]
    # и обе копии берут точку минимума из одной константы
    @test (:b, g.cc) in get_parents(g.w, g.dp)
    @test (:b, g.cc) in get_parents(g.w, g.dm)

    # РОМБ ГРАДИЕНТА: две ветви сходятся в узле разности
    @test sort(get_parents(g.w, g.diff)) == [(:a, g.fp), (:b, g.fm)]

    # ФОРМА, КОТОРОЙ НУЖЕН ПАТЧ ПЛАНИРОВЩИКА: у nextx один вход прямо от
    # головы, другой через длинный путь
    @test (:a, g.head) in get_parents(g.w, g.nextx)
    @test (:b, g.step) in get_parents(g.w, g.nextx)

    # арифметические узлы переиспользуются
    counts = Dict{String, Int}()
    for (_, n) in g.w.nodes
        counts[nodetypestr(n)] = get(counts, nodetypestr(n), 0) + 1
    end
    @test counts[nodetypestr(getnode(g.w, g.xm))] == 5      # SubFloat
    @test counts[nodetypestr(getnode(g.w, g.fp))] == 3      # MulFloat
    @test counts[nodetypestr(getnode(g.w, g.xp))] == 2      # AddFloat
    @test counts[nodetypestr(getnode(g.w, g.cx0))] == 5     # ConstFloat
    @test counts[nodetypestr(getnode(g.w, g.ci0))] == 3     # ConstInt

    @test MetidaFlows.is_cyclic(makegraph(g.w))
end

# --------------------------------------------------------------------------
@testset "D3. сходимость на квадратичной                   " begin
    r = graph_descent(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 3.0)

    @test r.reason === :converged
    @test isapprox(r.x, 3.0; atol = 1e-6)
    @test r.iter == length(DESCENT_TRACE)

    # численный градиент центральной разностью для (y−c)^2 равен
    # аналитическому 2(x−c), поэтому шаг сжимает ошибку ровно в (1 − 2·rate)
    @test r.iter == 71

    # ошибка монотонно убывает
    errs = abs.(DESCENT_TRACE .- 3.0)
    @test all(errs[i] < errs[i-1] for i in 2:length(errs))
    @test errs[end] < 5e-7
end

# --------------------------------------------------------------------------
@testset "D4. след итераций совпадает с эталоном           " begin
    # Граф не просто находит минимум, а проходит ТЕ ЖЕ точки, что обычный
    # код с тем же порядком операций — побитово, без допуска.
    for (x0, rate, c) in ((0.0, 0.1, 3.0), (10.0, 0.05, -2.0), (-5.0, 0.25, 0.0))
        r   = graph_descent(x0 = x0, rate = rate, tol = 1e-6, h = 1e-5, c = c)
        ref = descent_reference(x0 = x0, rate = rate, tol = 1e-6, h = 1e-5,
                                c = c, maxiter = 1000)
        @test r.reason === ref.reason
        @test r.iter == ref.iter
        @test r.x === ref.x                       # побитово
        @test DESCENT_TRACE == ref.trace
    end
end

# --------------------------------------------------------------------------
@testset "D5. исчерпание лимита итераций                   " begin
    # Второе условие останова: лимит достигнут раньше сходимости.
    r = graph_descent(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 3.0,
                      maxiter = 10)
    @test r.reason === :exhausted
    @test r.iter == 10
    @test length(DESCENT_TRACE) == 10
    @test !isapprox(r.x, 3.0; atol = 1e-6)        # не дошёл

    ref = descent_reference(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5,
                            c = 3.0, maxiter = 10)
    @test r.x === ref.x
    @test DESCENT_TRACE == ref.trace

    # лимит в одну итерацию: один шаг и остановка
    r = graph_descent(x0 = 0.0, rate = 0.1, c = 3.0, maxiter = 1)
    @test r.iter == 1
    @test r.reason === :exhausted
end

# --------------------------------------------------------------------------
@testset "D6. старт в минимуме и постпроверка цикла        " begin
    # Цикл с ПОСТпроверкой: чтобы узнать градиент, надо сделать шаг. Поэтому
    # даже из точки минимума делается одна итерация — нулевой длины.
    r = graph_descent(x0 = 3.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 3.0)
    @test r.iter == 1
    @test r.reason === :converged
    @test r.x === 3.0
    @test DESCENT_TRACE == [3.0]
end

# --------------------------------------------------------------------------
@testset "D7. большой шаг: расходимость и ЛОЖНАЯ сходимость" begin
    # rate > 1/L: шаг перелетает минимум, и ошибка удваивается каждую
    # итерацию (d' = −2d для f = (y−3)^2 при rate = 1.5).
    r = graph_descent(x0 = 0.0, rate = 1.5, tol = 1e-6, h = 1e-5, c = 3.0,
                      maxiter = 50)

    # НАХОДКА. Спуск докладывает :converged, находясь в 3.8e11 от минимума,
    # и упирается не в лимит итераций, а в арифметику. Причина не в спуске,
    # а в численной производной: при |x| ~ 1e11 машинный интервал eps(x)
    # больше шага h = 1e-5, поэтому x + h == x бит в бит, разность
    # f(x+h) − f(x−h) равна РОВНО нулю, и |grad| < tol срабатывает на пустом
    # месте. Критерий по одному |grad| не отличает «плоско, потому что мы в
    # минимуме» от «плоско, потому что разность провалилась».
    @test r.reason === :converged
    @test r.iter == 37
    @test abs(r.x - 3.0) > 1e11
    @test r.x + 1e-5 === r.x                      # шаг h уже не различим
    @test eps(r.x) > 1e-5

    # эталон воспроизводит это побитово: арифметика та же
    ref = descent_reference(x0 = 0.0, rate = 1.5, tol = 1e-6, h = 1e-5,
                            c = 3.0, maxiter = 50)
    @test r.x === ref.x
    @test r.iter == ref.iter
    @test r.reason === ref.reason

    # до провала разности ошибка росла монотонно, и остановилась ровно на
    # последнем шаге
    errs = abs.(DESCENT_TRACE .- 3.0)
    flat = findfirst(i -> errs[i] <= errs[i - 1], 2:length(errs))
    @test flat !== nothing
    @test flat + 1 == length(errs)                # росла до самого конца
    @test errs[end] === errs[end - 1]             # x перестал меняться

    # на границе rate = 1/L = 0.5 первый шаг попадает почти точно в минимум,
    # второй добирает остаток шума численной производной
    r = graph_descent(x0 = 0.0, rate = 0.5, tol = 1e-6, h = 1e-5, c = 3.0)
    @test r.iter == 2
    @test r.reason === :converged
    @test r.x === 3.0
    @test length(DESCENT_TRACE) == 2
end

# --------------------------------------------------------------------------
@testset "D8. цель задаётся графом, а не кодом             " begin
    # (а) точка минимума — настройка одной константы
    r = graph_descent(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 7.0)
    @test r.reason === :converged
    @test isapprox(r.x, 7.0; atol = 1e-6)

    # (б) форма цели — перепроводка. Вставляем масштаб: f(y) = s·(y − c)^2.
    # Градиент становится 2s(x − c), сжатие (1 − 2·s·rate), поэтому с s = 2
    # и тем же rate сходимость вдвое быстрее.
    resetdescent!()
    g  = build_descent(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 3.0)
    cs = add_node!(g.w, DataNode(ConstFloat, spec_constfloat()))
    sp = add_node!(g.w, DataNode(MulFloat,   spec_mulfloat()))
    sm = add_node!(g.w, DataNode(MulFloat,   spec_mulfloat()))
    setsettings!(g.w, cs, Dict(:value => 2.0))

    # разность градиента отвязываем от квадратов и подключаем к масштабам
    for cid in collect(keys(g.w.connections))
        c = getconnection(g.w, cid)
        c.input_id == g.diff && delete_connection!(g.w, cid)
    end
    add_connection!(g.w, g.fp, :out, sp, :a); add_connection!(g.w, cs, :out, sp, :b)
    add_connection!(g.w, g.fm, :out, sm, :a); add_connection!(g.w, cs, :out, sm, :b)
    add_connection!(g.w, sp, :out, g.diff, :a)
    add_connection!(g.w, sm, :out, g.diff, :b)

    @test length(g.w.nodes) == 29
    scheduler!(g.w; maxiter = 200_000)
    @test getdata(g.w, g.gate, :reason) === :converged
    @test isapprox(getdata(g.w, g.gate, :minimum), 3.0; atol = 1e-6)

    scaled = getdata(g.w, g.gate, :iterations)
    plain  = graph_descent(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 3.0).iter
    @test scaled < plain                          # то же rate, цель круче
    @test scaled == 33

    # эталон с тем же масштабом
    ref = descent_reference(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5,
                            c = 3.0, maxiter = 1000, scale = 2.0)
    @test scaled == ref.iter
    @test getdata(g.w, g.gate, :minimum) === ref.x
end

# --------------------------------------------------------------------------
@testset "D9. по одному исполнению на итерацию             " begin
    # Ромб градиента внутри цикла: ни одного лишнего пересчёта. На старом
    # планировщике это не выполнялось — см. D10.
    r = graph_descent(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 3.0)
    g = r.g

    for id in (g.head, g.xp, g.xm, g.dp, g.fp, g.dm, g.fm, g.diff, g.grad,
               g.step, g.nextx, g.agrad, g.conv, g.nexti, g.exh, g.stop, g.gate)
        @test getstate(getnode(g.w, id), :exec_n) == r.iter
    end

    # константы считаются один раз на весь прогон, включая h + h
    for id in (g.cx0, g.crate, g.ctol, g.ch, g.cc, g.ci0, g.cone, g.cmax)
        @test getstate(getnode(g.w, id), :exec_n) == 1
    end
    @test getstate(getnode(g.w, g.twoh), :exec_n) == 1   # обе ветви от константы

    @test isempty(g.w.log)
end

# --------------------------------------------------------------------------
@testset "D10. повторный прогон                            " begin
    # :full чистит буферы обратных портов, поэтому прогон повторяем.
    g = build_descent(x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 3.0)
    resetdescent!(); scheduler!(g.w; maxiter = 200_000)
    first_x     = getdata(g.w, g.gate, :minimum)
    first_iter  = getdata(g.w, g.gate, :iterations)
    first_trace = copy(DESCENT_TRACE)

    resetdescent!(); scheduler!(g.w; maxiter = 200_000)
    @test getdata(g.w, g.gate, :minimum) === first_x
    @test getdata(g.w, g.gate, :iterations) == first_iter
    @test DESCENT_TRACE == first_trace

    # :soft сохраняет состояние цикла: спуск продолжается с места останова.
    # Он уже сошёлся, поэтому следующий прогон — одна итерация.
    resetdescent!()
    scheduler!(g.w; reset_mode = :soft, maxiter = 200_000)
    @test length(DESCENT_TRACE) == 1
    @test getdata(g.w, g.gate, :reason) === :converged
    @test isapprox(getdata(g.w, g.gate, :minimum), 3.0; atol = 1e-6)
end

end # @testset "ГРАДИЕНТНЫЙ СПУСК"
