############################################################################
#
#  КАТЕГОРИЯ: ТИПИЗИРОВАННЫЕ КОНТЕЙНЕРЫ УЗЛА
#
#  Назначение: проверить, что узел можно собрать без единого `Dict` — на
#  своих структурах для настроек, данных и состояния, — и что такой узел
#  доживает до конца: считается, пересчитывается, сериализуется и
#  возвращается из снимка ТЕМ ЖЕ типизированным узлом.
#
#
############################################################################

import MetidaFlows: PortSpec, AbstractNodeFields, AbstractNodeSettings,
    AbstractNodeData, AbstractNodeState, AbstractNodeInputBuffer, NodeState,
    nodesettings, nodedata, nodestate, nodebuffer, getnode, getstatus,
    setinputbuffer!, reset!, mark_dirty!, settings_to_dict

# ==========================================================================
#  Контейнеры и узлы
# ==========================================================================

mutable struct TySettings <: AbstractNodeSettings
    factor::Int
    label::Symbol
    TySettings() = new(1, :none)
    TySettings(f, l) = new(f, l)
end
mutable struct TyData <: AbstractNodeData
    out::Union{Int, Nothing}
    TyData() = new(nothing)
end
#  Без конструктора без аргументов — чтобы проверить диагностику `empty!`
mutable struct TyNoDefault <: AbstractNodeSettings
    x::Int
end
#  Неизменяемая — чтобы проверить вторую диагностику
struct TyImmutable <: AbstractNodeData
    out::Int
end
#  Контейнер буфера, который по смыслу хотелось бы подставить, но нельзя
mutable struct TyBuf <: AbstractNodeInputBuffer
    inp::Dict{Int, Int}
    TyBuf() = new(Dict{Int, Int}())
end

struct TyScale <: AbstractNodeType end   # типизирован целиком
struct TyPlain <: AbstractNodeType end   # остаётся на Dict

sp_tyscale() = NodeSpec("Ty scale", [PortSpec("In", Int, :in)],
                                    [PortSpec("Out", Int, :out)], [:factor, :label])
sp_typlain() = NodeSpec("Ty plain", PortSpec[], [PortSpec("Out", Int, :out)], [:value])

MetidaFlows.nodesettings(::Type{TyScale}) = TySettings()
MetidaFlows.nodedata(::Type{TyScale})     = TyData()
MetidaFlows.nodebuffer(::Type{TyScale})   = Dict{Symbol, Dict{Int, Int}}()

MetidaFlows.execute_unsafe!(n::DataNode{TyPlain}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{TyScale}) =
    (setdata!(n, :out, getinputdata(n, :in) * n.settings[:factor]); [:out])

"Граф: источник на Dict → масштабирование на структурах."
function tygraph(; value = 5, factor = 3)
    w = Workflow(0; type = :DAW)
    c = add_node!(w, DataNode(TyPlain, sp_typlain())); setsettings!(w, c, Dict(:value => value))
    s = add_node!(w, DataNode(TyScale, sp_tyscale())); setsettings!(w, s, Dict(:factor => factor))
    add_connection!(w, c, :out, s, :in)
    (w = w, c = c, s = s)
end

# ==========================================================================

@testset verbose = true "ТИПИЗИРОВАННЫЕ КОНТЕЙНЕРЫ                        " begin

# --------------------------------------------------------------------------
@testset "Y1. протокол AbstractNodeFields                  " begin
    s = TySettings(2, :a)
    #  пять методов, которые движок зовёт на контейнере
    @test s[:factor] == 2
    @test s[:label] === :a
    @test (s[:factor] = 7; s[:factor] == 7)
    @test Set(keys(s)) == Set([:factor, :label])
    @test haskey(s, :factor) && haskey(s, :label)
    @test !haskey(s, :missing)
    @test get(s, :factor, 0) == 7
    @test get(s, :missing, :fallback) === :fallback
    #  empty! возвращает к тому, что даёт конструктор без аргументов
    @test (empty!(s); s[:factor] == 1 && s[:label] === :none)
    @test empty!(TySettings(9, :z)) isa TySettings

    #  NodeState — тот же протокол, со своим empty!
    ns = NodeState()
    @test ns[:exec_n] == 0
    @test haskey(ns, :exec_n) && !haskey(ns, :nope)
    @test get(ns, :nope, 42) == 42
    @test Set(keys(ns)) == Set([:exec_n, :ready_ports, :execution_id, :log, :stop])
end

# --------------------------------------------------------------------------
@testset "Y2. диагностика вместо MethodError               " begin
    #  Нет конструктора без аргументов: ошибка называет тип и что добавить
    n = TyNoDefault(5)
    @test_throws ErrorException empty!(n)
    msg = try; empty!(n); catch e; sprint(showerror, e); end
    @test occursin("TyNoDefault", msg)
    @test occursin("zero-argument constructor", msg)

    #  Неизменяемая структура: и запись, и empty! отказывают по-человечески
    im = TyImmutable(1)
    @test im[:out] == 1                      # чтение работает
    @test_throws ErrorException (im[:out] = 2)
    @test occursin("immutable", try; im[:out] = 2; catch e; sprint(showerror, e); end)
    @test_throws ErrorException empty!(im)
    @test occursin("immutable", try; empty!(im); catch e; sprint(showerror, e); end)
end

# --------------------------------------------------------------------------
@testset "Y3. точки расширения и умолчания                 " begin
    #  Умолчания не изменились: тип без специализации остаётся на Dict
    @test nodesettings(TyPlain) isa Dict{Symbol, Any}
    @test nodedata(TyPlain)     isa Dict{Symbol, Any}
    @test nodestate(TyPlain)    isa NodeState
    @test nodebuffer(TyPlain)   isa Dict{Symbol, Dict{Int, Any}}

    #  Специализированный тип получает свои контейнеры
    @test nodesettings(TyScale) isa TySettings
    @test nodedata(TyScale)     isa TyData
    @test nodebuffer(TyScale)   isa Dict{Symbol, Dict{Int, Int}}
    @test nodestate(TyScale)    isa NodeState   # состояние не специализировали

    #  Каждый вызов даёт СВЕЖИЙ контейнер, иначе два узла делили бы один
    @test nodesettings(TyScale) !== nodesettings(TyScale)
    @test nodedata(TyScale)     !== nodedata(TyScale)

    #  Узел собирается типизированным без единого кварга
    node = DataNode(TyScale, sp_tyscale())
    @test node isa DataNode{TyScale, TySettings, TyData, NodeState, Int}
    @test DataNode(TyPlain, sp_typlain()) isa
          DataNode{TyPlain, Dict{Symbol, Any}, Dict{Symbol, Any}, NodeState, Any}

    #  Явный кварг по-прежнему сильнее точки расширения
    mixed = DataNode(TyScale, sp_tyscale(); settings = Dict{Symbol, Any}())
    @test mixed isa DataNode{TyScale, Dict{Symbol, Any}, TyData, NodeState, Int}
end

# --------------------------------------------------------------------------
@testset "Y4. типизированный узел в графе                  " begin
    g = tygraph(value = 5, factor = 3)
    #  Раньше здесь падало: add_connection! → mark_dirty! → empty!(node.data)
    @test getnode(g.w, g.s) isa DataNode{TyScale, TySettings, TyData, NodeState, Int}
    @test scheduler!(g.w)
    @test getstatus(getnode(g.w, g.s)) === :clean
    @test getdata(g.w, g.s, :out) == 15

    #  настройка меняется через общий путь, пересчёт работает
    setsettings!(g.w, g.s, Dict(:factor => 4))
    @test getnode(g.w, g.s).settings[:factor] == 4
    @test getstatus(getnode(g.w, g.s)) === :dirty      # инвалидация прошла
    scheduler!(g.w)
    @test getdata(g.w, g.s, :out) == 20

    #  инвалидация чистит данные, а не ломается на них
    mark_dirty!(getnode(g.w, g.s))
    @test getnode(g.w, g.s).data[:out] === nothing
    @test getdata(g.w, g.s, :out) === nothing

    #  тип поля проверяется на записи — порт с чужим типом ловится сразу
    @test_throws MethodError setinputbuffer!(getnode(g.w, g.s), :in, 1, "строка")

    #  reset! узла: настройки возвращаются к конструктору без аргументов
    node = getnode(g.w, g.s)
    reset!(node)
    @test node.settings[:factor] == 1 && node.settings[:label] === :none
    @test node.data[:out] === nothing
end

# --------------------------------------------------------------------------
@testset "Y5. круг через снимок сохраняет типы             " begin
    g = tygraph(value = 5, factor = 3)
    scheduler!(g.w)
    @test getdata(g.w, g.s, :out) == 15

    MetidaFlows.unregister_all!()
    register_node!(g.w)
    d = workflow_to_dict(g.w)

    #  значения настроек типизированного узла попали в снимок
    sv = d["nodes"][string(g.s)]["settings_values"]
    @test sv["factor"] == 3
    #  и схема тоже снимается с типизированного контейнера
    @test settings_to_dict(getnode(g.w, g.s))["factor"] == 3

    w2 = dict_to_workflow(d)
    #  ГЛАВНОЕ: загруженный узел того же типа, а не на Dict-ах
    @test typeof(getnode(w2, g.s)) === typeof(getnode(g.w, g.s))
    @test getnode(w2, g.s) isa DataNode{TyScale, TySettings, TyData, NodeState, Int}
    @test getnode(w2, g.s).settings[:factor] == 3
    #  а узел без специализации остался на Dict
    @test getnode(w2, g.c) isa DataNode{TyPlain, Dict{Symbol, Any}, Dict{Symbol, Any}, NodeState, Any}

    @test scheduler!(w2)
    @test getdata(w2, g.s, :out) == 15
    MetidaFlows.unregister_all!()
end

# --------------------------------------------------------------------------
@testset "Y6. чего нельзя: контейнер буфера                " begin
    #  `nodebuffer` выбирает тип ЗНАЧЕНИЯ, а не контейнер: поле объявлено
    #  Dict{Symbol, Dict{Int, BufferT}}, и подменить его нельзя.
    @test fieldtype(DataNode, :input_buffer) <: Dict
    @test TyImmutable <: AbstractNodeData
    @test AbstractNodeInputBuffer <: AbstractNodeFields

    #  конструктор DataNode такого не принимает
    @test_throws MethodError DataNode(TyScale, sp_tyscale(); input_buffer = TyBuf())

    #  а тип значения — принимает, и он виден в параметре узла
    node = DataNode(TyScale, sp_tyscale(); input_buffer = Dict{Symbol, Dict{Int, Int8}}())
    @test node isa DataNode{TyScale, TySettings, TyData, NodeState, Int8}
end

end
