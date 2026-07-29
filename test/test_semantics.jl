############################################################################
#
#  КАТЕГОРИЯ: СЕМАНТИКА ИСПОЛНЕНИЯ
#
#  Назначение: зафиксировать модель состояний движка — то, что нельзя
#  проверить ни одним отдельным вызовом API, но от чего зависит
#  корректность любого конвейера:
#
#    * когда нода считается устаревшей и что при этом теряет;
#    * как инвалидация распространяется вниз по графу;
#    * что кешируется и что переиспользуется;
#    * как флаги ExecuteSettings меняют ход исполнения;
#    * как идентификатор прогона (run_id) разделяет запуски.
#
#  Эти тесты намеренно проверяют побочные эффекты, а не результат
#  вычисления: результат проверяется в категории «Сценарии».
#
############################################################################

@testset "СЕМАНТИКА ИСПОЛНЕНИЯ                             " begin

# --------------------------------------------------------------------------
@testset "M1. переходы статусов                            " begin
    # :idle -> :dirty -> :clean — полный жизненный цикл ноды.
    w   = Workflow(0)
    src = DataNode(ConstNode, spec_const())
    dbl = DataNode(DoubleNode, spec_double())
    sid = add_node!(w, src)
    did = add_node!(w, dbl)
    @test getstatus(src) == :idle && getstatus(dbl) == :idle

    # Подключение потомка сразу метит его как требующий пересчёта.
    add_connection!(w, sid, :out, did, :in)
    @test getstatus(src) == :idle
    @test getstatus(dbl) == :dirty

    # Настройка метит саму ноду и всё, что ниже.
    setsettings!(w, sid, Dict(:value => 21))
    @test getstatus(src) == :dirty

    execute!(w, did)
    @test getstatus(src) == :clean && getstatus(dbl) == :clean
end

# --------------------------------------------------------------------------
@testset "M2. кеширование :clean-нод                       " begin
    resetcalls!()
    lin = build_linear(21)
    w, src, dbl = lin.w, lin.src, lin.dbl

    @test execute!(w, dbl) == [:out]
    @test getdata(w, dbl, :out) == 42
    @test (calls(:const), calls(:double)) == (1, 1)

    # Повторные вызовы не пересчитывают ничего — ни снизу, ни сверху.
    @test execute!(w, dbl) == [:out]
    @test execute!(w, src) == [:out]
    @test (calls(:const), calls(:double)) == (1, 1)

    # Для :clean-ноды возвращается сам вектор ready_ports, а не копия:
    # результат нельзя мутировать.
    @test execute!(w, dbl) === getstate(getnode(w, dbl), :ready_ports)
    # Для только что посчитанной ноды возвращается копия.
    mark_dirty!(getnode(w, dbl))
    @test execute!(w, dbl) !== getstate(getnode(w, dbl), :ready_ports)
end

# --------------------------------------------------------------------------
@testset "M3. что теряет нода при инвалидации              " begin
    lin = build_linear(10)
    w, src, dbl, con = lin.w, lin.src, lin.dbl, lin.con
    srcnode, dblnode = getnode(w, src), getnode(w, dbl)
    execute!(w, dbl)

    # Инвалидация источника: сам он теряет кеш выходов, потомок —
    # ещё и запись буфера, относящуюся к этой связи.
    setsettings!(w, src, Dict(:value => 50))
    @test getstatus(srcnode) == :dirty && getstatus(dblnode) == :dirty
    @test getdata(srcnode, :out) === nothing
    @test getdata(dblnode, :out) === nothing
    @test isempty(getstate(srcnode, :ready_ports))
    @test isempty(dblnode.input_buffer[:in])

    # Настройки и структура буферов при этом сохраняются.
    @test srcnode.settings[:value] == 50
    @test haskey(dblnode.input_buffer, :in)

    execute!(w, dbl)
    @test getdata(w, dbl, :out) == 100
end

# --------------------------------------------------------------------------
@testset "M4. инвалидация не идёт глубже :dirty-ноды       " begin
    # Обход прекращается на ноде, которая уже помечена: считается, что её
    # поддерево инвалидировано более ранним вызовом. Это делает повторные
    # вызовы дешёвыми и идемпотентными.
    w = Workflow(0)
    a = add_node!(w, DataNode(ConstNode, spec_const()))
    b = add_node!(w, DataNode(DoubleNode, spec_double()))
    c = add_node!(w, DataNode(DoubleNode, spec_double()))
    cb = add_connection!(w, a, :out, b, :in)
    cc = add_connection!(w, b, :out, c, :in)
    setsettings!(w, a, Dict(:value => 2))
    scheduler!(w)
    @test getdata(w, c, :out) == 8

    bn, cn = getnode(w, b), getnode(w, c)
    setsettings!(w, a, Dict(:value => 3))          # цепочка целиком :dirty
    @test getstatus(bn) == :dirty && getstatus(cn) == :dirty
    @test isempty(bn.input_buffer[:in])
    @test isempty(cn.input_buffer[:in])

    # Повторный вызов на уже :dirty-ноде ничего не меняет.
    setinputbuffer!(cn, :in, cc, 999)
    invalidate_downstream!(w, b)                   # b уже :dirty -> выход сразу
    @test getinputdata(cn, :in, cc) == 999
end

# --------------------------------------------------------------------------
@testset "M5. правило сброса в add_node!                   " begin
    w = Workflow(0)

    # :idle — не сбрасывается, настройки переживают добавление.
    fresh = DataNode(ConstNode, spec_const())
    setsettings_unsafe!(fresh, Dict(:value => 11))
    add_node!(w, fresh)
    @test getstatus(fresh) == :idle
    @test fresh.settings[:value] == 11

    # :clean — не сбрасывается, результат переживает переподключение.
    computed = DataNode(ConstNode, spec_const())
    cid = add_node!(w, computed)
    setsettings!(w, cid, Dict(:value => 4))
    execute!(w, cid)
    @test getstatus(computed) == :clean
    delete_node!(w, cid)
    newid = add_node!(w, computed)
    @test newid == 3                                # идентификаторы не переиспользуются
    @test getstatus(computed) == :clean
    @test getdata(computed, :out) == 4

    # Любой другой статус — полный сброс.
    stale = DataNode(ConstNode, spec_const())
    setsettings_unsafe!(stale, Dict(:value => 99))
    setstatus!(stale, :dirty)
    add_node!(w, stale)
    @test getstatus(stale) == :idle
    @test isempty(stale.settings)
end

# --------------------------------------------------------------------------
@testset "M6. проброс данных при создании связи            " begin
    # Если родитель уже посчитан, новая связь сразу получает его данные —
    # потомок готов к исполнению без повторного счёта родителя.
    resetcalls!()
    w   = Workflow(0)
    sid = add_node!(w, DataNode(ConstNode, spec_const()))
    setsettings!(w, sid, Dict(:value => 7))
    execute!(w, sid)
    @test getstatus(getnode(w, sid)) == :clean

    did = add_node!(w, DataNode(DoubleNode, spec_double()))
    con = add_connection!(w, sid, :out, did, :in)
    @test getinputdata(getnode(w, did), :in, con) == 7
    @test getstatus(getnode(w, did)) == :dirty

    execute!(w, did)
    @test getdata(w, did, :out) == 14
    @test calls(:const) == 1                       # родитель не пересчитывался

    # Удаление связи убирает ровно её запись из буфера потомка.
    delete_connection!(w, con)
    @test isempty(getnode(w, did).input_buffer[:in])
    @test isnodeexist(w, did)                      # сама нода остаётся
end

# --------------------------------------------------------------------------
@testset "M7. флаги ExecuteSettings по одному              " begin
    # execute_upstream = false: родителя никто не подтянет.
    lin = build_linear(2)
    w, src, dbl = lin.w, lin.src, lin.dbl
    @test execute!(w, dbl; settings = ExecuteSettings(; execute_upstream = false)) == Symbol[]
    @test getstatus(getnode(w, dbl)) == :invalid_node
    @test getstatus(getnode(w, src)) == :dirty
    @test execute!(w, dbl) == [:out]               # с подтягиванием — проходит
    @test getdata(w, dbl, :out) == 4

    # invalidate_downstream = false: потомок не будет помечен после
    # пересчёта родителя, хотя данные в его буфер уже проброшены.
    lin2 = build_linear(3)
    w2, src2, dbl2, con2 = lin2.w, lin2.src, lin2.dbl, lin2.con
    execute!(w2, dbl2)
    setstatus!(getnode(w2, src2), :dirty)
    execute!(w2, src2; settings = ExecuteSettings(false))
    @test getstatus(getnode(w2, src2)) == :clean
    @test getstatus(getnode(w2, dbl2)) == :clean   # остался «чистым»
    @test getinputdata(getnode(w2, dbl2), :in, con2) == 3

    # check_input_buffer = false: обязательный вход не проверяется.
    w3  = Workflow(0)
    id3 = add_node!(w3, DataNode(AddNode, spec_add()))
    @test execute!(w3, id3) == Symbol[]
    @test execute!(w3, id3; settings = ExecuteSettings(; check_input_buffer = false)) == [:out]
    @test getdata(w3, id3, :out) == 0
end

# --------------------------------------------------------------------------
@testset "M8. run_id разделяет прогоны                     " begin
    lin = build_linear(1)
    w   = lin.w
    node = getnode(w, lin.src)
    @test w.run_id == 0
    @test getstate(node, :execution_id) == 0

    scheduler!(w)
    first_run = w.run_id
    @test first_run != 0
    @test getstate(node, :execution_id) == first_run

    scheduler!(w)
    @test w.run_id != first_run
    @test getstate(node, :execution_id) == w.run_id
end

# --------------------------------------------------------------------------
@testset "M9. разница между планировщиками                 " begin
    # Оба планировщика по умолчанию делают полный сброс (reset_mode = :full):
    # кеш выходов очищается и граф считается заново. Режимы :soft и :none
    # проверяются в категории cycles (L7).
    resetcalls!()
    daw = build_linear(5)
    scheduler!(daw.w)
    scheduler!(daw.w)
    @test calls(:const) == 2                       # оба прогона пересчитали источник

    resetcalls!()
    abw = build_linear(5; type = :ABW)
    scheduler!(abw.w)
    scheduler!(abw.w)
    @test calls(:const) == 2
    @test getdata(abw.w, abw.dbl, :out) == 10
end

# --------------------------------------------------------------------------
@testset "M10. мультипорт при инкрементальном пересчёте    " begin
    # Каждый родитель отвечает только за свою запись в буфере, поэтому
    # пересчёт одного из них не портит вклад остальных.
    resetcalls!()
    w   = Workflow(0)
    m   = DataNode(CollectNode, spec_collect())
    mid = add_node!(w, m)
    s1  = add_node!(w, DataNode(ConstNode, spec_const()))
    s2  = add_node!(w, DataNode(ConstNode, spec_const()))
    add_connection!(w, s1, :out, mid, :ins)
    add_connection!(w, s2, :out, mid, :ins)
    setsettings!(w, s1, Dict(:value => 5))
    setsettings!(w, s2, Dict(:value => 7))

    execute!(w, mid)
    @test getdata(w, mid, :out) == 12
    @test calls(:const) == 2

    # Меняем только один источник.
    setsettings!(w, s1, Dict(:value => 50))
    @test getstatus(getnode(w, s2)) == :clean
    execute!(w, mid)
    @test getdata(w, mid, :out) == 57
    @test calls(:const) == 3                       # второй источник не пересчитан
    @test length(getinputdata(m, :ins)) == 2
end

end # @testset "СЕМАНТИКА ИСПОЛНЕНИЯ"
