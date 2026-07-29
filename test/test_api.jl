############################################################################
#
#  КАТЕГОРИЯ: API
#
#  Назначение: зафиксировать контракт каждой публичной функции — что она
#  принимает, что возвращает и что меняет. Тесты этой категории намеренно
#  мелкие и независимые: одна функция — одно утверждение о поведении.
#  Сценарии, ошибки и краевые случаи вынесены в отдельные категории.
#
#  Покрывает: PortSpec, NodeSpec, NodeProperties, NodeState, LogMsg,
#  ExecuteSettings, DataNode, Workflow, весь слой доступа к портам,
#  данным, буферам, топологии, настройкам и состоянию.
#
############################################################################

@testset "API                                              " begin

# --------------------------------------------------------------------------
@testset "порты: PortSpec и арность                        " begin
    # PortSpec хранит четыре поля и параметризуется типом арности.
    p = PortSpec("Value", Int, :val)
    @test p isa PortSpec{SinglePort}
    @test p.name     == "Value"
    @test p.datatype === Int
    @test p.label    == :val
    @test p.required
    @test !ismultiport(p)

    m = PortSpec("Values", Int, :vals, MultiPort())
    @test m isa PortSpec{MultiPort}
    @test ismultiport(m)

    o = PortSpec("Hint", Int, :hint; required = false)
    @test o isa PortSpec{SinglePort}
    @test !o.required
end

# --------------------------------------------------------------------------
@testset "спецификация: NodeSpec и portmap                 " begin
    # Конструктор из четырёх аргументов задаёт список настроек явно.
    s = spec_add()
    @test s.name == "Add"
    @test length(s.input_ports)  == 2
    @test length(s.output_ports) == 1
    @test s.settings == Symbol[]

    # portmap строится автоматически: (направление, метка) -> индекс порта
    @test s.portmap[(:input, :a)]   == 1
    @test s.portmap[(:input, :b)]   == 2
    @test s.portmap[(:output, :out)] == 1
    @test length(s.portmap) == 3

    # Конструктор из трёх аргументов даёт пустой список настроек.
    s3 = NodeSpec("NoSettings", PortSpec[], [PortSpec("v", Int, :v)])
    @test s3.settings == Symbol[]
    @test length(s3.portmap) == 1

    @test spec_const().settings == [:value]
end

# --------------------------------------------------------------------------
@testset "порты: интроспекция ноды                        " begin
    node = DataNode(AddNode, spec_add())

    @test haveinputs(node)
    @test !haveinputs(DataNode(ConstNode, spec_const()))

    @test getportnumber(node, :a, :input)    == 1
    @test getportnumber(node, :b, :input)    == 2
    @test getportnumber(node, :out, :output) == 1

    # Тип порта доступен и по индексу, и по метке.
    @test getporttype(node, 1, :input)     === Int
    @test getporttype(node, :b, :input)    === Int
    @test getporttype(node, :out, :output) === Int

    ps = getportspec(node, :a, :input)
    @test ps isa PortSpec{SinglePort}
    @test ps.label == :a
    @test getportspec(node, :out, :output).label == :out

    # Направление по умолчанию — :any.
    @test isportexist(node, :a)
    @test isportexist(node, :a, :input)
    @test !isportexist(node, :a, :output)
    @test isportexist(node, :out, :output)
    @test isportexist(node, :out)
    @test !isportexist(node, :nope)

    # isportinspec работает со спецификацией напрямую.
    spec = spec_add()
    @test isportinspec(:a, spec, :input)
    @test !isportinspec(:a, spec, :output)
    @test isportinspec(:out, spec, :both)
    @test isportinspec(:a, spec, :both)
    @test !isportinspec(:nope, spec, :both)
end

# --------------------------------------------------------------------------
@testset "нода: свойства и идентификация                  " begin
    node = DataNode(ConstNode, spec_const())

    @test getid(node)       == 0
    @test getposition(node) == (0, 0)
    @test getstatus(node)   == :idle
    @test occursin("ConstNode", nodetypestr(node))

    # Все сеттеры мутируют ноду на месте и возвращают её саму.
    @test setid!(node, 7)            === node
    @test setposition!(node, (1, 2)) === node
    @test setstatus!(node, :dirty)   === node
    @test getid(node)       == 7
    @test getposition(node) == (1, 2)
    @test getstatus(node)   == :dirty

    np = NodeProperties()
    @test (np.id, np.status, np.position) == (0, :idle, (0, 0))
    np2 = NodeProperties(5, :clean, (3, 4))
    @test (np2.id, np2.status, np2.position) == (5, :clean, (3, 4))
end

# --------------------------------------------------------------------------
@testset "нода: состояние исполнения                      " begin
    st = NodeState()
    @test st.exec_n == 0
    @test isempty(st.ready_ports)
    @test st.execution_id == 0
    @test isempty(st.log)

    # AbstractNodeFields даёт словарный доступ по именам полей.
    @test keys(st) == (:exec_n, :ready_ports, :execution_id, :log)
    @test st[:exec_n] == 0
    st[:exec_n] = 3
    @test st[:exec_n] == 3
    push!(st[:ready_ports], :x)

    # empty! возвращает состояние к исходному виду.
    empty!(st)
    @test st[:exec_n] == 0
    @test isempty(st[:ready_ports])
    @test st[:execution_id] == 0
    @test isempty(st[:log])

    node = DataNode(ConstNode, spec_const())
    @test getstate(node, :execution_id) == 0
    @test setstate!(node, :execution_id, UInt64(5)) === node
    @test getstate(node, :execution_id) == UInt64(5)

    # setreadyports! переиспользует существующий вектор.
    @test setreadyports!(node, [:a, :b]) === node
    @test getstate(node, :ready_ports) == [:a, :b]
    setreadyports!(node, Symbol[])
    @test isempty(getstate(node, :ready_ports))

    # На immutable-подтипе чтение работает, запись запрещена.
    fs = FrozenState(1)
    @test fs[:value] == 1
    @test keys(fs)   == (:value,)
end

# --------------------------------------------------------------------------
@testset "журнал: LogMsg                                   " begin
    lm = LogMsg(:info, "hello")
    @test lm.level     == :info
    @test lm.message   == "hello"
    @test lm.timestamp isa DateTime
    @test lm.id isa UInt64

    lm2 = LogMsg(UInt64(7), lm.timestamp, :error, "bad")
    @test lm2.id      == UInt64(7)
    @test lm2.level   == :error
    @test lm2.message == "bad"
end

# --------------------------------------------------------------------------
@testset "ExecuteSettings: три конструктора               " begin
    s1 = ExecuteSettings()                          # всё включено
    @test s1.execute_upstream && s1.invalidate_downstream
    @test s1.check_cyclic && s1.check_input_buffer

    s2 = ExecuteSettings(false)                     # всё выключено одним флагом
    @test !s2.execute_upstream && !s2.invalidate_downstream
    @test !s2.check_cyclic && !s2.check_input_buffer
    @test ExecuteSettings(true).check_cyclic

    s3 = ExecuteSettings(true, false, true, false)  # позиционная форма
    @test s3.execute_upstream && !s3.invalidate_downstream
    @test s3.check_cyclic && !s3.check_input_buffer

    s4 = ExecuteSettings(; check_cyclic = false)    # именованная форма
    @test !s4.check_cyclic
    @test s4.execute_upstream && s4.invalidate_downstream && s4.check_input_buffer
end

# --------------------------------------------------------------------------
@testset "нода: конструкторы DataNode                     " begin
    # Короткая форма: свойства по умолчанию.
    n1 = DataNode(ConstNode, spec_const())
    @test getid(n1) == 0 && getstatus(n1) == :idle && getposition(n1) == (0, 0)
    @test isempty(n1.settings) && isempty(n1.data)
    @test n1.state isa NodeState

    # Форма с явными свойствами.
    n2 = DataNode(DoubleNode, 7, :dirty, (1, 2), spec_double())
    @test getid(n2) == 7 && getstatus(n2) == :dirty && getposition(n2) == (1, 2)

    # Конструктор заводит пустой буфер для каждого входного порта.
    @test haskey(n2.input_buffer, :in)
    @test isempty(n2.input_buffer[:in])
    @test isempty(n1.input_buffer)          # у источника входов нет

    # Буфер можно передать готовым.
    n3 = DataNode(DoubleNode, spec_double(); input_buffer = Dict(:in => Dict{Int, Any}(11 => 5)))
    @test getinputdata(n3, :in, 11) == 5

    # Начальные настройки и данные тоже задаются через kwargs.
    n4 = DataNode(ConstNode, spec_const();
                  settings = Dict{Symbol, Any}(:value => 9),
                  data     = Dict{Symbol, Any}(:out => 42))
    @test n4.settings[:value] == 9
    @test getdata(n4, :out)   == 42
end

# --------------------------------------------------------------------------
@testset "нода: выходные данные                           " begin
    n = DataNode(ConstNode, spec_const())

    # Объявленный, но незаполненный порт читается как nothing.
    @test getdata(n, :out) === nothing
    @test setdata!(n, :out, 42)
    @test getdata(n, :out)  == 42

    # Форма с workflow.
    w  = Workflow(0)
    id = add_node!(w, n)
    @test getdata(w, id, :out) == 42
end

# --------------------------------------------------------------------------
@testset "нода: входные буферы                            " begin
    # SinglePort: одно значение или nothing.
    n = DataNode(DoubleNode, spec_double())
    @test getinputdata(n, :in) === nothing
    @test setinputbuffer!(n, :in, 1, 10) === n
    @test getinputdata(n, :in)    == 10
    @test getinputdata(n, :in, 1) == 10
    @test getinputdata(n, :in, 99) === nothing    # такой связи нет

    # invalidate_buffer! удаляет запись конкретной связи.
    setinputbuffer!(n, :in, 2, 20)
    invalidate_buffer!(n, :in, 2)
    @test getinputdata(n, :in, 2) === nothing
    @test getinputdata(n, :in)    == 10

    # MultiPort: весь словарь {id связи => значение}.
    m = DataNode(CollectNode, spec_collect())
    setinputbuffer!(m, :ins, 1, 2)
    setinputbuffer!(m, :ins, 2, 3)
    buf = getinputdata(m, :ins)
    @test buf isa Dict
    @test length(buf) == 2
    @test sum(values(buf)) == 5
end

# --------------------------------------------------------------------------
@testset "workflow: создание и тип                        " begin
    w = Workflow(1)
    @test w isa Workflow{DAW}
    @test w.id     == 1
    @test w.name   == "Default"
    @test w.n_iter == 0 && w.c_iter == 0
    @test w.run_id == 0
    @test isempty(w.nodes) && isempty(w.connections)
    @test isempty(w.incoming) && isempty(w.outgoing)
    @test isempty(w.log) && isempty(w.audit_log)

    @test Workflow(0; type = :ABW) isa Workflow{ABW}

    w.name = "demo"
    @test w.name == "demo"
end

# --------------------------------------------------------------------------
@testset "workflow: ноды и связи                          " begin
    w   = Workflow(1)
    sid = add_node!(w, DataNode(ConstNode, spec_const()))
    a   = add_node!(w, DataNode(DoubleNode, spec_double()))
    b   = add_node!(w, DataNode(DoubleNode, spec_double()))
    @test (sid, a, b) == (1, 2, 3)
    @test w.n_iter == 3

    @test isnodeexist(w, sid)
    @test !isnodeexist(w, 99)
    @test getnode(w, a) isa DataNode
    @test getid(getnode(w, a)) == a

    # Обе формы add_connection! эквивалентны.
    c1 = add_connection!(w, sid, :out, a, :in)
    c2 = add_connection!(w, NodeConnection(sid, :out, b, :in))
    @test (c1, c2) == (1, 2)
    @test w.c_iter == 2

    con = getconnection(w, c1)
    @test con isa NodeConnection
    @test con.output_id   == sid
    @test con.output_port == :out
    @test con.input_id    == a
    @test con.input_port  == :in

    # Индексы incoming/outgoing поддерживаются автоматически.
    @test w.outgoing[sid] == [c1, c2]
    @test w.incoming[a]   == [c1]
    @test sort(find_connections(w, sid)) == [c1, c2]
    @test find_connections(w, a) == [c1]

    # Родители: (порт-приёмник, id родителя).
    @test get_parents(w, a) == [(:in, sid)]
    @test isempty(get_parents(w, sid))

    # Потомки: (порт-источник, id потомка, порт-приёмник).
    ch = get_children(w, sid)
    @test length(ch) == 2
    @test (:out, a, :in) in ch
    @test (:out, b, :in) in ch
    @test isempty(get_children(w, a))

    # Связи конкретного порта с фильтром по направлению.
    @test length(getportconnections(w, sid, :out; direction = :output)) == 2
    @test length(getportconnections(w, a, :in; direction = :input))     == 1
    @test length(getportconnections(w, a, :in))                          == 1   # :both
    @test isempty(getportconnections(w, sid, :out; direction = :input))

    # Удаление связи чистит оба индекса.
    @test delete_connection!(w, c2)
    @test !haskey(w.connections, c2)
    @test w.outgoing[sid] == [c1]
    @test isempty(w.incoming[b])

    # Удаление ноды снимает вместе с ней все её связи.
    @test delete_node!(w, a)
    @test !isnodeexist(w, a)
    @test !haskey(w.connections, c1)
    @test isempty(w.outgoing[sid])
    @test !haskey(w.incoming, a)
end

# --------------------------------------------------------------------------
@testset "workflow: граф для планировщика                 " begin
    w = Workflow(0)
    a = add_node!(w, DataNode(ConstNode, spec_const()))
    b = add_node!(w, DataNode(DoubleNode, spec_double()))
    add_connection!(w, a, :out, b, :in)

    g = makegraph(w)
    @test MetidaFlows.is_cyclic(g) == false
    @test collect(MetidaFlows.topological_sort(g)) == [a, b]
end

# --------------------------------------------------------------------------
@testset "настройки: setsettings! и unsafe-вариант         " begin
    w  = Workflow(0)
    n  = DataNode(ConstNode, spec_const())
    id = add_node!(w, n)

    # «Unsafe» пишет настройки без инвалидации графа.
    @test setsettings_unsafe!(n, Dict(:value => 1)) === n
    @test n.settings[:value] == 1
    @test getstatus(n) == :idle

    # Безопасная форма всегда инвалидирует ноду и потомков.
    setsettings!(w, id, Dict(:value => 2, :extra => "x"))
    @test n.settings[:value] == 2
    @test n.settings[:extra] == "x"
    @test getstatus(n) == :dirty

    # Настройки сливаются, а не заменяются целиком.
    setsettings!(w, id, Dict(:value => 3))
    @test n.settings[:value] == 3
    @test n.settings[:extra] == "x"
end

# --------------------------------------------------------------------------
@testset "валидация: хуки и агрегатор                     " begin
    w  = Workflow(0)
    n  = DataNode(ConstNode, spec_const())
    id = add_node!(w, n)

    # Реализации по умолчанию возвращают true, обе формы вызова эквивалентны.
    @test validate_node(n)
    @test validate_settings(n)
    @test validate_result(n)
    @test validate_node(w, id)
    @test validate_settings(w, id)
    @test validate_result(w, id)

    # Пользовательские специализации перекрывают умолчания.
    @test validate_node(DataNode(BadStructNode, spec_plain("B")))     == false
    @test validate_result(DataNode(BadResultNode, spec_plain("R")))   == false
    @test validate_settings(DataNode(NeedsCfgNode, spec_cfg()))       == false

    # execution_node_validation объединяет проверку буферов и validate_node.
    add = DataNode(AddNode, spec_add())
    @test execution_node_validation(add)        == false   # обязательные входы пусты
    @test execution_node_validation(add, false) == true    # проверка отключена
    setinputbuffer!(add, :a, 1, 1)
    setinputbuffer!(add, :b, 2, 2)
    @test execution_node_validation(add) == true

    # Необязательный вход не блокирует исполнение.
    @test execution_node_validation(DataNode(OptionalNode, spec_optional())) == true
end

# --------------------------------------------------------------------------
@testset "готовность и проброс буферов                    " begin
    lin = build_linear(4)
    w, src, dbl, con = lin.w, lin.src, lin.dbl, lin.con
    srcnode, dblnode = getnode(w, src), getnode(w, dbl)

    @test isready(w, src)        # нет родителей -> готова всегда
    @test !isready(w, dbl)       # родитель ещё :dirty

    # push_buffer! на ноде без исходящих связей — пустая операция.
    @test push_buffer!(w, dbl) === w

    execute!(w, src; settings = ExecuteSettings(false))
    @test isready(w, dbl)
    @test getinputdata(dblnode, :in, con) == 4

    # Форма без списка портов берёт state[:ready_ports].
    setdata!(srcnode, :out, 5)
    @test push_buffer!(w, src) === w
    @test getinputdata(dblnode, :in, con) == 5

    # Явные формы: один порт и вектор портов.
    setdata!(srcnode, :out, 6)
    push_buffer!(w, src, :out)
    @test getinputdata(dblnode, :in, con) == 6
    setdata!(srcnode, :out, 7)
    push_buffer!(w, src, [:out])
    @test getinputdata(dblnode, :in, con) == 7

    # Порт не в списке готовых — буфер не трогаем.
    setdata!(srcnode, :out, 8)
    push_buffer!(w, src, Symbol[])
    @test getinputdata(dblnode, :in, con) == 7
end

# --------------------------------------------------------------------------
@testset "сброс: три уровня                               " begin
    lin = build_linear(10)
    w, src, dbl = lin.w, lin.src, lin.dbl
    srcnode, dblnode = getnode(w, src), getnode(w, dbl)
    execute!(w, dbl)
    @test getstatus(srcnode) == :clean && getstatus(dblnode) == :clean

    # reset_status! — только статусы.
    reset_status!(w)
    @test getstatus(srcnode) == :dirty
    @test getdata(srcnode, :out) == 10

    # mark_dirty! — статус, ready_ports и кеш выходов; настройки остаются.
    setstatus!(srcnode, :clean)
    @test mark_dirty!(srcnode) === srcnode
    @test getstatus(srcnode) == :dirty
    @test getdata(srcnode, :out) === nothing
    @test isempty(getstate(srcnode, :ready_ports))
    @test srcnode.settings[:value] == 10

    # reset!(::Workflow) — mark_dirty! для каждой ноды.
    execute!(w, dbl)
    @test reset!(w) === w
    @test getstatus(srcnode) == :dirty && getstatus(dblnode) == :dirty
    @test getdata(dblnode, :out) === nothing
    @test srcnode.settings[:value] == 10

    # reset!(::AbstractDataNode) — полный сброс до :idle.
    setinputbuffer!(dblnode, :in, 1, 5)
    setstate!(dblnode, :execution_id, UInt64(123))
    @test reset!(dblnode) === dblnode
    @test getstatus(dblnode) == :idle
    @test isempty(dblnode.settings)
    @test isempty(dblnode.data)
    @test getstate(dblnode, :execution_id) == 0
    @test haskey(dblnode.input_buffer, :in)     # ключи портов сохраняются,
    @test isempty(dblnode.input_buffer[:in])    # очищается только содержимое
end

# --------------------------------------------------------------------------
@testset "инвалидация вниз по графу                       " begin
    lin = build_linear(3)
    w, src, dbl, con = lin.w, lin.src, lin.dbl, lin.con
    execute!(w, dbl)

    # Явный вызов повторяет то, что делает setsettings!.
    invalidate_downstream!(w, src)
    @test getstatus(getnode(w, src)) == :dirty
    @test getstatus(getnode(w, dbl)) == :dirty
    @test isempty(getnode(w, dbl).input_buffer[:in])
end

# --------------------------------------------------------------------------
@testset "execute!: контракт вызова                       " begin
    lin = build_linear(21)
    w, src, dbl = lin.w, lin.src, lin.dbl

    # Возвращается вектор фактически заполненных выходных портов.
    rp = execute!(w, dbl)
    @test rp isa Vector{Symbol}
    @test rp == [:out]
    @test getdata(w, dbl, :out) == 42

    # Нода отдаёт только те порты, которые действительно заполнила.
    w2  = Workflow(0)
    pid = add_node!(w2, DataNode(PartialOutNode, spec_partial()))
    @test execute!(w2, pid) == [:first]
    @test getdata(w2, pid, :first)  == 1
    @test getdata(w2, pid, :second) === nothing
end

# --------------------------------------------------------------------------
@testset "scheduler!: контракт вызова                     " begin
    # Оба планировщика возвращают true и принимают throw_error.
    @test scheduler!(build_linear(2).w) === true
    @test scheduler!(build_linear(2).w; throw_error = true) === true

    abw = build_linear(2; type = :ABW)
    @test scheduler!(abw.w) === true
    @test scheduler!(abw.w; maxiter = 100) === true
    @test scheduler!(abw.w; maxiter = 100, throw_error = true) === true

    # После прогона всем нодам присвоен идентификатор запуска.
    lin = build_linear(5)
    scheduler!(lin.w)
    @test lin.w.run_id != 0
    @test getstate(getnode(lin.w, lin.src), :execution_id) == lin.w.run_id
end

end # @testset "API"
