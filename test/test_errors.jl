############################################################################
#
#  КАТЕГОРИЯ: ОШИБКИ
#
#  Назначение: пройти каждый путь, на котором пакет обязан сообщить об
#  ошибке, и проверить, что он сообщает о ней ожидаемым способом.
#
#  В пакете три разных канала сигнализации, и тесты разделены по ним:
#    1) исключение (`error`, `KeyError`) — нарушение контракта вызова;
#    2) статус ноды (`:invalid_*`, `:failed`) — отказ во время исполнения;
#    3) предупреждение (`@warn`) — обнаруженная, но не фатальная ситуация.
#
#  Отдельно проверяется, что неудача не оставляет workflow в порванном
#  состоянии: отклонённая связь не расходует идентификатор, упавшая нода
#  не публикует данные вниз по графу.
#
############################################################################

@testset "ОШИБКИ                                           " begin

# --------------------------------------------------------------------------
@testset "E1. неверные аргументы конструкторов             " begin
    @test_throws ErrorException Workflow(0; type = :UNKNOWN)

    # Ключи входного буфера обязаны существовать во входных портах.
    @test_throws ErrorException DataNode(DoubleNode, spec_double();
                                         input_buffer = Dict(:ghost => Dict{Int, Any}()))

    # Запись в immutable-состояние запрещена.
    @test_throws ErrorException setindex!(FrozenState(1), 2, :value)
end

# --------------------------------------------------------------------------
@testset "E2. обращение к несуществующим объектам          " begin
    w  = Workflow(0)
    id = add_node!(w, DataNode(ConstNode, spec_const()))

    @test_throws KeyError getnode(w, 99)
    @test_throws KeyError getconnection(w, 99)
    @test_throws KeyError getdata(w, 99, :out)
    @test_throws KeyError setsettings!(w, 99, Dict(:value => 1))
    @test_throws KeyError execute!(w, 99)
    @test_throws KeyError getportconnections(w, 99, :out)

    # Несуществующая метка порта в portmap.
    node = getnode(w, id)
    @test_throws KeyError getportnumber(node, :ghost, :output)
    @test_throws KeyError getporttype(node, :ghost, :output)
    @test_throws KeyError getportspec(node, :ghost, :output)
end

# --------------------------------------------------------------------------
@testset "E3. неверные индексы и направления портов        " begin
    node = DataNode(AddNode, spec_add())      # 2 входа, 1 выход

    # Индекс вне диапазона — для обоих направлений.
    @test_throws ErrorException getporttype(node, 0, :input)
    @test_throws ErrorException getporttype(node, 3, :input)
    @test_throws ErrorException getporttype(node, 0, :output)
    @test_throws ErrorException getporttype(node, 2, :output)

    # Направление должно быть :input или :output.
    @test_throws ErrorException getporttype(node, 1, :both)
    @test_throws ErrorException getporttype(node, 1, :any)

    # У isportexist свой набор допустимых направлений.
    @test_throws ErrorException isportexist(node, :a, :sideways)
    @test_throws ErrorException isportexist(node, :a, :both)

    # У getportconnections — свой.
    w = Workflow(0)
    nid = add_node!(w, node)
    @test_throws ErrorException getportconnections(w, nid, :a; direction = :any)
end

# --------------------------------------------------------------------------
@testset "E4. работа с данными вне спецификации            " begin
    n = DataNode(ConstNode, spec_const())

    @test_throws ErrorException getdata(n, :ghost)
    @test_throws ErrorException setdata!(n, :ghost, 1)

    d = DataNode(DoubleNode, spec_double())
    @test_throws ErrorException getinputdata(d, :ghost)
    @test_throws ErrorException getinputdata(d, :ghost, 1)
    @test_throws ErrorException getinputdata(d, :out)  # выходной порт не читается как вход

    # Два значения в SinglePort прочитать нельзя.
    setinputbuffer!(d, :in, 1, 10)
    setinputbuffer!(d, :in, 2, 20)
    @test_throws ErrorException getinputdata(d, :in)
end

# --------------------------------------------------------------------------
@testset "E5. валидация связей: все ветки отказа           " begin
    w    = Workflow(0)
    src  = add_node!(w, DataNode(ConstNode, spec_const()))
    dst  = add_node!(w, DataNode(DoubleNode, spec_double()))
    txt  = add_node!(w, DataNode(TextNode, spec_text()))
    free = add_node!(w, DataNode(DoubleNode, spec_double()))
    ok   = add_connection!(w, src, :out, dst, :in)
    @test ok == 1

    # 1. Нет родительской ноды.
    @test_throws ErrorException add_connection!(w, NodeConnection(99, :out, dst, :in))
    # 2. Нет дочерней ноды.
    @test_throws ErrorException add_connection!(w, NodeConnection(src, :out, 99, :in))
    # 3. Нет выходного порта.
    @test_throws ErrorException add_connection!(w, NodeConnection(src, :ghost, free, :in))
    # 4. Нет входного порта.
    @test_throws ErrorException add_connection!(w, NodeConnection(src, :out, free, :ghost))
    # 5. Входной SinglePort уже занят.
    @test_throws ErrorException add_connection!(w, NodeConnection(src, :out, dst, :in))
    # 6. Тип выхода не является подтипом типа входа.
    @test_throws ErrorException add_connection!(w, NodeConnection(txt, :out, free, :in))

    # Ни одна отклонённая попытка не изменила состояние workflow.
    @test w.c_iter == 1
    @test length(w.connections) == 1
    @test isempty(get(w.incoming, free, Int[]))
end

# --------------------------------------------------------------------------
@testset "E6. исключение внутри execute_unsafe!            " begin
    # Реализация по умолчанию всегда бросает ошибку.
    @test_throws ErrorException MetidaFlows.execute_unsafe!(DataNode(UndefinedNode, spec_plain("U")))

    # По умолчанию execute! гасит исключение: статус :failed, запись в лог,
    # пустой список готовых портов.
    w  = Workflow(0)
    id = add_node!(w, DataNode(ErrorNode, spec_plain("Error")))
    n  = getnode(w, id)

    @test execute!(w, id) == Symbol[]
    @test getstatus(n) == :failed
    @test length(w.log) == 1
    @test w.log[1].level == :error
    @test occursin("execution failed", w.log[1].message)
    @test occursin(string(id), w.log[1].message)

    # throw_error = true пробрасывает исходное исключение наружу,
    # статус и запись в лог при этом всё равно выставляются.
    @test_throws ErrorException execute!(w, id; throw_error = true)
    @test getstatus(n) == :failed
    @test length(w.log) == 2

    # Нода без реализации execute_unsafe! ведёт себя так же.
    w2  = Workflow(0)
    id2 = add_node!(w2, DataNode(UndefinedNode, spec_plain("U")))
    @test execute!(w2, id2) == Symbol[]
    @test getstatus(getnode(w2, id2)) == :failed
    @test_throws ErrorException execute!(w2, id2; throw_error = true)
end

# --------------------------------------------------------------------------
@testset "E7. отказ прерывает прогон планировщика          " begin
    # throw_error = true доводится до каждой ноды, которую запускает
    # планировщик, поэтому падение ноды прерывает весь прогон.
    for wftype in (:DAW, :ABW)
        w  = Workflow(0; type = wftype)
        id = add_node!(w, DataNode(ErrorNode, spec_plain("Error")))
        @test scheduler!(w) === true                       # по умолчанию — не прерывает
        @test getstatus(getnode(w, id)) == :failed
        @test_throws ErrorException scheduler!(w; throw_error = true)
    end
end

# --------------------------------------------------------------------------
@testset "E8. отказ не публикует данные вниз по графу      " begin
    # Нода, не прошедшая validate_result, уже записала свои данные,
    # но потомок их не получает: push_buffer! идёт после валидации.
    w    = Workflow(0)
    bad  = add_node!(w, DataNode(BadResultNode, spec_plain("Bad")))
    sink = add_node!(w, DataNode(DoubleNode, spec_double()))
    add_connection!(w, bad, :out, sink, :in)
    badnode, sinknode = getnode(w, bad), getnode(w, sink)

    @test execute!(w, bad) == Symbol[]
    @test getstatus(badnode) == :invalid_result
    @test getdata(badnode, :out) == 1                 # данные записаны локально
    @test isempty(sinknode.input_buffer[:in])         # но вниз не ушли
    @test isempty(getstate(badnode, :ready_ports))

    # Потомок из-за этого не может исполниться.
    @test execute!(w, sink) == Symbol[]
    @test getstatus(sinknode) == :invalid_node
end

# --------------------------------------------------------------------------
@testset "E9. статусы отказа от хуков валидации            " begin
    # validate_node -> :invalid_node
    w1  = Workflow(0)
    id1 = add_node!(w1, DataNode(BadStructNode, spec_plain("S")))
    @test execute!(w1, id1) == Symbol[]
    @test getstatus(getnode(w1, id1)) == :invalid_node

    # validate_settings -> :invalid_settings
    w2  = Workflow(0)
    id2 = add_node!(w2, DataNode(NeedsCfgNode, spec_cfg()))
    @test execute!(w2, id2) == Symbol[]
    @test getstatus(getnode(w2, id2)) == :invalid_settings
    # после исправления настроек нода считается
    setsettings!(w2, id2, Dict(:k => 11))
    @test execute!(w2, id2) == [:out]
    @test getstatus(getnode(w2, id2)) == :clean

    # незаполненный обязательный вход -> :invalid_node
    w3  = Workflow(0)
    id3 = add_node!(w3, DataNode(AddNode, spec_add()))
    @test execute!(w3, id3) == Symbol[]
    @test getstatus(getnode(w3, id3)) == :invalid_node

    # ни один из этих отказов не пишет в журнал workflow
    @test isempty(w1.log) && isempty(w2.log) && isempty(w3.log)
end

# --------------------------------------------------------------------------
@testset "E10. отказы планировщиков                        " begin
    # DAW отвергает циклический граф до начала исполнения.
    wc = Workflow(0)
    n1 = add_node!(wc, DataNode(DoubleNode, spec_double()))
    n2 = add_node!(wc, DataNode(DoubleNode, spec_double()))
    add_connection!(wc, n1, :out, n2, :in)
    add_connection!(wc, n2, :out, n1, :in)
    @test_throws ErrorException scheduler!(wc)
    @test getstatus(getnode(wc, n1)) == :dirty     # ничего не исполнялось

    # ABW прерывается по счётчику итераций.
    lin = build_linear(2; type = :ABW)
    @test_throws ErrorException scheduler!(lin.w; maxiter = 0)
end

# --------------------------------------------------------------------------
@testset "E11. предупреждения                              " begin
    # Повторный заход в исполняющуюся ноду: рекурсия обрывается
    # предупреждением, а не исключением.
    w  = Workflow(0)
    ln = DataNode(SelfLoopNode, spec_loop())
    id = add_node!(w, ln)
    add_connection!(w, id, :out, id, :in)

    rp = @test_logs (:warn, "Ring detected") execute!(w, id)
    @test rp == Symbol[]
    @test getstatus(ln) == :invalid_node

    # Предупреждение о возможном переполнении стека при подтягивании
    # родителей в очень большом графе.
    wl = Workflow(0)
    for _ in 1:1001
        nid = add_node!(wl, DataNode(ConstNode, spec_const()))
        setsettings_unsafe!(getnode(wl, nid), Dict(:value => nid))
    end
    @test_logs (:warn, r"large number") execute!(wl, 1)
    @test getdata(wl, 1, :out) == 1
end

end # @testset "ОШИБКИ"
