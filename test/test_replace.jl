############################################################################
#
#  КАТЕГОРИЯ: ЗАМЕНА УЗЛА НА МЕСТЕ
#
#  `replace!(w, node, id)` - поставить другой узел под тем же
#  идентификатором, сохранив связи. Через `delete_node!` + `add_node!` так
#  нельзя: удаление узла уносит его связи, вместе с ними порядок на
#  мультипорте (он задаётся идентификаторами связей).
#
#  Назначение этого набора:
#
#    1. всё, что может отказать, проверяется ДО первой записи, поэтому отказ
#       оставляет граф в точности прежним. Поэтому тесты отказов идут первыми
#       и каждый из них проверяет неизменность: узел на месте, `ver` прежний,
#       число связей прежнее;
#    2. при успехе узлы, которых замена не касается, сохраняют посчитанное:
#       `exec_n` родителя не растёт,  потомки инвалидируются.
#
############################################################################

import MetidaFlows: nodetype, replacespec!, replaceport!,
                    register_node!, unregister_all!, unregister_node!,
                    noderegkey, workflow_to_dict, dict_to_workflow, getregnodeinfo,
                    isportexist, getportspec, getposition, setposition!,
                    NodeAdded, NodeReplaced, SpecChanged, SETTINGS,
                    AbstractNodeSettings,
                    setreadyports!, getstate, getexecn, getnode, getid,
                    getporttype, reset!, mark_dirty!

function rp_withaudit(f)
    saved = SETTINGS[:audit]
    try
        SETTINGS[:audit] = true
        f()
    finally
        SETTINGS[:audit] = saved
    end
end

struct RpConst  <: AbstractNodeType end   # -> :out::Int, settings [:value]
struct RpDouble <: AbstractNodeType end   # :in::Int -> :out::Int, ×2
struct RpTriple <: AbstractNodeType end   # :in::Int -> :out::Int, ×3
struct RpFloat  <: AbstractNodeType end   # :in::Float64 — чужой тип входа
struct RpStrOut <: AbstractNodeType end   # :out::String — чужой тип выхода
struct RpNoIn   <: AbstractNodeType end   # вообще без входов
struct RpMulti  <: AbstractNodeType end   # MultiPort :in
struct RpGiver  <: AbstractNodeType end   # отдающий выход
struct RpTaker  <: AbstractNodeType end   # забирающий вход
struct RpReader <: AbstractNodeType end   # обычный потребитель вектора
struct RpTyped  <: AbstractNodeType end   # настройки структурой
struct RpLoop   <: AbstractNodeType end   # петля через :feedback

mutable struct RpSettings <: AbstractNodeSettings
    value::Int
    RpSettings() = new(0)
end
MetidaFlows.nodesettings(::Type{RpTyped}) = RpSettings()

MetidaFlows.execute_unsafe!(n::DataNode{RpConst}) =
    (setdata!(n, :out, Int(get(n.settings, :value, 0))); setreadyports!(n, :out))
MetidaFlows.execute_unsafe!(n::DataNode{RpDouble}) =
    (setdata!(n, :out, 2 * getinputdata(n, :in)); setreadyports!(n, :out))
MetidaFlows.execute_unsafe!(n::DataNode{RpTriple}) =
    (setdata!(n, :out, 3 * getinputdata(n, :in)); setreadyports!(n, :out))
MetidaFlows.execute_unsafe!(n::DataNode{RpFloat}) =
    (setdata!(n, :out, 1); setreadyports!(n, :out))
MetidaFlows.execute_unsafe!(n::DataNode{RpStrOut}) =
    (setdata!(n, :out, "x"); setreadyports!(n, :out))
MetidaFlows.execute_unsafe!(n::DataNode{RpNoIn}) =
    (setdata!(n, :out, 0); setreadyports!(n, :out))
MetidaFlows.execute_unsafe!(n::DataNode{RpMulti}) =
    (setdata!(n, :out, sum(getinputdata(n, :in)); ); setreadyports!(n, :out))
MetidaFlows.execute_unsafe!(n::DataNode{RpGiver}) =
    (setdata!(n, :out, [1, 2, 3]); setreadyports!(n, :out))
function MetidaFlows.execute_unsafe!(n::DataNode{RpTaker})
    v = take!(n, :in)
    setdata!(n, :out, v === nothing ? 0 : sum(v))
    return setreadyports!(n, :out)
end
MetidaFlows.execute_unsafe!(n::DataNode{RpReader}) =
    (setdata!(n, :out, sum(getinputdata(n, :in))); setreadyports!(n, :out))
MetidaFlows.execute_unsafe!(n::DataNode{RpTyped}) =
    (setdata!(n, :out, n.settings[:value]); setreadyports!(n, :out))
function MetidaFlows.execute_unsafe!(n::DataNode{RpLoop})
    prev = getinputdata(n, :prev)
    k = prev === nothing ? 1 : prev + 1
    k >= 3 && return setreadyports!(n)
    setdata!(n, :out, k)
    return setreadyports!(n, :out)
end

rp_const()  = NodeSpec("Const",  PortSpec[], [PortSpec("Out", Int, :out)], [:value])
rp_double() = NodeSpec("Double", [PortSpec("In", Int, :in)], [PortSpec("Out", Int, :out)])
rp_triple() = NodeSpec("Triple", [PortSpec("In", Int, :in)], [PortSpec("Out", Int, :out)])
rp_float()  = NodeSpec("Float",  [PortSpec("In", Float64, :in)], [PortSpec("Out", Int, :out)])
rp_strout() = NodeSpec("StrOut", [PortSpec("In", Int, :in)], [PortSpec("Out", String, :out)])
rp_noin()   = NodeSpec("NoIn",   PortSpec[], [PortSpec("Out", Int, :out)])
rp_multi()  = NodeSpec("Multi",  [PortSpec("In", Int, :in, MultiPort())],
                                 [PortSpec("Out", Int, :out)])
rp_giver()  = NodeSpec("Giver",  PortSpec[],
                       [PortSpec("Out", Vector{Int}, :out; handover = true)])
rp_plain()  = NodeSpec("Plain",  PortSpec[], [PortSpec("Out", Vector{Int}, :out)])
rp_taker()  = NodeSpec("Taker",  [PortSpec("In", Vector{Int}, :in; handover = true)],
                                 [PortSpec("Out", Int, :out)])
rp_reader() = NodeSpec("Reader", [PortSpec("In", Vector{Int}, :in)],
                                 [PortSpec("Out", Int, :out)])
rp_typed()  = NodeSpec("Typed",  PortSpec[], [PortSpec("Out", Int, :out)], [:value])
rp_loop()   = NodeSpec("Loop",   [PortSpec("Prev", Int, :prev; kind = :feedback)],
                                 [PortSpec("Out", Int, :out)])
rp_loopany()= NodeSpec("LoopAny",[PortSpec("Prev", Any, :prev; kind = :feedback)],
                                 [PortSpec("Out", Any, :out)])

"Граф: Const -> Double. Возвращает (w, источник, потребитель)."
function rp_chain(; value = 21)
    w = Workflow(1)
    c = add_node!(w, DataNode(RpConst,  rp_const()))
    d = add_node!(w, DataNode(RpDouble, rp_double()))
    add_connection!(w, c, :out, d, :in)
    setsettings!(w, c, Dict(:value => value))
    (w = w, c = c, d = d)
end

#  Снимок того, что обязано не измениться после отказа.
rp_snapshot(w) = (ver = w.ver, nodes = length(w.nodes), cons = length(w.connections),
                  ids = sort!(collect(keys(w.nodes))),
                  cids = sort!(collect(keys(w.connections))))

@testset "ЗАМЕНА УЗЛА НА МЕСТЕ                             " begin

# ======================================================================
#  ОТКАЗЫ. Каждый проверяет и сообщение, и неизменность графа.
# ======================================================================

# --------------------------------------------------------------------------
@testset "W1. узла с таким id нет                          " begin
    g = rp_chain()
    s = rp_snapshot(g.w)
    @test_throws ErrorException replace!(g.w, DataNode(RpDouble, rp_double()), 99)
    @test rp_snapshot(g.w) == s
end

# --------------------------------------------------------------------------
@testset "W2. у замены нет нужного порта                   " begin
    g = rp_chain()
    old = getnode(g.w, g.d)
    s   = rp_snapshot(g.w)

    #  Входной порт :in, на котором висит связь, у замены отсутствует.
    @test_throws ErrorException replace!(g.w, DataNode(RpNoIn, rp_noin()), g.d)
    msg = try; replace!(g.w, DataNode(RpNoIn, rp_noin()), g.d); catch e; sprint(showerror, e); end
    @test occursin("no input port", msg)
    @test occursin("in", msg)
    @test getnode(g.w, g.d) === old
    @test rp_snapshot(g.w) == s

    #  И то же с выходной стороны: у замены источника нет порта :out.
    only_in = NodeSpec("OnlyIn", [PortSpec("In", Int, :in)], PortSpec[])
    @test_throws ErrorException replace!(g.w, DataNode(RpDouble, only_in), g.c)
    msg2 = try; replace!(g.w, DataNode(RpDouble, only_in), g.c); catch e; sprint(showerror, e); end
    @test occursin("no output port", msg2)
    @test rp_snapshot(g.w) == s
end

# --------------------------------------------------------------------------
@testset "W3. типы не сходятся                             " begin
    #  На входе: родитель отдаёт Int, у замены вход Float64.
    g = rp_chain()
    old = getnode(g.w, g.d)
    s   = rp_snapshot(g.w)
    @test_throws ErrorException replace!(g.w, DataNode(RpFloat, rp_float()), g.d)
    msg = try; replace!(g.w, DataNode(RpFloat, rp_float()), g.d); catch e; sprint(showerror, e); end
    @test occursin("Type mismatch", msg)
    @test getnode(g.w, g.d) === old
    @test rp_snapshot(g.w) == s

    #  На выходе: замена источника отдаёт String, потомок ждёт Int.
    g2 = rp_chain()
    old2 = getnode(g2.w, g2.c)
    s2   = rp_snapshot(g2.w)
    strsrc = NodeSpec("StrSrc", PortSpec[], [PortSpec("Out", String, :out)])
    @test_throws ErrorException replace!(g2.w, DataNode(RpStrOut, strsrc), g2.c)
    @test getnode(g2.w, g2.c) === old2
    @test rp_snapshot(g2.w) == s2
end

# --------------------------------------------------------------------------
@testset "W4. SinglePort против двух входящих связей        " begin
    #  У мультипорта две связи; замена на SinglePort должна отказать.
    w = Workflow(1)
    a = add_node!(w, DataNode(RpConst, rp_const())); setsettings!(w, a, Dict(:value => 1))
    b = add_node!(w, DataNode(RpConst, rp_const())); setsettings!(w, b, Dict(:value => 2))
    m = add_node!(w, DataNode(RpMulti, rp_multi()))
    add_connection!(w, a, :out, m, :in)
    add_connection!(w, b, :out, m, :in)
    old = getnode(w, m)
    s   = rp_snapshot(w)

    @test_throws ErrorException replace!(w, DataNode(RpDouble, rp_double()), m)
    msg = try; replace!(w, DataNode(RpDouble, rp_double()), m); catch e; sprint(showerror, e); end
    @test occursin("SinglePort", msg)
    @test occursin("2 connections", msg)
    @test getnode(w, m) === old
    @test rp_snapshot(w) == s

    #  Замена на другой мультипорт — законна.
    @test replace!(w, DataNode(RpMulti, rp_multi()), m) === old
    scheduler!(w)
    @test getdata(w, m, :out) == 3
end

# --------------------------------------------------------------------------
@testset "W5. отдающий выход с двумя потребителями         " begin
    #  Обычный выход на двух потребителей — замена на отдающий отказывает.
    w = Workflow(1)
    p = add_node!(w, DataNode(RpGiver, rp_plain()))
    r1 = add_node!(w, DataNode(RpTaker, rp_reader()))
    r2 = add_node!(w, DataNode(RpTaker, rp_reader()))
    add_connection!(w, p, :out, r1, :in)
    add_connection!(w, p, :out, r2, :in)
    old = getnode(w, p)
    s   = rp_snapshot(w)

    @test_throws ErrorException replace!(w, DataNode(RpGiver, rp_giver()), p)
    msg = try; replace!(w, DataNode(RpGiver, rp_giver()), p); catch e; sprint(showerror, e); end
    @test occursin("hands its value over", msg)
    @test occursin("2 connections", msg)
    @test getnode(w, p) === old
    @test rp_snapshot(w) == s
end

# --------------------------------------------------------------------------
@testset "W6. правило handover с обеих сторон              " begin
    #  Забирающий вход у замены, а кормит его обычный выход.
    w = Workflow(1)
    p = add_node!(w, DataNode(RpGiver, rp_plain()))
    r = add_node!(w, DataNode(RpTaker, rp_reader()))
    add_connection!(w, p, :out, r, :in)
    old = getnode(w, r)
    s   = rp_snapshot(w)
    @test_throws ErrorException replace!(w, DataNode(RpTaker, rp_taker()), r)
    msg = try; replace!(w, DataNode(RpTaker, rp_taker()), r); catch e; sprint(showerror, e); end
    @test occursin("takes ownership", msg)
    @test getnode(w, r) === old
    @test rp_snapshot(w) == s

    #  И обратное: потребитель забирает, а замену производителя ставим
    #  обычную — тоже отказ, иначе инвариант остался бы нарушенным.
    w2 = Workflow(1)
    p2 = add_node!(w2, DataNode(RpGiver, rp_giver()))
    t2 = add_node!(w2, DataNode(RpTaker, rp_taker()))
    add_connection!(w2, p2, :out, t2, :in)
    old2 = getnode(w2, p2)
    s2   = rp_snapshot(w2)
    @test_throws ErrorException replace!(w2, DataNode(RpGiver, rp_plain()), p2)
    msg2 = try; replace!(w2, DataNode(RpGiver, rp_plain()), p2); catch e; sprint(showerror, e); end
    @test occursin("takes ownership", msg2)
    @test getnode(w2, p2) === old2
    @test rp_snapshot(w2) == s2

    #  Отдающий на отдающий — законно, и забор продолжает работать.
    @test replace!(w2, DataNode(RpGiver, rp_giver()), p2) === old2
    scheduler!(w2)
    @test getdata(w2, t2, :out) == 6
    @test getstatus(w2, p2) == :released
end

# --------------------------------------------------------------------------
@testset "W7. настройки не подходят замене                 " begin
    #  Главный тест на «до первой записи»: отказывает ПЕРЕНОС НАСТРОЕК, то
    #  есть шаг после всех проверок портов. Граф обязан остаться прежним.
    w = Workflow(1)
    c = add_node!(w, DataNode(RpConst, rp_const()))
    d = add_node!(w, DataNode(RpDouble, rp_double()))
    add_connection!(w, c, :out, d, :in)
    setsettings!(w, c, Dict(:value => 5, :weird => "строка"))
    scheduler!(w)
    @test getdata(w, d, :out) == 10

    old = getnode(w, c)
    s   = rp_snapshot(w)
    #  У типизированного контейнера есть только поле value — ключ :weird
    #  в него не ложится.
    cand = DataNode(RpTyped, rp_typed())
    @test getid(cand) == 0
    @test_throws ErrorException replace!(w, cand, c)
    msg = try; replace!(w, DataNode(RpTyped, rp_typed()), c); catch e; sprint(showerror, e); end
    @test occursin("do not fit the replacement", msg)
    @test occursin("weird", msg)

    #  Отказ не коснулся ни графа, ни кандидата: id ему не выдан, то есть
    #  до первой записи дело не дошло. Откат после подмены вернул бы граф,
    #  но id у кандидата остался бы — это и различает «проверено заранее»
    #  и «откачено потом».
    @test getid(cand) == 0
    @test getnode(w, c) === old
    @test rp_snapshot(w) == s
    #  И посчитанное не пострадало.
    @test getstatus(w, c) == :clean
    @test getdata(w, c, :out) == 5
    @test getdata(w, d, :out) == 10

    #  Без лишнего ключа та же замена проходит, и значение переносится.
    setsettings!(w, c, Dict(:value => 7); replace = true)
    @test replace!(w, DataNode(RpTyped, rp_typed()), c) === old
    @test getnode(w, c).settings[:value] == 7
    scheduler!(w)
    @test getdata(w, d, :out) == 14
end

# --------------------------------------------------------------------------
@testset "W8. тот же объект уже в графе                    " begin
    g = rp_chain()
    s = rp_snapshot(g.w)
    other = getnode(g.w, g.c)
    @test_throws ErrorException replace!(g.w, other, g.d)
    msg = try; replace!(g.w, other, g.d); catch e; sprint(showerror, e); end
    @test occursin("already in the workflow", msg)
    @test rp_snapshot(g.w) == s

    #  Замена узла на себя же законна: это «перечитать буферы».
    self = getnode(g.w, g.d)
    @test replace!(g.w, self, g.d) === self
end

# ======================================================================
#  УСПЕХ
# ======================================================================

# --------------------------------------------------------------------------
@testset "R1. связи, id и настройки сохраняются            " begin
    g = rp_chain(value = 21)
    scheduler!(g.w)
    @test getdata(g.w, g.d, :out) == 42

    cids = sort!(collect(keys(g.w.connections)))
    old  = replace!(g.w, DataNode(RpTriple, rp_triple()), g.d)

    @test old isa DataNode{RpDouble}            # вернулся вытесненный узел
    @test getid(old) == g.d
    @test getnode(g.w, g.d) isa DataNode{RpTriple}
    @test getid(getnode(g.w, g.d)) == g.d
    @test sort!(collect(keys(g.w.connections))) == cids   # связи те же
    @test length(g.w.nodes) == 2

    scheduler!(g.w; reset_mode = :none)
    @test getdata(g.w, g.d, :out) == 63         # уже ×3
    @test getexecn(g.w, g.c) == 1               # источник не пересчитывался

    #  Настройки переносятся: у замены источника их не было.
    old_c = replace!(g.w, DataNode(RpConst, rp_const()), g.c)
    @test getnode(g.w, g.c).settings[:value] == 21
    @test old_c isa DataNode{RpConst}
end

# --------------------------------------------------------------------------
@testset "R2. буферы подтягиваются, родитель не считается  " begin
    g = rp_chain(value = 4)
    scheduler!(g.w)
    @test getexecn(g.w, g.c) == 1

    replace!(g.w, DataNode(RpTriple, rp_triple()), g.d)
    #  Буфер нового узла уже наполнен тем, что родитель опубликовал.
    @test getinputdata(getnode(g.w, g.d), :in) == 4

    scheduler!(g.w; reset_mode = :none)
    @test getdata(g.w, g.d, :out) == 12
    @test getexecn(g.w, g.c) == 1               # и после прогона — один раз
end

# --------------------------------------------------------------------------
@testset "R3. потомки инвалидируются                       " begin
    #  Const -> Double -> Double: меняем середину, нижний обязан пересчитаться.
    w = Workflow(1)
    c = add_node!(w, DataNode(RpConst,  rp_const())); setsettings!(w, c, Dict(:value => 1))
    m = add_node!(w, DataNode(RpDouble, rp_double()))
    b = add_node!(w, DataNode(RpDouble, rp_double()))
    add_connection!(w, c, :out, m, :in)
    add_connection!(w, m, :out, b, :in)
    scheduler!(w)
    @test getdata(w, b, :out) == 4
    @test getstatus(w, b) == :clean

    replace!(w, DataNode(RpTriple, rp_triple()), m)
    @test getstatus(w, b) == :dirty             # потомок инвалидирован
    @test getdata(w, b, :out) === nothing

    scheduler!(w; reset_mode = :none)
    @test getdata(w, b, :out) == 6              # 1 ×3 ×2
    @test getexecn(w, c) == 1
end

# --------------------------------------------------------------------------
@testset "R4. версия графа и журнал правок                 " begin
    g = rp_chain()
    v = g.w.ver
    replace!(g.w, DataNode(RpTriple, rp_triple()), g.d)
    @test g.w.ver == v + 1                      # ровно на единицу

    rp_withaudit() do
        g2 = rp_chain()
        n0 = length(g2.w.audit_log)
        replace!(g2.w, DataNode(RpTriple, rp_triple()), g2.d)
        @test length(g2.w.audit_log) == n0 + 1
        #  Своё событие, и в одной записи видно, что чем стало.
        @test g2.w.audit_log[end] == NodeReplaced(g2.d, "Main.RpTriple", "Main.RpDouble")
        #  Круг через словарь сохраняет обе метки типов.
        d = MetidaFlows.audit_event_to_dict(g2.w.audit_log[end])
        @test d["event"] == "NodeReplaced"
        @test d["type"] == "Main.RpTriple" && d["previous"] == "Main.RpDouble"
        @test MetidaFlows.dict_to_audit_event(d) == g2.w.audit_log[end]
    end
    @test SETTINGS[:audit] === false
end

# --------------------------------------------------------------------------
@testset "R5. петля: проверяются обе стороны связи         " begin
    #  Узел связан сам с собой через :feedback. Обе стороны такой связи
    #  после замены — новый узел, и проверять надо его.
    w = Workflow(1; type = :ABW)
    s = add_node!(w, DataNode(RpNoIn, rp_noin()))
    l = add_node!(w, DataNode(RpLoop, rp_loop()))
    add_connection!(w, l, :out, l, :prev)
    old = getnode(w, l)
    snap = rp_snapshot(w)

    #  Замена без порта :prev отказывает, граф цел.
    @test_throws ErrorException replace!(w, DataNode(RpNoIn, rp_noin()), l)
    @test getnode(w, l) === old
    @test rp_snapshot(w) == snap

    #  Замена с теми же портами проходит, и петля остаётся петлёй.
    @test replace!(w, DataNode(RpLoop, rp_loop()), l) === old
    @test length(w.connections) == 1
    con = first(values(w.connections))
    @test con.output_id == l && con.input_id == l

    #  Сужение типа петли. Обе стороны связи после замены — новый узел, и
    #  проверять надо его: если бы одна сторона бралась у СТАРОГО узла,
    #  вышло бы `Any <: Int`, и законная замена была бы отвергнута.
    w2 = Workflow(1; type = :ABW)
    la = add_node!(w2, DataNode(RpLoop, rp_loopany()))
    add_connection!(w2, la, :out, la, :prev)
    oldany = getnode(w2, la)
    @test replace!(w2, DataNode(RpLoop, rp_loop()), la) === oldany
    @test getporttype(getnode(w2, la), :out, :output) === Int
    @test getporttype(getnode(w2, la), :prev, :input) === Int
end

# --------------------------------------------------------------------------
@testset "R6. порядок мультипорта сохраняется              " begin
    #  Порядок на мультипорте задают идентификаторы связей — именно то, что
    #  потерялось бы при delete_node! + add_node!.
    w = Workflow(1)
    a = add_node!(w, DataNode(RpConst, rp_const())); setsettings!(w, a, Dict(:value => 1))
    b = add_node!(w, DataNode(RpConst, rp_const())); setsettings!(w, b, Dict(:value => 2))
    m = add_node!(w, DataNode(RpMulti, rp_multi()))
    c1 = add_connection!(w, a, :out, m, :in)
    c2 = add_connection!(w, b, :out, m, :in)
    scheduler!(w)
    @test getinputdata(getnode(w, m), :in) == [1, 2]

    replace!(w, DataNode(RpMulti, rp_multi()), m)
    @test sort!(collect(keys(w.connections))) == sort!([c1, c2])
    scheduler!(w; reset_mode = :none)
    @test getinputdata(getnode(w, m), :in) == [1, 2]
    @test getdata(w, m, :out) == 3
end

# --------------------------------------------------------------------------
@testset "R7. замена всегда :dirty                         " begin
    #  Решение владельца 20.11.2026: «замена в любом случае инвалидируется
    #  (на всякий случай)». Свежий узел приходит :idle — становится :dirty.
    g = rp_chain()
    scheduler!(g.w)
    fresh = DataNode(RpTriple, rp_triple())
    @test getstatus(fresh) == :idle
    replace!(g.w, fresh, g.d)
    @test getstatus(g.w, g.d) == :dirty

    #  Узел, который уже считал, приходит :clean — и всё равно :dirty, а
    #  принесённый кеш снят: опубликовать его как своё этот граф не может.
    w = Workflow(1)
    c = add_node!(w, DataNode(RpNoIn,   rp_noin()))      # без настроек
    d = add_node!(w, DataNode(RpDouble, rp_double()))
    add_connection!(w, c, :out, d, :in)
    scheduler!(w)
    @test getdata(w, d, :out) == 0

    #  Донор считает в своём графе и вынимается из него, иначе один объект
    #  оказался бы под двумя идентификаторами.
    w2 = Workflow(1)
    did = add_node!(w2, DataNode(RpConst, rp_const()))
    setsettings!(w2, did, Dict(:value => 100))
    scheduler!(w2)
    donor = getnode(w2, did)
    @test getstatus(donor) == :clean && getdata(donor, :out) == 100
    delete_node!(w2, did)

    replace!(w, donor, c)
    @test getstatus(w, c) == :dirty
    @test getdata(w, c, :out) === nothing                # кеш снят
    @test getstate(getnode(w, c), :ready_ports) == Symbol[]

    #  Потомок пересчитается, исполнив замену здесь заново.
    scheduler!(w; reset_mode = :none)
    @test getdata(w, c, :out) == 100
    @test getdata(w, d, :out) == 200
    @test getexecn(w, c) == 2                            # один раз там, один здесь

    #  Настройки переносятся со старого узла, и пересчёт идёт на них.
    w3 = Workflow(1)
    c3 = add_node!(w3, DataNode(RpConst, rp_const())); setsettings!(w3, c3, Dict(:value => 3))
    d3 = add_node!(w3, DataNode(RpDouble, rp_double()))
    add_connection!(w3, c3, :out, d3, :in)
    scheduler!(w3)

    w4 = Workflow(1)
    did4 = add_node!(w4, DataNode(RpConst, rp_const()))
    setsettings!(w4, did4, Dict(:value => 100))
    scheduler!(w4)
    donor4 = getnode(w4, did4)
    delete_node!(w4, did4)

    replace!(w3, donor4, c3)
    @test getstatus(w3, c3) == :dirty
    @test getnode(w3, c3).settings[:value] == 3          # 3, а не 100
    scheduler!(w3; reset_mode = :none)
    @test getdata(w3, d3, :out) == 6            # пересчитался на 3, не на 100
end

# --------------------------------------------------------------------------
@testset "R8. вытесненный узел можно вернуть               " begin
    g = rp_chain(value = 10)
    scheduler!(g.w)
    @test getdata(g.w, g.d, :out) == 20

    old = replace!(g.w, DataNode(RpTriple, rp_triple()), g.d)
    scheduler!(g.w; reset_mode = :none)
    @test getdata(g.w, g.d, :out) == 30

    back = replace!(g.w, old, g.d)              # ставим прежний узел назад
    @test back isa DataNode{RpTriple}
    @test getnode(g.w, g.d) === old
    scheduler!(g.w; reset_mode = :none)
    @test getdata(g.w, g.d, :out) == 20
    @test getexecn(g.w, g.c) == 1
end

# ======================================================================
#  ЗАМЕНА СПЕЦИФИКАЦИИ И ОТДЕЛЬНОГО ПОРТА
#
#  Спецификация узла — РАЗДЕЛЯЕМОЕ неизменяемое значение, и загрузка снимка
#  отдаёт всем узлам одного типа один объект из NODE_REGISTER. Поэтому порты
#  правятся этими двумя функциями, а не присваиванием в spec.input_ports:
#  правка на месте ушла бы в соседние узлы, в регистр и в каждый следующий
#  загруженный граф того же процесса.
# ======================================================================

# --------------------------------------------------------------------------
@testset "S1. nodetype отдаёт параметр типа                 " begin
    @test nodetype(DataNode(RpConst, rp_const())) === RpConst
    @test nodetype(DataNode(RpMulti, rp_multi())) === RpMulti
end

# --------------------------------------------------------------------------
@testset "S2. replacespec! меняет спек, связи целы          " begin
    g = rp_chain(value = 5)
    scheduler!(g.w)
    @test getdata(g.w, g.d, :out) == 10
    cids = sort!(collect(keys(g.w.connections)))

    #  Тот же тип узла, другой спек: вход принимает Any вместо Int.
    wide = NodeSpec("Double", [PortSpec("In", Any, :in)],
                              [PortSpec("Out", Int, :out)])
    old = replacespec!(g.w, g.d, wide)
    @test old isa DataNode{RpDouble}
    @test getnode(g.w, g.d) isa DataNode{RpDouble}          # тип сохранён
    @test getnode(g.w, g.d).spec === wide                   # спек тот, что дали
    @test sort!(collect(keys(g.w.connections))) == cids     # связи те же
    @test getid(getnode(g.w, g.d)) == g.d

    scheduler!(g.w; reset_mode = :none)
    @test getdata(g.w, g.d, :out) == 10
    @test getexecn(g.w, g.c) == 1                           # родитель не считался
end

# --------------------------------------------------------------------------
@testset "S3. replaceport! по метке: замена и добавление    " begin
    g = rp_chain()
    scheduler!(g.w)

    #  Метка есть — порт заменяется, остальные на месте.
    old = replaceport!(g.w, g.d, PortSpec("In", Any, :in), :input)
    @test old isa DataNode{RpDouble}
    node = getnode(g.w, g.d)
    @test length(node.spec.input_ports) == 1
    @test getportspec(node, :in, :input).datatype === Any
    @test isportexist(node, :out, :output)

    #  Метки нет — порт добавляется, и portmap пересобран: именно это
    #  потерялось бы, если копировать спек целиком вместе со старым portmap.
    replaceport!(g.w, g.d, PortSpec("Extra", Int, :extra), :output)
    node = getnode(g.w, g.d)
    @test length(node.spec.output_ports) == 2
    @test isportexist(node, :extra, :output)
    @test getportspec(node, :extra, :output).datatype === Int
    @test isportexist(node, :out, :output)                  # прежний не потерян

    #  Порт ищется ПО МЕТКЕ, а не по первому попавшемуся: у узла с двумя
    #  входами меняется именно названный, второй цел.
    w2 = Workflow(1)
    two = add_node!(w2, DataNode(RpConst, NodeSpec("Two",
        [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
        [PortSpec("Out", Int, :out)], [:value])))
    replaceport!(w2, two, PortSpec("B", Float64, :b), :input)
    n2 = getnode(w2, two)
    @test getportspec(n2, :b, :input).datatype === Float64
    @test getportspec(n2, :a, :input).datatype === Int        # первый не тронут
    @test length(n2.spec.input_ports) == 2

    #  Сторона проверяется.
    @test_throws ErrorException replaceport!(g.w, g.d, PortSpec("X", Int, :x), :sideways)
    msg = try; replaceport!(g.w, g.d, PortSpec("X", Int, :x), :sideways); catch e; sprint(showerror, e); end
    @test occursin(":input or :output", msg)
end

# --------------------------------------------------------------------------
@testset "S4. проверки replace! наследуются                 " begin
    #  Сужение типа входа, которому связь больше не отвечает: родитель
    #  отдаёт Int, а Int <: Float64 ложно.
    g = rp_chain()
    scheduler!(g.w)
    old  = getnode(g.w, g.d)
    snap = rp_snapshot(g.w)
    @test_throws ErrorException replaceport!(g.w, g.d, PortSpec("In", Float64, :in), :input)
    msg = try; replaceport!(g.w, g.d, PortSpec("In", Float64, :in), :input); catch e; sprint(showerror, e); end
    @test occursin("Type mismatch", msg)
    @test getnode(g.w, g.d) === old
    @test rp_snapshot(g.w) == snap

    #  MultiPort с двумя связями нельзя сузить до SinglePort.
    w = Workflow(1)
    a = add_node!(w, DataNode(RpConst, rp_const())); setsettings!(w, a, Dict(:value => 1))
    b = add_node!(w, DataNode(RpConst, rp_const())); setsettings!(w, b, Dict(:value => 2))
    m = add_node!(w, DataNode(RpMulti, rp_multi()))
    add_connection!(w, a, :out, m, :in)
    add_connection!(w, b, :out, m, :in)
    oldm = getnode(w, m)
    snapm = rp_snapshot(w)
    @test_throws ErrorException replaceport!(w, m, PortSpec("In", Int, :in), :input)
    @test occursin("SinglePort", try; replaceport!(w, m, PortSpec("In", Int, :in), :input); catch e; sprint(showerror, e); end)
    @test getnode(w, m) === oldm
    @test rp_snapshot(w) == snapm
    #  А на мультипорт — можно.
    @test replaceport!(w, m, PortSpec("In", Any, :in, MultiPort()), :input) === oldm
end

# --------------------------------------------------------------------------
@testset "S5. узлы снимка разделяют спек, replacespec! отцепляет" begin
    #  Здесь ничего не правится на месте намеренно: порча объекта из
    #  NODE_REGISTER вышла бы за пределы этого файла.
    unregister_all!()
    w = Workflow(1)
    s = add_node!(w, DataNode(RpNoIn,   rp_noin()))
    e1 = add_node!(w, DataNode(RpDouble, rp_double()))
    e2 = add_node!(w, DataNode(RpDouble, rp_double()))
    add_connection!(w, s, :out, e1, :in)
    #  Фабрика на каждый вызов — спеки разные.
    @test !(getnode(w, e1).spec === getnode(w, e2).spec)

    register_node!(w)
    w2 = dict_to_workflow(workflow_to_dict(w))
    #  А после загрузки — один объект, и он же в регистре.
    @test getnode(w2, e1).spec === getnode(w2, e2).spec
    @test getnode(w2, e1).spec === getregnodeinfo("Main.RpDouble")[2]

    #  replacespec! даёт узлу собственный спек: больше ничего не разделяется.
    own = NodeSpec("Double", [PortSpec("In", Any, :in)], [PortSpec("Out", Int, :out)])
    replacespec!(w2, e1, own)
    @test getnode(w2, e1).spec === own
    @test !(getnode(w2, e1).spec === getnode(w2, e2).spec)
    #  Сосед и регистр не тронуты.
    @test getportspec(getnode(w2, e2), :in, :input).datatype === Int
    @test getregnodeinfo("Main.RpDouble")[2].input_ports[1].datatype === Int

    #  То же для replaceport! — и это главная гарантия всей затеи: правка
    #  порта у узла, который делит спек с соседом и с регистром, не должна
    #  уйти ни в соседа, ни в регистр. Правка на месте ушла бы в оба.
    w3 = dict_to_workflow(workflow_to_dict(w))
    shared = getnode(w3, e1).spec
    @test shared === getnode(w3, e2).spec                    # делят объект
    replaceport!(w3, e1, PortSpec("In", Any, :in), :input)
    @test getportspec(getnode(w3, e1), :in, :input).datatype === Any
    @test getportspec(getnode(w3, e2), :in, :input).datatype === Int
    @test shared.input_ports[1].datatype === Int             # общий объект цел
    @test getregnodeinfo("Main.RpDouble")[2].input_ports[1].datatype === Int
    unregister_all!()
end

# --------------------------------------------------------------------------
@testset "S6. журнал и версия как у replace!                " begin
    unregister_all!()
    rp_withaudit() do
        g = rp_chain()
        v  = g.w.ver
        n0 = length(g.w.audit_log)
        wide = NodeSpec("Double", [PortSpec("In", Any, :in)], [PortSpec("Out", Int, :out)])
        replacespec!(g.w, g.d, wide)
        @test g.w.ver == v + 1
        @test length(g.w.audit_log) == n0 + 1
        #  Тип не менялся, поэтому запись своя: `NodeReplaced` назвал бы
        #  один и тот же тип дважды. Ключей нет - спеки не зарегистрированы.
        @test g.w.audit_log[end] == SpecChanged(g.d, "", "")
    end
    @test SETTINGS[:audit] === false
end

# ======================================================================
#  ВАРИАНТЫ СПЕКИ, ПОЗИЦИЯ И ЖУРНАЛ (0.8.0)
# ======================================================================

# --------------------------------------------------------------------------
@testset "V1. позиция переходит к замене                   " begin
    g = rp_chain()
    setposition!(getnode(g.w, g.d), (120, 40))

    #  Узел собран на умолчании (0, 0), но встаёт на место старого.
    old = replace!(g.w, DataNode(RpTriple, rp_triple()), g.d)
    @test getposition(old) == (120, 40)
    @test getposition(getnode(g.w, g.d)) == (120, 40)

    #  И своя позиция замены отбрасывается: место в графе важнее.
    setposition!(getnode(g.w, g.d), (7, 8))
    far = DataNode(RpDouble, 0, :idle, (999, 999), rp_double())
    replace!(g.w, far, g.d)
    @test getposition(getnode(g.w, g.d)) == (7, 8)

    #  Через спеку и через порт - то же самое: узел собирается внутри.
    replacespec!(g.w, g.d, rp_double())
    @test getposition(getnode(g.w, g.d)) == (7, 8)
    replaceport!(g.w, g.d, PortSpec("In", Any, :in), :input)
    @test getposition(getnode(g.w, g.d)) == (7, 8)
end

# --------------------------------------------------------------------------
@testset "V2. SpecChanged: ключи, кодек, закрытый набор     " begin
    unregister_all!()
    rp_withaudit() do
        g = rp_chain()
        #  Спека по умолчанию зарегистрирована, вариант - под своим ключом.
        register_node!(g.w; throw_warn = false)
        wide = NodeSpec("Double", [PortSpec("In", Any, :in)], [PortSpec("Out", Int, :out)])
        register_node!(DataNode(RpDouble, wide); key = "Main.RpDouble@any")

        replacespec!(g.w, g.d, wide)
        ev = g.w.audit_log[end]
        @test ev == SpecChanged(g.d, "Main.RpDouble@any", "Main.RpDouble")

        #  Смена узла по-прежнему пишет NodeReplaced.
        replace!(g.w, DataNode(RpTriple, rp_triple()), g.d)
        @test g.w.audit_log[end] == NodeReplaced(g.d, "Main.RpTriple", "Main.RpDouble")

        #  Кодек в обе стороны, и имя - из закрытого набора.
        d = MetidaFlows.audit_event_to_dict(ev)
        @test d["event"] == "SpecChanged"
        @test MetidaFlows.dict_to_audit_event(d) == ev
        @test "SpecChanged" in MetidaFlows.AUDIT_EVENT_NAMES
        @test length(MetidaFlows.AUDIT_EVENT_NAMES) == 7
        @test_throws ErrorException MetidaFlows.dict_to_audit_event(
            Dict{String, Any}("event" => "SpecInvented", "id" => 1))

        #  Журнал переживает круг через снимок целиком.
        register_node!(g.w; skipmode = true, throw_warn = false)   # RpTriple
        w2 = dict_to_workflow(workflow_to_dict(g.w; throw_warn = false))
        @test w2.audit_log == g.w.audit_log
    end
    unregister_all!()
end

# --------------------------------------------------------------------------
@testset "V3. ключ варианта в снимке                       " begin
    unregister_all!()
    g = rp_chain()
    register_node!(g.w; throw_warn = false)
    wide = NodeSpec("Double", [PortSpec("In", Any, :in)],
                              [PortSpec("Out", Int, :out), PortSpec("Dbg", Int, :dbg)])

    #  Без регистрации варианта: предупреждение при записи и порты типа
    #  после круга - то есть правка портов файл не переживает.
    replacespec!(g.w, g.d, wide)
    @test isnothing(noderegkey(getnode(g.w, g.d)))
    d0 = @test_logs (:warn, r"registered under no key") workflow_to_dict(g.w)
    @test d0["nodes"][string(g.d)]["type"] == "Main.RpDouble"
    @test [p.label for p in getnode(dict_to_workflow(d0), g.d).spec.output_ports] == [:out]

    #  Зарегистрировали тот же объект спеки - и ключ находится по тождеству.
    register_node!(getnode(g.w, g.d); key = "Main.RpDouble@dbg")
    @test noderegkey(getnode(g.w, g.d)) == "Main.RpDouble@dbg"
    d1 = workflow_to_dict(g.w)
    @test d1["format_version"] == 4
    @test d1["nodes"][string(g.d)]["type"] == "Main.RpDouble@dbg"

    w2 = dict_to_workflow(d1)
    @test [p.label for p in getnode(w2, g.d).spec.output_ports] == [:out, :dbg]
    @test getnode(w2, g.d).spec === getregnodeinfo("Main.RpDouble@dbg")[2]
    scheduler!(w2)
    @test getdata(w2, g.d, :out) == 42
    unregister_all!()
end

# --------------------------------------------------------------------------
@testset "V4. отдающий порт: снимок собирается только с ключом" begin
    #  Случай владельца: спека по умолчанию отдаёт значение, вариант - нет,
    #  и потребителей двое. Без ключа снимок не загружается вообще.
    for registered in (false, true)
        unregister_all!()
        plain = rp_plain()
        w = Workflow(1)
        s  = add_node!(w, DataNode(RpGiver, rp_giver()))
        register_node!(w; throw_warn = false)
        replacespec!(w, s, plain)
        r1 = add_node!(w, DataNode(RpReader, rp_reader()))
        r2 = add_node!(w, DataNode(RpReader, rp_reader()))
        add_connection!(w, s, :out, r1, :in)
        add_connection!(w, s, :out, r2, :in)
        register_node!(w; skipmode = true, throw_warn = false)
        registered && register_node!(getnode(w, s); key = "Main.RpGiver@plain")

        d = workflow_to_dict(w; throw_warn = false)
        if registered
            w2 = dict_to_workflow(d)
            scheduler!(w2)
            @test getdata(w2, r1, :out) == 6
            @test getdata(w2, r2, :out) == 6
        else
            @test_throws ErrorException dict_to_workflow(d)
        end
    end
    unregister_all!()
end

# --------------------------------------------------------------------------
@testset "V5. register_node!(w): по возрастанию id          " begin
    unregister_all!()
    w = Workflow(1)
    n1 = add_node!(w, DataNode(RpDouble, rp_double()))
    wide = NodeSpec("Double", [PortSpec("In", Any, :in)], [PortSpec("Out", Int, :out)])
    n2 = add_node!(w, DataNode(RpDouble, wide))
    n3 = add_node!(w, DataNode(RpDouble, wide))

    #  Регистрируется спека узла с наименьшим id, а не первого по словарю;
    #  про остальные сказано, и сказано с их номерами.
    #  Regex собирается строкой: в r"..." интерполяции нет.
    names = @test_logs (:warn,
        Regex("registered from node $(n1).*\\[$(n2), $(n3)\\]")) register_node!(w)
    @test names == ["Main.RpDouble"]
    @test getregnodeinfo("Main.RpDouble")[2] === getnode(w, n1).spec
    @test getregnodeinfo("Main.RpDouble")[2].input_ports[1].datatype === Int

    #  Предупреждение глушится, и это не меняет того, что регистрируется.
    unregister_all!()
    @test register_node!(w; throw_warn = false) == ["Main.RpDouble"]
    @test getregnodeinfo("Main.RpDouble")[2] === getnode(w, n1).spec

    #  Узлы, у которых спека совпадает по содержимому, не ссорятся: фабрика
    #  на каждый узел - обычное дело, и предупреждения здесь быть не должно.
    unregister_all!()
    w2 = Workflow(1)
    add_node!(w2, DataNode(RpDouble, rp_double()))
    add_node!(w2, DataNode(RpDouble, rp_double()))   # разные объекты, одни порты
    @test @test_logs(register_node!(w2)) == ["Main.RpDouble"]
    unregister_all!()
end

# --------------------------------------------------------------------------
@testset "V6. noderegkey и ключи регистра                  " begin
    unregister_all!()
    own, var = rp_double(), NodeSpec("Double", [PortSpec("In", Any, :in)],
                                               [PortSpec("Out", Int, :out)])
    @test register_node!(DataNode(RpDouble, own)) == "Main.RpDouble"
    @test register_node!(DataNode(RpDouble, var); key = "Main.RpDouble@any") ==
          "Main.RpDouble@any"

    @test noderegkey(DataNode(RpDouble, own)) == "Main.RpDouble"
    @test noderegkey(DataNode(RpDouble, var)) == "Main.RpDouble@any"
    #  Та же форма портов, но другой объект - ключа нет: тождество, не равенство.
    @test isnothing(noderegkey(DataNode(RpDouble, rp_double())))
    #  Чужой тип с той же спекой - тоже нет.
    @test isnothing(noderegkey(DataNode(RpTriple, own)))

    #  Занятый ключ и пустой ключ - отказ.
    @test_throws ErrorException register_node!(DataNode(RpDouble, var); key = "Main.RpDouble")
    @test_throws ErrorException register_node!(DataNode(RpDouble, var); key = "")
    @test isnothing(register_node!(DataNode(RpDouble, var); key = "Main.RpDouble",
                                   skipmode = true))
    #  Один объект под двумя ключами: ответ не зависит от обхода словаря.
    register_node!(DataNode(RpDouble, own); key = "Aaa.First")
    @test noderegkey(DataNode(RpDouble, own)) == "Main.RpDouble"   # свой ключ первым
    unregister_node!("Main.RpDouble")
    @test noderegkey(DataNode(RpDouble, own)) == "Aaa.First"
    unregister_all!()
end

end # @testset "ЗАМЕНА УЗЛА НА МЕСТЕ"
