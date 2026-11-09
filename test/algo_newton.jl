############################################################################
#
#  ЗООПАРК АЛГОРИТМОВ: МЕТОД НЬЮТОНА И ПОРТЫ :error
#
#
############################################################################

import MetidaFlows: PortSpec, DAW, ABW, getnode, getconnection, nodetypestr,
    getportspec, getporttype, getid, makegraph, get_children, get_parents,
    isportexist, setinputbuffer!, reset!, isready, getstate

# --------------------------------------------------------------------------
#  Исключение, которое едет по :error-порту. Тип порта должен быть
#  подтипом Exception — проверка стоит в конструкторе PortSpec.
# --------------------------------------------------------------------------

struct NewtonStall <: Exception
    x::Float64
    iter::Int
    f::Float64
    df::Float64
    eps::Float64
end

Base.showerror(io::IO, e::NewtonStall) = print(io,
    "NewtonStall: |f'(x)| = ", abs(e.df), " < ", e.eps,
    " at x = ", e.x, " (iteration ", e.iter, ", f = ", e.f, ")")

# --------------------------------------------------------------------------
#  Инструментовка: след точек по виткам.
# --------------------------------------------------------------------------

NEWTON_TRACE = Float64[]
tracenewton!(x) = push!(NEWTON_TRACE, x)
resetnewton!()  = empty!(NEWTON_TRACE)

# --------------------------------------------------------------------------
#  Эталон: тот же метод обычным кодом, порядок операций повторён, чтобы
#  след сравнивался побитово.
# --------------------------------------------------------------------------

function newton_reference(; x0, c, tol, eps, maxiter)
    x     = x0
    iter  = 0
    trace = Float64[]
    while true
        push!(trace, x)
        f  = x * x - c
        df = 2.0 * x
        if abs(f) < tol || iter >= maxiter
            return (x = x, iter = iter, trace = trace,
                    reason = abs(f) < tol ? :converged : :exhausted)
        end
        if abs(df) < eps
            return (x = x, iter = iter, trace = trace, reason = :stalled,
                    f = f, df = df)
        end
        x    = x - f / df
        iter = iter + 1
    end
end

# ==========================================================================
#  Элементарные узлы
# ==========================================================================

struct NConstF    <: AbstractNodeType end  # источник Float64
struct NConstI    <: AbstractNodeType end  # источник Int
struct NewtonState<: AbstractNodeType end  # состояние цикла (x, iter)
struct NMul       <: AbstractNodeType end  # a · b
struct NSub       <: AbstractNodeType end  # a − b
struct NAbs       <: AbstractNodeType end  # |a|
struct NLess      <: AbstractNodeType end  # a < b
struct NAddI      <: AbstractNodeType end  # a + b, целые
struct NNotLessI  <: AbstractNodeType end  # a >= b, целые
struct NOr        <: AbstractNodeType end  # a || b
struct NStep      <: AbstractNodeType end  # шаг f/f' ЛИБО :error
struct NewtonGate <: AbstractNodeType end  # ветвление витка
struct NewtonRescue <: AbstractNodeType end # обработчик ошибки

# --- спецификации ---------------------------------------------------------

spec_nconstf() = NodeSpec("N const float", PortSpec[],
    [PortSpec("Out", Float64, :out)], [:value])
spec_nconsti() = NodeSpec("N const int", PortSpec[],
    [PortSpec("Out", Int, :out)], [:value])

spec_newtonstate() = NodeSpec("Newton state",
    [PortSpec("Initial x",    Float64, :init_x),
     PortSpec("Initial iter", Int,     :init_iter),
     PortSpec("X",         Float64, :x;    kind = :feedback, required = false),
     PortSpec("Iteration", Int,     :iter; kind = :feedback, required = false)],
    [PortSpec("X",         Float64, :x),
     PortSpec("Iteration", Int,     :iter)])

n_binary_float(name, out) = NodeSpec(name,
    [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
    [PortSpec("Out", out, :out)])

spec_nmul()  = n_binary_float("N mul",  Float64)
spec_nsub()  = n_binary_float("N sub",  Float64)
spec_nless() = n_binary_float("N less", Bool)

spec_nabs() = NodeSpec("N abs",
    [PortSpec("A", Float64, :a)], [PortSpec("Out", Float64, :out)])

spec_naddi() = NodeSpec("N add int",
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
    [PortSpec("Out", Int, :out)])
spec_nnotlessi() = NodeSpec("N not less int",
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
    [PortSpec("Out", Bool, :out)])
spec_nor() = NodeSpec("N or",
    [PortSpec("A", Bool, :a), PortSpec("B", Bool, :b)],
    [PortSpec("Out", Bool, :out)])

#  ЕДИНСТВЕННЫЙ узел с :error-выходом. Контекст отказа (x, iter) входит
#  сюда, потому что исключение должно донести его до обработчика: у
#  обработчика других входов нет, и это не случайно — см. ниже.
spec_nstep() = NodeSpec("N step",
    [PortSpec("F",         Float64, :f),
     PortSpec("Df",        Float64, :df),
     PortSpec("Eps",       Float64, :eps),
     PortSpec("X",         Float64, :x),
     PortSpec("Iteration", Int,     :iter)],
    [PortSpec("Out",   Float64,     :out),
     PortSpec("Error", NewtonStall, :err; kind = :error, required = false)])

spec_newtongate() = NodeSpec("Newton gate",
    [PortSpec("Stop",      Bool,    :stop),
     PortSpec("Converged", Bool,    :converged),
     PortSpec("X",         Float64, :x),
     PortSpec("X next",    Float64, :x_next),
     PortSpec("Iteration", Int,     :iter),
     PortSpec("Iter next", Int,     :iter_next)],
    [PortSpec("X",          Float64, :x),
     PortSpec("Iteration",  Int,     :iter),
     PortSpec("Root",       Float64, :root;       kind = :terminal),
     PortSpec("Iterations", Int,     :iterations; kind = :terminal),
     PortSpec("Reason",     Symbol,  :reason;     kind = :terminal)])

#  У обработчика ОДИН вход, и он :error. Обычных входов нет намеренно:
#  узел с одним только :error-входом от `isready` свободен, но в очередь
#  попадает лишь тогда, когда родитель опубликовал :err. На обычных
#  витках он остаётся :dirty и не считается.
spec_newtonrescue() = NodeSpec("Newton rescue",
    [PortSpec("Error", NewtonStall, :err; kind = :error, required = false)],
    [PortSpec("Reason",     Symbol,  :reason;     kind = :terminal),
     PortSpec("X",          Float64, :x;          kind = :terminal),
     PortSpec("Iterations", Int,     :iterations; kind = :terminal),
     PortSpec("Derivative", Float64, :derivative; kind = :terminal),
     PortSpec("Restart",    Float64, :restart;    kind = :terminal)])

# --- реализации -----------------------------------------------------------

MetidaFlows.execute_unsafe!(n::DataNode{NConstF}) =
    (setdata!(n, :out, Float64(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{NConstI}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])

MetidaFlows.execute_unsafe!(n::DataNode{NMul}) =
    (setdata!(n, :out, getinputdata(n, :a) * getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{NSub}) =
    (setdata!(n, :out, getinputdata(n, :a) - getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{NAbs}) =
    (setdata!(n, :out, abs(getinputdata(n, :a))); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{NLess}) =
    (setdata!(n, :out, getinputdata(n, :a) < getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{NAddI}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{NNotLessI}) =
    (setdata!(n, :out, getinputdata(n, :a) >= getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{NOr}) =
    (setdata!(n, :out, getinputdata(n, :a) || getinputdata(n, :b)); [:out])

#  Узел сам ловит свой отказ. Бросить исключение он мог бы, но тогда
#  `execute!` поставил бы ему :failed и прогон кончился бы без диагноза в
#  графе — см. группу N5, там это измерено.
function MetidaFlows.execute_unsafe!(node::DataNode{NStep})
    f   = getinputdata(node, :f)
    df  = getinputdata(node, :df)
    eps = getinputdata(node, :eps)
    if abs(df) < eps
        setdata!(node, :err, NewtonStall(getinputdata(node, :x),
                                         getinputdata(node, :iter), f, df, eps))
        return [:err]
    end
    setdata!(node, :out, f / df)
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{NewtonGate})
    x    = getinputdata(node, :x)
    iter = getinputdata(node, :iter)
    tracenewton!(x)
    if getinputdata(node, :stop)
        setdata!(node, :root,       x)
        setdata!(node, :iterations, iter)
        setdata!(node, :reason, getinputdata(node, :converged) ? :converged : :exhausted)
        return [:root, :iterations, :reason]
    end
    setdata!(node, :x,    getinputdata(node, :x_next))
    setdata!(node, :iter, getinputdata(node, :iter_next))
    return [:x, :iter]
end

function MetidaFlows.execute_unsafe!(node::DataNode{NewtonRescue})
    e = getinputdata(node, :err)
    setdata!(node, :reason,     :stalled)
    setdata!(node, :x,          e.x)
    setdata!(node, :iterations, e.iter)
    setdata!(node, :derivative, e.df)
    #  Куда перезапуститься — дело алгоритма, не движка: сдвинуть точку
    #  так, чтобы производная перестала быть нулевой.
    setdata!(node, :restart, e.x + 1.0)
    return [:reason, :x, :iterations, :derivative, :restart]
end

function MetidaFlows.execute_unsafe!(node::DataNode{NewtonState})
    back = getinputdata(node, :x)
    if back === nothing
        setdata!(node, :x,    getinputdata(node, :init_x))
        setdata!(node, :iter, getinputdata(node, :init_iter))
    else
        setdata!(node, :x,    back)
        setdata!(node, :iter, getinputdata(node, :iter))
    end
    return [:x, :iter]
end

# ==========================================================================
#  Сборка графа
# ==========================================================================

"""
    build_newton(; x0, c, tol, eps, maxiter) -> NamedTuple

Граф метода Ньютона для `f(x) = x² − c` с маршрутизацией отказа через
`:error`-порт. Возвращает workflow и идентификаторы узлов.
"""
function build_newton(; x0 = 1.0, c = 2.0, tol = 1e-10, eps = 1e-8,
                       maxiter = 100)
    w      = Workflow(0; type = :ABW)
    w.name = "Newton-Raphson"

    cx0   = add_node!(w, DataNode(NConstF, spec_nconstf()))
    cc    = add_node!(w, DataNode(NConstF, spec_nconstf()))
    ctol  = add_node!(w, DataNode(NConstF, spec_nconstf()))
    ceps  = add_node!(w, DataNode(NConstF, spec_nconstf()))
    ctwo  = add_node!(w, DataNode(NConstF, spec_nconstf()))
    ci0   = add_node!(w, DataNode(NConstI, spec_nconsti()))
    cone  = add_node!(w, DataNode(NConstI, spec_nconsti()))
    cmax  = add_node!(w, DataNode(NConstI, spec_nconsti()))

    head  = add_node!(w, DataNode(NewtonState, spec_newtonstate()))

    sq    = add_node!(w, DataNode(NMul,  spec_nmul()))    # x · x
    f     = add_node!(w, DataNode(NSub,  spec_nsub()))    # x² − c
    df    = add_node!(w, DataNode(NMul,  spec_nmul()))    # 2 · x
    af    = add_node!(w, DataNode(NAbs,  spec_nabs()))    # |f|
    conv  = add_node!(w, DataNode(NLess, spec_nless()))   # |f| < tol
    nexti = add_node!(w, DataNode(NAddI, spec_naddi()))   # iter + 1
    exh   = add_node!(w, DataNode(NNotLessI, spec_nnotlessi()))  # iter >= maxiter
    stop  = add_node!(w, DataNode(NOr,   spec_nor()))     # conv || exh

    step  = add_node!(w, DataNode(NStep, spec_nstep()))   # f/f' либо :err
    nextx = add_node!(w, DataNode(NSub,  spec_nsub()))    # x − step

    gate   = add_node!(w, DataNode(NewtonGate,   spec_newtongate()))
    rescue = add_node!(w, DataNode(NewtonRescue, spec_newtonrescue()))

    setsettings!(w, cx0,  Dict(:value => x0))
    setsettings!(w, cc,   Dict(:value => c))
    setsettings!(w, ctol, Dict(:value => tol))
    setsettings!(w, ceps, Dict(:value => eps))
    setsettings!(w, ctwo, Dict(:value => 2.0))
    setsettings!(w, ci0,  Dict(:value => 0))
    setsettings!(w, cone, Dict(:value => 1))
    setsettings!(w, cmax, Dict(:value => maxiter))

    add_connection!(w, cx0, :out, head, :init_x)
    add_connection!(w, ci0, :out, head, :init_iter)

    #  f(x) = x·x − c
    add_connection!(w, head, :x,   sq, :a)
    add_connection!(w, head, :x,   sq, :b)
    add_connection!(w, sq,   :out, f,  :a)
    add_connection!(w, cc,   :out, f,  :b)

    #  f'(x) = 2·x
    add_connection!(w, ctwo, :out, df, :a)
    add_connection!(w, head, :x,   df, :b)

    #  сходимость по остатку
    add_connection!(w, f,    :out, af,   :a)
    add_connection!(w, af,   :out, conv, :a)
    add_connection!(w, ctol, :out, conv, :b)

    #  счётчик и лимит
    add_connection!(w, head, :iter, nexti, :a)
    add_connection!(w, cone, :out,  nexti, :b)
    add_connection!(w, head, :iter, exh,   :a)
    add_connection!(w, cmax, :out,  exh,   :b)
    add_connection!(w, conv, :out,  stop,  :a)
    add_connection!(w, exh,  :out,  stop,  :b)

    #  шаг: единственный узел, который может отказать
    add_connection!(w, f,    :out,  step, :f)
    add_connection!(w, df,   :out,  step, :df)
    add_connection!(w, ceps, :out,  step, :eps)
    add_connection!(w, head, :x,    step, :x)
    add_connection!(w, head, :iter, step, :iter)
    add_connection!(w, head, :x,    nextx, :a)
    add_connection!(w, step, :out,  nextx, :b)

    #  ворота
    add_connection!(w, stop,  :out,  gate, :stop)
    add_connection!(w, conv,  :out,  gate, :converged)
    add_connection!(w, head,  :x,    gate, :x)
    add_connection!(w, nextx, :out,  gate, :x_next)
    add_connection!(w, head,  :iter, gate, :iter)
    add_connection!(w, nexti, :out,  gate, :iter_next)

    #  путь ошибки: единственное :error-ребро графа
    add_connection!(w, step, :err, rescue, :err)

    #  замыкание цикла
    add_connection!(w, gate, :x,    head, :x)
    add_connection!(w, gate, :iter, head, :iter)

    return (w = w, cx0 = cx0, cc = cc, ctol = ctol, ceps = ceps, ctwo = ctwo,
            ci0 = ci0, cone = cone, cmax = cmax, head = head, sq = sq, f = f,
            df = df, af = af, conv = conv, nexti = nexti, exh = exh,
            stop = stop, step = step, nextx = nextx, gate = gate,
            rescue = rescue)
end

"""
    graph_newton(; kw...) -> NamedTuple

Прогнать метод графом. Возвращает исход — сошлось, исчерпано или
застряло — одним и тем же набором полей независимо от того, какая ветвь
сработала.
"""
function graph_newton(; maxiter = 100, schedmaxiter = 200_000, kw...)
    resetnewton!()
    g = build_newton(; maxiter = maxiter, kw...)
    scheduler!(g.w; maxiter = schedmaxiter)
    stalled = getdata(g.w, g.rescue, :reason) !== nothing
    return (reason  = stalled ? getdata(g.w, g.rescue, :reason)
                              : getdata(g.w, g.gate, :reason),
            x       = stalled ? getdata(g.w, g.rescue, :x)
                              : getdata(g.w, g.gate, :root),
            iter    = stalled ? getdata(g.w, g.rescue, :iterations)
                              : getdata(g.w, g.gate, :iterations),
            restart = stalled ? getdata(g.w, g.rescue, :restart) : nothing,
            trace   = copy(NEWTON_TRACE),
            g       = g)
end

# ==========================================================================

@testset verbose = true "МЕТОД НЬЮТОНА И ПОРТЫ :error                     " begin

# --------------------------------------------------------------------------
@testset "N1. элементарные узлы по отдельности             " begin
    function run1(type, spec, inputs::Dict{Symbol, Any}; settings = Dict{Symbol, Any}())
        node = DataNode(type, spec; settings = settings)
        for (port, value) in inputs
            setinputbuffer!(node, port, 1, value)
        end
        node, MetidaFlows.execute_unsafe!(node)
    end

    n, p = run1(NConstF, spec_nconstf(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => 2.5))
    @test p == [:out] && getdata(n, :out) === 2.5

    n, _ = run1(NMul, spec_nmul(), Dict{Symbol, Any}(:a => 3.0, :b => 4.0))
    @test getdata(n, :out) === 12.0
    n, _ = run1(NSub, spec_nsub(), Dict{Symbol, Any}(:a => 3.0, :b => 4.0))
    @test getdata(n, :out) === -1.0
    n, _ = run1(NAbs, spec_nabs(), Dict{Symbol, Any}(:a => -1.5))
    @test getdata(n, :out) === 1.5
    n, _ = run1(NLess, spec_nless(), Dict{Symbol, Any}(:a => 1.0, :b => 2.0))
    @test getdata(n, :out) === true
    n, _ = run1(NAddI, spec_naddi(), Dict{Symbol, Any}(:a => 2, :b => 1))
    @test getdata(n, :out) === 3
    n, _ = run1(NNotLessI, spec_nnotlessi(), Dict{Symbol, Any}(:a => 5, :b => 5))
    @test getdata(n, :out) === true
    n, _ = run1(NOr, spec_nor(), Dict{Symbol, Any}(:a => false, :b => true))
    @test getdata(n, :out) === true

    #  NStep: две ветви одного узла
    base = Dict{Symbol, Any}(:f => 2.0, :df => 4.0, :eps => 1e-8,
                             :x => 1.0, :iter => 3)
    n, p = run1(NStep, spec_nstep(), base)
    @test p == [:out] && getdata(n, :out) === 0.5
    @test getdata(n, :err) === nothing                 # второй порт не заполнен

    n, p = run1(NStep, spec_nstep(), merge(base, Dict{Symbol, Any}(:df => 0.0)))
    @test p == [:err]
    @test getdata(n, :out) === nothing                 # обычный порт не заполнен
    e = getdata(n, :err)
    @test e isa NewtonStall
    @test e.x === 1.0 && e.iter === 3 && e.df === 0.0 && e.f === 2.0
    @test occursin("NewtonStall", sprint(showerror, e))
    @test occursin("x = 1.0", sprint(showerror, e))

    #  обработчик
    n, p = run1(NewtonRescue, spec_newtonrescue(),
                Dict{Symbol, Any}(:err => NewtonStall(0.0, 2, 1.0, 0.0, 1e-8)))
    @test Set(p) == Set([:reason, :x, :iterations, :derivative, :restart])
    @test getdata(n, :reason) === :stalled
    @test getdata(n, :x) === 0.0 && getdata(n, :iterations) === 2
    @test getdata(n, :derivative) === 0.0
    @test getdata(n, :restart) === 1.0

    #  ворота: два исхода
    gbase = Dict{Symbol, Any}(:stop => false, :converged => false, :x => 1.5,
                              :x_next => 1.4, :iter => 2, :iter_next => 3)
    resetnewton!()
    n, p = run1(NewtonGate, spec_newtongate(), gbase)
    @test p == [:x, :iter]
    @test getdata(n, :x) === 1.4 && getdata(n, :iter) === 3
    n, p = run1(NewtonGate, spec_newtongate(),
                merge(gbase, Dict{Symbol, Any}(:stop => true, :converged => true)))
    @test p == [:root, :iterations, :reason]
    @test getdata(n, :root) === 1.5 && getdata(n, :reason) === :converged
    n, _ = run1(NewtonGate, spec_newtongate(),
                merge(gbase, Dict{Symbol, Any}(:stop => true, :converged => false)))
    @test getdata(n, :reason) === :exhausted
    @test NEWTON_TRACE == [1.5, 1.5, 1.5]              # ворота видят x каждый виток
end

# --------------------------------------------------------------------------
@testset "N2. что движок делает с видом :error            " begin
    #  1. Проверки конструктора PortSpec
    @test_throws ErrorException PortSpec("E", NewtonStall, :e; kind = :error,
                                         required = true)
    @test_throws ErrorException PortSpec("E", Float64, :e; kind = :error,
                                         required = false)
    @test PortSpec("E", NewtonStall, :e; kind = :error, required = false).kind === :error
    #  подтип Exception обязателен, сам Exception годится
    @test PortSpec("E", Exception, :e; kind = :error, required = false).kind === :error
    #  на выходе :error разрешён, в отличие от :feedback
    @test_throws ErrorException NodeSpec("X", PortSpec[],
        [PortSpec("O", Int, :o; kind = :feedback)])
    @test NodeSpec("X", PortSpec[],
        [PortSpec("E", NewtonStall, :e; kind = :error, required = false)]) isa NodeSpec

    #  2. isready не смотрит на :error-входы
    g = build_newton()
    #  обработчик готов считать, хотя его родитель :dirty и буфер пуст
    @test getstatus(getnode(g.w, g.step)) === :dirty
    @test isready(g.w, g.rescue)
    @test isempty(getnode(g.w, g.rescue).input_buffer[:err])

    #  3. :error-ребро не делает граф циклическим. Проверяем прямо: тот
    #  же граф с единственным :error-ребром, замыкающим цикл, DAW берёт.
    w = Workflow(0; type = :DAW)
    src = add_node!(w, DataNode(NConstF, spec_nconstf()))
    #  узел с обычным входом и :error-выходом
    sp  = NodeSpec("Loop err",
        [PortSpec("A", Float64, :a),
         PortSpec("E", NewtonStall, :e_in; kind = :error, required = false)],
        [PortSpec("Out", Float64, :out),
         PortSpec("Err", NewtonStall, :e_out; kind = :error, required = false)])
    a = add_node!(w, DataNode(NStep, sp))
    b = add_node!(w, DataNode(NStep, sp))
    setsettings!(w, src, Dict(:value => 1.0))
    add_connection!(w, src, :out,   a, :a)
    add_connection!(w, a,   :out,   b, :a)
    add_connection!(w, b,   :e_out, a, :e_in)   # ребро назад, но :error
    @test length(w.connections) == 3
    @test makegraph(w) isa Any                   # обход не идёт по :error
    #  а такое же ребро обычного вида DAW уже не возьмёт
    w2 = Workflow(0; type = :DAW)
    sp2 = NodeSpec("Loop normal",
        [PortSpec("A", Float64, :a), PortSpec("B", Float64, :b)],
        [PortSpec("Out", Float64, :out)])
    x = add_node!(w2, DataNode(NMul, sp2))
    y = add_node!(w2, DataNode(NMul, sp2))
    add_connection!(w2, x, :out, y, :a)
    add_connection!(w2, y, :out, x, :b)
    @test_throws ErrorException scheduler!(w2)
end

# --------------------------------------------------------------------------
@testset "N3. структура графа                             " begin
    g = build_newton()
    @test length(g.w.nodes) == 21
    @test length(g.w.connections) == 33

    #  ровно одно :error-ребро, из шага в обработчик
    errc = [c for (_, c) in g.w.connections
            if getportspec(getnode(g.w, c.input_id), c.input_port, :input).kind == :error]
    @test length(errc) == 1
    @test only(errc).output_id == g.step && only(errc).input_id == g.rescue

    #  ровно два обратных ребра, оба из ворот в голову
    fbc = [c for (_, c) in g.w.connections
           if getportspec(getnode(g.w, c.input_id), c.input_port, :input).kind == :feedback]
    @test length(fbc) == 2
    @test all(c -> c.output_id == g.gate && c.input_id == g.head, fbc)

    #  у обработчика нет ни одного обычного входа — это и держит его
    #  вне обычных витков
    rspec = getnode(g.w, g.rescue).spec
    @test isempty([p for p in rspec.input_ports if p.kind == :normal])
    @test all(p -> p.kind == :terminal, rspec.output_ports)

    #  два источника исхода, и терминальные порты у них не пересекаются
    gspec = getnode(g.w, g.gate).spec
    @test Set(p.label for p in gspec.output_ports if p.kind == :terminal) ==
          Set([:root, :iterations, :reason])
    @test getportspec(getnode(g.w, g.step), :err, :output).datatype === NewtonStall
end

# --------------------------------------------------------------------------
@testset "N4. сходимость совпадает с эталоном             " begin
    for (x0, c) in ((1.0, 2.0), (3.0, 9.0), (0.5, 0.25), (10.0, 2.0),
                    (-1.0, 2.0), (2.0, 1e6))
        r   = graph_newton(x0 = x0, c = c, tol = 1e-10, eps = 1e-8)
        ref = newton_reference(x0 = x0, c = c, tol = 1e-10, eps = 1e-8,
                               maxiter = 100)
        @test r.reason === ref.reason
        @test r.x === ref.x                       # побитово
        @test r.iter == ref.iter
        @test r.trace == ref.trace
    end

    #  √2 действительно получился
    r = graph_newton(x0 = 1.0, c = 2.0, tol = 1e-12, eps = 1e-8)
    @test r.reason === :converged
    @test abs(r.x - sqrt(2.0)) < 1e-12
    @test r.iter <= 6                             # квадратичная сходимость

    #  лимит итераций: та же ветвь ворот, другая причина
    r = graph_newton(x0 = 100.0, c = 2.0, tol = 1e-12, eps = 1e-8, maxiter = 2)
    @test r.reason === :exhausted
    @test r.iter == 2
    @test r.restart === nothing                   # обработчик не работал
end

# --------------------------------------------------------------------------
@testset "N5. отказ уходит в :error, а не в :failed       " begin
    #  c = −1: корня нет, Ньютон приходит в x = 0 на втором витке
    r = graph_newton(x0 = 1.0, c = -1.0, tol = 1e-10, eps = 1e-8)
    ref = newton_reference(x0 = 1.0, c = -1.0, tol = 1e-10, eps = 1e-8,
                           maxiter = 100)
    @test r.reason === :stalled === ref.reason
    @test r.x === 0.0 === ref.x
    @test r.iter == 1 == ref.iter
    #  СЛЕД КОРОЧЕ ЭТАЛОННОГО НА ОДНУ ТОЧКУ. Инструментовка живёт в
    #  воротах, а на витке с отказом ворота не работают, поэтому точка
    #  отказа в след не попадает — она есть только в исключении.
    @test r.trace == [1.0]
    @test ref.trace == [1.0, 0.0]
    @test r.trace == ref.trace[1:end-1]
    @test r.x === last(ref.trace)              # потерянная точка — у обработчика
    @test r.restart === 1.0

    #  НИ ОДИН узел не упал: отказ прошёл данными, а не исключением
    @test isempty([n for (_, n) in r.g.w.nodes if getstatus(n) === :failed])
    @test isempty([m for m in r.g.w.log if m.level === :error])

    #  обычная ветвь в этот виток не считалась и осталась :dirty
    @test getstatus(getnode(r.g.w, r.g.nextx)) === :dirty
    @test getstatus(getnode(r.g.w, r.g.gate))  === :dirty
    #  а то, что не зависит от шага, посчиталось
    @test getstatus(getnode(r.g.w, r.g.f))    === :clean
    @test getstatus(getnode(r.g.w, r.g.conv)) === :clean
    #  ворота держат данные ПРЕДЫДУЩЕГО витка — «все :clean» не признак
    #  завершения, и «ворота отдали результат» тоже
    @test getdata(r.g.w, r.g.gate, :root) === nothing

    #  обработчик отработал один раз, ворота — один раз (первый виток)
    @test getnode(r.g.w, r.g.rescue).state.exec_n == 1
    @test getnode(r.g.w, r.g.gate).state.exec_n   == 1
    @test getnode(r.g.w, r.g.step).state.exec_n   == 2

    #  на сходящемся прогоне обработчик не запускался НИ РАЗУ, хотя
    #  isready его пускал: в очередь он не попадал
    r2 = graph_newton(x0 = 1.0, c = 2.0, tol = 1e-12, eps = 1e-8)
    @test getnode(r2.g.w, r2.g.rescue).state.exec_n == 0
    @test getstatus(getnode(r2.g.w, r2.g.rescue)) === :dirty
    @test getdata(r2.g.w, r2.g.rescue, :reason) === nothing
end

# --------------------------------------------------------------------------
@testset "N6. восстановление — на уровне вызывающего      " begin
    #  Путь ошибки не может вернуться в обычный (см. заголовок), поэтому
    #  обработчик публикует точку перезапуска, а решение принимает тот,
    #  кто запускал граф.
    bad = graph_newton(x0 = 0.0, c = 4.0, tol = 1e-10, eps = 1e-8)
    @test bad.reason === :stalled
    @test bad.x === 0.0 && bad.iter == 0          # застряли на первом витке
    @test bad.restart === 1.0

    good = graph_newton(x0 = bad.restart, c = 4.0, tol = 1e-10, eps = 1e-8)
    @test good.reason === :converged
    @test abs(good.x - 2.0) < 1e-10

    #  тот же перезапуск на том же графе, через настройки и reset
    g = bad.g
    setsettings!(g.w, g.cx0, Dict(:value => bad.restart))
    resetnewton!()
    scheduler!(g.w; maxiter = 200_000)
    @test getdata(g.w, g.gate, :reason) === :converged
    @test abs(getdata(g.w, g.gate, :root) - 2.0) < 1e-10
    #  данные обработчика с прошлого прогона затёрлись сбросом
    @test getdata(g.w, g.rescue, :reason) === nothing
end

# --------------------------------------------------------------------------
@testset "N7. двойной корень: диагноз раньше сходимости   " begin
    #  c = 0 — двойной корень в нуле. Сходимость там линейная: x делится
    #  на два каждый виток, остаток x² делится на четыре. Производная
    #  тоже стремится к нулю, поэтому при достаточно тугом tol диагноз
    #  успевает раньше, чем сходимость.
    loose = graph_newton(x0 = 1.0, c = 0.0, tol = 1e-10, eps = 1e-8)
    @test loose.reason === :converged              # tol достижим
    @test abs(loose.x) < 1e-5

    tight = graph_newton(x0 = 1.0, c = 0.0, tol = 1e-30, eps = 1e-8)
    @test tight.reason === :stalled
    ref = newton_reference(x0 = 1.0, c = 0.0, tol = 1e-30, eps = 1e-8,
                           maxiter = 100)
    @test tight.x === ref.x && tight.iter == ref.iter

    #  в момент диагноза ответ УЖЕ был хорош, просто не по заявленному
    #  допуску: вот во что обходится «остановиться, а не починиться»
    @test abs(tight.x) < 1e-8
    @test abs(tight.x^2) < 1e-15
    @test abs(tight.x^2) > 1e-30                   # но tol не достигнут

    #  линейная сходимость: ровно деление на два каждый виток
    @test tight.trace[1] === 1.0
    @test all(tight.trace[k + 1] === tight.trace[k] / 2 for k in 1:length(tight.trace)-1)
end

# --------------------------------------------------------------------------
@testset "N8. если узел всё-таки бросает исключение       " begin
    #  Для сравнения: что делает движок, когда отказ НЕ пойман узлом.
    #  Это и есть причина, по которой NStep ловит свой отказ сам.

    #  Сначала мимо: деление на нуль в Float64 исключения не бросает, и
    #  при eps = 0 порог не срабатывает — граф посчитает Inf или NaN и
    #  будет считать это нормальным результатом.
    g = build_newton(x0 = 0.0, c = 4.0, eps = 0.0, maxiter = 3)
    resetnewton!()
    scheduler!(g.w; maxiter = 200_000)
    step_out = getdata(g.w, g.step, :out)
    @test isinf(step_out) || isnan(step_out)
    @test getstatus(getnode(g.w, g.step)) === :clean
    @test getdata(g.w, g.rescue, :reason) === nothing   # отказа «не было»

    #  А теперь настоящее исключение: испортим настройку источника так,
    #  чтобы узел упал на преобразовании.
    g2 = build_newton()
    setsettings!(g2.w, g2.cx0, Dict(:value => "не число"))
    resetnewton!()

    #  ПЛАНИРОВЩИК НЕ БРОСАЕТ. Гаснет зависимое поддерево, а здесь это
    #  весь граф: от упавшего источника зависит каждый узел. С
    #  `strict = true` тот же прогон закончился бы ошибкой со списком.
    @test scheduler!(g2.w; maxiter = 200_000) isa Any
    @test getstatus(getnode(g2.w, g2.cx0)) === :failed
    #  и дальше не исполнился НИ ОДИН узел, зависящий от источника
    @test getnode(g2.w, g2.head).state.exec_n == 0
    @test getnode(g2.w, g2.gate).state.exec_n == 0
    @test getdata(g2.w, g2.gate, :root) === nothing

    #  единственный след — запись в журнале
    errs = [m for m in g2.w.log if m.level === :error]
    @test length(errs) == 1
    @test occursin("id: $(g2.cx0)", errs[1].message)
    @test occursin("MethodError", errs[1].message)

    #  в :error-порты движок не положил ничего: он их не знает
    @test getdata(g2.w, g2.rescue, :reason) === nothing
    @test isempty(getnode(g2.w, g2.rescue).input_buffer[:err])

    #  с throw_error исключение доходит до вызывающего, но это уже
    #  execute!, а не планировщик
    g3 = build_newton()
    setsettings!(g3.w, g3.cx0, Dict(:value => "не число"))
    @test_throws Exception execute!(g3.w, g3.cx0; throw_error = true)
end

end
