############################################################################
#
#  КАТЕГОРИЯ: СОБЫТИЯ ИСПОЛНЕНИЯ
#
#  Движок сообщает о двух моментах на каждое исполнение узла: взял узел и
#  отпустил. Событие — `NodeExecutionEvent` с id, run_id, статусом и
#  счётчиком исполнений на момент события; обратные вызовы лежат в
#  `ExecuteSettings` параметрами типа, поэтому в выключенном состоянии от
#  них не остаётся ни ветвления, ни сборки события.
#
#  Назначение: закрепить четыре свойства, каждое из которых легко потерять
#  при правке `execute_node!`.
#
#    * парность. Событие начала выдаётся на входе, до проверки на `:clean`
#      и до валидации, событие завершения — из `finally`. Значит у каждого
#      завершения ровно одно начало, на всех выходах функции, включая
#      `rethrow` при `throw_error = true`;
#    * различимость пропуска. Одинаковый `exec_n` в паре означает, что код
#      узла не запускался. Без этого `:clean` узел не отличить от
#      исполненного;
#    * обратный вызов не роняет прогон. Исключение ловится и пишется в
#      `model.log` уровнем `:error`;
#    * правка графа из обратного вызова обнаруживается по сдвигу `model.ver`
#      и тоже попадает в журнал: отменить её нельзя, но молчать о ней нельзя
#      тем более.
#
#  Поток, а не журнал: движок ничего не накапливает, в ABW узел на сорок
#  исполнений даёт сорок пар.
#
############################################################################

@testset "СОБЫТИЯ ИСПОЛНЕНИЯ                               " begin

#  Собиратель: замыкание над своим вектором, как в документации.
collector() = (acc = Tuple{Symbol, Int, Symbol, Int}[];
               (acc,
                ev -> push!(acc, (:start,  ev.id, ev.status, ev.exec_n)),
                ev -> push!(acc, (:finish, ev.id, ev.status, ev.exec_n))))

# --------------------------------------------------------------------------
@testset "V1. парность и порядок событий                   " begin
    w = Workflow(1)
    a = add_node!(w, DataNode(ConstNode, spec_const()))
    b = add_node!(w, DataNode(DoubleNode, spec_double()))
    add_connection!(w, a, :out, b, :in)

    acc, ons, onf = collector()
    scheduler!(w; on_start = ons, on_finish = onf)

    @test length(acc) == 4
    @test first.(acc) == [:start, :finish, :start, :finish]
    @test [t[2] for t in acc] == [a, a, b, b]
    #  На входе узел ещё :dirty, на выходе :clean.
    @test acc[1][3] == :dirty && acc[2][3] == :clean
    #  Счётчик вырос внутри пары: код узла запускался.
    @test acc[1][4] == 0 && acc[2][4] == 1
end

# --------------------------------------------------------------------------
@testset "V2. run_id один на прогон и меняется между ними  " begin
    w = Workflow(1)
    add_node!(w, DataNode(ConstNode, spec_const()))

    ids = UInt64[]
    scheduler!(w; on_start = ev -> push!(ids, ev.run_id))
    first_run = only(ids)
    @test first_run == w.run_id

    empty!(ids)
    scheduler!(w; on_start = ev -> push!(ids, ev.run_id))
    @test only(ids) != first_run
end

# --------------------------------------------------------------------------
@testset "V3. пропуск отличим от исполнения                " begin
    #  reset_mode = :none не трогает статусы, :clean узел возвращается сразу.
    w = Workflow(1)
    add_node!(w, DataNode(ConstNode, spec_const()))
    scheduler!(w)

    acc, ons, onf = collector()
    scheduler!(w; reset_mode = :none, on_start = ons, on_finish = onf)

    @test length(acc) == 2                      # пара всё равно есть
    @test acc[1][3] == :clean                   # вошли уже чистыми
    @test acc[1][4] == acc[2][4]                # счётчик не двинулся
end

# --------------------------------------------------------------------------
@testset "V4. завершение приходит на каждом выходе         " begin
    #  Отказ узла: статус :failed, счётчик успел вырасти.
    w = Workflow(1)
    e = add_node!(w, DataNode(ErrorNode, spec_plain("Err")))
    acc, ons, onf = collector()
    scheduler!(w; on_start = ons, on_finish = onf)
    @test length(acc) == 2
    @test acc[2][3] == :failed
    @test acc[2][4] == 1

    #  Непройденная валидация настроек: до кода узла не дошло.
    w2 = Workflow(1)
    n2 = add_node!(w2, DataNode(NeedsCfgNode, spec_plain("Cfg")))
    acc2, ons2, onf2 = collector()
    scheduler!(w2; on_start = ons2, on_finish = onf2)
    @test length(acc2) == 2
    @test acc2[2][3] == :invalid_settings
    @test acc2[1][4] == acc2[2][4] == 0

    #  throw_error = true: исключение уходит наружу, но завершение из
    #  finally приходит всё равно.
    w3 = Workflow(1)
    e3 = add_node!(w3, DataNode(ErrorNode, spec_plain("Err")))
    acc3, ons3, onf3 = collector()
    @test_throws Exception execute!(w3, e3;
        settings = ExecuteSettings(; on_start = ons3, on_finish = onf3),
        throw_error = true)
    @test length(acc3) == 2
    @test acc3[2][1] == :finish
    @test acc3[2][3] == :failed
end

# --------------------------------------------------------------------------
@testset "V5. исключение из обратного вызова не роняет     " begin
    w = Workflow(1)
    a = add_node!(w, DataNode(ConstNode, spec_const()))
    b = add_node!(w, DataNode(DoubleNode, spec_double()))
    add_connection!(w, a, :out, b, :in)

    @test scheduler!(w; on_start = ev -> error("подписчик сломан")) === true
    @test getstatus(w, a) == :clean
    @test getstatus(w, b) == :clean
    bad = filter(m -> m.level == :error && occursin("callback failed", m.message), w.log)
    @test length(bad) == 2                      # по одному на узел
    @test occursin("подписчик сломан", bad[1].message)
end

# --------------------------------------------------------------------------
@testset "V6. правка графа из обратного вызова замечена    " begin
    w = Workflow(1)
    a = add_node!(w, DataNode(ConstNode, spec_const()))

    fired = Ref(false)
    scheduler!(w; on_finish = function (ev)
            fired[] && return nothing
            fired[] = true
            add_node!(w, DataNode(ConstNode, spec_const()))   # ТАК НЕ НАДО
            nothing
        end)

    moved = filter(m -> m.level == :error && occursin("edited the graph", m.message), w.log)
    @test length(moved) == 1
    @test occursin("version", moved[1].message)
end

# --------------------------------------------------------------------------
@testset "V7. ABW: поток, пара на каждое исполнение        " begin
    #  Петля на себя: число пар равно числу исполнений, а не числу узлов.
    w    = Workflow(0; type = :ABW)
    seed = add_node!(w, DataNode(ConstNode,   spec_const()))
    loop = add_node!(w, DataNode(CounterLoop, spec_counterloop()))
    add_connection!(w, seed, :out,  loop, :start)
    add_connection!(w, loop, :next, loop, :previous)
    setsettings!(w, seed, Dict(:value => 0))
    setsettings!(w, loop, Dict(:limit => 3))

    perid = Dict{Int, Int}()
    @test scheduler!(w; on_finish = ev -> (perid[ev.id] = get(perid, ev.id, 0) + 1)) === true
    @test perid[loop] == getexecn(w, loop) == 4
    @test perid[seed] == getexecn(w, seed) == 1
end

# --------------------------------------------------------------------------
@testset "V8. выключенное состояние ничего не стоит        " begin
    #  Умолчание — ExecuteSettings{Nothing, Nothing}: метод, выдающий
    #  событие, вырождается в пустое тело, и событие не собирается.
    s = ExecuteSettings()
    @test s isa ExecuteSettings{Nothing, Nothing}
    @test s.on_start === nothing && s.on_finish === nothing
    @test ExecuteSettings(true) isa ExecuteSettings{Nothing, Nothing}
    @test ExecuteSettings(true, true, true, true) isa ExecuteSettings{Nothing, Nothing}

    #  С обратным вызовом тип несёт его конкретным параметром.
    f = ev -> nothing
    s2 = ExecuteSettings(; on_start = f)
    @test s2 isa ExecuteSettings{typeof(f), Nothing}

    #  Событие неизменяемо и все его поля конкретны, поэтому обратный вызов
    #  конкретного типа получает его без аллокации (замерено: прогон на 1000
    #  узлов с пустыми обратными вызовами выделяет столько же, сколько без них).
    ev = NodeExecutionEvent(3, UInt64(7), :clean, 2)
    @test !ismutabletype(NodeExecutionEvent)
    @test all(isconcretetype, fieldtypes(NodeExecutionEvent))
    @test (ev.id, ev.run_id, ev.status, ev.exec_n) == (3, UInt64(7), :clean, 2)
end

end # @testset "СОБЫТИЯ ИСПОЛНЕНИЯ"
