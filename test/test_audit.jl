############################################################################
#
#  КАТЕГОРИЯ: ЖУРНАЛЫ
#
#  Два журнала с одним и тем же контрактом: `audit_log` — правки графа,
#  `log` — сообщения движка. Оба переключаются целиком и ни один не
#  вытесняет записи: журнал с дырами отвечает на вопрос «это случилось?»
#  словом «может быть», и это хуже, чем отсутствие журнала.
#
#  Назначение: закрепить контракт `audit_log`. До 0.3.0 поле существовало,
#  конкретных подтипов `AbstractAuditEvent` не было ни одного, никто в поле
#  не писал, а в загрузчике снимка стояло `# w.audit_log # technical debt`.
#  Худшее из состояний: зарезервировано и пусто — заморозив такое в 1.0,
#  пакет обязуется это поддерживать.
#
#  Теперь пять событий, по одному на каждый мутатор, которому передают
#  `Workflow`. Это и граница: `setid!` и `setposition!` получают узел без
#  модели, поэтому перемещение узла в редакторе журнал не видит.
#
#  Обе настройки — в одной общей таблице `SETTINGS`, то есть на весь
#  процесс, а не на workflow. Значит любой тест, который их меняет, обязан
#  вернуть как было: иначе набор станет зависеть от порядка файлов. Для
#  этого здесь `withsettings`.
#
#  Запись правок ВЫКЛЮЧЕНА по умолчанию: журнал растёт всю жизнь workflow и
#  попадает в снимок (замерено: +27…29 % к размеру снимка), а скрипту,
#  собирающему сетку из сотен узлов, он не нужен.
#
############################################################################

import MetidaFlows: NodeAdded, NodeDeleted, ConnectionAdded, ConnectionDeleted,
                    SettingsChanged, AbstractAuditEvent, audit!,
                    audit_event_to_dict, dict_to_audit_event, AUDIT_EVENT_NAMES,
                    unregister_all!, SETTINGS, log!, LogMsg

#  Настройки общие на процесс, поэтому меняем их только так: что бы ни
#  случилось внутри, таблица возвращается в прежнее состояние.
function withsettings(f; kw...)
    saved = copy(SETTINGS)
    try
        for (k, v) in kw; SETTINGS[k] = v; end
        f()
    finally
        empty!(SETTINGS); merge!(SETTINGS, saved)
    end
end

# --------------------------------------------------------------------------
#  Фикстуры: двухвходовая клетка и источник
# --------------------------------------------------------------------------
struct AuSrc  <: AbstractNodeType end
struct AuCell <: AbstractNodeType end

sp_ausrc()  = NodeSpec("Au src", PortSpec[], [PortSpec("Out", Int, :out)], [:v])
sp_aucell() = NodeSpec("Au cell", [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
                                  [PortSpec("Out", Int, :out)], [:k])

MetidaFlows.execute_unsafe!(n::DataNode{AuSrc})  = (setdata!(n, :out, Int(n.settings[:v])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{AuCell}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])

struct AuFail <: AbstractNodeType end
sp_aufail() = NodeSpec("Au fail", [PortSpec("A", Int, :a)], [PortSpec("Out", Int, :out)])
MetidaFlows.execute_unsafe!(::DataNode{AuFail}) = error("по замыслу падаю")

#  Узел, который рассказывает о себе пользователю из собственного тела
struct AuTalk <: AbstractNodeType end
sp_autalk() = NodeSpec("Au talk", PortSpec[], [PortSpec("Out", Int, :out)], [:v])
function MetidaFlows.execute_unsafe!(n::DataNode{AuTalk})
    v = Int(n.settings[:v])
    MetidaFlows.log!(n, :info, "начал, v = $(v)")
    setdata!(n, :out, v * 2)
    MetidaFlows.log!(n, :info, "отдал $(v * 2)")
    return [:out]
end

#  Голова цикла, которая пишет на каждом витке
struct AuLoop <: AbstractNodeType end
struct AuSrc2 <: AbstractNodeType end
sp_auloop() = NodeSpec("Au loop",
    [PortSpec("Seed", Int, :seed),
     PortSpec("Back", Int, :back; kind = :feedback, required = false)],
    [PortSpec("Out", Int, :out), PortSpec("Done", Int, :done; kind = :terminal)], [:limit])
sp_ausrc2() = NodeSpec("Au src2", [PortSpec("A", Int, :a)], [PortSpec("Out", Int, :out)])
MetidaFlows.execute_unsafe!(n::DataNode{AuSrc2}) = (setdata!(n, :out, getinputdata(n, :a)); [:out])
function MetidaFlows.execute_unsafe!(n::DataNode{AuLoop})
    back = getinputdata(n, :back)
    i = isnothing(back) ? 1 : back + 1
    MetidaFlows.log!(n, :info, "виток $(i)")
    if i > n.settings[:limit]
        setdata!(n, :done, i); return [:done]
    end
    setdata!(n, :out, i); return [:out]
end

#  Состояние без поля log: писать некуда, и это должно быть сказано
mutable struct AuNoLog <: MetidaFlows.AbstractNodeState
    exec_n::Int
    ready_ports::Vector{Symbol}
    execution_id::UInt64
    stop::Bool
    AuNoLog() = new(0, Symbol[], 0, false)
end

#  Небольшой граф с правками всех пяти видов
function au_build()
    w = Workflow(0; type = :DAW)
    a = add_node!(w, DataNode(AuSrc,  sp_ausrc()))
    b = add_node!(w, DataNode(AuSrc,  sp_ausrc()))
    c = add_node!(w, DataNode(AuCell, sp_aucell()))
    setsettings!(w, a, Dict(:v => 2))
    setsettings!(w, b, Dict(:v => 3))
    ca = add_connection!(w, a, :out, c, :a)
    cb = add_connection!(w, b, :out, c, :b)
    (w = w, a = a, b = b, c = c, ca = ca, cb = cb)
end

############################################################################

@testset "ЖУРНАЛЫ                                          " begin

# --------------------------------------------------------------------------
@testset "A1. по умолчанию выключен                        " begin
    #  Главное: поведение без просьбы не изменилось.
    @test SETTINGS[:audit] === false
    g = au_build()
    @test isempty(g.w.audit_log)
    @test scheduler!(g.w)
    @test getdata(g.w, g.c, :out) == 5
    #  прогон графа — не правка
    @test isempty(g.w.audit_log)

    #  правки при выключенной записи не оставляют следов
    delete_connection!(g.w, g.ca)
    delete_node!(g.w, g.b)
    setsettings!(g.w, g.a, Dict(:v => 9))
    @test isempty(g.w.audit_log)

    #  включили — пишется дальше, что было раньше, того нет
    withsettings(audit = true) do
        setsettings!(g.w, g.a, Dict(:v => 10))
        @test length(g.w.audit_log) == 1
        @test g.w.audit_log[1] == SettingsChanged(g.a, [:v])
    end
    #  и настройка вернулась сама
    @test SETTINGS[:audit] === false
    setsettings!(g.w, g.a, Dict(:v => 11))
    @test length(g.w.audit_log) == 1
end

# --------------------------------------------------------------------------
@testset "A2. пять событий, по одному на мутатор           " begin
  withsettings(audit = true) do
    g = au_build()
    #  3 узла + 2 настройки + 2 связи
    @test length(g.w.audit_log) == 7
    @test g.w.audit_log[1] == NodeAdded(g.a, "Main.AuSrc")
    @test g.w.audit_log[2] == NodeAdded(g.b, "Main.AuSrc")
    @test g.w.audit_log[3] == NodeAdded(g.c, "Main.AuCell")
    @test g.w.audit_log[4] == SettingsChanged(g.a, [:v])
    @test g.w.audit_log[5] == SettingsChanged(g.b, [:v])
    @test g.w.audit_log[6] == ConnectionAdded(g.ca, g.a, :out, g.c, :a)
    @test g.w.audit_log[7] == ConnectionAdded(g.cb, g.b, :out, g.c, :b)

    #  тип узла записан СТРОКОЙ реестра, а не типом: запись едет в файл
    @test g.w.audit_log[1].type isa String
    @test g.w.audit_log[1].type == nodetypestr(getnode(g.w, g.a))

    #  удаление связи
    n = length(g.w.audit_log)
    delete_connection!(g.w, g.ca)
    @test g.w.audit_log[n + 1] == ConnectionDeleted(g.ca)
    #  удаление того, чего нет, ничего не пишет
    delete_connection!(g.w, 999)
    @test length(g.w.audit_log) == n + 1
    delete_node!(g.w, 999)
    @test length(g.w.audit_log) == n + 1
  end
end

# --------------------------------------------------------------------------
@testset "A3. каскад удаления узла виден сам               " begin
    #  delete_node! снимает связи через delete_connection!, поэтому каскад
    #  получается без особого события: сперва связи, потом узел.
  withsettings(audit = true) do
    g = au_build()
    n = length(g.w.audit_log)
    @test delete_node!(g.w, g.c)
    tail = g.w.audit_log[n + 1:end]
    @test length(tail) == 3
    @test Set(tail[1:2]) == Set([ConnectionDeleted(g.ca), ConnectionDeleted(g.cb)])
    @test tail[3] == NodeDeleted(g.c)       # узел ПОСЛЕ своих связей
    @test all(e -> e isa ConnectionDeleted, tail[1:2])
  end
end

# --------------------------------------------------------------------------
@testset "A4. порядок ключей настроек детерминирован       " begin
    #  Передают Dict, порядок обхода которого машинно-зависим. Журнал
    #  одинаковых правок обязан быть одинаковым, поэтому ключи сортируются.
  withsettings(audit = true) do
    w = Workflow(0; type = :DAW)
    id = add_node!(w, DataNode(AuCell, sp_aucell()))
    setsettings!(w, id, Dict(:k => 1))
    @test w.audit_log[end] == SettingsChanged(id, [:k])

    sp = NodeSpec("Many", PortSpec[], [PortSpec("O", Int, :o)],
                  [:zebra, :alpha, :middle, :beta])
    m = add_node!(w, DataNode(AuSrc, sp))
    setsettings!(w, m, Dict(:zebra => 1, :alpha => 2, :middle => 3, :beta => 4))
    @test w.audit_log[end].keys == [:alpha, :beta, :middle, :zebra]
    @test issorted(w.audit_log[end].keys)
  end
end

# --------------------------------------------------------------------------
@testset "A5. равенство и хеш структурные                  " begin
    #  Умолчание Julia для неизменяемой структуры сводится к `===`, а
    #  NodeAdded несёт String, SettingsChanged — Vector. Без своего `==`
    #  журнал нельзя было бы сравнить до и после круга.
    @test NodeAdded(1, "A") == NodeAdded(1, "A")
    @test NodeAdded(1, "A") != NodeAdded(1, "B")
    @test NodeAdded(1, "A") != NodeAdded(2, "A")
    @test SettingsChanged(1, [:a, :b]) == SettingsChanged(1, [:a, :b])
    @test SettingsChanged(1, [:a, :b]) != SettingsChanged(1, [:b, :a])
    #  разные типы с одинаковым полем не равны
    @test NodeDeleted(1) != ConnectionDeleted(1)
    #  хеш согласован с равенством, иначе события нельзя в Set
    @test hash(NodeAdded(1, "A")) == hash(NodeAdded(1, "A"))
    @test length(Set([NodeAdded(1, "A"), NodeAdded(1, "A")])) == 1
    @test length(Set([NodeDeleted(1), ConnectionDeleted(1)])) == 2
end

# --------------------------------------------------------------------------
@testset "A6. кодек: круг и закрытый набор имён            " begin
    events = AbstractAuditEvent[
        NodeAdded(1, "Main.AuSrc"), NodeDeleted(2),
        ConnectionAdded(3, 1, :out, 2, :a), ConnectionDeleted(4),
        SettingsChanged(5, [:a, :b])]

    for e in events
        d = audit_event_to_dict(e)
        @test d["event"] in AUDIT_EVENT_NAMES
        @test dict_to_audit_event(d) == e
    end
    @test length(AUDIT_EVENT_NAMES) == 5

    #  Ярлыки портов и ключи — простыми строками: журнал читают люди
    dc = audit_event_to_dict(ConnectionAdded(3, 1, :out, 2, :a))
    @test dc["output_port"] == "out"
    @test dc["input_port"]  == "a"
    @test audit_event_to_dict(SettingsChanged(5, [:a, :b]))["keys"] == ["a", "b"]

    #  но Symbol на входе тоже принимается, как и везде в загрузчике
    @test dict_to_audit_event(Dict{String, Any}("event" => "ConnectionAdded",
            "id" => 3, "output_id" => 1, "output_port" => :out,
            "input_id" => 2, "input_port" => :a)) == ConnectionAdded(3, 1, :out, 2, :a)

    #  НАБОР ЗАКРЫТ: имя из файла ни во что не разрешается
    @test_throws ErrorException dict_to_audit_event(
        Dict{String, Any}("event" => "DropDatabase", "id" => 1))
    err = try
        dict_to_audit_event(Dict{String, Any}("event" => "Base.run", "id" => 1))
    catch e; e; end
    @test err isa ErrorException
    @test occursin("Unknown audit event", err.msg)
    @test occursin("NodeAdded", err.msg)          # перечисляет известные
    @test_throws ErrorException dict_to_audit_event(Dict{String, Any}("id" => 1))
end

# --------------------------------------------------------------------------
@testset "A7. снимок: ключа нет, пока журнал пуст          " begin
    unregister_all!()
    gf = au_build()
    register_node!(gf.w)
    df = workflow_to_dict(gf.w; values = true, state = true)
    #  ГЛАВНОЕ: по умолчанию снимок такой же, каким был — ключа просто нет,
    #  и format_version поднимать не за что.
    @test !haskey(df, "audit_log")
    @test df["format_version"] == MetidaFlows.SNAPSHOT_FORMAT_VERSION

    wf2 = dict_to_workflow(df)
    @test isempty(wf2.audit_log)

    #  с журналом — ключ есть, круг поэлементно совпадает
    local dt, gt
    withsettings(audit = true) do
        gt = au_build()
        dt = workflow_to_dict(gt.w; values = true, state = true)
        @test haskey(dt, "audit_log")
        @test length(dt["audit_log"]) == length(gt.w.audit_log)
        wt2 = dict_to_workflow(dt)
        @test wt2.audit_log == gt.w.audit_log
        #  и правка после загрузки попадает в тот же журнал
        n = length(wt2.audit_log)
        setsettings!(wt2, gt.a, Dict(:v => 7))
        @test length(wt2.audit_log) == n + 1
        #  граф после круга считается, и притом с ПРАВКОЙ, сделанной выше:
        #  :v стал 7, значит 7 + 3, а не исходные 2 + 3
        @test scheduler!(wt2)
        @test getdata(wt2, gt.c, :out) == 10
    end

    #  Снимок с журналом НЕ включает запись: настройка принадлежит процессу,
    #  и файл не вправе её менять. Записи восстановлены, новых нет.
    wt3 = dict_to_workflow(dt)
    @test !isempty(wt3.audit_log)
    n3 = length(wt3.audit_log)
    setsettings!(wt3, gt.a, Dict(:v => 1))
    @test length(wt3.audit_log) == n3
    unregister_all!()
end

# --------------------------------------------------------------------------
@testset "A8. audit! — единственное место записи           " begin
    #  Проверка флага сидит в одном месте, поэтому мутатор пишет одной
    #  строкой, а выключенный журнал не стоит ничего, кроме ветки.
    w = Workflow(0; type = :DAW)
    @test audit!(w, NodeDeleted(1)) === w
    @test isempty(w.audit_log)
    withsettings(audit = true) do
        audit!(w, NodeDeleted(1))
        @test w.audit_log == [NodeDeleted(1)]
    end

    #  Граница журнала: setid!/setposition! получают узел без модели, значит
    #  записать им некуда — и это задокументированное свойство.
    node = getnode(w, add_node!(w, DataNode(AuSrc, sp_ausrc())))
    n = length(w.audit_log)
    MetidaFlows.setposition!(node, (5, 6))
    @test length(w.audit_log) == n
    @test getposition(node) == (5, 6)
end


# --------------------------------------------------------------------------
@testset "A9. выключатель лога                             " begin
    #  Утечка была здесь: `log` не чистил никто — ни `reset!`, ни прогон, —
    #  и падающий граф, который перезапускают, копил запись на узел на
    #  прогон. Замерено: 1000 прогонов → 1000 записей, 5 КБ → 134 КБ.
    function failing()
        w = Workflow(0; type = :DAW)
        a = add_node!(w, DataNode(AuSrc, sp_ausrc())); setsettings!(w, a, Dict(:v => 1))
        f = add_node!(w, DataNode(AuFail, sp_aufail()))
        add_connection!(w, a, :out, f, :a)
        (w = w, f = f)
    end

    #  По умолчанию журнал ведётся — так движок и работал
    @test SETTINGS[:logging] === true
    g = failing()
    scheduler!(g.w; throw_error = false)
    @test length([m for m in g.w.log if m.level === :error]) == 1

    #  и он НЕ чистится ни прогоном, ни reset!: это свойство, а не упущение
    n = length(g.w.log)
    reset!(g.w)
    @test length(g.w.log) == n
    scheduler!(g.w; throw_error = false)
    @test length(g.w.log) == n + 1

    #  Выключатель: записи не ведётся вовсе
    withsettings(logging = false) do
        go = failing()
        for _ in 1:20
            reset!(go.w); scheduler!(go.w; throw_error = false)
        end
        @test isempty(go.w.log)
        #  но граф работает как обычно, и отказ виден по статусу
        @test getstatus(getnode(go.w, go.f)) === :failed
        @test !isempty(failed_nodes(go.w))
    end
    @test SETTINGS[:logging] === true

    #  чистка — дело вызывающего, стандартным empty!
    w2 = Workflow(0; type = :DAW)
    log!(w2, LogMsg(:info, "раз"))
    @test length(w2.log) == 1
    empty!(w2.log)
    @test isempty(w2.log)

    #  испорченная настройка: ошибка называет ключ, а не падает TypeError
    withsettings(logging = "да") do
        err = try; log!(w2, LogMsg(:info, "x")); catch e; e; end
        @test err isa ErrorException
        @test occursin(":logging", err.msg)
        @test occursin("Bool", err.msg)
    end
    #  удалённый ключ — тоже внятно
    saved = copy(SETTINGS)
    try
        delete!(SETTINGS, :log_limit)
        err = try; log!(w2, LogMsg(:info, "x")); catch e; e; end
        @test err isa ErrorException
        @test occursin(":log_limit", err.msg)
    finally
        empty!(SETTINGS); merge!(SETTINGS, saved)
    end
end

# --------------------------------------------------------------------------
@testset "A10. логи ограничены, аудит — нет               " begin
    #  Политика разная, и это не недосмотр: лог отвечает «что происходило
    #  недавно», журнал правок — «что с графом случилось». Второй с дырами
    #  отвечал бы «может быть», поэтому его не вытесняют вовсе.
    @test SETTINGS[:log_limit] == 1000

    withsettings(audit = true) do
        w = Workflow(0; type = :DAW)
        id = add_node!(w, DataNode(AuSrc, sp_ausrc()))
        for i in 1:2500
            setsettings!(w, id, Dict(:v => i))
            log!(w, LogMsg(:info, "сообщение $(i)"))
        end

        #  ЛОГ: держит последние :log_limit, вытесняя с головы
        @test length(w.log) == 1000
        @test w.log[1].message   == "сообщение 1501"
        @test w.log[end].message == "сообщение 2500"

        #  АУДИТ: ничего не вытеснено, 1 NodeAdded + 2500 SettingsChanged
        @test length(w.audit_log) == 2501
        @test w.audit_log[1] == NodeAdded(id, "Main.AuSrc")
        @test w.audit_log[2] == SettingsChanged(id, [:v])
        @test w.audit_log[end] == SettingsChanged(id, [:v])

        #  понижение предела срезает сразу, а не по одному за запись
        SETTINGS[:log_limit] = 10
        log!(w, LogMsg(:info, "после понижения"))
        @test length(w.log) == 10
        @test w.log[end].message == "после понижения"
        @test w.log[1].message == "сообщение 2492"

        #  выключение не стирает уже записанное
        na = length(w.audit_log); nl = length(w.log)
        SETTINGS[:audit] = false; SETTINGS[:logging] = false
        setsettings!(w, id, Dict(:v => 0))
        log!(w, LogMsg(:info, "мимо"))
        @test length(w.audit_log) == na
        @test length(w.log) == nl
        @test w.audit_log[1] == NodeAdded(id, "Main.AuSrc")   # по-прежнему первая
    end

    #  ноль — без предела
    withsettings(log_limit = 0) do
        w2 = Workflow(0; type = :DAW)
        for i in 1:3000; log!(w2, LogMsg(:info, "$(i)")); end
        @test length(w2.log) == 3000
        @test w2.log[1].message == "1"
    end

    #  единственная точка записи у каждого, и обе возвращают модель
    w3 = Workflow(0; type = :DAW)
    @test audit!(w3, NodeDeleted(1)) === w3
    @test log!(w3, LogMsg(:info, "x")) === w3

    #  настройки вернулись после всех блоков
    @test SETTINGS[:log_limit] == 1000
    @test SETTINGS[:logging] === true
    @test SETTINGS[:audit] === false
end

# --------------------------------------------------------------------------
@testset "A11. лог узла: пишет сам узел                   " begin
    #  Это лог ДЛЯ ПОЛЬЗОВАТЕЛЯ, и пишет его тело узла: execute_unsafe!
    #  получает только узел, чего для этого и достаточно.
    w = Workflow(0; type = :DAW)
    id = add_node!(w, DataNode(AuTalk, sp_autalk()))
    setsettings!(w, id, Dict(:v => 3))
    node = getnode(w, id)
    @test isempty(getstate(node, :log))

    scheduler!(w)
    msgs = getstate(node, :log)
    @test length(msgs) == 2
    @test msgs[1].level === :info
    @test msgs[1].message == "начал, v = 3"
    @test msgs[2].message == "отдал 6"
    #  движок сюда не писал: его сообщения в model.log
    @test isempty(w.log)

    #  трёхаргументная форма — та же запись
    log!(node, :warn, "вручную")
    @test getstate(node, :log)[end].level === :warn
    @test log!(node, LogMsg(:info, "ещё")) === node

    #  Предел общий, из той же таблицы: поля на каждом узле нет, потому что
    #  это числовая политика, а не свойство узла.
    @test !haskey(node.state, :log_limit)
    withsettings(log_limit = 3) do
        for i in 1:10; log!(node, :info, "м$(i)"); end
        @test length(getstate(node, :log)) == 3
        @test getstate(node, :log)[end].message == "м10"
        @test getstate(node, :log)[1].message   == "м8"
    end

    #  чистится сбросом УЗЛА, но не сбросом модели
    reset!(w)
    @test !isempty(getstate(node, :log))
    reset!(node)
    @test isempty(getstate(node, :log))

    #  Логирование на каждом витке цикла не растёт без границы: предел
    #  держит последние сообщения.
    withsettings(log_limit = 20) do
        wc = Workflow(0; type = :ABW)
        s2 = add_node!(wc, DataNode(AuSrc, sp_ausrc())); setsettings!(wc, s2, Dict(:v => 0))
        h = add_node!(wc, DataNode(AuLoop, sp_auloop())); setsettings!(wc, h, Dict(:limit => 500))
        b = add_node!(wc, DataNode(AuSrc2, sp_ausrc2()))
        add_connection!(wc, s2, :out, h, :seed)
        add_connection!(wc, h, :out, b, :a)
        add_connection!(wc, b, :out, h, :back)
        @test scheduler!(wc; maxiter = 6000)
        hl = getstate(getnode(wc, h), :log)
        @test getstate(getnode(wc, h), :exec_n) > 100     # витков много
        @test length(hl) == 20                            # а записей ровно предел
        @test hl[end].message == "виток 501"
    end

    #  состояние без поля log писать нельзя, и об этом говорится внятно
    nd = DataNode(AuSrc, sp_ausrc(); state = AuNoLog())
    err = try; log!(nd, :info, "x"); catch e; e; end
    @test err isa ErrorException
    @test occursin("AuNoLog", err.msg)
    @test occursin("log", err.msg)
end


end # @testset "ЖУРНАЛЫ"
