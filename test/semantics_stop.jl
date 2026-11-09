############################################################################
#
#  РАННЯЯ ОСТАНОВКА ПРОГОНА
#
#
############################################################################

import MetidaFlows: PortSpec, DAW, ABW, getnode, getstatus, request_stop!,
    isstoprequested, failed_nodes, check_failed_nodes, reset!, NodeState,
    AbstractNodeState, setinputbuffer!

# --------------------------------------------------------------------------
#  Узлы: источник, рабочий узел со счётчиком исполнений и узел, который
#  находит ответ и просит остановиться.
# --------------------------------------------------------------------------

STOP_WORK = Ref(0)
resetstopwork!() = (STOP_WORK[] = 0)

struct StSeed  <: AbstractNodeType end
struct StWork  <: AbstractNodeType end
struct StFound <: AbstractNodeType end
struct StPlain <: AbstractNodeType end

sp_stseed()  = NodeSpec("St seed", PortSpec[], [PortSpec("Out", Int, :out)], [:value])
sp_stwork()  = NodeSpec("St work", [PortSpec("In", Int, :in)],
                                   [PortSpec("Out", Int, :out)])
sp_stfound() = NodeSpec("St found", [PortSpec("In", Int, :in)],
                                    [PortSpec("Out",    Int, :out),
                                     PortSpec("Answer", Int, :answer; kind = :terminal)])
sp_stplain() = NodeSpec("St plain", [PortSpec("In", Int, :in)],
                                    [PortSpec("Out", Int, :out)])

MetidaFlows.execute_unsafe!(n::DataNode{StSeed}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{StWork}) =
    (STOP_WORK[] += 1; setdata!(n, :out, getinputdata(n, :in) + 1); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{StPlain}) =
    (setdata!(n, :out, 2 * getinputdata(n, :in)); [:out])

#  Нашёл ответ: публикует и терминальный порт, и обычный — чтобы было
#  видно, что опубликованное доходит до буферов, а потомок всё равно не
#  считается. Просит остановиться, только пока взведён: иначе снятие
#  признака при reset! не отличить от повторной просьбы.
STOP_ARM = Ref(true)

function MetidaFlows.execute_unsafe!(n::DataNode{StFound})
    v = getinputdata(n, :in)
    setdata!(n, :answer, v)
    setdata!(n, :out,    v)
    STOP_ARM[] && request_stop!(n)
    return [:answer, :out]
end

#  Цикл, который сам решает, когда хватит: тело считает и на пределе
#  просит остановиться. Ни ворот, ни терминальных портов не нужно.
STOP_LIMIT = Ref(5)

struct StHead <: AbstractNodeType end
struct StBody <: AbstractNodeType end

sp_sthead() = NodeSpec("St head",
    [PortSpec("Seed", Int, :seed),
     PortSpec("Back", Int, :back; kind = :feedback, required = false)],
    [PortSpec("Out", Int, :out)])
sp_stbody() = NodeSpec("St body", [PortSpec("In", Int, :in)],
                                  [PortSpec("Out", Int, :out)])

MetidaFlows.execute_unsafe!(n::DataNode{StHead}) =
    (b = getinputdata(n, :back);
     setdata!(n, :out, isnothing(b) ? getinputdata(n, :seed) : b); [:out])

function MetidaFlows.execute_unsafe!(n::DataNode{StBody})
    v = getinputdata(n, :in) + 1
    setdata!(n, :out, v)
    v >= STOP_LIMIT[] && request_stop!(n)
    return [:out]
end

# --------------------------------------------------------------------------
#  Граф: `branches` независимых ветвей по `depth` рабочих узлов. В первой
#  ветви после рабочих узлов стоит StFound, а после него ещё StPlain.
# --------------------------------------------------------------------------
#  Ветвь с находкой КОРОТКАЯ, остальные длинные: иначе при обходе в
#  ширину вся работа успевает сделаться до узла-находки, и остановке
#  уже нечего экономить.
function stop_stand(type; branches = 5, answer_depth = 1, other_depth = 10,
                    tail_depth = 6)
    w = Workflow(0; type = type)
    found = 0; tail = 0; work = Int[]; tailwork = Int[]
    for k in 1:branches
        sd = add_node!(w, DataNode(StSeed, sp_stseed()))
        setsettings!(w, sd, Dict(:value => k))
        prev = sd
        for _ in 1:(k == 1 ? answer_depth : other_depth)
            c = add_node!(w, DataNode(StWork, sp_stwork()))
            add_connection!(w, prev, :out, c, :in)
            push!(work, c)
            prev = c
        end
        if k == 1
            found = add_node!(w, DataNode(StFound, sp_stfound()))
            add_connection!(w, prev, :out, found, :in)
            tail  = add_node!(w, DataNode(StPlain, sp_stplain()))
            add_connection!(w, found, :out, tail, :in)
            #  Цепочка ЗА находкой. Она ниже по потоку, значит в любом
            #  топологическом порядке идёт после неё — это единственная
            #  работа, экономия которой гарантирована в обоих движках.
            prev2 = tail
            for _ in 1:tail_depth
                c = add_node!(w, DataNode(StWork, sp_stwork()))
                add_connection!(w, prev2, :out, c, :in)
                push!(tailwork, c)
                prev2 = c
            end
        end
    end
    (w = w, found = found, tail = tail, work = work, tailwork = tailwork,
     branches = branches, answer_depth = answer_depth,
     other_depth = other_depth, tail_depth = tail_depth)
end

# ==========================================================================

@testset verbose = true "РАННЯЯ ОСТАНОВКА ПРОГОНА                         " begin

# --------------------------------------------------------------------------
@testset "T1. request_stop! и isstoprequested             " begin
    node = DataNode(StPlain, sp_stplain())
    @test !isstoprequested(node)
    @test request_stop!(node) === node
    @test isstoprequested(node)
    @test node.state.stop === true

    #  снимается только сбросом состояния
    empty!(node.state)
    @test !isstoprequested(node)

    #  своё состояние без поля stop: всегда false, попросить нельзя
    struct_state = FrozenState(1)
    other = DataNode(StPlain, sp_stplain(); state = struct_state)
    @test !isstoprequested(other)
    @test_throws ErrorException request_stop!(other)

    #  на уровне модели: кто остановил прогон — обычный запрос
    g = stop_stand(:ABW)
    scheduler!(g.w)
    @test [id for (id, n) in g.w.nodes if isstoprequested(n)] == [g.found]
end

# --------------------------------------------------------------------------
@testset "T2. ABW: работа после остановки не делается     " begin
    STOP_ARM[] = true
    g = stop_stand(:ABW)
    resetstopwork!()
    scheduler!(g.w)

    #  ГЛАВНОЕ ИЗМЕРЕНИЕ. Сколько именно успеет до находки, зависит от
    #  порядка очереди (она FIFO, но засевается в порядке обхода словаря
    #  узлов), поэтому проверяется неравенство. Было бы 41 + 6 из 41 + 6.
    @test length(g.work) == g.answer_depth + (g.branches - 1) * g.other_depth
    @test STOP_WORK[] < length(g.work) ÷ 2
    @test all(id -> getnode(g.w, id).state.exec_n == 0, g.tailwork)

    #  ответ отдан
    @test getdata(g.w, g.found, :answer) == 1 + g.answer_depth
    #  несчитанного много, и хвост целиком в том числе
    @test count(n -> getstatus(n) === :dirty, values(g.w.nodes)) ==
          length(g.work) - STOP_WORK[] + 1 + g.tail_depth
end

# --------------------------------------------------------------------------
@testset "T3. DAW: обход прекращается                    " begin
    STOP_ARM[] = true
    g = stop_stand(:DAW)
    resetstopwork!()
    scheduler!(g.w)

    #  ВАЖНОЕ ОТЛИЧИЕ ОТ ABW. Порядок обхода топологический и не в руках
    #  автора графа: независимые ветви могут оказаться и до узла, который
    #  просит остановиться, и после него.
    #
    #  СКОЛЬКО ЧУЖОЙ РАБОТЫ УСПЕЕТ — НЕ ОПРЕДЕЛЕНО. `topological_sort`
    #  строится по `makegraph`, а тот обходит словари узлов и связей,
    #  поэтому порядок зависит от версии Julia и от истории вставок.
    #  Замерено: на Julia 1.11.8 успевает 1 рабочий узел из 41, на 1.13.3
    #  — все 41. Поэтому утверждать про объём экономии в DAW нельзя, и
    #  проверяется только то, что гарантировано зависимостями: ниже узла
    #  по потоку не исполняется ничего.
    @test getdata(g.w, g.found, :answer) == 1 + g.answer_depth
    @test all(id -> getnode(g.w, id).state.exec_n == 0, g.tailwork)
    @test getnode(g.w, g.tail).state.exec_n == 0
    @test all(id -> getstatus(getnode(g.w, id)) === :dirty, g.tailwork)
    #  и что ветвь самой находки, конечно, посчиталась
    @test g.answer_depth <= STOP_WORK[] <= length(g.work)
end

# --------------------------------------------------------------------------
@testset "T4. опубликованное доходит, потомок не считается" begin
    STOP_ARM[] = true
    for type in (:ABW, :DAW)
        g = stop_stand(type)
        scheduler!(g.w)

        #  StFound опубликовал и :answer, и :out
        @test getdata(g.w, g.found, :answer) == 1 + g.answer_depth
        @test getdata(g.w, g.found, :out)    == 1 + g.answer_depth
        #  буфер потомка заполнен — публикация произошла
        @test !isempty(getnode(g.w, g.tail).input_buffer[:in])
        @test first(values(getnode(g.w, g.tail).input_buffer[:in])) ==
              1 + g.answer_depth
        #  но сам потомок не исполнялся
        @test getnode(g.w, g.tail).state.exec_n == 0
        @test getstatus(getnode(g.w, g.tail)) === :dirty
        @test getdata(g.w, g.tail, :out) === nothing
    end
end

# --------------------------------------------------------------------------
@testset "T5. остановка — не отказ                       " begin
    STOP_ARM[] = true
    for type in (:ABW, :DAW)
        g = stop_stand(type)
        scheduler!(g.w)
        @test isempty(failed_nodes(g.w))
        @test check_failed_nodes(g.w)
        @test isempty([m for m in g.w.log if m.level === :error])

        #  и strict на ней не ругается
        g2 = stop_stand(type)
        @test scheduler!(g2.w; strict = true)
        @test getdata(g2.w, g2.found, :answer) == 1 + g2.answer_depth
    end
end

# --------------------------------------------------------------------------
@testset "T6. запись в журнале                           " begin
    STOP_ARM[] = true
    for type in (:ABW, :DAW)
        g = stop_stand(type)
        scheduler!(g.w)
        infos = [m for m in g.w.log if m.level === :info]
        @test length(infos) == 1
        @test occursin("id: $(g.found)", infos[1].message)
        @test occursin("stopped", lowercase(infos[1].message))
    end
end

# --------------------------------------------------------------------------
@testset "T7. reset! снимает признак                     " begin
    #  Чтобы снятие признака было видно, узел «разводится»: первый прогон
    #  он просит остановиться, дальше — нет. Тогда разница между режимами
    #  в том, доходит ли прогон до хвоста за узлом-находкой.
    for mode in (:full, :soft)
        STOP_ARM[] = true
        g = stop_stand(:ABW)
        scheduler!(g.w)
        @test isstoprequested(getnode(g.w, g.found))
        @test getnode(g.w, g.tail).state.exec_n == 0

        STOP_ARM[] = false
        scheduler!(g.w; reset_mode = mode)
        @test !isstoprequested(getnode(g.w, g.found))     # reset! снял
        @test getnode(g.w, g.tail).state.exec_n == 1      # дошли до хвоста
        @test getdata(g.w, g.tail, :out) == 2 * (1 + g.answer_depth)
    end

    #  :none reset! не зовёт, поэтому признак прошлого прогона на месте и
    #  прогон опять кончается на том же узле, хотя узел уже не просит
    STOP_ARM[] = true
    g = stop_stand(:ABW)
    scheduler!(g.w)
    @test isstoprequested(getnode(g.w, g.found))

    STOP_ARM[] = false
    scheduler!(g.w; reset_mode = :none, maxiter = 10_000)
    @test isstoprequested(getnode(g.w, g.found))          # не снят
    @test getnode(g.w, g.tail).state.exec_n == 0          # до хвоста не дошли

    #  снять руками можно, и тогда :none тоже идёт дальше
    empty!(getnode(g.w, g.found).state)
    @test !isstoprequested(getnode(g.w, g.found))
    scheduler!(g.w; reset_mode = :none, maxiter = 10_000)
    @test getnode(g.w, g.tail).state.exec_n == 1
    STOP_ARM[] = true
end

@testset "T8. остановка в цикле ABW                      " begin
    #  Самый полезный случай: цикл, который сам решает, когда хватит, без
    #  ворот и терминальных портов.
    w  = Workflow(0; type = :ABW)
    sd = add_node!(w, DataNode(StSeed, sp_stseed()))
    setsettings!(w, sd, Dict(:value => 0))
    hd = add_node!(w, DataNode(StHead,  sp_sthead()))
    bd = add_node!(w, DataNode(StBody,  sp_stbody()))
    add_connection!(w, sd, :out, hd, :seed)
    add_connection!(w, hd, :out, bd, :in)
    add_connection!(w, bd, :out, hd, :back)

    STOP_LIMIT[] = 5
    resetstopwork!()
    scheduler!(w; maxiter = 10_000)
    @test getdata(w, bd, :out) == 5
    @test getnode(w, bd).state.exec_n == 5
    @test isstoprequested(getnode(w, bd))
    @test isempty(failed_nodes(w))

    #  тот же граф с другим лимитом после :full
    STOP_LIMIT[] = 9
    scheduler!(w; maxiter = 10_000)
    @test getdata(w, bd, :out) == 9
    @test getnode(w, bd).state.exec_n == 9
end

end
