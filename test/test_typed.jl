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
    setinputbuffer!, reset!, mark_dirty!, settings_to_dict,
    MultiPort, buffervalues, bufferkeys, PortBuffer

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
#  Буфер-структура: по одному полю на каждый ВХОДНОЙ порт спеки, и в
#  каждом — контейнер по номеру связи. Поля под связи быть не может:
#  номера выдаются в работе.
mutable struct TyBuf <: AbstractNodeInputBuffer
    in::Dict{Int, Int}
    TyBuf() = new(Dict{Int, Int}())
end

#  Тот же тип, но поле названо не как порт: initbuffer! обязан сказать это
#  внятно, потому что поле не доращивается.
mutable struct TyBufWrong <: AbstractNodeInputBuffer
    inp::Dict{Int, Int}
    TyBufWrong() = new(Dict{Int, Int}())
end

#  Контейнер ОДНОГО порта, который держит ключи упорядоченными. Нужен, чтобы
#  проверить точку расширения `buffervalues`/`bufferkeys`: словарь порядка не
#  хранит, поэтому умолчание обязано собрать ключи и отсортировать, а такой
#  контейнер уже знает ответ и только копирует.
mutable struct SortedBuf{V} <: AbstractDict{Int, V}
    cids::Vector{Int}
    vals::Vector{V}
    SortedBuf{V}() where V = new{V}(Int[], V[])
end

Base.length(b::SortedBuf)  = length(b.cids)
Base.isempty(b::SortedBuf) = isempty(b.cids)
Base.keys(b::SortedBuf)    = b.cids
Base.values(b::SortedBuf)  = b.vals
Base.haskey(b::SortedBuf, c::Int) = !isempty(searchsorted(b.cids, c))
function Base.getindex(b::SortedBuf, c::Int)
    r = searchsorted(b.cids, c)
    isempty(r) && throw(KeyError(c))
    b.vals[first(r)]
end
Base.get(b::SortedBuf, c::Int, d) = haskey(b, c) ? b[c] : d
function Base.setindex!(b::SortedBuf, v, c::Int)
    i = searchsortedfirst(b.cids, c)
    if i <= length(b.cids) && b.cids[i] == c
        b.vals[i] = v
    else
        insert!(b.cids, i, c); insert!(b.vals, i, v)
    end
    b
end
function Base.delete!(b::SortedBuf, c::Int)
    r = searchsorted(b.cids, c)
    isempty(r) || (deleteat!(b.cids, first(r)); deleteat!(b.vals, first(r)))
    b
end
Base.empty!(b::SortedBuf) = (empty!(b.cids); empty!(b.vals); b)
function Base.iterate(b::SortedBuf, i::Int = 1)
    i > length(b.cids) && return nothing
    (b.cids[i] => b.vals[i], i + 1)
end

#  Вот и всё переопределение: сортировать нечего, копия обязательна.
MetidaFlows.bufferkeys(b::SortedBuf)   = copy(b.cids)
MetidaFlows.buffervalues(b::SortedBuf) = copy(b.vals)

struct TySorted <: AbstractNodeType end  # MultiPort на упорядоченном буфере
sp_tysorted() = NodeSpec("Ty sorted", [PortSpec("In", Int, :ins, MultiPort())],
                                      [PortSpec("Out", Int, :out)])
MetidaFlows.nodebuffer(::Type{TySorted}) = Dict{Symbol, SortedBuf{Int}}(:ins => SortedBuf{Int}())
MetidaFlows.execute_unsafe!(n::DataNode{TySorted}) =
    (setdata!(n, :out, sum(getinputdata(n, :ins); init = 0)); [:out])

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
    @test nodebuffer(TyPlain)   isa Dict{Symbol, PortBuffer{Any}}

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
    @test node isa DataNode{TyScale, TySettings, TyData, NodeState, Dict{Symbol, Dict{Int, Int}}}
    @test DataNode(TyPlain, sp_typlain()) isa
          DataNode{TyPlain, Dict{Symbol, Any}, Dict{Symbol, Any}, NodeState, Dict{Symbol, PortBuffer{Any}}}

    #  Явный кварг по-прежнему сильнее точки расширения
    mixed = DataNode(TyScale, sp_tyscale(); settings = Dict{Symbol, Any}())
    @test mixed isa DataNode{TyScale, Dict{Symbol, Any}, TyData, NodeState, Dict{Symbol, Dict{Int, Int}}}
end

# --------------------------------------------------------------------------
@testset "Y4. типизированный узел в графе                  " begin
    g = tygraph(value = 5, factor = 3)
    #  Раньше здесь падало: add_connection! → mark_dirty! → empty!(node.data)
    @test getnode(g.w, g.s) isa DataNode{TyScale, TySettings, TyData, NodeState, Dict{Symbol, Dict{Int, Int}}}
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
    @test getnode(w2, g.s) isa DataNode{TyScale, TySettings, TyData, NodeState, Dict{Symbol, Dict{Int, Int}}}
    @test getnode(w2, g.s).settings[:factor] == 3
    #  а узел без специализации остался на Dict
    @test getnode(w2, g.c) isa DataNode{TyPlain, Dict{Symbol, Any}, Dict{Symbol, Any}, NodeState, Dict{Symbol, PortBuffer{Any}}}

    @test scheduler!(w2)
    @test getdata(w2, g.s, :out) == 15
    MetidaFlows.unregister_all!()
end

# --------------------------------------------------------------------------
@testset "Y6. контейнер буфера — тоже параметр          " begin
    #  До 0.3.0 поле было объявлено Dict{Symbol, Dict{Int, BufferT}}: контейнер
    #  фиксирован, свободен только тип значения. Здесь стоял тест, что
    #  конструктор структуры НЕ принимает. Теперь принимает.
    @test TyImmutable <: AbstractNodeData
    @test AbstractNodeInputBuffer <: AbstractNodeFields

    node = DataNode(TyScale, sp_tyscale(); input_buffer = TyBuf())
    @test node isa DataNode{TyScale, TySettings, TyData, NodeState, TyBuf}
    @test node.input_buffer isa TyBuf

    #  и он работает как буфер: чтение, запись, пустота, очистка
    @test getinputdata(node, :in) === nothing
    setinputbuffer!(node, :in, 7, 42)
    @test getinputdata(node, :in) == 42
    @test getinputdata(node, :in, 7) == 42
    @test getinputconnections(node, :in) == [7]
    @test node.input_buffer.in[7] == 42          # поле, а не хеш по Symbol
    MetidaFlows.invalidate_buffer!(node, :in, 7)
    @test getinputdata(node, :in) === nothing

    #  тип значения по-прежнему выбирается, просто теперь вместе с контейнером
    n8 = DataNode(TyScale, sp_tyscale(); input_buffer = Dict{Symbol, Dict{Int, Int8}}())
    @test n8 isa DataNode{TyScale, TySettings, TyData, NodeState, Dict{Symbol, Dict{Int, Int8}}}

    #  Поле должно называться как порт — доращивать структуру нечем, поэтому
    #  это ошибка, и она называет и тип, и нужное поле.
    #  Опечатка в имени поля нарушает обе проверки сразу, и сообщение
    #  называет обе стороны: что нужно и что лишнее.
    err = try; DataNode(TyScale, sp_tyscale(); input_buffer = TyBufWrong()); catch e; e; end
    @test err isa ErrorException
    @test occursin("TyBufWrong", err.msg)
    @test occursin("`in`", err.msg)          # нужное поле
    @test occursin("`inp`", err.msg)         # лишнее поле

    #  Лишнее поле само по себе — тоже ошибка: буфер не должен обещать
    #  портов, которых в спеке нет
    err3 = try; DataNode(TyPlain, sp_typlain(); input_buffer = TyBuf()); catch e; e; end
    @test err3 isa ErrorException
    @test occursin("`in`", err3.msg)
    @test !occursin("no field for input port", err3.msg)   # нечего не хватать

    #  Словарь, значение которого не контейнер, нарастить нельзя — и об этом
    #  тоже говорится внятно, а не MethodError из глубины.
    err2 = try; DataNode(TyScale, sp_tyscale(); input_buffer = Dict{Symbol, Any}()); catch e; e; end
    @test err2 isa ErrorException
    @test occursin("cannot be constructed", err2.msg)

    @test fieldtype(DataNode{TyScale, TySettings, TyData, NodeState, TyBuf}, :input_buffer) === TyBuf
end

# --------------------------------------------------------------------------
@testset "Y7. контейнер, который знает свой порядок        " begin
    #  `buffervalues`/`bufferkeys` — точка расширения: словарь порядка не
    #  хранит, поэтому умолчание собирает ключи и сортирует. Контейнер,
    #  который держит их упорядоченными, отвечает копией.
    b = SortedBuf{Int}()
    b[30] = 3; b[10] = 1; b[20] = 2            # пишем вразнобой
    @test collect(keys(b)) == [10, 20, 30]
    @test MetidaFlows.bufferkeys(b)   == [10, 20, 30]
    @test MetidaFlows.buffervalues(b) == [1, 2, 3]

    #  копия, а не внутренний вектор: иначе узел дотянулся бы до буфера
    @test !(MetidaFlows.buffervalues(b) === b.vals)
    @test !(MetidaFlows.bufferkeys(b)   === b.cids)
    v = MetidaFlows.buffervalues(b); empty!(v)
    @test MetidaFlows.buffervalues(b) == [1, 2, 3]

    #  переопределение даёт ТО ЖЕ, что умолчание на словаре с теми же данными
    d = Dict{Int, Int}(30 => 3, 10 => 1, 20 => 2)
    @test MetidaFlows.buffervalues(d) == MetidaFlows.buffervalues(b)
    @test MetidaFlows.bufferkeys(d)   == MetidaFlows.bufferkeys(b)

    #  и то же в узле: MultiPort отдаёт порядок подключения
    w = Workflow(0; type = :DAW)
    sm = add_node!(w, DataNode(TySorted, sp_tysorted()))
    @test getnode(w, sm).input_buffer[:ins] isa SortedBuf{Int}
    cids = Int[]
    for i in 1:12
        p = add_node!(w, DataNode(TyPlain, sp_typlain()))
        setsettings!(w, p, Dict(:value => i))
        push!(cids, add_connection!(w, p, :out, sm, :ins))
    end
    scheduler!(w)
    node = getnode(w, sm)
    @test getinputdata(node, :ins) == collect(1:12)     # на Dict тут было cbfedahgjkli
    @test getinputconnections(node, :ins) == cids
    @test getdata(w, sm, :out) == sum(1:12)

    #  удаление связи и переподключение ведут себя как на словаре
    delete_connection!(w, cids[3])
    scheduler!(w)
    @test getinputdata(node, :ins) == [1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12]

    #  круг через снимок сохраняет и тип контейнера, и порядок
    MetidaFlows.unregister_all!()
    register_node!(w)
    w2 = dict_to_workflow(workflow_to_dict(w; values = true, state = true))
    @test getnode(w2, sm).input_buffer[:ins] isa SortedBuf{Int}
    scheduler!(w2)
    @test getinputdata(getnode(w2, sm), :ins) == [1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    MetidaFlows.unregister_all!()
end

end
