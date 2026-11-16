############################################################################
#
#  КАТЕГОРИЯ: ПЕРЕДАЧА ВЛАДЕНИЯ
#
#  На связи ничего не копируется: производитель и каждый потребитель держат
#  ОДИН И ТОТ ЖЕ объект. Отсюда ошибка, ради которой всё это сделано: узел,
#  правящий полученное на месте, портит кеш производителя, а производитель
#  остаётся `:clean` и на следующем прогоне выдаёт испорченное за своё.
#  Воспроизводится на `reset_mode = :none` и на прямом `execute!`; режимы
#  `:full` и `:soft` её прячут, потому что помечают `:dirty` всех.
#
#  Легальный способ работать на месте — объявить `handover = true` на ВЫХОДЕ
#  производителя и на ВХОДЕ потребителя, а в теле потребителя взять значение
#  через `take!`. Объявление — это разрешение, а не передача: пока никто не
#  взял, значение общее, и портить его нельзя.
#
#  Передача засчитывается по факту: движок видит, что объявленный вход опустел
#  за время исполнения узла, и тогда снимает кеш отдавшего порта у
#  производителя и ставит ему `:released`. То есть статус производителя меняет
#  исполнение ПОТРЕБИТЕЛЯ, а не его собственная публикация.
#
#  Ключевое в статусе: `:released` отвечает как `:clean` на вопрос «ты
#  отработал, на тебя можно положиться» (значение уже у потребителя) и как
#  `:dirty` на вопрос «есть ли у тебя кеш». Если перепутать первое, граф
#  встанет сразу после передачи: потребитель не станет готов никогда.
#
############################################################################

struct HTable  <: AbstractNodeType end   # производит вектор
struct HScale  <: AbstractNodeType end   # ЧИТАЕТ и правит на месте — так нельзя
struct HTwo    <: AbstractNodeType end   # два выхода, отдаётся один
struct HSum    <: AbstractNodeType end   # обычный потребитель
struct HTake   <: AbstractNodeType end   # забирает владение через take!
struct HScaleT <: AbstractNodeType end   # забирающий двойник HScale
struct HBoom   <: AbstractNodeType end   # забрал и упал

MetidaFlows.execute_unsafe!(n::DataNode{HTable}) =
    (setdata!(n, :out, [1.0, 2.0, 3.0]); setreadyports!(n, :out))

function MetidaFlows.execute_unsafe!(n::DataNode{HScale})
    v = getinputdata(n, :in)
    v .*= get(n.settings, :k, 2.0)          # правка на месте БЕЗ взятия
    setdata!(n, :sum, sum(v))
    return setreadyports!(n, :sum)
end

function MetidaFlows.execute_unsafe!(n::DataNode{HScaleT})
    v = take!(n, :in)                       # то же самое, но со взятием
    v .*= get(n.settings, :k, 2.0)
    setdata!(n, :sum, sum(v))
    return setreadyports!(n, :sum)
end

function MetidaFlows.execute_unsafe!(n::DataNode{HTwo})
    setdata!(n, :given, [1.0, 2.0])
    setdata!(n, :kept,  10)
    return setreadyports!(n, :given, :kept)
end

#  Забирает значение и правит его на месте — законно только с handover.
function MetidaFlows.execute_unsafe!(n::DataNode{HTake})
    v = take!(n, :in)
    v === nothing && return setreadyports!(n)
    v .*= 2.0
    sort!(v; rev = true)
    setdata!(n, :out, v)
    return setreadyports!(n, :out)
end

MetidaFlows.execute_unsafe!(n::DataNode{HBoom}) =
    (take!(n, :in); error("после взятия"))

MetidaFlows.execute_unsafe!(n::DataNode{HSum}) =
    (setdata!(n, :out, sum(getinputdata(n, :in))); setreadyports!(n, :out))

h_table(handover) = NodeSpec("HTable", PortSpec[],
    [PortSpec("out", Vector{Float64}, :out; handover = handover)])
h_scale() = NodeSpec("HScale", [PortSpec("in", Vector{Float64}, :in)],
    [PortSpec("sum", Float64, :sum)], [:k])
h_scalet() = NodeSpec("HScaleT", [PortSpec("in", Vector{Float64}, :in; handover = true)],
    [PortSpec("sum", Float64, :sum)], [:k])
h_two() = NodeSpec("HTwo", PortSpec[],
    [PortSpec("given", Vector{Float64}, :given; handover = true),
     PortSpec("kept",  Int,             :kept)])
h_sum() = NodeSpec("HSum", [PortSpec("in", Vector{Float64}, :in)],
    [PortSpec("out", Float64, :out)])
h_take() = NodeSpec("HTake", [PortSpec("in", Vector{Float64}, :in; handover = true)],
    [PortSpec("out", Vector{Float64}, :out)])
h_boom() = NodeSpec("HBoom", [PortSpec("in", Vector{Float64}, :in; handover = true)],
    PortSpec[])

#  Пара «таблица → потребитель». handover — на выходе таблицы, take — тип
#  потребителя: HScale читает, HScaleT забирает.
function h_build(handover, T = HScale, spec = h_scale())
    w = Workflow(1)
    t = add_node!(w, DataNode(HTable, h_table(handover)))
    s = add_node!(w, DataNode(T, spec))
    add_connection!(w, t, :out, s, :in)
    setsettings!(w, s, Dict(:k => 2.0))
    (w, t, s)
end

@testset "ПЕРЕДАЧА ВЛАДЕНИЯ                                " begin

# --------------------------------------------------------------------------
@testset "H1. ошибка, ради которой это сделано             " begin
    #  Без объявления: тот же объект у родителя и в буфере потомка.
    w, t, s = h_build(false)
    scheduler!(w)
    @test getdata(w, s, :sum) == 12.0
    @test getdata(w, t, :out) == [2.0, 4.0, 6.0]      # кеш родителя испорчен
    @test getinputdata(getnode(w, s), :in) === getdata(w, t, :out)

    setsettings!(w, s, Dict(:k => 2.0))               # настройки те же
    scheduler!(w; reset_mode = :none)
    @test getdata(w, s, :sum) == 24.0                 # БУКВАЛЬНО неверно
    @test getexecn(w, t) == 1                         # родитель не считался

    #  Одного объявления МАЛО. Потребитель по-прежнему читает через
    #  getinputdata и правит общее значение — ошибка та же. Объявление даёт
    #  право забрать, а не забирает.
    w1, t1, s1 = h_build(true)
    scheduler!(w1)
    setsettings!(w1, s1, Dict(:k => 2.0))
    scheduler!(w1; reset_mode = :none)
    @test getdata(w1, s1, :sum) == 24.0
    @test getstatus(w1, t1) == :clean                 # никто ничего не брал

    #  Со взятием: правка на месте законна, ответ верный на любом прогоне.
    w2, t2, s2 = h_build(true, HScaleT, h_scalet())
    scheduler!(w2)
    @test getdata(w2, s2, :sum) == 12.0
    setsettings!(w2, s2, Dict(:k => 2.0))
    scheduler!(w2; reset_mode = :none)
    @test getdata(w2, s2, :sum) == 12.0               # и во второй раз
    scheduler!(w2; reset_mode = :none)
    @test getdata(w2, s2, :sum) == 12.0               # и в третий

    #  Тот же сценарий через прямой execute! с подтягиванием родителя.
    w3, t3, s3 = h_build(true, HScaleT, h_scalet())
    scheduler!(w3)
    setsettings!(w3, s3, Dict(:k => 2.0))
    execute!(w3, s3)
    @test getdata(w3, s3, :sum) == 12.0
end

# --------------------------------------------------------------------------
@testset "H2. :released — что он значит                    " begin
    w, t, s = h_build(true, HScaleT, h_scalet())
    scheduler!(w)

    @test getstatus(w, t) == :released
    @test getstatus(w, s) == :clean
    #  Кеша отданного порта нет...
    @test getdata(w, t, :out) === nothing
    #  ...а список опубликованных портов есть: на нём стоит проверка готовности.
    @test getstate(getnode(w, t), :ready_ports) == [:out]
    #  Потребитель всё получил — значит готовность сработала, несмотря на то,
    #  что родитель не :clean. Если бы :released вёл себя как :dirty, граф
    #  встал бы здесь.
    @test getdata(w, s, :sum) == 12.0

    #  Пересчитывается, как :dirty: :none не считает только :clean.
    before = getexecn(w, t)
    scheduler!(w; reset_mode = :none)
    @test getexecn(w, t) == before + 1

    #  Обычная инвалидация метку не бережёт.
    scheduler!(w)
    @test getstatus(w, t) == :released
    mark_dirty!(getnode(w, t))
    @test getstatus(w, t) == :dirty
end

# --------------------------------------------------------------------------
@testset "H3. отдающий порт берёт ровно одну связь         " begin
    w, t, s = h_build(true)
    other = add_node!(w, DataNode(HSum, h_sum()))
    @test_throws ErrorException add_connection!(w, t, :out, other, :in)
    #  Первая связь цела, граф исполним.
    @test length(w.connections) == 1
    scheduler!(w)
    @test getdata(w, s, :sum) == 12.0

    #  Обычный порт по-прежнему принимает сколько угодно потребителей.
    w2, t2, s2 = h_build(false)
    o2 = add_node!(w2, DataNode(HSum, h_sum()))
    @test add_connection!(w2, t2, :out, o2, :in) > 0
    @test length(w2.connections) == 2
end

# --------------------------------------------------------------------------
@testset "H4. не отдал — значит :clean                     " begin
    #  Порт объявлен отдающим, но слушать некому: передавать нечего.
    w = Workflow(1)
    t = add_node!(w, DataNode(HTable, h_table(true)))
    scheduler!(w)
    @test getstatus(w, t) == :clean
    @test getdata(w, t, :out) == [1.0, 2.0, 3.0]

    #  Узел с двумя выходами: один забрали, второй кешируется как обычно.
    w2 = Workflow(1)
    a  = add_node!(w2, DataNode(HTwo, h_two()))
    b  = add_node!(w2, DataNode(HTake, h_take()))
    add_connection!(w2, a, :given, b, :in)
    scheduler!(w2)
    @test getstatus(w2, a) == :released
    @test getdata(w2, a, :given) === nothing
    @test getdata(w2, a, :kept)  == 10
end

# --------------------------------------------------------------------------
@testset "H5. один ключ на обе стороны, правило по направлению" begin
    #  Ключ законен и на входе, и на выходе; умолчание прежнее.
    sp = NodeSpec("Ok", [PortSpec("in", Int, :in; handover = true)],
                        [PortSpec("out", Int, :out; handover = true)])
    @test sp.input_ports[1].handover && sp.output_ports[1].handover
    @test !PortSpec("out", Int, :out).handover

    #  Забирающий вход — только от отдающего выхода.
    w = Workflow(1)
    plain = add_node!(w, DataNode(HTable, h_table(false)))
    taker = add_node!(w, DataNode(HTake,  h_take()))
    @test_throws ErrorException add_connection!(w, plain, :out, taker, :in)
    @test isempty(w.connections)

    #  От отдающего — можно.
    giver = add_node!(w, DataNode(HTable, h_table(true)))
    @test add_connection!(w, giver, :out, taker, :in) > 0

    #  Обратное направление открыто: отдающий выход и обычный вход. Никто не
    #  берёт — производитель остаётся :clean со своим кешем.
    w2 = Workflow(1)
    g2 = add_node!(w2, DataNode(HTable, h_table(true)))
    s2 = add_node!(w2, DataNode(HScale, h_scale()))
    @test add_connection!(w2, g2, :out, s2, :in) > 0
    scheduler!(w2)
    @test getdata(w2, s2, :sum) == 12.0
    @test getstatus(w2, g2) == :clean
    @test getdata(w2, g2, :out) !== nothing
end

# --------------------------------------------------------------------------
@testset "H7. take! забирает значение из буфера            " begin
    w = Workflow(1)
    g = add_node!(w, DataNode(HTable, h_table(true)))
    k = add_node!(w, DataNode(HTake,  h_take()))
    add_connection!(w, g, :out, k, :in)
    scheduler!(w)

    #  Узел отсортировал полученное НА МЕСТЕ — это законно.
    @test getdata(w, k, :out) == [6.0, 4.0, 2.0]
    #  И буфер после take! пуст: единственная ссылка ушла в узел.
    @test isempty(getnode(w, k).input_buffer[:in])
    #  Производитель узнал об этом по факту взятия.
    @test getstatus(w, g) == :released
    #  Повторные прогоны дают то же самое.
    scheduler!(w; reset_mode = :none)
    @test getdata(w, k, :out) == [6.0, 4.0, 2.0]

    #  Второй take! подряд находит пустой буфер: прогон перед этим заполнил
    #  его заново, поэтому первый ещё отдаёт значение, а второй — nothing.
    node = getnode(w, k)
    @test take!(node, :in) == [1.0, 2.0, 3.0]
    @test take!(node, :in) === nothing

    #  Брать с необъявленного порта нельзя.
    scale = DataNode(HScale, h_scale())
    @test_throws ErrorException take!(scale, :in)
    #  И с несуществующего.
    @test_throws ErrorException take!(node, :nosuchport)
end

# --------------------------------------------------------------------------
@testset "H8. взяли и упали — передача всё равно засчитана " begin
    #  Значения у потребителя уже нет, и держать его производителю незачем:
    #  освобождение идёт из finally, поэтому падение тела его не отменяет.
    w = Workflow(1)
    g = add_node!(w, DataNode(HTable, h_table(true)))
    b = add_node!(w, DataNode(HBoom,  h_boom()))
    add_connection!(w, g, :out, b, :in)
    scheduler!(w)
    @test getstatus(w, b) == :failed
    @test getstatus(w, g) == :released
    @test getdata(w, g, :out) === nothing
end

# --------------------------------------------------------------------------
@testset "H6. снимок несёт признак для редактора           " begin
    unregister_all!()
    w = Workflow(1)
    a = add_node!(w, DataNode(HTwo, h_two()))
    register_node!(DataNode(HTwo, h_two()))
    d = workflow_to_dict(w)
    ports = d["nodes"][string(a)]["spec"]["output_ports"]
    given = only(filter(p -> p["label"] == "given", ports))
    kept  = only(filter(p -> p["label"] == "kept",  ports))
    @test given["handover"] === true
    @test kept["handover"]  === false
    unregister_all!()
end

end # @testset "ПЕРЕДАЧА ВЛАДЕНИЯ"
