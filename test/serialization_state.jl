############################################################################
#
#  СЕРИАЛИЗАЦИЯ: ЗНАЧЕНИЯ НАСТРОЕК И СОСТОЯНИЕ ЦИКЛА
#
#
#  ГРАФ ДЛЯ ПРОВЕРОК
#
#   ConstSeed ─┬──────────▶ Acc ──▶ Gate ──▶ :total  (терминальный)
#              │             ▲        │  └──▶ :trace (терминальный)
#   ConstLimit ─┼─────────────┼───────┘
#              │             │        │
#              │             └── :back, :hist (обратные) ◀──┘
#
#
############################################################################

import MetidaFlows: value_to_dict, dict_to_value, settings_to_dict,
    dict_to_settings!, node_state_to_dict, dict_to_node_state!,
    SNAPSHOT_FORMAT_VERSION, VALUE_TYPES, register_node!, unregister_all!,
    dict_to_workflow, dict_to_node, workflow_to_dict, node_to_dict,
    getnode, nodetypestr, getportspec, reset!, settings_schema

# --------------------------------------------------------------------------
#  Типы узлов
# --------------------------------------------------------------------------
struct VSeed  <: AbstractNodeType end   # источник Int из настройки
struct VAcc   <: AbstractNodeType end   # голова цикла
struct VGate  <: AbstractNodeType end   # ворота
struct VZoo   <: AbstractNodeType end   # узел со настройками всех видов

spec_vseed() = NodeSpec("V seed", PortSpec[],
    [PortSpec("Out", Int, :out)], [:value])

spec_vacc() = NodeSpec("V acc",
    [PortSpec("Seed",    Int,         :seed),
     PortSpec("Back",    Int,         :back; kind = :feedback, required = false),
     PortSpec("History", Vector{Int}, :hist; kind = :feedback, required = false)],
    [PortSpec("Sum",     Int,         :sum),
     PortSpec("History", Vector{Int}, :hist)])

spec_vgate() = NodeSpec("V gate",
    [PortSpec("Sum",     Int,         :sum),
     PortSpec("History", Vector{Int}, :hist),
     PortSpec("Limit",   Int,         :limit)],
    [PortSpec("Sum",     Int,         :sum),
     PortSpec("History", Vector{Int}, :hist),
     PortSpec("Total",   Int,         :total; kind = :terminal),
     PortSpec("Trace",   Vector{Int}, :trace; kind = :terminal)])

spec_vzoo() = NodeSpec("V zoo", PortSpec[], [PortSpec("Out", Int, :out)],
    [:sym, :chr, :tup, :vec, :dic, :i32, :f32, :non, :boo, :str, :undeclared])

MetidaFlows.execute_unsafe!(n::DataNode{VSeed}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])

function MetidaFlows.execute_unsafe!(node::DataNode{VAcc})
    seed = getinputdata(node, :seed)
    back = getinputdata(node, :back)
    hist = getinputdata(node, :hist)
    s = isnothing(back) ? seed : back + seed
    h = isnothing(hist) ? Int[] : copy(hist)
    push!(h, s)
    setdata!(node, :sum,  s)
    setdata!(node, :hist, h)
    return [:sum, :hist]
end

function MetidaFlows.execute_unsafe!(node::DataNode{VGate})
    s = getinputdata(node, :sum)
    h = getinputdata(node, :hist)
    if s >= getinputdata(node, :limit)
        setdata!(node, :total, s)
        setdata!(node, :trace, h)
        return [:total, :trace]
    end
    setdata!(node, :sum,  s)
    setdata!(node, :hist, h)
    return [:sum, :hist]
end

MetidaFlows.execute_unsafe!(n::DataNode{VZoo}) = (setdata!(n, :out, 0); [:out])

"""
    build_vloop(; seed, limit) -> NamedTuple

Циклический граф-накопитель. Возвращает workflow и идентификаторы узлов.
"""
function build_vloop(; seed = 1, limit = 5)
    w      = Workflow(0; type = :ABW)
    w.name = "V loop"
    cseed = add_node!(w, DataNode(VSeed, spec_vseed()))
    clim  = add_node!(w, DataNode(VSeed, spec_vseed()))
    acc   = add_node!(w, DataNode(VAcc,  spec_vacc()))
    gate  = add_node!(w, DataNode(VGate, spec_vgate()))
    setsettings!(w, cseed, Dict(:value => seed))
    setsettings!(w, clim,  Dict(:value => limit))
    add_connection!(w, cseed, :out,  acc,  :seed)
    add_connection!(w, acc,   :sum,  gate, :sum)
    add_connection!(w, acc,   :hist, gate, :hist)
    add_connection!(w, clim,  :out,  gate, :limit)
    add_connection!(w, gate,  :sum,  acc,  :back)
    add_connection!(w, gate,  :hist, acc,  :hist)
    return (w = w, cseed = cseed, clim = clim, acc = acc, gate = gate)
end

registered_vloop(; kw...) = (g = build_vloop(; kw...);
                             register_node!(g.w; skipmode = true); g)

#  Что делает со словарём любой текстовый формат: ключи становятся
#  строками, Symbol — строкой, Tuple — массивом, ширина целых теряется.
#  Проезд через эту функцию равносилен JSON.parse(JSON.json(d)).
textish(x::AbstractDict) = Dict{String, Any}(string(k) => textish(v) for (k, v) in x)
textish(x::Union{AbstractVector, Tuple}) = Any[textish(v) for v in x]
textish(x::Symbol)        = String(x)
textish(x::Char)          = string(x)
textish(x::Bool)          = x
textish(x::Integer)       = Int64(x)
textish(x::AbstractFloat) = Float64(x)
textish(x::Nothing)       = nothing
textish(x::AbstractString) = String(x)

#  Остались ли в разделе только типы, которые текстовый формат умеет.
jsonnative(x::Union{Nothing, Bool, Int64, Float64, String}) = true
jsonnative(x::AbstractVector) = all(jsonnative, x)
jsonnative(x::AbstractDict)   = all(k -> k isa AbstractString, keys(x)) &&
                                all(jsonnative, values(x))
jsonnative(x) = false

# ==========================================================================

@testset verbose = true "ЗНАЧЕНИЯ НАСТРОЕК И СОСТОЯНИЕ ЦИКЛА             " begin

# --------------------------------------------------------------------------
@testset "V1. что теперь лежит в снимке                    " begin
    unregister_all!()
    g = registered_vloop()
    scheduler!(g.w; maxiter = 1000)
    @test getdata(g.w, g.gate, :total) == 5

    d = workflow_to_dict(g.w)
    @test d["format_version"] == SNAPSHOT_FORMAT_VERSION

    nd = d["nodes"][string(g.cseed)]
    # СХЕМА осталась схемой, значения приехали отдельным ключом
    @test nd["settings"]["settingslist"] == [:value]
    @test nd["settings_values"] == Dict("value" => 1)
    # состояние цикла по умолчанию НЕ выгружается
    @test !haskey(nd, "state")

    ds = workflow_to_dict(g.w; state = true)
    sd = ds["nodes"][string(g.acc)]["state"]["feedback_buffer"]
    # только обратные порты, обычный :seed не попал
    @test Set(keys(sd)) == Set(["back", "hist"])
    @test !haskey(ds["nodes"][string(g.gate)]["state"]["feedback_buffer"], "sum")

    # оба раздела пригодны для текстового формата как есть
    for (_, n) in ds["nodes"]
        @test jsonnative(n["settings_values"])
        @test jsonnative(n["state"])
    end

    # старое поведение доступно
    @test !haskey(node_to_dict(getnode(g.w, g.cseed); values = false), "settings_values")
end

# --------------------------------------------------------------------------
@testset "V2. загруженный граф считает                     " begin
    unregister_all!()
    g = registered_vloop()
    scheduler!(g.w; maxiter = 1000)
    ref = getdata(g.w, g.gate, :trace)

    w2 = dict_to_workflow(textish(workflow_to_dict(g.w)))
    # настройки вернулись сами, руками ничего подставлять не надо
    @test getnode(w2, g.cseed).settings[:value] === 1
    @test getnode(w2, g.clim).settings[:value]  === 5

    scheduler!(w2; maxiter = 1000)
    @test getdata(w2, g.gate, :total) == 5
    @test getdata(w2, g.gate, :trace) == ref
    @test getdata(w2, g.gate, :trace) isa Vector{Int}
end

# --------------------------------------------------------------------------
@testset "V3. кодек значений                               " begin
    zoo = Dict{Symbol, Any}(
        :sym => :alpha,
        :chr => 'x',
        :tup => (1, 2.5, "three"),
        :vec => [3, 1, 2],
        :dic => Dict(:a => 1, :b => "two"),
        :i32 => Int32(7),
        :f32 => Float32(0.5),
        :non => nothing,
        :boo => true,
        :str => "text")
    node = DataNode(VZoo, spec_vzoo(); settings = copy(zoo))
    d    = textish(settings_to_dict(node))

    back = DataNode(VZoo, spec_vzoo())
    dict_to_settings!(back, d)

    for k in (:sym, :chr, :tup, :vec, :dic, :i32, :f32, :non, :boo, :str)
        @test back.settings[k] == zoo[k]
        @test typeof(back.settings[k]) === typeof(zoo[k])
    end
    #  конкретный тип элемента массива выжил дорогу через текст
    @test back.settings[:vec] isa Vector{Int}
    @test back.settings[:dic] isa Dict{Symbol, Any}

    #  необъявленный ключ в файл не попадает и из файла не читается
    node.settings[:sneaky] = 1
    @test !haskey(settings_to_dict(node), "sneaky")
    dict_to_settings!(back, Dict("sneaky" => 1, "undeclared" => 2))
    @test !haskey(back.settings, :sneaky)
    @test back.settings[:undeclared] == 2     # объявлен в спеке — читается
end

# --------------------------------------------------------------------------
@testset "V4. чекпойнт и продолжение                       " begin
    unregister_all!()
    gf = registered_vloop(limit = 12)
    scheduler!(gf.w; maxiter = 1000)
    full = getdata(gf.w, gf.gate, :trace)
    @test full == collect(1:12)

    #  обрываем лимитом алгоритма на пятом витке
    unregister_all!()
    gc = registered_vloop(limit = 5)
    scheduler!(gc.w; maxiter = 1000)
    @test getdata(gc.w, gc.gate, :trace) == collect(1:5)

    d  = textish(workflow_to_dict(gc.w; state = true))
    w2 = dict_to_workflow(d)
    #  Состояние цикла на месте, и с правильным типом. В буфере состояние
    #  ПРЕДЫДУЩЕГО витка: останавливаясь, ворота публикуют терминальные
    #  порты и в обратный не пишут, поэтому последний виток при
    #  продолжении считается заново.
    @test getinputdata(getnode(w2, gc.acc), :back) == 4
    @test getinputdata(getnode(w2, gc.acc), :hist) == collect(1:4)
    @test getinputdata(getnode(w2, gc.acc), :hist) isa Vector{Int}

    setsettings!(w2, gc.clim, Dict(:value => 12))     # поднять лимит
    scheduler!(w2; reset_mode = :soft, maxiter = 1000)

    #  ПРОДОЛЖЕНИЕ: дошли туда же, куда непрерывный прогон
    @test getdata(w2, gc.gate, :total) == 12
    @test getdata(w2, gc.gate, :trace) == full

    #  negative control: без состояния цикла то же продолжение начинает с нуля
    w3 = dict_to_workflow(textish(workflow_to_dict(gc.w)))   # без state
    setsettings!(w3, gc.clim, Dict(:value => 12))
    scheduler!(w3; reset_mode = :soft, maxiter = 1000)
    @test getdata(w3, gc.gate, :trace) == full               # результат тот же,
    @test isempty(getnode(w3, gc.acc).input_buffer[:back]) == false  # но пройден весь путь
end

# --------------------------------------------------------------------------
@testset "V5. отказы вместо тихой порчи                    " begin
    unregister_all!()
    g = registered_vloop()
    scheduler!(g.w; maxiter = 1000)

    #  несериализуемая настройка: ошибка называет узел и ключ
    bad = getnode(g.w, g.cseed)
    bad.settings[:value] = DataFrame(a = [1])
    e = try workflow_to_dict(g.w); "" catch err sprint(showerror, err) end
    @test occursin("Node $(g.cseed)", e) && occursin(":value", e)
    @test occursin("DataFrame", e)
    bad.settings[:value] = 1                       # вернуть

    #  неизвестный тег не разворачивается в тип, а отвергается
    @test_throws ErrorException dict_to_value(Dict("t" => "Main.Evil", "v" => 1))
    @test_throws ErrorException dict_to_value(Dict("t" => "Vector", "e" => "Evil", "v" => []))
    @test_throws ErrorException dict_to_value(Dict("v" => 1))

    #  буфер обычного порта через раздел состояния не протащить
    nd = node_to_dict(getnode(g.w, g.acc); state = true)
    nd["state"]["feedback_buffer"]["seed"] = Dict("1" => 99)
    @test_throws ErrorException dict_to_node(nd)
    delete!(nd["state"]["feedback_buffer"], "seed")
    nd["state"]["feedback_buffer"]["nosuchport"] = Dict("1" => 99)
    @test_throws ErrorException dict_to_node(nd)

    #  несогласованный id узла
    nd2 = node_to_dict(getnode(g.w, g.acc))
    nd2["id"] = 999
    @test_throws ErrorException dict_to_node(nd2)

    #  снимок из будущего не читается
    d = workflow_to_dict(g.w)
    d["format_version"] = SNAPSHOT_FORMAT_VERSION + 1
    @test_throws ErrorException dict_to_workflow(d)
    #  снимок без версии читается как первый
    delete!(d, "format_version")
    @test dict_to_workflow(d) isa Workflow
end

# --------------------------------------------------------------------------
@testset "V6. загрузка проверяет занятость и не теряет id   " begin
    unregister_all!()
    g = registered_vloop()
    d = workflow_to_dict(g.w)

    #  дубль связи в SinglePort: через add_connection! запрещено, и через
    #  загрузку теперь тоже — раньше индекс на момент проверки был пуст
    dup = Dict{String, Any}(d["connections"]["1"])
    d["connections"][string(maximum(parse.(Int, keys(d["connections"]))) + 1)] = dup
    @test_throws ErrorException dict_to_workflow(d)
    w = dict_to_workflow(d; check_connection_throw_error = false)
    @test length(w.connections) == length(d["connections"]) - 1

    #  c_iter из файла меньше, чем есть связей: следующий id не должен
    #  затирать загруженную связь
    d2 = workflow_to_dict(g.w)
    d2["c_iter"] = 0
    w2  = dict_to_workflow(d2)
    @test w2.c_iter == maximum(keys(w2.connections))
    was = w2.connections[1]
    n1  = add_node!(w2, DataNode(VSeed, spec_vseed()))
    n2  = add_node!(w2, DataNode(VAcc,  spec_vacc()))
    cid = add_connection!(w2, n1, :out, n2, :seed)
    @test cid == length(d2["connections"]) + 1
    @test w2.connections[1] === was
    @test length(w2.connections) == length(d2["connections"]) + 1
end

end
