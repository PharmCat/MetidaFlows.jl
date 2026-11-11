############################################################################
#
#  КАТЕГОРИЯ: MULTIPORT
#
#  Назначение: закрепить контракт входа, принимающего произвольное число
#  связей. До 0.3.0 `getinputdata` отдавал на таком порту САМ словарь
#  буфера с ключами по номерам связей, и из этого следовало три беды:
#
#    1) порядок обхода `Dict` не определён порядком вставки — на 12 входах,
#       подключённых по алфавиту, словарь отдавал `cbfedahgjkli`;
#    2) номер связи узлу ни о чём не говорит, а модели у `execute_unsafe!`
#       нет, так что назвать производителя было нечем;
#    3) словарь был живой: узел, прибравший за собой, вытирал свой буфер.
#
#  Вместе это значило, что на MultiPort нельзя было написать ничего, кроме
#  коммутативной свёртки: ни склейки, ни выбора «какой вход выиграл».
#
#  Теперь правило одно: значения отдаются вектором по ВОЗРАСТАНИЮ НОМЕРА
#  СВЯЗИ, то есть в порядке, в котором входы подключали. Номера связей
#  выдаёт монотонный счётчик и никогда не переиспользует, поэтому порядок
#  определён навсегда и переживает снимок.
#
############################################################################

# --------------------------------------------------------------------------
# Фикстуры
# --------------------------------------------------------------------------
import MetidaFlows: getinputconnections, dict_to_workflow

struct MpSrc  <: AbstractNodeType end   # константа-источник
struct MpCat  <: AbstractNodeType end   # НЕкоммутативный: склейка по порядку
struct MpPick <: AbstractNodeType end   # сообщает, КАКОЙ вход выиграл
struct MpFb   <: AbstractNodeType end   # MultiPort на обратном порту

spec_mpsrc() = NodeSpec("Mp src", PortSpec[], [PortSpec("Out", Any, :out)], [:v])

spec_mpcat() = NodeSpec("Mp cat",
                        [PortSpec("In", Any, :ins, MultiPort())],
                        [PortSpec("Out", Any, :out)])

spec_mppick() = NodeSpec("Mp pick",
                         [PortSpec("In", Any, :ins, MultiPort())],
                         [PortSpec("Best", Any, :best),
                          PortSpec("Which", Int, :which)])

spec_mpfb() = NodeSpec("Mp fb",
                       [PortSpec("Back", Any, :back, MultiPort(); kind = :feedback, required = false)],
                       [PortSpec("Out", Any, :out)])

MetidaFlows.execute_unsafe!(n::DataNode{MpSrc}) =
    (setdata!(n, :out, n.settings[:v]); [:out])

#  Склейка: порядок значений — это ответ. На прежнем аксессоре такой узел
#  был бы неверен, и неверен МОЛЧА.
MetidaFlows.execute_unsafe!(n::DataNode{MpCat}) =
    (setdata!(n, :out, join(getinputdata(n, :ins))); [:out])

#  «Какой вход выиграл»: позиция в векторе — это порядок подключения,
#  то есть внешнее знание автора графа, которым узел теперь располагает.
function MetidaFlows.execute_unsafe!(n::DataNode{MpPick})
    v = getinputdata(n, :ins)
    i = argmin(v)
    setdata!(n, :best,  v[i])
    setdata!(n, :which, i)
    return [:best, :which]
end

MetidaFlows.execute_unsafe!(n::DataNode{MpFb}) = (setdata!(n, :out, 0); [:out])

#  Граф: n источников с буквами, подключённые по алфавиту в один MultiPort.
function mp_build_cat(n)
    w   = Workflow(0; type = :DAW)
    cat = add_node!(w, DataNode(MpCat, spec_mpcat()))
    cids = Int[]
    for i in 1:n
        s = add_node!(w, DataNode(MpSrc, spec_mpsrc()))
        setsettings!(w, s, Dict(:v => string(Char('a' + i - 1))))
        push!(cids, add_connection!(w, s, :out, cat, :ins))
    end
    (w = w, cat = cat, cids = cids)
end

############################################################################

@testset "MULTIPORT                                        " begin

# --------------------------------------------------------------------------
@testset "M1. порядок = порядок подключения                " begin
    #  Ровно те N, на которых обход Dict расходился с порядком вставки.
    #  На 3 входах он отдавал `cba`, на 12 — `cbfedahgjkli`.
    for n in (1, 2, 3, 8, 12, 17, 26)
        g = mp_build_cat(n)
        scheduler!(g.w)
        @test getdata(g.w, g.cat, :out) == join(string(Char('a' + i - 1)) for i in 1:n)
    end

    #  Порядок — это именно номера связей, а не порядок создания УЗЛОВ:
    #  подключаем в обратном порядке, узлы те же.
    w   = Workflow(0; type = :DAW)
    cat = add_node!(w, DataNode(MpCat, spec_mpcat()))
    a   = add_node!(w, DataNode(MpSrc, spec_mpsrc())); setsettings!(w, a, Dict(:v => "a"))
    b   = add_node!(w, DataNode(MpSrc, spec_mpsrc())); setsettings!(w, b, Dict(:v => "b"))
    cb  = add_connection!(w, b, :out, cat, :ins)       # b подключили первым
    ca  = add_connection!(w, a, :out, cat, :ins)
    @test cb < ca
    scheduler!(w)
    @test getdata(w, cat, :out) == "ba"

    #  И это не свойство DAW: в ABW правило то же
    g2 = mp_build_cat(10)
    w2 = g2.w
    @test getdata((scheduler!(w2); w2), g2.cat, :out) == "abcdefghij"
end

# --------------------------------------------------------------------------
@testset "M2. вектор, а не живой буфер                     " begin
    m = DataNode(MpCat, spec_mpcat())
    setinputbuffer!(m, :ins, 3, "c")      # пишем вразнобой
    setinputbuffer!(m, :ins, 1, "a")
    setinputbuffer!(m, :ins, 2, "b")

    v = getinputdata(m, :ins)
    @test v isa Vector
    @test v == ["a", "b", "c"]
    @test !(v === m.input_buffer[:ins])   # прежде это был САМ буфер

    #  узел вправе съесть, отсортировать, вывернуть — буфер не страдает
    empty!(v)
    @test getinputdata(m, :ins) == ["a", "b", "c"]
    reverse!(getinputdata(m, :ins))
    @test getinputdata(m, :ins) == ["a", "b", "c"]

    #  каждый вызов — свежий вектор
    @test !(getinputdata(m, :ins) === getinputdata(m, :ins))

    #  пустой порт — пустой вектор, а не nothing и не пустой Dict
    e = DataNode(MpCat, spec_mpcat())
    @test getinputdata(e, :ins) == []
    @test isempty(getinputdata(e, :ins))
    @test isempty(getinputconnections(e, :ins))
end

# --------------------------------------------------------------------------
@testset "M3. getinputconnections выровнен со значениями   " begin
    g = mp_build_cat(6)
    scheduler!(g.w)
    node = getnode(g.w, g.cat)

    cids = getinputconnections(node, :ins)
    vals = getinputdata(node, :ins)
    @test cids == sort(g.cids)
    @test length(cids) == length(vals)
    @test issorted(cids)

    #  зип даёт то же, что трёхаргументная форма: это и есть «выровнен»
    for (cid, v) in zip(cids, vals)
        @test getinputdata(node, :ins, cid) == v
    end

    #  аксессор не требует модели — его зовут из execute_unsafe!
    @test_throws ErrorException getinputconnections(node, :ghost)

    #  SinglePort не затронут
    s = DataNode(AddNode, spec_add())
    setinputbuffer!(s, :a, 7, 42)
    @test getinputdata(s, :a) == 42
    @test getinputconnections(s, :a) == [7]
end

# --------------------------------------------------------------------------
@testset "M4. метаданные выровнены с данными               " begin
    #  Одно правило порядка на оба механизма: иначе правило метаданных
    #  нельзя написать согласованно с телом узла.
    MetidaFlows.getmeta_unsafe(n::DataNode{MpSrc}, ::Symbol, inmeta) =
        (letter = n.settings[:v],)

    g = mp_build_cat(9)
    im = getinputmeta(g.w, g.cat)[:ins]
    @test im isa Vector
    @test length(im) == 9
    @test [x.letter for x in im] == [string(Char('a' + i - 1)) for i in 1:9]

    #  позиция в описаниях = позиция в значениях
    scheduler!(g.w)
    vals = getinputdata(getnode(g.w, g.cat), :ins)
    @test [x.letter for x in im] == vals

    #  неподключённый MultiPort — пустой вектор
    w = Workflow(0)
    lone = add_node!(w, DataNode(MpCat, spec_mpcat()))
    @test getinputmeta(w, lone)[:ins] == Any[]
end

# --------------------------------------------------------------------------
@testset "M5. узел, который прежде был невозможен          " begin
    #  «Какой из входов выиграл» — то, что на MultiPort сказать было
    #  нечем: минимум брался, а направление терялось.
    w = Workflow(0; type = :DAW)
    pick = add_node!(w, DataNode(MpPick, spec_mppick()))
    vals = [5, 3, 9, 3]
    for v in vals
        s = add_node!(w, DataNode(MpSrc, spec_mpsrc()))
        setsettings!(w, s, Dict(:v => v))
        add_connection!(w, s, :out, pick, :ins)
    end
    scheduler!(w)
    @test getdata(w, pick, :best)  == 3
    @test getdata(w, pick, :which) == 2        # ПЕРВЫЙ из двух минимумов

    #  детерминизм при равных значениях — следствие порядка: повторный
    #  прогон того же графа даёт тот же ответ, а не какой-нибудь из двух
    for _ in 1:5
        reset!(w); scheduler!(w)
        @test getdata(w, pick, :which) == 2
    end

    #  склейка — вторая форма того же: ответ зависит от порядка
    g = mp_build_cat(5)
    scheduler!(g.w)
    @test getdata(g.w, g.cat, :out) == "abcde"
end

# --------------------------------------------------------------------------
@testset "M6. удаление и переподключение                   " begin
    g = mp_build_cat(5)
    scheduler!(g.w)
    @test getdata(g.w, g.cat, :out) == "abcde"

    #  Выбросили середину: порядок выживших сохраняется, дыра в номерах
    #  на него не влияет.
    delete_connection!(g.w, g.cids[3])
    scheduler!(g.w)
    @test getdata(g.w, g.cat, :out) == "abde"
    @test getinputconnections(getnode(g.w, g.cat), :ins) ==
          sort([g.cids[1], g.cids[2], g.cids[4], g.cids[5]])

    #  Переподключение уходит в КОНЕЦ: счётчик связей монотонен и номера
    #  не переиспользуются. Это предсказуемо, и это надо знать.
    src_c = getconnection(g.w, g.cids[1]).output_id
    delete_connection!(g.w, g.cids[1])
    newc = add_connection!(g.w, src_c, :out, g.cat, :ins)
    @test newc > maximum(g.cids)
    scheduler!(g.w)
    @test getdata(g.w, g.cat, :out) == "bdea"      # «a» теперь последняя
end

# --------------------------------------------------------------------------
@testset "M7. порядок переживает снимок                    " begin
    #  Обычные входные буферы в снимок не пишутся: их пересчитывают, а
    #  номера связей снимок сохраняет, поэтому порядок восстанавливается
    #  сам. Буфер :feedback — единственный, который возвращается С ДИСКА,
    #  значит проверять надо именно его.
    unregister_all!()
    w = Workflow(0; type = :ABW)
    sink = add_node!(w, DataNode(MpFb, spec_mpfb()))
    cids = Int[]
    for i in 1:6
        s = add_node!(w, DataNode(MpSrc, spec_mpsrc()))
        setsettings!(w, s, Dict(:v => i * 10))
        push!(cids, add_connection!(w, s, :out, sink, :back))
    end
    scheduler!(w)
    node   = getnode(w, sink)
    before = getinputdata(node, :back)
    @test before == [10, 20, 30, 40, 50, 60]

    register_node!(w)
    w2 = dict_to_workflow(workflow_to_dict(w; values = true, state = true))
    node2 = getnode(w2, sink)
    @test getinputdata(node2, :back)        == before
    @test getinputconnections(node2, :back) == sort(cids)
    unregister_all!()

    #  и обычный порт после круга: буфера в файле нет, но номера связей
    #  те же, поэтому пересчёт даёт тот же порядок
    g = mp_build_cat(12)
    scheduler!(g.w)
    register_node!(g.w)
    w3 = dict_to_workflow(workflow_to_dict(g.w; values = true, state = true))
    scheduler!(w3)
    @test getdata(w3, g.cat, :out) == "abcdefghijkl"
    unregister_all!()
end


end # @testset "MULTIPORT"
