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
import MetidaFlows: getmeta_unsafe, getmeta, getinputmeta

struct MetaSource <: AbstractNodeType end  # описание знает сам, входов нет
struct MetaThru   <: AbstractNodeType end  # прозрачная нода: проброс описания
struct MetaGate   <: AbstractNodeType end  # условный источник: зависит от настроек
struct MetaMute   <: AbstractNodeType end  # хук не реализован: разрыв цепочки
struct MetaJoin   <: AbstractNodeType end  # два входа одного типа
struct MetaRaw    <: AbstractNodeType end  # нетотальное правило: читает настройку без haskey
struct MetaBlind  <: AbstractNodeType end  # источник, который лезет в пустой inmeta

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

function MetidaFlows.getmeta_unsafe(node::DataNode{MetaSource}, ::Symbol, inmeta)
    countcall!(:meta_source)
    return (columns = [:a, :b],)
end

function MetidaFlows.getmeta_unsafe(node::DataNode{MetaThru}, ::Symbol, inmeta)
    countcall!(:meta_thru)
    return inmeta[:table]                      # проброс ЯВНЫЙ
end

# Условный источник: если схема задана настройкой — знаю сам, иначе спрашиваю выше.
MetidaFlows.ismetasource(node::DataNode{MetaGate}, ::Symbol) = haskey(node.settings, :schema)

function MetidaFlows.getmeta_unsafe(node::DataNode{MetaGate}, ::Symbol, inmeta)
    countcall!(:meta_gate)
    isempty(inmeta) && countcall!(:meta_gate_empty_inmeta)
    haskey(node.settings, :schema) && return (columns = node.settings[:schema],)
    return inmeta[:table]
end

# Две — и ровно две — формы нетотального правила. Неподключённый вход в их
# число НЕ входит: getinputmeta кладёт ключ на каждый :normal-порт.
#   1) чтение настройки без проверки
function MetidaFlows.getmeta_unsafe(node::DataNode{MetaRaw}, ::Symbol, inmeta)
    countcall!(:meta_raw)
    return (columns = node.settings[:need],)
end
#   2) чтение inmeta в ветке, объявленной источником: словарь там пуст
MetidaFlows.ismetasource(::DataNode{MetaBlind}, ::Symbol) = true

function MetidaFlows.getmeta_unsafe(node::DataNode{MetaBlind}, ::Symbol, inmeta)
    countcall!(:meta_blind)
    return inmeta[:table]
end

function MetidaFlows.getmeta_unsafe(node::DataNode{MetaJoin}, ::Symbol, inmeta)
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

    @test getmeta(w, s,  :out) == (columns = [:a, :b],)
    @test getmeta(w, t2, :out) == (columns = [:a, :b],)

    inmeta = getinputmeta(w, t2)
    @test collect(keys(inmeta)) == [:table]     # метка входа потребителя
    @test inmeta[:table] == (columns = [:a, :b],)

    # источник опрашивался на каждый запрос: результат нигде не кешируется
    resetcalls!()
    getmeta(w, t2, :out)
    getmeta(w, t2, :out)
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
    @test getmeta(w, t, :out) == (columns = [:a, :b],)
    @test calls(:meta_source) == 1
    @test calls(:meta_gate_empty_inmeta) == 0

    # Настройка задана: гейт объявляет себя источником описания.
    setsettings!(w, g, Dict(:schema => [:x, :y]))
    @test MetidaFlows.ismetasource(getnode(w, g), :out) == true

    resetcalls!()
    @test getmeta(w, g, :out) == (columns = [:x, :y],)
    @test calls(:meta_source) == 0               # выше не поднимались
    @test calls(:meta_gate)   == 1
    @test calls(:meta_gate_empty_inmeta) == 1    # inmeta пришёл пустым

    # Запрос ниже по цепочке тоже останавливается на гейте.
    resetcalls!()
    @test getmeta(w, t, :out) == (columns = [:x, :y],)
    @test calls(:meta_source) == 0
end

# --------------------------------------------------------------------------
@testset "P3. незнание распространяется как nothing        " begin
    # Неподключённый вход.
    w1 = Workflow(0)
    t1 = add_node!(w1, DataNode(MetaThru, spec_metathru()))
    @test getinputmeta(w1, t1) == Dict{Symbol, Any}(:table => nothing)
    @test getmeta(w1, t1, :out) === nothing

    # Нода без реализации хука рвёт цепочку, но не роняет её.
    w2 = Workflow(0)
    s2 = add_node!(w2, DataNode(MetaSource, spec_metasource()))
    m2 = add_node!(w2, DataNode(MetaMute,   spec_metathru()))
    t2 = add_node!(w2, DataNode(MetaThru,   spec_metathru()))
    add_connection!(w2, s2, :out, m2, :table)
    add_connection!(w2, m2, :out, t2, :table)
    @test getmeta(w2, m2, :out) === nothing
    @test getmeta(w2, t2, :out) === nothing

    # Несуществующий выходной порт — ошибка, а не тихий nothing.
    @test_throws ErrorException getmeta(w2, t2, :ghost)
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
    @test getmeta(w, j, :out) == (columns = [:a, :b, :z],)

    # Один вход не подключён -> nothing, но ключ на месте.
    w2 = Workflow(0)
    a2 = add_node!(w2, DataNode(MetaSource, spec_metasource()))
    j2 = add_node!(w2, DataNode(MetaJoin,   spec_metajoin()))
    add_connection!(w2, a2, :out, j2, :input1)
    im2 = getinputmeta(w2, j2)
    @test im2[:input1] == (columns = [:a, :b],)
    @test im2[:input2] === nothing
    @test getmeta(w2, j2, :out) === nothing

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
    @test getmeta(w1, a1, :out) === nothing

    # Тот же цикл, но один из узлов объявил себя источником описания:
    # подъёма из него нет, поэтому ответ определён.
    w2 = Workflow(0)
    g2 = add_node!(w2, DataNode(MetaGate, spec_metathru()))
    t2 = add_node!(w2, DataNode(MetaThru, spec_metathru()))
    add_connection!(w2, g2, :out, t2, :table)
    add_connection!(w2, t2, :out, g2, :table)
    setsettings!(w2, g2, Dict(:schema => [:x]))
    @test getmeta(w2, g2, :out) == (columns = [:x],)
    @test getmeta(w2, t2, :out) == (columns = [:x],)

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
    @test getmeta(w3, l3, :out) == (columns = [:a, :b],)
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
    @test getmeta(w, j, :out) == (columns = [:a, :b, :a, :b],)
    @test calls(:meta_source) == 1        # общий предок — один раз
    @test calls(:meta_thru)   == 2

    # мемо не переживает вызов: следующий запрос считает заново
    resetcalls!()
    getmeta(w, j, :out)
    @test calls(:meta_source) == 1
    getmeta(w, j, :out)
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
    @test getmeta(w, t4, :out) == (columns = [:a, :b],)

    # тесный предел обрывает обход ошибкой, а не тихим nothing
    @test_throws ErrorException getmeta(w, t4, :out; maxdepth = 3)

    # достаточный предел проходит
    @test getmeta(w, t4, :out; maxdepth = 10) == (columns = [:a, :b],)

    # источник описания обрывает обход, не расходуя глубину:
    # с тем же тесным пределом запрос теперь проходит
    setsettings!(w, g, Dict(:schema => [:x]))
    @test getmeta(w, t4, :out; maxdepth = 3) == (columns = [:x],)
end

# --------------------------------------------------------------------------
@testset "P8. весь граф одним обходом                      " begin
    # Цепочка s -> t1 -> ... -> tn. Поштучный опрос портов поднимается от
    # каждого заново, то есть O(n^2) вызовов правил на O(n) узлах; общий
    # мемо делает ту же работу за O(n).
    function chain(n)
        w = Workflow(0)
        prev = add_node!(w, DataNode(MetaSource, spec_metasource()))
        ids  = [prev]
        for _ in 2:n
            cur = add_node!(w, DataNode(MetaThru, spec_metathru()))
            add_connection!(w, prev, :out, cur, :table)
            push!(ids, cur)
            prev = cur
        end
        return w, ids
    end

    w, ids = chain(8)

    # ОДИН обход: каждое правило ровно один раз
    resetcalls!()
    whole = getmeta(w)
    @test calls(:meta_source) == 1
    @test calls(:meta_thru)   == 7

    # поштучно: 1 + 2 + ... + 8 = 36 вызовов правил на тех же 8 узлах
    resetcalls!()
    piece = Dict((id, :out) => getmeta(w, id, :out) for id in ids)
    @test calls(:meta_source) + calls(:meta_thru) == 36

    # и оба способа отвечают одно и то же
    @test whole == piece
    @test length(whole) == 8
    @test sort!(collect(keys(whole))) == [(id, :out) for id in sort(ids)]
    @test all(v -> v == (columns = [:a, :b],), values(whole))

    # ничего не исполнялось
    @test all(n -> n.state.exec_n == 0, values(w.nodes))
    @test w.run_id == 0

    # Ромб: общий предок описывается один раз на весь словарь, а не
    # по разу на каждый вопрос.
    w2 = Workflow(0)
    s  = add_node!(w2, DataNode(MetaSource, spec_metasource()))
    l  = add_node!(w2, DataNode(MetaThru,   spec_metathru()))
    r  = add_node!(w2, DataNode(MetaThru,   spec_metathru()))
    j  = add_node!(w2, DataNode(MetaJoin,   spec_metajoin()))
    add_connection!(w2, s, :out, l, :table)
    add_connection!(w2, s, :out, r, :table)
    add_connection!(w2, l, :out, j, :input1)
    add_connection!(w2, r, :out, j, :input2)

    resetcalls!()
    d = getmeta(w2)
    @test calls(:meta_source) == 1
    @test calls(:meta_thru)   == 2
    @test calls(:meta_join)   == 1
    @test d[(j, :out)] == (columns = [:a, :b, :a, :b],)
    @test d[(s, :out)] == (columns = [:a, :b],)

    # Узел без правила и узел, вернувший nothing, в словаре ЕСТЬ — со
    # значением nothing. Отсутствие ключа означало бы «порта нет», а не
    # «описание неизвестно».
    w3 = Workflow(0)
    m  = add_node!(w3, DataNode(MetaMute, spec_metasource()))
    t  = add_node!(w3, DataNode(MetaThru, spec_metathru()))
    add_connection!(w3, m, :out, t, :table)
    d3 = getmeta(w3)
    @test haskey(d3, (m, :out)) && d3[(m, :out)] === nothing
    @test haskey(d3, (t, :out)) && d3[(t, :out)] === nothing

    # Многопортовый узел и узел с несколькими выходами: ключей столько,
    # сколько выходных портов, и ярлыки свои у каждого.
    w4 = Workflow(0)
    s4 = add_node!(w4, DataNode(MetaSource,
                   NodeSpec("Two out", PortSpec[],
                            [PortSpec("A", Int, :outa), PortSpec("B", Int, :outb)])))
    d4 = getmeta(w4)
    @test sort!(collect(keys(d4))) == [(s4, :outa), (s4, :outb)]

    # maxdepth прокидывается в обход — но сработает он не всегда, и это
    # свойство общего мемо, а не недосмотр. Вопросы задаются по возрастанию
    # id; если граф строился по потоку, родитель уже в мемо к моменту
    # вопроса о ребёнке, и глубже одного уровня обход не спускается.
    w5, _ = chain(20)
    @test length(getmeta(w5; maxdepth = 2)) == 20      # цепочка из 20 при пределе 2

    # А если id идут ПРОТИВ потока, спускаться приходится, и предел работает.
    w6 = Workflow(0)
    back = [add_node!(w6, DataNode(MetaThru, spec_metathru())) for _ in 1:5]
    push!(back, add_node!(w6, DataNode(MetaSource, spec_metasource())))
    for i in length(back):-1:2                         # связи против порядка id
        add_connection!(w6, back[i], :out, back[i - 1], :table)
    end
    @test_throws ErrorException getmeta(w6; maxdepth = 3)
    @test length(getmeta(w6; maxdepth = 10)) == 6

    # Цикл: обход завершается и описывает все порты. Обратное ребро
    # объявляется видом ВХОДНОГО порта, и обход по нему не идёт.
    spec_loop = NodeSpec("Loop body",
                         [PortSpec("Table", Int, :table),
                          PortSpec("Back",  Int, :back; kind = :feedback)],
                         [PortSpec("Out",   Int, :out)])
    w7 = Workflow(0; type = :ABW)
    a  = add_node!(w7, DataNode(MetaSource, spec_metasource()))
    b  = add_node!(w7, DataNode(MetaThru,   spec_loop))
    c  = add_node!(w7, DataNode(MetaThru,   spec_metathru()))
    add_connection!(w7, a, :out, b, :table)
    add_connection!(w7, b, :out, c, :table)
    add_connection!(w7, c, :out, b, :back)      # замыкаем цикл
    d7 = getmeta(w7)
    @test length(d7) == 3
    @test d7[(c, :out)] == (columns = [:a, :b],)

    # Пустой граф — пустой словарь, а не ошибка
    @test getmeta(Workflow(0)) == Dict{Tuple{Int, Symbol}, Any}()
end

# --------------------------------------------------------------------------
@testset "P9. ошибка правила с контекстом                  " begin
    # Нетотальное правило: MetaRaw читает настройку :need без проверки.
    # Это ловушка тотальности — ошибка выходит из середины рекурсии, и без
    # обёртки по ней не видно, какой узел и какой порт её породил.
    w = Workflow(0)
    b = add_node!(w, DataNode(MetaRaw, spec_metathru()))

    @test_throws MetidaFlows.MetaRuleError getmeta(w, b, :out)

    e = try; getmeta(w, b, :out); catch err; err; end
    @test e isa MetidaFlows.MetaRuleError
    @test e.id   == b
    @test e.port == :out
    @test e.cause isa KeyError          # исходная причина не потеряна
    msg = sprint(showerror, e)
    @test occursin("Node $(b)", msg)
    @test occursin(":out", msg)
    @test occursin("need", msg)         # и текст исходной ошибки на месте

    # Вторая форма той же ловушки: источник читает inmeta, а там пусто.
    # Неподключённый вход в эту ловушку НЕ ведёт — у каждого :normal-порта
    # ключ есть всегда, со значением nothing.
    wb = Workflow(0)
    bl = add_node!(wb, DataNode(MetaBlind, spec_metathru()))
    @test_throws MetidaFlows.MetaRuleError getmeta(wb, bl, :out)
    eb = try; getmeta(wb, bl, :out); catch err; err; end
    @test eb.id == bl && eb.cause isa KeyError

    wt = Workflow(0)
    th = add_node!(wt, DataNode(MetaThru, spec_metathru()))   # вход не подключён
    @test getmeta(wt, th, :out) === nothing                   # не ошибка, а «неизвестно»

    # Ошибка называет СВОЙ узел, а не тот, о котором спросили: ниже по
    # потоку она проходит сквозь getinputmeta, не перезаворачиваясь.
    j = add_node!(w, DataNode(MetaJoin, spec_metajoin()))
    add_connection!(w, b, :out, j, :input1)
    e2 = try; getmeta(w, j, :out); catch err; err; end
    @test e2 isa MetidaFlows.MetaRuleError
    @test e2.id == b                    # не j
    @test e2.cause isa KeyError

    # Форма на весь граф падает так же громко: половина описанного графа
    # хуже явной ошибки.
    @test_throws MetidaFlows.MetaRuleError getmeta(w)

    # Границы обёртки: ошибки САМОГО обхода остаются как были, потому что
    # у них контекст уже есть в тексте.
    w2 = Workflow(0)
    s  = add_node!(w2, DataNode(MetaSource, spec_metasource()))
    t  = add_node!(w2, DataNode(MetaThru,   spec_metathru()))
    add_connection!(w2, s, :out, t, :table)
    @test_throws ErrorException getmeta(w2, t, :ghost)          # нет такого порта
    @test_throws ErrorException getmeta(w2, t, :out; maxdepth = 1)  # предел глубины
    @test !(try; getmeta(w2, t, :ghost); catch err; err; end isa MetidaFlows.MetaRuleError)

    # Тотальное правило на том же месте ошибки не даёт
    @test getmeta(w2, t, :out) == (columns = [:a, :b],)
end


end # @testset "МЕТАДАННЫЕ ПОРТОВ"
