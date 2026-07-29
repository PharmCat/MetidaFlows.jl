############################################################################
#
#  КАТЕГОРИЯ: ЦИКЛИЧЕСКИЕ ГРАФЫ
#
#  Назначение: проверить итеративное исполнение в ABW — то, чего DAW не
#  умеет и не должен. Цикл в графе допустим, если замыкающее его ребро
#  входит в порт с `kind = :feedback`.
#
#  Механизм держится на двух независимых деталях движка, и тесты
#  проверяют каждую отдельно:
#
#    1) `isready` ждёт только производителей на `:normal`-портах.
#       Обратное ребро не проверяется — иначе цикл был бы дедлоком:
#       узел ждал бы предка, который ждёт его самого.
#
#    2) планировщик ABW помечает `:dirty` каждого потомка, которого
#       ставит в очередь. Без этого второй узел петли остался бы
#       `:clean`, а `execute!` вернул бы сохранённые `ready_ports`
#       без пересчёта — петля крутилась бы вхолостую до `maxiter`.
#
#  Отдельно проверяются два документированных правила: цикл требует
#  узла-источника без входных портов, а DAW обратную связь не признаёт.
#
############################################################################

@testset "ЦИКЛИЧЕСКИЕ ГРАФЫ                                " begin

# --------------------------------------------------------------------------
@testset "L1. петля на себя: счётчик витков                " begin
    # Простейший цикл: узел подключён к самому себе через :feedback-порт.
    # Останов — по счётчику: узел публикует терминальный порт вместо того,
    # который замыкает петлю, и очередь пустеет.
    resetcalls!()
    w    = Workflow(0; type = :ABW)
    seed = add_node!(w, DataNode(ConstNode,   spec_const()))
    loop = add_node!(w, DataNode(CounterLoop, spec_counterloop()))
    add_connection!(w, seed, :out,  loop, :start)
    cfb = add_connection!(w, loop, :next, loop, :previous)      # петля
    setsettings!(w, seed, Dict(:value => 0))
    setsettings!(w, loop, Dict(:limit => 3))

    @test scheduler!(w) === true
    @test getdata(w, loop, :total) == 3
    @test calls(:counterloop) == 4        # витки n = 0, 1, 2, 3
    @test calls(:const) == 1              # источник вне петли — один раз
    @test getstatus(getnode(w, loop)) == :clean

    # exec_n ведёт счёт исполнений внутри прогона
    @test getstate(getnode(w, loop), :exec_n) == 4
    @test getstate(getnode(w, seed), :exec_n) == 1

    # значение последнего опубликованного витка осталось в буфере задержки
    @test getinputdata(getnode(w, loop), :previous, cfb) == 3
end

# --------------------------------------------------------------------------
@testset "L2. петля из двух узлов: исполнитель и контроллер" begin
    # Работа и политика останова разделены: StepNode считает, CtrlNode
    # решает. Ровно этот случай требует, чтобы планировщик помечал :dirty
    # потомка на ОБЫЧНОМ ребре: иначе CtrlNode после первого исполнения
    # остался бы :clean и вечно воспроизводил своё первое решение.
    resetcalls!()
    w    = Workflow(0; type = :ABW)
    seed = add_node!(w, DataNode(ConstNode, spec_const()))
    step = add_node!(w, DataNode(StepNode,  spec_step()))
    ctrl = add_node!(w, DataNode(CtrlNode,  spec_ctrl()))
    add_connection!(w, seed, :out,   step, :start)
    add_connection!(w, step, :state, ctrl, :state)       # обычное ребро
    add_connection!(w, ctrl, :next,  step, :previous)    # обратное ребро
    setsettings!(w, seed, Dict(:value => 0))
    setsettings!(w, ctrl, Dict(:limit => 3))

    @test scheduler!(w) === true
    @test getdata(w, ctrl, :total) == 3
    @test calls(:step) == 3
    @test calls(:ctrl) == 3               # контроллер пересчитывался каждый виток
    @test getstate(getnode(w, ctrl), :exec_n) == 3
    @test getstatus(getnode(w, step)) == :clean
end

# --------------------------------------------------------------------------
@testset "L3. ромб внутри цикла                            " begin
    # Внутри петли значение расходится на две ветви и снова сходится:
    #
    #   Const ─▶ Head ─┬─▶ Scale ─┐
    #             ▲     │          ├─▶ Join ─▶ Ctrl ─┐
    #             │     └─▶ Shift ─┘                 │
    #             └────────── :feedback ─────────────┘
    #
    # Проверяется, что свойство ромба сохраняется в цикле: узел слияния
    # ждёт ОБЕ ветви и исполняется ровно один раз за виток. Это работа
    # `isready`: обратное ребро он пропускает, обычные — нет.
    resetcalls!()
    w     = Workflow(0; type = :ABW)
    seed  = add_node!(w, DataNode(ConstNode,  spec_const()))
    head  = add_node!(w, DataNode(LoopHead,   spec_loophead()))
    scale = add_node!(w, DataNode(ScaleNode,  spec_scale()))
    shift = add_node!(w, DataNode(ShiftNode,  spec_shift()))
    join  = add_node!(w, DataNode(JoinNode,   spec_join()))
    ctrl  = add_node!(w, DataNode(CtrlNode,   spec_ctrl()))

    add_connection!(w, seed,  :out,   head,  :start)
    add_connection!(w, head,  :state, scale, :in)
    add_connection!(w, head,  :state, shift, :in)
    add_connection!(w, scale, :out,   join,  :a)
    add_connection!(w, shift, :out,   join,  :b)
    add_connection!(w, join,  :out,   ctrl,  :state)
    add_connection!(w, ctrl,  :next,  head,  :previous)   # единственное обратное ребро

    setsettings!(w, seed, Dict(:value => 1))
    setsettings!(w, ctrl, Dict(:limit => 100))

    @test scheduler!(w) === true

    # рекуррента: n -> 2n + (n + 10) = 3n + 10;  1 -> 13 -> 49 -> 157
    @test getdata(w, ctrl, :total) == 157
    @test calls(:loophead) == 3

    # ГЛАВНОЕ: слияние исполнилось по одному разу за виток, а не по разу
    # на каждую пришедшую ветвь
    @test calls(:join) == 3
    @test getstate(getnode(w, join), :exec_n) == 3

    # и оба входа слияния всегда принадлежали одному витку
    @test calls(:join_mismatch) == 0

    @test calls(:scale) == 3
    @test calls(:shift) == 3
    @test calls(:const) == 1
    @test all(getstatus(getnode(w, i)) == :clean
              for i in (seed, head, scale, shift, join, ctrl))
end

# --------------------------------------------------------------------------
@testset "L4. страховка по числу итераций                  " begin
    # Если узел продолжает публиковать в петлю, прогон обрывается
    # ошибкой, а не зависает.
    resetcalls!()
    w    = Workflow(0; type = :ABW)
    seed = add_node!(w, DataNode(ConstNode,   spec_const()))
    loop = add_node!(w, DataNode(CounterLoop, spec_counterloop()))
    add_connection!(w, seed, :out,  loop, :start)
    add_connection!(w, loop, :next, loop, :previous)
    setsettings!(w, seed, Dict(:value => 0))
    setsettings!(w, loop, Dict(:limit => 100))     # витков больше, чем разрешено

    @test_throws ErrorException scheduler!(w; maxiter = 5)

    # с достаточным лимитом тот же граф доходит до конца
    @test scheduler!(w; maxiter = 1000) === true
    @test getdata(w, loop, :total) == 100
end

# --------------------------------------------------------------------------
@testset "L5. правило: циклу нужен узел-источник           " begin
    # :feedback-порт остаётся входным портом, поэтому узел, у которого все
    # входы обратные, не попадает в стартовую очередь. Петля без внешнего
    # источника не начинается: это не ошибка, а предупреждение.
    w = Workflow(0; type = :ABW)
    a = add_node!(w, DataNode(FeedbackOnlyNode, spec_fbonly()))
    b = add_node!(w, DataNode(DoubleNode,       spec_double()))
    add_connection!(w, a, :out, b, :in)           # обычное ребро
    add_connection!(w, b, :out, a, :previous)     # обратное ребро

    @test haveinputs(getnode(w, a))               # обратный вход тоже вход
    @test_logs (:warn, "No nodes in queue...") scheduler!(w)
    @test getstatus(getnode(w, a)) == :dirty      # симптом: узлы остались :dirty
    @test getstatus(getnode(w, b)) == :dirty
    @test calls(:fbonly) == 0

    # предупреждение отключается флагом
    @test scheduler!(w; throw_warn = false) === true
end

# --------------------------------------------------------------------------
@testset "L6. правило: DAW обратную связь не признаёт      " begin
    # makegraph включает ВСЕ связи независимо от вида порта, поэтому для
    # DAW петля через :feedback остаётся обычным циклом и отвергается.
    w    = Workflow(0)                            # DAW
    seed = add_node!(w, DataNode(ConstNode,   spec_const()))
    loop = add_node!(w, DataNode(CounterLoop, spec_counterloop()))
    add_connection!(w, seed, :out,  loop, :start)
    add_connection!(w, loop, :next, loop, :previous)

    @test MetidaFlows.is_cyclic(makegraph(w))
    @test_throws ErrorException scheduler!(w)
    @test getstatus(getnode(w, loop)) == :dirty   # исполнение не начиналось

    # В DAW единственный эффект :feedback — освобождение от проверки
    # заполненности буфера. Никакой задержки и второго прохода нет.
    @test execution_node_validation(DataNode(FeedbackOnlyNode, spec_fbonly())) == true
end

# --------------------------------------------------------------------------
@testset "L7. reset_mode                                   " begin
    @test_throws ErrorException scheduler!(build_linear(2).w; reset_mode = :bogus)
    @test_throws ErrorException scheduler!(build_linear(2; type = :ABW).w;
                                           reset_mode = :bogus)

    # :full (по умолчанию) — кеш выходов сбрасывается, всё считается заново
    resetcalls!()
    lin = build_linear(5; type = :ABW)
    scheduler!(lin.w)
    scheduler!(lin.w; reset_mode = :full)
    @test calls(:const) == 2
    @test getdata(lin.w, lin.dbl, :out) == 10

    # :soft — статусы :dirty, кеш выходов сохраняется
    lin2 = build_linear(5; type = :ABW)
    scheduler!(lin2.w)
    src2 = getnode(lin2.w, lin2.src)
    reset!(lin2.w; soft = true)
    @test getstatus(src2) == :dirty
    @test getdata(src2, :out) == 5
    @test getstate(src2, :exec_n) == 0            # счётчик обнуляется в любом режиме
    reset!(lin2.w)                                # полный сброс
    @test getdata(src2, :out) === nothing

    # :none — статусы не трогаем, поэтому :clean-узлы не пересчитываются
    resetcalls!()
    lin3 = build_linear(7; type = :ABW)
    scheduler!(lin3.w)
    before = calls(:const)
    scheduler!(lin3.w; reset_mode = :none)
    @test calls(:const) == before
    @test getdata(lin3.w, lin3.dbl, :out) == 14
end

# --------------------------------------------------------------------------
@testset "L8. exec_n: счётчик исполнений                   " begin
    lin = build_linear(3)
    n   = getnode(lin.w, lin.src)
    @test getstate(n, :exec_n) == 0

    execute!(lin.w, lin.src)
    @test getstate(n, :exec_n) == 1
    execute!(lin.w, lin.src)                      # :clean -> короткое замыкание
    @test getstate(n, :exec_n) == 1

    # mark_dirty! счётчик НЕ трогает: инвалидация поддерева не должна
    # терять число исполнений — иначе в петле ABW нельзя было бы считать витки
    mark_dirty!(n)
    @test getstate(n, :exec_n) == 1
    execute!(lin.w, lin.src)
    @test getstate(n, :exec_n) == 2               # накапливается

    # обнуляет полный сброс модели — в любом режиме
    reset!(lin.w)
    @test getstate(n, :exec_n) == 0
    reset!(lin.w; soft = true)
    @test getstate(n, :exec_n) == 0

    # узел, не прошедший валидацию, до execute_unsafe! не доходит
    w2  = Workflow(0)
    bad = DataNode(AddNode, spec_add())
    id2 = add_node!(w2, bad)
    execute!(w2, id2)
    @test getstatus(bad) == :invalid_node
    @test getstate(bad, :exec_n) == 0

    # упавший узел исполнение начал, поэтому счётчик увеличен
    w3  = Workflow(0)
    err = DataNode(ErrorNode, spec_plain("E"))
    id3 = add_node!(w3, err)
    execute!(w3, id3)
    @test getstatus(err) == :failed
    @test getstate(err, :exec_n) == 1

    # инвалидация вниз по графу счётчик потомка сохраняет
    lin2 = build_linear(4)
    execute!(lin2.w, lin2.dbl)
    dbl2 = getnode(lin2.w, lin2.dbl)
    @test getstate(dbl2, :exec_n) == 1
    setsettings!(lin2.w, lin2.src, Dict(:value => 9))   # invalidate_downstream!
    @test getstatus(dbl2) == :dirty
    @test getstate(dbl2, :exec_n) == 1
    execute!(lin2.w, lin2.dbl)
    @test getstate(dbl2, :exec_n) == 2

    # полный сброс самой ноды обнуляет вместе со всем состоянием
    reset!(dbl2)
    @test getstate(dbl2, :exec_n) == 0
end

# --------------------------------------------------------------------------
@testset "L9. валидация вида порта                         " begin
    @test PortSpec("x", Int, :x).kind === :normal
    @test PortSpec("x", Int, :x; kind = :terminal).kind === :terminal
    @test PortSpec("x", Int, :x; kind = :feedback).kind === :feedback
    @test PortSpec("e", ErrorException, :e; kind = :error, required = false).kind === :error

    @test_throws ErrorException PortSpec("x", Int, :x; kind = :bogus)
    # :error-порт не может быть обязательным
    @test_throws ErrorException PortSpec("e", ErrorException, :e; kind = :error)
    # и должен нести подтип Exception
    @test_throws ErrorException PortSpec("e", Int, :e; kind = :error, required = false)

    # :feedback описывает потребителя, поэтому на выходе запрещён
    @test_throws ErrorException NodeSpec("Bad", PortSpec[],
        [PortSpec("out", Int, :out; kind = :feedback)])

    # вид порта попадает в сериализованное описание
    @test portspec_to_dict(PortSpec("x", Int, :x; kind = :terminal))["kind"] == "terminal"
end

end # @testset "ЦИКЛИЧЕСКИЕ ГРАФЫ"
