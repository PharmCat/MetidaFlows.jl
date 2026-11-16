############################################################################
#
#  КАТЕГОРИЯ: ВОССТАНОВЛЕНИЕ ГРАФА ПО ЧАСТЯМ
#
#  Запрос, ради которого это сделано, пришёл от сервера-редактора: он держит
#  граф живым и хочет применять к нему РАЗНИЦУ между двумя сохранёнными
#  версиями, а не собирать всё заново. Заново — значит перенумеровать узлы,
#  потерять посчитанное у тех, кого никто не трогал, и начать журнал правок с
#  чистого листа.
#
#  Для этого нужны ровно три вещи, и все три обязаны жить в пакете: снаружи
#  их не сделать, потому что `audit!`, `setid!` и `invalidate_downstream!` не
#  экспортированы, а прямая запись в `model.nodes` оставляет `ver` и кеш
#  графа недостоверными.
#
#    1. вставка узла с заданным id,
#    2. вставка связи с заданным id (она же задаёт порядок на MultiPort),
#    3. замена настроек целиком, со снятием ключей.
#
#  А вот сам диф — политика приложения, а не механика движка: что считать
#  «тем же узлом», что делать с посчитанным при смене настроек, в каком
#  порядке применять. Поэтому `restore!` в пакете нет и не планируется.
#
#  Отдельно закреплено то, о чём в запросе просили зря: `setsettings!` НЕ
#  поднимает `model.ver`. Версия — про структуру графа, на ней висят четыре
#  кешированных значения; поднимать её на правке настроек значит выбрасывать
#  топологическую сортировку впустую.
#
############################################################################

import MetidaFlows: NodeAdded, ConnectionAdded, SettingsChanged, SETTINGS,
                    AbstractNodeSettings, pickid, replacesettings_unsafe!,
                    audit_event_to_dict, dict_to_audit_event

#  Таблица настроек общая на процесс: что бы ни случилось внутри, вернуть.
function withaudit(f)
    saved = SETTINGS[:audit]
    try
        SETTINGS[:audit] = true
        f()
    finally
        SETTINGS[:audit] = saved
    end
end

struct RConst  <: AbstractNodeType end   # settings[:value] -> :out
struct RSum    <: AbstractNodeType end   # MultiPort :ins -> :out, по порядку
struct RTyped  <: AbstractNodeType end   # настройки структурой, не Dict

mutable struct RSettings <: AbstractNodeSettings
    factor::Int
    label::Symbol
    RSettings() = new(1, :none)
    RSettings(f, l) = new(f, l)
end
MetidaFlows.nodesettings(::Type{RTyped}) = RSettings()

MetidaFlows.execute_unsafe!(n::DataNode{RConst}) =
    (setdata!(n, :out, Int(get(n.settings, :value, 0))); setreadyports!(n, :out))
#  Склеивает, а не суммирует: нужен ПОРЯДОК значений мультипорта.
MetidaFlows.execute_unsafe!(n::DataNode{RSum}) =
    (setdata!(n, :out, collect(getinputdata(n, :ins))); setreadyports!(n, :out))
MetidaFlows.execute_unsafe!(n::DataNode{RTyped}) =
    (setdata!(n, :out, n.settings[:factor]); setreadyports!(n, :out))

r_const() = NodeSpec("RConst", PortSpec[], [PortSpec("Out", Int, :out)], [:value])
r_sum()   = NodeSpec("RSum", [PortSpec("In", Int, :ins, MultiPort())],
                             [PortSpec("Out", Vector{Int}, :out)])
r_typed() = NodeSpec("RTyped", PortSpec[], [PortSpec("Out", Int, :out)], [:factor, :label])

@testset "ВОССТАНОВЛЕНИЕ ГРАФА ПО ЧАСТЯМ                   " begin

# --------------------------------------------------------------------------
@testset "R1. узел с заданным id                           " begin
    w = Workflow(1)
    @test add_node!(w, DataNode(RConst, r_const()); id = 7) == 7
    @test isnodeexist(w, 7)
    @test getid(getnode(w, 7)) == 7

    #  Занятый id — отказ, и граф после отказа не изменён.
    before = w.ver
    @test_throws ErrorException add_node!(w, DataNode(RConst, r_const()); id = 7)
    @test length(w.nodes) == 1
    @test w.ver == before

    #  Неположительный id — отказ. 0 это «следующий свободный», не ошибка.
    @test_throws ErrorException add_node!(w, DataNode(RConst, r_const()); id = -1)
    @test add_node!(w, DataNode(RConst, r_const()); id = 0) > 0
end

# --------------------------------------------------------------------------
@testset "R2. id из будущего не ломает автонумерацию       " begin
    #  Это и есть ловушка: счётчик надо поднять до явного id, иначе следующая
    #  автоматическая вставка попадёт в занятое место.
    w = Workflow(1)
    add_node!(w, DataNode(RConst, r_const()); id = 100)
    nxt = add_node!(w, DataNode(RConst, r_const()))
    @test nxt == 101
    @test length(w.nodes) == 2

    #  Вставка с МЕНЬШИМ id счётчик не опускает: id не переиспользуются.
    add_node!(w, DataNode(RConst, r_const()); id = 3)
    @test add_node!(w, DataNode(RConst, r_const())) == 102

    #  Сначала автоматические, потом явный ниже текущего счётчика — тоже цел.
    w2 = Workflow(1)
    a = add_node!(w2, DataNode(RConst, r_const()))
    b = add_node!(w2, DataNode(RConst, r_const()))
    @test (a, b) == (1, 2)
    add_node!(w2, DataNode(RConst, r_const()); id = 50)
    @test add_node!(w2, DataNode(RConst, r_const())) == 51

    #  То же правило на связях.
    @test pickid(5, Dict{Int, Int}(), 0, "X") == (6, 6)
    @test pickid(5, Dict{Int, Int}(), 9, "X") == (9, 9)
    @test pickid(5, Dict{Int, Int}(), 2, "X") == (2, 5)
end

# --------------------------------------------------------------------------
@testset "R3. связь с заданным id задаёт порядок мультипорта" begin
    w = Workflow(1)
    s = add_node!(w, DataNode(RSum, r_sum()))
    a = add_node!(w, DataNode(RConst, r_const())); setsettings!(w, a, Dict(:value => 1))
    b = add_node!(w, DataNode(RConst, r_const())); setsettings!(w, b, Dict(:value => 2))
    c = add_node!(w, DataNode(RConst, r_const())); setsettings!(w, c, Dict(:value => 3))

    #  Подключаем в одном порядке, а id назначаем в другом: значения на
    #  мультипорте идут по возрастанию id связи, а не по порядку вызовов.
    @test add_connection!(w, a, :out, s, :ins; id = 30) == 30
    @test add_connection!(w, b, :out, s, :ins; id = 10) == 10
    @test add_connection!(w, c, :out, s, :ins; id = 20) == 20
    scheduler!(w)
    @test getdata(w, s, :out) == [2, 3, 1]        # id 10, 20, 30

    #  Занятый id связи — отказ, индексы не тронуты.
    d = add_node!(w, DataNode(RConst, r_const()))
    @test_throws ErrorException add_connection!(w, d, :out, s, :ins; id = 10)
    @test length(w.connections) == 3
    @test length(w.incoming[s]) == 3

    #  Счётчик связей поднят до 30.
    @test add_connection!(w, d, :out, s, :ins) == 31
end

# --------------------------------------------------------------------------
@testset "R4. замена настроек снимает ключ (Dict)          " begin
    w = Workflow(1)
    n = add_node!(w, DataNode(RConst, r_const()))
    setsettings!(w, n, Dict(:value => 5, :extra => "x"))
    @test Set(keys(getnode(w, n).settings)) == Set([:value, :extra])

    #  Слияние ключ не снимает — так было и так остаётся по умолчанию.
    setsettings!(w, n, Dict(:value => 6))
    @test haskey(getnode(w, n).settings, :extra)
    @test getnode(w, n).settings[:value] == 6

    #  Замена снимает.
    setsettings!(w, n, Dict(:value => 7); replace = true)
    @test !haskey(getnode(w, n).settings, :extra)
    @test getnode(w, n).settings[:value] == 7

    #  Замена пустым словарём опустошает настройки целиком.
    setsettings!(w, n, Dict{Symbol, Any}(); replace = true)
    @test isempty(getnode(w, n).settings)

    #  И то и другое инвалидирует узел.
    scheduler!(w)
    @test getstatus(w, n) == :clean
    setsettings!(w, n, Dict(:value => 1); replace = true)
    @test getstatus(w, n) == :dirty
end

# --------------------------------------------------------------------------
@testset "R5. замена в типизированном контейнере           " begin
    #  У структуры нет «отсутствующего поля», поэтому снятие ключа значит
    #  возврат к значению из конструктора без аргументов — тем же правилом,
    #  что и `empty!`.
    w = Workflow(1)
    n = add_node!(w, DataNode(RTyped, r_typed()))
    setsettings!(w, n, Dict(:factor => 7, :label => :x))
    st = getnode(w, n).settings
    @test (st[:factor], st[:label]) == (7, :x)

    setsettings!(w, n, Dict(:factor => 9); replace = true)
    @test st[:factor] == 9
    @test st[:label] === :none              # свежее значение, не :x

    #  Ключи у структуры никуда не деваются: это поля.
    @test Set(keys(st)) == Set([:factor, :label])

    #  Та же механика напрямую, без модели.
    node = DataNode(RTyped, r_typed())
    replacesettings_unsafe!(node, Dict(:label => :z))
    @test node.settings[:label] === :z
    @test node.settings[:factor] == 1
end

# --------------------------------------------------------------------------
@testset "R6. журнал различает замену и слияние            " begin
    withaudit() do
        w = Workflow(1)
        n = add_node!(w, DataNode(RConst, r_const()); id = 4)
        setsettings!(w, n, Dict(:value => 1))
        setsettings!(w, n, Dict(:value => 2); replace = true)

        @test w.audit_log[1] == NodeAdded(4, "Main.RConst")
        @test w.audit_log[2] == SettingsChanged(4, [:value], false)
        @test w.audit_log[3] == SettingsChanged(4, [:value], true)
        #  Без замены две записи были бы неразличимы.
        @test w.audit_log[2] != w.audit_log[3]

        #  Круг через словарь сохраняет режим.
        for e in w.audit_log[2:3]
            @test dict_to_audit_event(audit_event_to_dict(e)) == e
        end
        @test audit_event_to_dict(w.audit_log[3])["replace"] === true

        #  Запись без ключа — слияние: так выглядит всё, что записано до
        #  появления поля.
        old = Dict{String, Any}("event" => "SettingsChanged", "id" => 4,
                                "keys" => ["value"])
        @test dict_to_audit_event(old) == SettingsChanged(4, [:value], false)

        #  Короткая форма конструктора — тоже слияние.
        @test SettingsChanged(4, [:value]).replace === false
    end
    @test SETTINGS[:audit] === false        # таблица возвращена
end

# --------------------------------------------------------------------------
@testset "R7. ver: структура поднимает, настройки нет      " begin
    w = Workflow(1)
    v0 = w.ver
    a = add_node!(w, DataNode(RConst, r_const()); id = 2)
    @test w.ver == v0 + 1
    b = add_node!(w, DataNode(RSum, r_sum()); id = 5)
    @test w.ver == v0 + 2
    add_connection!(w, a, :out, b, :ins; id = 8)
    @test w.ver == v0 + 3

    #  А вот настройки структуру не меняют.
    v = w.ver
    setsettings!(w, a, Dict(:value => 1))
    setsettings!(w, a, Dict(:value => 2); replace = true)
    @test w.ver == v

    delete_connection!(w, 8); @test w.ver == v + 1
    delete_node!(w, 5);       @test w.ver == v + 2
end

# --------------------------------------------------------------------------
@testset "R8. разница применяется к живому графу           " begin
    withaudit() do
        #  Версия 1: источник -> сумматор. Считаем.
        w = Workflow(1)
        src = add_node!(w, DataNode(RConst, r_const()); id = 11)
        dst = add_node!(w, DataNode(RSum,   r_sum());   id = 12)
        setsettings!(w, src, Dict(:value => 4))
        add_connection!(w, src, :out, dst, :ins; id = 21)
        scheduler!(w)
        @test getdata(w, dst, :out) == [4]
        @test getexecn(w, src) == 1
        marker = length(w.audit_log)

        #  Версия 2 отличается одним новым узлом и его связью. Применяем
        #  разницу теми же функциями, граф остаётся тем же объектом.
        two = add_node!(w, DataNode(RConst, r_const()); id = 13)
        setsettings!(w, two, Dict(:value => 9); replace = true)
        add_connection!(w, two, :out, dst, :ins; id = 22)

        #  Нетронутый узел сохранил посчитанное и остался :clean.
        @test getstatus(w, src) == :clean
        @test getdata(w, src, :out) == 4
        #  Потребитель — нет: у него появился новый вход.
        @test getstatus(w, dst) == :dirty

        scheduler!(w; reset_mode = :none)
        @test getdata(w, dst, :out) == [4, 9]
        @test getexecn(w, src) == 1           # источник так и не пересчитался

        #  Журнал непрерывен: прежние записи на месте, новые дописаны.
        @test length(w.audit_log) == marker + 3
        @test w.audit_log[1] == NodeAdded(11, "Main.RConst")
        @test w.audit_log[marker + 1] == NodeAdded(13, "Main.RConst")
        @test w.audit_log[marker + 2] == SettingsChanged(13, [:value], true)
        @test w.audit_log[marker + 3] == ConnectionAdded(22, 13, :out, 12, :ins)
    end
end

end # @testset "ВОССТАНОВЛЕНИЕ ГРАФА ПО ЧАСТЯМ"
