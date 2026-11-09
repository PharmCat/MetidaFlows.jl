############################################################################
#
#  ОТКАЗ УЗЛА И ИСХОД ПРОГОНА
#
#
############################################################################

import MetidaFlows: PortSpec, DAW, ABW, getnode, getstatus, getportspec,
    failed_nodes, check_failed_nodes, setinputbuffer!, isready, reset!

# --------------------------------------------------------------------------
#  Узлы
# --------------------------------------------------------------------------

struct RSrc    <: AbstractNodeType end   # источник Int из настройки
struct RDbl    <: AbstractNodeType end   # вдвое
struct RFlaky  <: AbstractNodeType end   # падает по настройке
struct RGlobal <: AbstractNodeType end   # падает по внешнему флагу
struct RHead   <: AbstractNodeType end   # голова цикла
struct RGate   <: AbstractNodeType end   # ворота цикла

sp_rsrc()   = NodeSpec("R src", PortSpec[], [PortSpec("Out", Int, :out)], [:value])
sp_rdbl()   = NodeSpec("R dbl", [PortSpec("In", Int, :in)],
                                [PortSpec("Out", Int, :out)])
sp_rflaky() = NodeSpec("R flaky", [PortSpec("In", Int, :in)],
                                  [PortSpec("Out", Int, :out)], [:fail])
sp_rglobal()= NodeSpec("R global", [PortSpec("In", Int, :in)],
                                   [PortSpec("Out", Int, :out)])

MetidaFlows.execute_unsafe!(n::DataNode{RSrc}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{RDbl}) =
    (setdata!(n, :out, 2 * getinputdata(n, :in)); [:out])

function MetidaFlows.execute_unsafe!(n::DataNode{RFlaky})
    get(n.settings, :fail, false) && error("узел упал по настройке")
    setdata!(n, :out, 10 * getinputdata(n, :in))
    return [:out]
end

#  Падение по внешнему флагу: настройки не меняются, значит
#  `invalidate_downstream!` не вызывается и буферы прошлого прогона целы.
#  Именно в этом сценарии DAW отдавал неверный результат.
RFAIL = Ref(false)
function MetidaFlows.execute_unsafe!(n::DataNode{RGlobal})
    RFAIL[] && error("узел упал по внешнему флагу")
    setdata!(n, :out, 10 * getinputdata(n, :in))
    return [:out]
end

#  Минимальный цикл для проверки, что strict не ругается на законно
#  оставшийся :dirty.
sp_rhead() = NodeSpec("R head",
    [PortSpec("Seed", Int, :seed),
     PortSpec("Back", Int, :back; kind = :feedback, required = false)],
    [PortSpec("Out", Int, :out)])
sp_rgate() = NodeSpec("R gate",
    [PortSpec("In",    Int, :in),
     PortSpec("Limit", Int, :limit)],
    [PortSpec("Out",   Int, :out),
     PortSpec("Total", Int, :total; kind = :terminal)])

function MetidaFlows.execute_unsafe!(n::DataNode{RHead})
    back = getinputdata(n, :back)
    setdata!(n, :out, isnothing(back) ? getinputdata(n, :seed) : back)
    return [:out]
end
function MetidaFlows.execute_unsafe!(n::DataNode{RGate})
    v = getinputdata(n, :in)
    if v >= getinputdata(n, :limit)
        setdata!(n, :total, v)
        return [:total]
    end
    setdata!(n, :out, v + 1)
    return [:out]
end

# --------------------------------------------------------------------------
#  Графы
# --------------------------------------------------------------------------

#  Две независимые ветви, в левой посередине падающий узел.
#     s1 ─▶ fl(падает) ─▶ a1 ─▶ a2
#     s2 ─▶ b1 ─▶ b2
function two_branch(type; failing = RFlaky, spec = sp_rflaky())
    w  = Workflow(0; type = type)
    s1 = add_node!(w, DataNode(RSrc,    sp_rsrc()))
    fl = add_node!(w, DataNode(failing, spec))
    a1 = add_node!(w, DataNode(RDbl,    sp_rdbl()))
    a2 = add_node!(w, DataNode(RDbl,    sp_rdbl()))
    s2 = add_node!(w, DataNode(RSrc,    sp_rsrc()))
    b1 = add_node!(w, DataNode(RDbl,    sp_rdbl()))
    b2 = add_node!(w, DataNode(RDbl,    sp_rdbl()))
    setsettings!(w, s1, Dict(:value => 5))
    setsettings!(w, s2, Dict(:value => 7))
    add_connection!(w, s1, :out, fl, :in)
    add_connection!(w, fl, :out, a1, :in)
    add_connection!(w, a1, :out, a2, :in)
    add_connection!(w, s2, :out, b1, :in)
    add_connection!(w, b1, :out, b2, :in)
    (w = w, s1 = s1, fl = fl, a1 = a1, a2 = a2, s2 = s2, b1 = b1, b2 = b2)
end

#  Цикл-накопитель: от seed до limit, по единице за виток.
function counter_loop(; seed = 1, limit = 4)
    w  = Workflow(0; type = :ABW)
    cs = add_node!(w, DataNode(RSrc,  sp_rsrc()))
    cl = add_node!(w, DataNode(RSrc,  sp_rsrc()))
    hd = add_node!(w, DataNode(RHead, sp_rhead()))
    gt = add_node!(w, DataNode(RGate, sp_rgate()))
    #  Отвод от петлевого порта ворот. На завершающем витке ворота
    #  публикуют только терминальный порт, поэтому отвод не считается и
    #  остаётся :dirty — законно, а не из-за отказа.
    tap = add_node!(w, DataNode(RDbl, sp_rdbl()))
    setsettings!(w, cs, Dict(:value => seed))
    setsettings!(w, cl, Dict(:value => limit))
    add_connection!(w, cs, :out, hd, :seed)
    add_connection!(w, hd, :out, gt, :in)
    add_connection!(w, cl, :out, gt, :limit)
    add_connection!(w, gt, :out, hd, :back)
    add_connection!(w, gt, :out, tap, :in)
    (w = w, cs = cs, cl = cl, hd = hd, gt = gt, tap = tap)
end

# ==========================================================================

@testset verbose = true "ОТКАЗ УЗЛА И ИСХОД ПРОГОНА                       " begin

# --------------------------------------------------------------------------
@testset "R1. узел с упавшим предком не считается          " begin
    #  РЕГРЕССИЯ. Сценарий: первый прогон удачный, потом узел посередине
    #  падает по внешней причине, настройки не менялись, буферы целы.
    for type in (:DAW, :ABW)
        g = two_branch(type; failing = RGlobal, spec = sp_rglobal())
        RFAIL[] = false
        scheduler!(g.w)
        @test getdata(g.w, g.a2, :out) == 200          # 5·10·2·2
        stale = copy(getnode(g.w, g.a1).input_buffer[:in])
        @test !isempty(stale)

        RFAIL[] = true
        scheduler!(g.w)
        @test getstatus(getnode(g.w, g.fl)) === :failed
        #  ниже упавшего — ничего не посчитано
        @test getstatus(getnode(g.w, g.a1)) === :dirty
        @test getstatus(getnode(g.w, g.a2)) === :dirty
        @test getnode(g.w, g.a1).state.exec_n == 0
        @test getdata(g.w, g.a2, :out) === nothing
        #  и это НЕ из-за очистки буферов: значение прошлого прогона на месте
        @test getnode(g.w, g.a1).input_buffer[:in] == stale
    end
    RFAIL[] = false
end

# --------------------------------------------------------------------------
@testset "R2. независимые ветви доходят до конца           " begin
    for type in (:DAW, :ABW)
        g = two_branch(type)
        setsettings!(g.w, g.fl, Dict(:fail => true))
        scheduler!(g.w)

        @test getstatus(getnode(g.w, g.fl)) === :failed
        @test getstatus(getnode(g.w, g.a2)) === :dirty
        #  другая ветвь посчиталась целиком
        @test getstatus(getnode(g.w, g.b1)) === :clean
        @test getstatus(getnode(g.w, g.b2)) === :clean
        @test getdata(g.w, g.b2, :out) == 28           # 7·2·2
        #  одна запись в журнале, и прогон вернулся без исключения
        @test length([m for m in g.w.log if m.level === :error]) == 1
    end
end

# --------------------------------------------------------------------------
@testset "R3. failed_nodes                                 " begin
    #  чистый прогон — список пуст
    g = two_branch(:DAW)
    setsettings!(g.w, g.fl, Dict(:fail => false))
    scheduler!(g.w)
    @test isempty(failed_nodes(g.w))
    @test check_failed_nodes(g.w)

    #  упавший узел попадает в список со своим статусом
    g = two_branch(:DAW)
    setsettings!(g.w, g.fl, Dict(:fail => true))
    scheduler!(g.w)
    @test failed_nodes(g.w) == [g.fl => :failed]

    #  :dirty в список НЕ попадает, хотя узлов таких два
    @test length([id for (id, n) in g.w.nodes if getstatus(n) === :dirty]) == 2
    @test all(p -> last(p) !== :dirty, failed_nodes(g.w))

    #  статусы отказа валидации тоже считаются отказом
    w  = Workflow(0; type = :DAW)
    bad = add_node!(w, DataNode(NeedsCfgNode, spec_cfg()))     # требует :k
    scheduler!(w)
    @test failed_nodes(w) == [bad => :invalid_settings]
    @test !check_failed_nodes(w; throw_error = false)

    #  порядок — по id
    g2 = two_branch(:DAW)
    setsettings!(g2.w, g2.fl, Dict(:fail => true))
    g2b = add_node!(g2.w, DataNode(NeedsCfgNode, spec_cfg()))
    scheduler!(g2.w)
    ids = first.(failed_nodes(g2.w))
    @test ids == sort(ids)
    @test Set(ids) == Set([g2.fl, g2b])
end

# --------------------------------------------------------------------------
@testset "R4. check_failed_nodes                           " begin
    g = two_branch(:ABW)
    setsettings!(g.w, g.fl, Dict(:fail => true))
    scheduler!(g.w)

    @test !check_failed_nodes(g.w; throw_error = false)
    e = try (check_failed_nodes(g.w); "") catch err sprint(showerror, err) end
    @test occursin("1 node(s) did not execute", e)
    @test occursin("node $(g.fl) (failed)", e)
    @test occursin("workflow.log", e)

    #  два отказа — оба в сообщении
    g2 = two_branch(:ABW)
    setsettings!(g2.w, g2.fl, Dict(:fail => true))
    g2b = add_node!(g2.w, DataNode(NeedsCfgNode, spec_cfg()))
    scheduler!(g2.w)
    e2 = try (check_failed_nodes(g2.w); "") catch err sprint(showerror, err) end
    @test occursin("2 node(s) did not execute", e2)
    @test occursin("node $(g2.fl) (failed)", e2)
    @test occursin("node $(g2b) (invalid_settings)", e2)
end

# --------------------------------------------------------------------------
@testset "R5. strict: досчитать всё, потом упасть          " begin
    for type in (:DAW, :ABW)
        g = two_branch(type)
        setsettings!(g.w, g.fl, Dict(:fail => true))

        e = try (scheduler!(g.w; strict = true); "") catch err sprint(showerror, err) end
        @test occursin("node $(g.fl) (failed)", e)
        #  ГЛАВНОЕ: независимая ветвь ПОСЧИТАНА, несмотря на ошибку
        @test getdata(g.w, g.b2, :out) == 28
        @test getstatus(getnode(g.w, g.b2)) === :clean
        #  граф оставлен в послепрогонном состоянии — можно разбираться
        @test failed_nodes(g.w) == [g.fl => :failed]
        @test length([m for m in g.w.log if m.level === :error]) == 1
    end

    #  на чистом прогоне strict ничего не меняет
    for type in (:DAW, :ABW)
        g = two_branch(type)
        setsettings!(g.w, g.fl, Dict(:fail => false))
        @test scheduler!(g.w; strict = true)
        @test getdata(g.w, g.a2, :out) == 200
        @test getdata(g.w, g.b2, :out) == 28
    end
end

# --------------------------------------------------------------------------
@testset "R6. strict против throw_error                    " begin
    #  Разница в том, сколько работы теряется. `throw_error` обрывает
    #  обход в точке отказа, поэтому теряется всё, что к этому моменту
    #  ещё не считалось, — а что именно, зависит от ПОРЯДКА ОБХОДА, не от
    #  структуры графа. Гарантии нет ни в ту, ни в другую сторону.
    #  `strict` такой зависимости не имеет: независимая ветвь считается
    #  всегда.
    for type in (:DAW, :ABW)
        gt = two_branch(type)
        setsettings!(gt.w, gt.fl, Dict(:fail => true))
        @test_throws Exception scheduler!(gt.w; throw_error = true)
        done_throw = count(n -> getstatus(n) === :clean, values(gt.w.nodes))

        gs = two_branch(type)
        setsettings!(gs.w, gs.fl, Dict(:fail => true))
        @test_throws Exception scheduler!(gs.w; strict = true)
        done_strict = count(n -> getstatus(n) === :clean, values(gs.w.nodes))

        #  независимая ветвь при strict посчитана ВСЕГДА
        @test getdata(gs.w, gs.b2, :out) == 28
        @test getnode(gs.w, gs.b2).state.exec_n == 1
        #  и работы сделано не меньше, чем при обрыве
        @test done_strict >= done_throw
        @test done_strict == 4            # s1, s2, b1, b2
    end

    #  throw_error сильнее: если он бросил, до проверки strict не доходит
    g = two_branch(:ABW)
    setsettings!(g.w, g.fl, Dict(:fail => true))
    e = try (scheduler!(g.w; throw_error = true, strict = true); "")
        catch err sprint(showerror, err) end
    @test occursin("узел упал по настройке", e)
    @test !occursin("did not execute", e)
end

# --------------------------------------------------------------------------
@testset "R7. strict не ругается на законный :dirty        " begin
    #  Законченный циклический прогон оставляет тело :dirty — это не
    #  отказ, и strict молчит.
    g = counter_loop(seed = 1, limit = 4)
    @test scheduler!(g.w; strict = true)
    @test getdata(g.w, g.gt, :total) == 4
    @test isempty(failed_nodes(g.w))
    #  при этом :dirty в графе есть — отвод от петлевого порта
    @test getstatus(getnode(g.w, g.tap)) === :dirty
    @test !isempty([id for (id, n) in g.w.nodes if getstatus(n) === :dirty])

    #  и ветвь, которую ворота не выбрали, тоже не отказ
    g2 = counter_loop(seed = 9, limit = 4)       # сразу терминальный порт
    @test scheduler!(g2.w; strict = true)
    @test getdata(g2.w, g2.gt, :total) == 9
    @test isempty(failed_nodes(g2.w))
end

# --------------------------------------------------------------------------
@testset "R8. DAW: пропуск, а не :invalid_node             " begin
    #  До правки DAW доходил до потомка упавшего узла и ставил ему
    #  :invalid_node — то есть «узел настроен неверно», хотя настроен он
    #  правильно, а не хватало входа. Теперь он просто пропускается.
    g = two_branch(:DAW)
    setsettings!(g.w, g.fl, Dict(:fail => true))
    scheduler!(g.w)
    @test getstatus(getnode(g.w, g.a1)) === :dirty
    @test getstatus(getnode(g.w, g.a2)) === :dirty
    @test failed_nodes(g.w) == [g.fl => :failed]     # :invalid_node нет

    #  isready — ровно тот предикат, по которому идёт пропуск
    @test !isready(g.w, g.a1)
    @test isready(g.w, g.b1)                         # эта ветвь готова

    #  ABW ведёт себя так же
    gb = two_branch(:ABW)
    setsettings!(gb.w, gb.fl, Dict(:fail => true))
    scheduler!(gb.w)
    @test failed_nodes(gb.w) == [gb.fl => :failed]
end

end
