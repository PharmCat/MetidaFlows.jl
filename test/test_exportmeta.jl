############################################################################
#
#  КАТЕГОРИЯ: МЕТАДАННЫЕ ПОРТОВ
#
#  Назначение: проверить распространение описаний портов — механизм,
#  который отвечает на вопрос «что появится на этом порту», НЕ исполняя
#  граф. Именно им нода настраивается по данным родителя: список колонок
#  CSV нужен до того, как файл прочитан.
#
#  Проверяется четыре вещи:
#    1) подъём по графу: описание доходит через транзитные ноды;
#    2) ismetasource обрывает подъём, и ветви выше не посещаются;
#    3) незнание распространяется как nothing, а не как ошибка;
#    4) обход завершается на любых графах, включая циклические.
#
#
############################################################################

# --------------------------------------------------------------------------
# Фикстуры
# --------------------------------------------------------------------------
import MetidaFlows: exportmeta_unsafe, exportmeta, getinputmeta

struct MetaSource <: AbstractNodeType end  # описание знает сам, входов нет
struct MetaThru   <: AbstractNodeType end  # прозрачная нода: проброс описания
struct MetaGate   <: AbstractNodeType end  # условный источник: зависит от настроек
struct MetaMute   <: AbstractNodeType end  # хук не реализован: разрыв цепочки
struct MetaJoin   <: AbstractNodeType end  # два входа одного типа

spec_metasource() = NodeSpec("Meta source", PortSpec[], [PortSpec("Out", Int, :out)])

spec_metathru()   = NodeSpec("Meta thru",
                             [PortSpec("Table", Int, :table)],
                             [PortSpec("Out",   Int, :out)],
                             [:schema])

spec_metajoin()   = NodeSpec("Meta join",
                             [PortSpec("Left",  Int, :input1),
                              PortSpec("Right", Int, :input2)],
                             [PortSpec("Out",   Int, :out)])

spec_metamulti()  = NodeSpec("Meta multi",
                             [PortSpec("Items", Int, :items, MultiPort())],
                             [PortSpec("Out",   Int, :out)])

# --- реализации хука ------------------------------------------------------

function MetidaFlows.exportmeta_unsafe(node::DataNode{MetaSource}, ::Symbol, inmeta)
    countcall!(:meta_source)
    return (columns = [:a, :b],)
end

function MetidaFlows.exportmeta_unsafe(node::DataNode{MetaThru}, ::Symbol, inmeta)
    countcall!(:meta_thru)
    return inmeta[:table]                      # проброс ЯВНЫЙ
end

# Условный источник: если схема задана настройкой — знаю сам, иначе спрашиваю выше.
MetidaFlows.ismetasource(node::DataNode{MetaGate}, ::Symbol) = haskey(node.settings, :schema)

function MetidaFlows.exportmeta_unsafe(node::DataNode{MetaGate}, ::Symbol, inmeta)
    countcall!(:meta_gate)
    isempty(inmeta) && countcall!(:meta_gate_empty_inmeta)
    haskey(node.settings, :schema) && return (columns = node.settings[:schema],)
    return inmeta[:table]
end

function MetidaFlows.exportmeta_unsafe(node::DataNode{MetaJoin}, ::Symbol, inmeta)
    countcall!(:meta_join)
    l, r = inmeta[:input1], inmeta[:input2]
    (l === nothing || r === nothing) && return nothing
    return (columns = vcat(l.columns, r.columns),)
end

############################################################################

@testset "МЕТАДАННЫЕ ПОРТОВ                                " begin

# --------------------------------------------------------------------------
@testset "P1. подъём по цепочке                            " begin
    # Описание рождается в источнике и проходит через транзитные ноды.
    # Потребитель видит его под меткой СВОЕГО входного порта.
    resetcalls!()
    w  = Workflow(0)
    s  = add_node!(w, DataNode(MetaSource, spec_metasource()))
    t1 = add_node!(w, DataNode(MetaThru,   spec_metathru()))
    t2 = add_node!(w, DataNode(MetaThru,   spec_metathru()))
    add_connection!(w, s,  :out, t1, :table)
    add_connection!(w, t1, :out, t2, :table)

    @test exportmeta(w, s,  :out) == (columns = [:a, :b],)
    @test exportmeta(w, t2, :out) == (columns = [:a, :b],)

    inmeta = getinputmeta(w, t2)
    @test collect(keys(inmeta)) == [:table]     # метка входа потребителя
    @test inmeta[:table] == (columns = [:a, :b],)

    # источник опрашивался на каждый запрос: результат нигде не кешируется
    resetcalls!()
    exportmeta(w, t2, :out)
    exportmeta(w, t2, :out)
    @test calls(:meta_source) == 2
    @test calls(:meta_thru)   == 4
end

# --------------------------------------------------------------------------
@testset "P2. ismetasource обрывает подъём                 " begin
    resetcalls!()
    w = Workflow(0)
    s = add_node!(w, DataNode(MetaSource, spec_metasource()))
    g = add_node!(w, DataNode(MetaGate,   spec_metathru()))
    t = add_node!(w, DataNode(MetaThru,   spec_metathru()))
    add_connection!(w, s, :out, g, :table)
    add_connection!(w, g, :out, t, :table)

    # По умолчанию нода источником не является.
    @test MetidaFlows.ismetasource(getnode(w, t), :out) == false
    @test MetidaFlows.ismetasource(getnode(w, g), :out) == false

    # Настройки не заданы: гейт закрыт, поднимаемся до самого источника.
    resetcalls!()
    @test exportmeta(w, t, :out) == (columns = [:a, :b],)
    @test calls(:meta_source) == 1
    @test calls(:meta_gate_empty_inmeta) == 0

    # Настройка задана: гейт объявляет себя источником описания.
    setsettings!(w, g, Dict(:schema => [:x, :y]))
    @test MetidaFlows.ismetasource(getnode(w, g), :out) == true

    resetcalls!()
    @test exportmeta(w, g, :out) == (columns = [:x, :y],)
    @test calls(:meta_source) == 0               # выше не поднимались
    @test calls(:meta_gate)   == 1
    @test calls(:meta_gate_empty_inmeta) == 1    # inmeta пришёл пустым

    # Запрос ниже по цепочке тоже останавливается на гейте.
    resetcalls!()
    @test exportmeta(w, t, :out) == (columns = [:x, :y],)
    @test calls(:meta_source) == 0
end

# --------------------------------------------------------------------------
@testset "P3. незнание распространяется как nothing        " begin
    # Неподключённый вход.
    w1 = Workflow(0)
    t1 = add_node!(w1, DataNode(MetaThru, spec_metathru()))
    @test getinputmeta(w1, t1) == Dict{Symbol, Any}(:table => nothing)
    @test exportmeta(w1, t1, :out) === nothing

    # Нода без реализации хука рвёт цепочку, но не роняет её.
    w2 = Workflow(0)
    s2 = add_node!(w2, DataNode(MetaSource, spec_metasource()))
    m2 = add_node!(w2, DataNode(MetaMute,   spec_metathru()))
    t2 = add_node!(w2, DataNode(MetaThru,   spec_metathru()))
    add_connection!(w2, s2, :out, m2, :table)
    add_connection!(w2, m2, :out, t2, :table)
    @test exportmeta(w2, m2, :out) === nothing
    @test exportmeta(w2, t2, :out) === nothing

    # Несуществующий выходной порт — ошибка, а не тихий nothing.
    @test_throws ErrorException exportmeta(w2, t2, :ghost)
end

# --------------------------------------------------------------------------
@testset "P4. два входа одного типа и мультипорт           " begin
    # Ключи приходят из связей, поэтому одинаковые типы не путаются.
    resetcalls!()
    w  = Workflow(0)
    s1 = add_node!(w, DataNode(MetaSource, spec_metasource()))
    s2 = add_node!(w, DataNode(MetaGate,   spec_metathru()))
    j  = add_node!(w, DataNode(MetaJoin,   spec_metajoin()))
    setsettings!(w, s2, Dict(:schema => [:z]))
    add_connection!(w, s1, :out, j, :input1)
    add_connection!(w, s2, :out, j, :input2)

    inmeta = getinputmeta(w, j)
    @test Set(keys(inmeta)) == Set([:input1, :input2])
    @test inmeta[:input1] == (columns = [:a, :b],)
    @test inmeta[:input2] == (columns = [:z],)
    @test exportmeta(w, j, :out) == (columns = [:a, :b, :z],)

    # Один вход не подключён -> nothing, но ключ на месте.
    w2 = Workflow(0)
    a2 = add_node!(w2, DataNode(MetaSource, spec_metasource()))
    j2 = add_node!(w2, DataNode(MetaJoin,   spec_metajoin()))
    add_connection!(w2, a2, :out, j2, :input1)
    im2 = getinputmeta(w2, j2)
    @test im2[:input1] == (columns = [:a, :b],)
    @test im2[:input2] === nothing
    @test exportmeta(w2, j2, :out) === nothing

    # MultiPort: словарь по id связей, как во входном буфере.
    w3 = Workflow(0)
    m3 = add_node!(w3, DataNode(MetaJoin, spec_metamulti()))
    @test getinputmeta(w3, m3) == Dict{Symbol, Any}(:items => Dict{Int, Any}())
    p1 = add_node!(w3, DataNode(MetaSource, spec_metasource()))
    p2 = add_node!(w3, DataNode(MetaSource, spec_metasource()))
    c1 = add_connection!(w3, p1, :out, m3, :items)
    c2 = add_connection!(w3, p2, :out, m3, :items)
    im3 = getinputmeta(w3, m3)[:items]
    @test length(im3) == 2
    @test im3[c1] == (columns = [:a, :b],)
    @test im3[c2] == (columns = [:a, :b],)
end

# --------------------------------------------------------------------------
@testset "P5. обход завершается на циклах                  " begin
    # Цикл из :normal-рёбер: обратное ребро распознаётся и даёт nothing,
    # а не бесконечную рекурсию.
    w1 = Workflow(0)
    a1 = add_node!(w1, DataNode(MetaThru, spec_metathru()))
    b1 = add_node!(w1, DataNode(MetaThru, spec_metathru()))
    add_connection!(w1, a1, :out, b1, :table)
    add_connection!(w1, b1, :out, a1, :table)
    @test exportmeta(w1, a1, :out) === nothing

    # Тот же цикл, но один из узлов объявил себя источником описания:
    # подъёма из него нет, поэтому ответ определён.
    w2 = Workflow(0)
    g2 = add_node!(w2, DataNode(MetaGate, spec_metathru()))
    t2 = add_node!(w2, DataNode(MetaThru, spec_metathru()))
    add_connection!(w2, g2, :out, t2, :table)
    add_connection!(w2, t2, :out, g2, :table)
    setsettings!(w2, g2, Dict(:schema => [:x]))
    @test exportmeta(w2, g2, :out) == (columns = [:x],)
    @test exportmeta(w2, t2, :out) == (columns = [:x],)

    # Обратное ребро ABW не обходится вообще.
    w3 = Workflow(0; type = :ABW)
    s3 = add_node!(w3, DataNode(MetaSource, spec_metasource()))
    l3 = add_node!(w3, DataNode(MetaThru,
        NodeSpec("Loop",
            [PortSpec("Table",    Int, :table),
             PortSpec("Previous", Int, :previous; kind = :feedback)],
            [PortSpec("Out", Int, :out)])))
    add_connection!(w3, s3, :out, l3, :table)
    add_connection!(w3, l3, :out, l3, :previous)
    im3 = getinputmeta(w3, l3)
    @test collect(keys(im3)) == [:table]         # :feedback в сборе не участвует
    @test exportmeta(w3, l3, :out) == (columns = [:a, :b],)
end

# --------------------------------------------------------------------------
@testset "P6. ромб считает общего предка один раз          " begin
    #        s
    #       / \
    #     t1   t2
    #       \ /
    #        j
    # Мемоизация живёт один вызов: без неё источник опрашивался бы дважды.
    w  = Workflow(0)
    s  = add_node!(w, DataNode(MetaSource, spec_metasource()))
    t1 = add_node!(w, DataNode(MetaThru,   spec_metathru()))
    t2 = add_node!(w, DataNode(MetaThru,   spec_metathru()))
    j  = add_node!(w, DataNode(MetaJoin,   spec_metajoin()))
    add_connection!(w, s,  :out, t1, :table)
    add_connection!(w, s,  :out, t2, :table)
    add_connection!(w, t1, :out, j,  :input1)
    add_connection!(w, t2, :out, j,  :input2)

    resetcalls!()
    @test exportmeta(w, j, :out) == (columns = [:a, :b, :a, :b],)
    @test calls(:meta_source) == 1        # общий предок — один раз
    @test calls(:meta_thru)   == 2

    # мемо не переживает вызов: следующий запрос считает заново
    resetcalls!()
    exportmeta(w, j, :out)
    @test calls(:meta_source) == 1
    exportmeta(w, j, :out)
    @test calls(:meta_source) == 2
end

# --------------------------------------------------------------------------
@testset "P7. предел глубины обхода                        " begin
    # Цепочка s -> t1 -> g -> t3 -> t4, запрос с конца.
    w  = Workflow(0)
    s  = add_node!(w, DataNode(MetaSource, spec_metasource()))
    t1 = add_node!(w, DataNode(MetaThru,   spec_metathru()))
    g  = add_node!(w, DataNode(MetaGate,   spec_metathru()))
    t3 = add_node!(w, DataNode(MetaThru,   spec_metathru()))
    t4 = add_node!(w, DataNode(MetaThru,   spec_metathru()))
    add_connection!(w, s,  :out, t1, :table)
    add_connection!(w, t1, :out, g,  :table)
    add_connection!(w, g,  :out, t3, :table)
    add_connection!(w, t3, :out, t4, :table)

    # умолчание с запасом
    @test exportmeta(w, t4, :out) == (columns = [:a, :b],)

    # тесный предел обрывает обход ошибкой, а не тихим nothing
    @test_throws ErrorException exportmeta(w, t4, :out; maxdepth = 3)

    # достаточный предел проходит
    @test exportmeta(w, t4, :out; maxdepth = 10) == (columns = [:a, :b],)

    # источник описания обрывает обход, не расходуя глубину:
    # с тем же тесным пределом запрос теперь проходит
    setsettings!(w, g, Dict(:schema => [:x]))
    @test exportmeta(w, t4, :out; maxdepth = 3) == (columns = [:x],)
end


end # @testset "МЕТАДАННЫЕ ПОРТОВ"
