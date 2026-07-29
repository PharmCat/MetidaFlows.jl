############################################################################
#
#  КАТЕГОРИЯ: КРАЕВЫЕ СЛУЧАИ
#
#  Назначение: проверить поведение на границах — там, где количество
#  объектов равно нулю или единице, где счётчик упирается в предел, где
#  структура вырождена. Это не проверка ошибок: здесь пакет обязан
#  отработать штатно, просто на вырожденных данных.
#
#  Оси, по которым выбраны границы:
#    * количество нод: 0, 1, много;
#    * количество связей у порта: 0, 1, N (для MultiPort);
#    * количество портов: 0 входов, 0 выходов, 0 и того и другого;
#    * идентификаторы: пропуски после удаления, повторное добавление;
#    * счётчик итераций планировщика: ровно на границе;
#    * вырожденная топология: изолированная нода, петля на себя.
#
############################################################################

@testset "КРАЕВЫЕ СЛУЧАИ                                   " begin

# --------------------------------------------------------------------------
@testset "B1. пустой workflow                              " begin
    # Ноль нод — законное состояние: планировщики отрабатывают вхолостую.
    @test scheduler!(Workflow(0)) === true
    # у пустого графа стартовая очередь пуста, поэтому ABW предупреждает
    @test scheduler!(Workflow(0; type = :ABW); throw_warn = false) === true

    w = Workflow(0)
    g = makegraph(w)
    @test MetidaFlows.is_cyclic(g) == false
    @test isempty(collect(MetidaFlows.topological_sort(g)))

    @test reset!(w) === w
    @test isempty(w.nodes)

    d = workflow_to_dict(w)
    @test isempty(d["nodes"]) && isempty(d["connections"])
    @test d["n_iter"] == 0 && d["c_iter"] == 0
end

# --------------------------------------------------------------------------
@testset "B2. одна нода без связей                         " begin
    # Изолированная нода: все топологические запросы дают пустые ответы,
    # но исполнение проходит нормально.
    w  = Workflow(0)
    id = add_node!(w, DataNode(ConstNode, spec_const()))
    setsettings!(w, id, Dict(:value => 5))

    @test find_connections(w, id) == Int[]
    @test isempty(get_parents(w, id))
    @test isempty(get_children(w, id))

    # Запросы про несуществующую ноду не ошибка: топология пуста.
    @test find_connections(w, 99) == Int[]
    @test isempty(get_parents(w, 99))
    @test isempty(get_children(w, 99))
    @test isempty(getportconnections(w, id, :out))
    @test isready(w, id)                       # нет родителей — всегда готова
    @test push_buffer!(w, id) === w            # нет потомков — пустая операция

    @test scheduler!(w) === true
    @test getdata(w, id, :out) == 5
end

# --------------------------------------------------------------------------
@testset "B3. вырожденные спецификации портов              " begin
    # Нода вообще без портов.
    none = DataNode(ConstNode, spec_noports())
    @test !haveinputs(none)
    @test isempty(none.input_buffer)
    @test !isportexist(none, :out)
    @test length(spec_noports().portmap) == 0
    # all() по пустому списку входов истинно, поэтому валидация проходит
    @test execution_node_validation(none) == true

    # Нода без выходов (терминальный приёмник).
    sink = DataNode(DoubleNode, spec_sink())
    @test haveinputs(sink)
    @test !isportexist(sink, :out, :output)
    @test isportexist(sink, :in, :input)

    # Дубликаты меток не проверяются: в portmap выигрывает последний порт.
    dup = NodeSpec("Dup",
                   [PortSpec("first", Int, :p), PortSpec("second", Int, :p)],
                   PortSpec[])
    @test length(dup.portmap) == 1
    @test dup.portmap[(:input, :p)] == 2
end

# --------------------------------------------------------------------------
@testset "B4. буфер порта: 0, 1 и N записей                " begin
    # SinglePort.
    d = DataNode(DoubleNode, spec_double())
    @test getinputdata(d, :in) === nothing            # 0
    setinputbuffer!(d, :in, 1, 10)
    @test getinputdata(d, :in) == 10                  # 1
    invalidate_buffer!(d, :in, 1)
    @test getinputdata(d, :in) === nothing            # снова 0

    # MultiPort: пустой буфер — это пустой словарь, а не nothing.
    m = DataNode(CollectNode, spec_collect())
    @test getinputdata(m, :ins) == Dict{Int, Any}()
    @test isempty(getinputdata(m, :ins))
    for (i, v) in enumerate((1, 2, 3))
        setinputbuffer!(m, :ins, i, v)
    end
    @test length(getinputdata(m, :ins)) == 3
end

# --------------------------------------------------------------------------
@testset "B5. необязательный вход остаётся пустым          " begin
    w  = Workflow(0)
    id = add_node!(w, DataNode(OptionalNode, spec_optional()))
    n  = getnode(w, id)

    @test !getportspec(n, :maybe, :input).required
    @test isempty(n.input_buffer[:maybe])
    @test execute!(w, id) == [:out]
    @test getdata(n, :out) == -1
    @test getstatus(n) == :clean

    # Тот же граф с обязательным входом исполниться не может.
    w2  = Workflow(0)
    id2 = add_node!(w2, DataNode(DoubleNode, spec_double()))
    @test execute!(w2, id2) == Symbol[]
    @test getstatus(getnode(w2, id2)) == :invalid_node
end

# --------------------------------------------------------------------------
@testset "B6. пропуски в идентификаторах                   " begin
    # Счётчики только растут, поэтому после удалений в графе появляются
    # «дыры». Планировщик обязан работать с разреженными id.
    w   = Workflow(0)
    a   = add_node!(w, DataNode(ConstNode, spec_const()))
    tmp = add_node!(w, DataNode(DoubleNode, spec_double()))
    @test delete_node!(w, tmp)
    b   = add_node!(w, DataNode(DoubleNode, spec_double()))
    @test (a, tmp, b) == (1, 2, 3)
    @test !isnodeexist(w, tmp)

    add_connection!(w, a, :out, b, :in)
    setsettings!(w, a, Dict(:value => 6))
    @test scheduler!(w) === true
    @test getdata(w, b, :out) == 12

    # Повторное удаление и удаление несуществующего — не ошибка, а false.
    @test delete_node!(w, tmp) == false
    @test delete_connection!(w, 99) == false
    cid = first(keys(w.connections))
    @test delete_connection!(w, cid) == true
    @test delete_connection!(w, cid) == false
end

# --------------------------------------------------------------------------
@testset "B7. граница счётчика итераций ABW                " begin
    # Линейный граф из двух нод требует ровно двух итераций очереди.
    lin = build_linear(3; type = :ABW)
    @test_throws ErrorException scheduler!(lin.w; maxiter = 0)

    lin2 = build_linear(3; type = :ABW)
    @test scheduler!(lin2.w; maxiter = 1) === true
    @test getdata(lin2.w, lin2.dbl, :out) == 6

    # Одиночной ноде хватает и нулевого лимита: проверка стоит в начале
    # итерации, а очередь опустеет сразу после первой.
    w  = Workflow(0; type = :ABW)
    id = add_node!(w, DataNode(ConstNode, spec_const()))
    setsettings!(w, id, Dict(:value => 1))
    @test scheduler!(w; maxiter = 0) === true
    @test getdata(w, id, :out) == 1
end

# --------------------------------------------------------------------------
@testset "B8. недостижимые ноды в ABW                      " begin
    # Нода со входами, но без родителей, в очередь не попадает и остаётся
    # :dirty — прогон при этом считается завершённым.
    w  = Workflow(0; type = :ABW)
    u  = add_node!(w, DataNode(DoubleNode, spec_double()))
    @test_logs (:warn, "No nodes in queue...") scheduler!(w)
    @test getstatus(getnode(w, u)) == :dirty
    @test getdata(w, u, :out) === nothing

    # ABW не проверяет заполненность обязательных входов, поэтому нода
    # с одним подключённым входом из двух всё же исполнится.
    w2 = Workflow(0; type = :ABW)
    s  = add_node!(w2, DataNode(ConstNode, spec_const()))
    j  = add_node!(w2, DataNode(AddNode, spec_add()))
    add_connection!(w2, s, :out, j, :a)          # порт :b не подключён
    setsettings!(w2, s, Dict(:value => 9))
    @test scheduler!(w2) === true
    @test getstatus(getnode(w2, j)) == :clean
    @test getdata(w2, j, :out) == 9

    # DAW в том же графе отвергает ноду.
    w3 = Workflow(0)
    s3 = add_node!(w3, DataNode(ConstNode, spec_const()))
    j3 = add_node!(w3, DataNode(AddNode, spec_add()))
    add_connection!(w3, s3, :out, j3, :a)
    setsettings!(w3, s3, Dict(:value => 9))
    @test scheduler!(w3) === true
    @test getstatus(getnode(w3, j3)) == :invalid_node
end

# --------------------------------------------------------------------------
@testset "B9. петля на себя                                " begin
    # Графовое API петлю принимает: проверка ацикличности живёт в
    # планировщике, а не в add_connection!.
    w  = Workflow(0)
    id = add_node!(w, DataNode(SelfLoopNode, spec_loop()))
    cid = add_connection!(w, id, :out, id, :in)
    @test cid == 1
    @test get_parents(w, id)  == [(:in, id)]
    @test get_children(w, id) == [(:out, id, :in)]
    @test length(find_connections(w, id)) == 2      # входящая и исходящая — одна связь

    @test MetidaFlows.is_cyclic(makegraph(w))
    @test_throws ErrorException scheduler!(w)

    # Удаление ноды с петлёй проходит без повторного удаления связи.
    @test delete_node!(w, id) == true
    @test isempty(w.connections)
    @test isempty(w.nodes)
end

# --------------------------------------------------------------------------
@testset "B10. частичное заполнение выходных портов        " begin
    # Нода объявляет два выхода, но заполняет один. Вниз уходит только он.
    w   = Workflow(0)
    p   = add_node!(w, DataNode(PartialOutNode, spec_partial()))
    c1  = add_node!(w, DataNode(DoubleNode, spec_double()))
    c2  = add_node!(w, DataNode(DoubleNode, spec_double()))
    con1 = add_connection!(w, p, :first, c1, :in)
    con2 = add_connection!(w, p, :second, c2, :in)

    @test execute!(w, p) == [:first]
    @test getstate(getnode(w, p), :ready_ports) == [:first]
    @test getinputdata(getnode(w, c1), :in, con1) == 1
    @test getinputdata(getnode(w, c2), :in, con2) === nothing
    @test getdata(w, p, :second) === nothing
end

# --------------------------------------------------------------------------
@testset "B11. setreadyports! меняет длину вектора         " begin
    # Вектор ready_ports переиспользуется, поэтому важно, что он
    # корректно растёт и сокращается.
    n = DataNode(ConstNode, spec_const())
    setreadyports!(n, [:a, :b, :c])
    @test getstate(n, :ready_ports) == [:a, :b, :c]
    setreadyports!(n, [:x])
    @test getstate(n, :ready_ports) == [:x]
    setreadyports!(n, Symbol[])
    @test isempty(getstate(n, :ready_ports))
end

end # @testset "КРАЕВЫЕ СЛУЧАИ"
