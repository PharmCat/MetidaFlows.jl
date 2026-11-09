############################################################################
#
#  «ЗНАЧЕНИЯ НЕТ» ПРОТИВ «ЗНАЧЕНИЕ ПРОШЛОГО ВИТКА»
#
#
############################################################################

import MetidaFlows: PortSpec, DAW, ABW, getnode, getstatus, push_buffer!,
    invalidate_unpublished!, invalidate_buffer!, setinputbuffer!, reset!,
    getportspec, invalidate_stale_optional!, release_optional_blocked!,
    isready

# --------------------------------------------------------------------------
#  Узлы
# --------------------------------------------------------------------------

AB_SEEN = Any[]
AB_FLAG = Ref(true)          # публиковать ли :a
resetab!() = empty!(AB_SEEN)

struct AbSrc   <: AbstractNodeType end
struct AbFlip  <: AbstractNodeType end   # :a либо :b, по флагу
struct AbOpt   <: AbstractNodeType end   # :p необязательный
struct AbReq   <: AbstractNodeType end   # :p обязательный
struct AbGuard <: AbstractNodeType end   # сторож: проводит вход или молчит
struct AbUse   <: AbstractNodeType end   # охраняемый узел

sp_absrc()  = NodeSpec("Ab src", PortSpec[], [PortSpec("Out", Int, :out)], [:value])
sp_abflip() = NodeSpec("Ab flip", [PortSpec("In", Int, :in)],
                                  [PortSpec("A", Int, :a), PortSpec("B", Int, :b)])
sp_abopt()  = NodeSpec("Ab opt",
    [PortSpec("P", Int, :p; required = false), PortSpec("Q", Int, :q)],
    [PortSpec("Out", Int, :out)])
sp_abreq()  = NodeSpec("Ab req",
    [PortSpec("P", Int, :p), PortSpec("Q", Int, :q)],
    [PortSpec("Out", Int, :out)])
#  Сторож проводит ОБА значения, которые нужны охраняемому узлу, или не
#  публикует ничего. Тогда охраняемый узел не попадает в очередь.
sp_abguard() = NodeSpec("Ab guard",
    [PortSpec("Value", Int, :value), PortSpec("Pass", Bool, :pass)],
    [PortSpec("Value", Int, :value)])
sp_abuse()   = NodeSpec("Ab use", [PortSpec("Value", Int, :value)],
                                  [PortSpec("Out", Int, :out)])

AB_PASS = Ref(true)

struct AbPass <: AbstractNodeType end    # источник признака для сторожа
struct AbHead <: AbstractNodeType end    # голова цикла (для A7)
struct AbGate <: AbstractNodeType end    # ворота цикла (для A7)

sp_abpass() = NodeSpec("Ab pass", PortSpec[], [PortSpec("Out", Bool, :out)])
sp_abhead() = NodeSpec("Ab head",
    [PortSpec("Seed", Int, :seed),
     PortSpec("Back", Int, :back; kind = :feedback, required = false)],
    [PortSpec("Out", Int, :out)])
sp_abgate() = NodeSpec("Ab gate",
    [PortSpec("In", Int, :in), PortSpec("Lim", Int, :lim)],
    [PortSpec("Out",   Int, :out),
     PortSpec("Total", Int, :total; kind = :terminal)])

MetidaFlows.execute_unsafe!(n::DataNode{AbPass}) =
    (setdata!(n, :out, AB_PASS[]); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{AbHead}) =
    (b = getinputdata(n, :back);
     setdata!(n, :out, isnothing(b) ? getinputdata(n, :seed) : b); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{AbGate}) =
    (v = getinputdata(n, :in);
     v >= getinputdata(n, :lim) ? (setdata!(n, :total, v); [:total]) :
                                  (setdata!(n, :out, v + 1); [:out]))

MetidaFlows.execute_unsafe!(n::DataNode{AbSrc}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{AbFlip}) =
    (v = getinputdata(n, :in);
     AB_FLAG[] ? (setdata!(n, :a, v * 10); [:a]) : (setdata!(n, :b, v * 10); [:b]))
function MetidaFlows.execute_unsafe!(n::DataNode{AbOpt})
    p = getinputdata(n, :p)
    push!(AB_SEEN, p)
    setdata!(n, :out, isnothing(p) ? getinputdata(n, :q) : p)
    return [:out]
end
function MetidaFlows.execute_unsafe!(n::DataNode{AbReq})
    p = getinputdata(n, :p)
    push!(AB_SEEN, p)
    setdata!(n, :out, p + getinputdata(n, :q))
    return [:out]
end
MetidaFlows.execute_unsafe!(n::DataNode{AbGuard}) =
    (getinputdata(n, :pass) ?
        (setdata!(n, :value, getinputdata(n, :value)); [:value]) : Symbol[])
MetidaFlows.execute_unsafe!(n::DataNode{AbUse}) =
    (push!(AB_SEEN, getinputdata(n, :value));
     setdata!(n, :out, 2 * getinputdata(n, :value)); [:out])

# --------------------------------------------------------------------------
#  Узлы для release_optional (группы A8–A10)
# --------------------------------------------------------------------------

struct RelBoom   <: AbstractNodeType end  # падает по настройке
struct RelSink   <: AbstractNodeType end  # обязательный + необязательный вход
struct RelHead   <: AbstractNodeType end  # голова цикла: счётчик и сумма
struct RelOdd    <: AbstractNodeType end  # isodd
struct RelDouble <: AbstractNodeType end  # 2i
struct RelGate   <: AbstractNodeType end  # ворота: копит сумму или выдаёт итог

sp_relboom() = NodeSpec("Rel boom", [PortSpec("In", Int, :in)],
    [PortSpec("Out", Int, :out)], [:fail])
sp_relsink() = NodeSpec("Rel sink",
    [PortSpec("Req", Int, :req), PortSpec("Opt", Int, :opt; required = false)],
    [PortSpec("Out", Int, :out)])
sp_relhead() = NodeSpec("Rel head",
    [PortSpec("Seed i",   Int, :seed_i), PortSpec("Seed acc", Int, :seed_acc),
     PortSpec("I back",   Int, :i_back;   kind = :feedback, required = false),
     PortSpec("Acc back", Int, :acc_back; kind = :feedback, required = false)],
    [PortSpec("I", Int, :i), PortSpec("Acc", Int, :acc)])
sp_relodd()  = NodeSpec("Rel odd", [PortSpec("I", Int, :i)],
    [PortSpec("Out", Bool, :out)])
sp_reldbl()  = NodeSpec("Rel double", [PortSpec("I", Int, :i)],
    [PortSpec("Out", Int, :out)])
sp_relgate() = NodeSpec("Rel gate",
    [PortSpec("I", Int, :i), PortSpec("Acc", Int, :acc), PortSpec("Lim", Int, :lim),
     PortSpec("Add", Int, :add; required = false)],
    [PortSpec("I", Int, :i), PortSpec("Acc", Int, :acc),
     PortSpec("Total", Int, :total; kind = :terminal)])

REL_OPT = Ref{Any}(:none)   # что потребитель прочитал на необязательном порту

function MetidaFlows.execute_unsafe!(n::DataNode{RelBoom})
    n.settings[:fail] === true && error("boom")
    setdata!(n, :out, 100 + getinputdata(n, :in))
    return [:out]
end
function MetidaFlows.execute_unsafe!(n::DataNode{RelSink})
    o = getinputdata(n, :opt)
    REL_OPT[] = o
    setdata!(n, :out, getinputdata(n, :req) + (isnothing(o) ? 0 : o))
    return [:out]
end
MetidaFlows.execute_unsafe!(n::DataNode{RelOdd}) =
    (setdata!(n, :out, isodd(getinputdata(n, :i))); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{RelDouble}) =
    (setdata!(n, :out, 2 * getinputdata(n, :i)); [:out])
function MetidaFlows.execute_unsafe!(n::DataNode{RelHead})
    b = getinputdata(n, :i_back)
    if b === nothing
        setdata!(n, :i,   getinputdata(n, :seed_i))
        setdata!(n, :acc, getinputdata(n, :seed_acc))
    else
        setdata!(n, :i,   b)
        setdata!(n, :acc, getinputdata(n, :acc_back))
    end
    return [:i, :acc]
end
function MetidaFlows.execute_unsafe!(n::DataNode{RelGate})
    i = getinputdata(n, :i); acc = getinputdata(n, :acc)
    if i >= getinputdata(n, :lim)
        setdata!(n, :total, acc)
        return [:total]
    end
    add = getinputdata(n, :add)          # nothing на чётном витке
    setdata!(n, :i,   i + 1)
    setdata!(n, :acc, acc + (isnothing(add) ? 0 : add))
    return [:i, :acc]
end

#  DAW: источник кормит и обязательный порт потребителя, и падающий узел,
#  который кормит необязательный.
function relfailgraph(fail::Bool)
    w = Workflow(0; type = :DAW)
    s = add_node!(w, DataNode(AbSrc,    sp_absrc()));   setsettings!(w, s, Dict(:value => 7))
    b = add_node!(w, DataNode(RelBoom,  sp_relboom())); setsettings!(w, b, Dict(:fail => fail))
    k = add_node!(w, DataNode(RelSink,  sp_relsink()))
    add_connection!(w, s, :out, b, :in)
    add_connection!(w, s, :out, k, :req)
    add_connection!(w, b, :out, k, :opt)
    (w = w, s = s, b = b, k = k)
end

#  ABW: цикл со СТОРОЖЕВОЙ ветвью. Сумма 2i по нечётным i < lim, причём
#  узел удвоения на чётных витках не исполняется вовсе.
function relaccgraph(lim::Int)
    w = Workflow(0; type = :ABW)
    z = add_node!(w, DataNode(AbSrc, sp_absrc())); setsettings!(w, z, Dict(:value => 0))
    a = add_node!(w, DataNode(AbSrc, sp_absrc())); setsettings!(w, a, Dict(:value => 0))
    l = add_node!(w, DataNode(AbSrc, sp_absrc())); setsettings!(w, l, Dict(:value => lim))
    h = add_node!(w, DataNode(RelHead,   sp_relhead()))
    o = add_node!(w, DataNode(RelOdd,    sp_relodd()))
    g = add_node!(w, DataNode(AbGuard,   sp_abguard()))
    d = add_node!(w, DataNode(RelDouble, sp_reldbl()))
    k = add_node!(w, DataNode(RelGate,   sp_relgate()))
    add_connection!(w, z, :out, h, :seed_i)
    add_connection!(w, a, :out, h, :seed_acc)
    add_connection!(w, h, :i,   o, :i)
    add_connection!(w, h, :i,   g, :value)      # сторож проводит i
    add_connection!(w, o, :out, g, :pass)       # ...по признаку чётности
    add_connection!(w, g, :value, d, :i)
    add_connection!(w, h, :i,   k, :i)
    add_connection!(w, h, :acc, k, :acc)
    add_connection!(w, l, :out, k, :lim)
    add_connection!(w, d, :out, k, :add)        # необязательный порт
    add_connection!(w, k, :i,   h, :i_back)
    add_connection!(w, k, :acc, h, :acc_back)
    (w = w, h = h, o = o, g = g, d = d, k = k, lim = lim)
end

#  Эталон той же суммы обычным кодом.
relref(lim::Int) = sum(2i for i in 0:lim-1 if isodd(i); init = 0)

#  Источник → flip → потребитель; второй родитель потребителя публикует
#  всегда, поэтому потребитель попадает в очередь на каждом прогоне.
function abgraph(type, sinktype, sinkspec)
    w = Workflow(0; type = type)
    s = add_node!(w, DataNode(AbSrc, sp_absrc())); setsettings!(w, s, Dict(:value => 1))
    f = add_node!(w, DataNode(AbFlip, sp_abflip()))
    k = add_node!(w, DataNode(sinktype, sinkspec))
    add_connection!(w, s, :out, f, :in)
    add_connection!(w, f, :a,   k, :p)
    add_connection!(w, s, :out, k, :q)
    (w = w, s = s, f = f, k = k)
end

# ==========================================================================

@testset verbose = true "ОТСУТСТВИЕ ПРОТИВ УСТАРЕВШЕГО                    " begin

# --------------------------------------------------------------------------
@testset "A1. invalidate_unpublished! сама по себе        " begin
    g = abgraph(:DAW, AbOpt, sp_abopt())
    node = getnode(g.w, g.f)
    #  положим значение в буфер потребителя руками
    setinputbuffer!(getnode(g.w, g.k), :p, 2, 99)
    @test getinputdata(getnode(g.w, g.k), :p) == 99

    #  публикация :b означает, что в :a не публиковали
    invalidate_unpublished!(g.w, g.f, [:b])
    @test getinputdata(getnode(g.w, g.k), :p) === nothing

    #  а если порт в списке — не трогает
    setinputbuffer!(getnode(g.w, g.k), :p, 2, 99)
    invalidate_unpublished!(g.w, g.f, [:a])
    @test getinputdata(getnode(g.w, g.k), :p) == 99

    #  узел без исходящих связей проходит без ошибки
    @test invalidate_unpublished!(g.w, g.k, Symbol[]) === g.w
end

# --------------------------------------------------------------------------
@testset "A2. контракт push_buffer! не изменился          " begin
    #  push_buffer! остался низкоуровневым: порт не в списке готовых —
    #  буфер не трогаем. Чистит именно execute!.
    g = abgraph(:DAW, AbOpt, sp_abopt())
    setinputbuffer!(getnode(g.w, g.k), :p, 2, 99)
    setdata!(getnode(g.w, g.f), :b, 1)
    push_buffer!(g.w, g.f, [:b])
    @test getinputdata(getnode(g.w, g.k), :p) == 99     # push_buffer! не чистит
end

# --------------------------------------------------------------------------
@testset "A3. необязательный порт: отсутствие отличимо    " begin
    #  ГЛАВНОЕ ИЗМЕРЕНИЕ. Раньше второй прогон видел 10.
    for type in (:DAW, :ABW)
        g = abgraph(type, AbOpt, sp_abopt())

        AB_FLAG[] = true; resetab!()
        scheduler!(g.w)
        @test AB_SEEN == [10]
        @test getdata(g.w, g.k, :out) == 10
        @test !isempty(getnode(g.w, g.k).input_buffer[:p])

        #  настройки НЕ меняем, поэтому invalidate_downstream! не
        #  вызывается и буфер чистится только новым механизмом
        AB_FLAG[] = false; resetab!()
        scheduler!(g.w)
        @test AB_SEEN == [nothing]
        @test getdata(g.w, g.k, :out) == 1              # взято :q
        @test isempty(getnode(g.w, g.k).input_buffer[:p])
        @test getstatus(getnode(g.w, g.k)) === :clean

        #  и обратно: публикация возвращает значение
        AB_FLAG[] = true; resetab!()
        scheduler!(g.w)
        @test AB_SEEN == [10]
    end
end

# --------------------------------------------------------------------------
@testset "A4. условное вычисление через nothing           " begin
    #  Способ 1: узел считается, но без охраняемого входа.
    for type in (:DAW, :ABW)
        g = abgraph(type, AbOpt, sp_abopt())
        for (flag, expected) in ((true, 10), (false, 1), (true, 10), (false, 1))
            AB_FLAG[] = flag; resetab!()
            scheduler!(g.w)
            @test getdata(g.w, g.k, :out) == expected
            @test AB_SEEN == [flag ? 10 : nothing]
        end
    end
end

# --------------------------------------------------------------------------
@testset "A5. условное вычисление через сторожа           " begin
    #  Способ 2: всё, что нужно охраняемому узлу, идёт через сторожа,
    #  поэтому при закрытом стороже узел НЕ ИСПОЛНЯЕТСЯ вовсе.
    for type in (:DAW, :ABW)
        w  = Workflow(0; type = type)
        sv = add_node!(w, DataNode(AbSrc,   sp_absrc()))
        pa = add_node!(w, DataNode(AbPass,  sp_abpass()))
        gd = add_node!(w, DataNode(AbGuard, sp_abguard()))
        us = add_node!(w, DataNode(AbUse,   sp_abuse()))
        setsettings!(w, sv, Dict(:value => 5))
        add_connection!(w, sv, :out,   gd, :value)
        add_connection!(w, pa, :out,   gd, :pass)
        add_connection!(w, gd, :value, us, :value)

        #  сторож открыт: охраняемый узел считается
        AB_PASS[] = true; resetab!()
        scheduler!(w)
        @test getnode(w, us).state.exec_n == 1
        @test getdata(w, us, :out) == 10
        @test AB_SEEN == [5]

        #  закрыт: не считается вовсе, и значение прошлого прогона в его
        #  буфере не остаётся
        AB_PASS[] = false; resetab!()
        scheduler!(w)
        @test getnode(w, us).state.exec_n == 0
        @test isempty(AB_SEEN)
        @test getstatus(getnode(w, us)) === :dirty
        @test isempty(getnode(w, us).input_buffer[:value])
        @test getdata(w, us, :out) === nothing

        #  снова открыт — считается опять
        AB_PASS[] = true; resetab!()
        scheduler!(w)
        @test getnode(w, us).state.exec_n == 1
        @test AB_SEEN == [5]
    end
end

# --------------------------------------------------------------------------
@testset "A6. обязательный порт: оба движка одинаково     " begin
    #  Производитель замолчал, а порт потребителя ОБЯЗАТЕЛЬНЫЙ. Теперь
    #  `isready` это видит: родитель :clean, но в нужный порт не
    #  публиковал, значит значения не будет — узел не готов и не
    #  исполняется, оставаясь :dirty. Оба движка ведут себя одинаково.
    #
    #  Было иначе: DAW отвечал :invalid_node (ярлык врал — узел настроен
    #  правильно), а ABW вызывал тело с nothing, и оно падало внутри
    #  себя (:failed, MethodError в журнале).
    for type in (:DAW, :ABW)
        g = abgraph(type, AbReq, sp_abreq())
        AB_FLAG[] = true; resetab!(); scheduler!(g.w)
        @test AB_SEEN == [10]
        @test getstatus(getnode(g.w, g.k)) === :clean

        AB_FLAG[] = false; resetab!(); scheduler!(g.w)
        @test getstatus(getnode(g.w, g.k)) === :dirty
        @test getnode(g.w, g.k).state.exec_n == 0
        @test isempty(AB_SEEN)                             # тело не вызывалось
        @test isempty([m for m in g.w.log if m.level === :error])
        @test getdata(g.w, g.k, :out) === nothing

        #  и вернулось, когда производитель заговорил снова
        AB_FLAG[] = true; resetab!(); scheduler!(g.w)
        @test AB_SEEN == [10]
    end

    #  ГРАНИЦА. Порт без связи вовсе — другой случай: `isready` ходит по
    #  связям и такого порта не видит. Его ловит проверка обязательных
    #  буферов, и её теперь делают оба движка, поэтому статус другой —
    #  :invalid_node, то есть структурная ошибка, а не «не посчитан».
    for type in (:DAW, :ABW)
        w = Workflow(0; type = type)
        s = add_node!(w, DataNode(AbSrc, sp_absrc())); setsettings!(w, s, Dict(:value => 9))
        k = add_node!(w, DataNode(AbReq, sp_abreq()))
        add_connection!(w, s, :out, k, :q)                 # :p не подключён
        resetab!(); scheduler!(w)
        @test getstatus(getnode(w, k)) === :invalid_node
        @test getnode(w, k).state.exec_n == 0
        @test isempty(AB_SEEN)
    end
end

# --------------------------------------------------------------------------
@testset "A7. обратные буферы не чистятся                 " begin
    #  Ворота на последнем витке публикуют только терминальный порт, то
    #  есть в петлевой порт НЕ публикуют. Если бы его буфер чистился,
    #  сломались бы и цикл, и продолжение с :soft.
    w  = Workflow(0; type = :ABW)
    cs = add_node!(w, DataNode(AbSrc, sp_absrc())); setsettings!(w, cs, Dict(:value => 1))
    cl = add_node!(w, DataNode(AbSrc, sp_absrc())); setsettings!(w, cl, Dict(:value => 6))
    hd = add_node!(w, DataNode(AbHead, sp_abhead()))
    gt = add_node!(w, DataNode(AbGate, sp_abgate()))
    add_connection!(w, cs, :out, hd, :seed)
    add_connection!(w, hd, :out, gt, :in)
    add_connection!(w, cl, :out, gt, :lim)
    add_connection!(w, gt, :out, hd, :back)

    scheduler!(w; maxiter = 10_000)
    @test getdata(w, gt, :total) == 6
    #  состояние цикла на месте, несмотря на то что последний виток в
    #  петлевой порт не публиковал
    @test !isempty(getnode(w, hd).input_buffer[:back])
    @test getinputdata(getnode(w, hd), :back) == 6
    @test getportspec(getnode(w, hd), :back, :input).kind === :feedback

    #  и продолжение с :soft работает
    scheduler!(w; reset_mode = :soft, maxiter = 10_000)
    @test getdata(w, gt, :total) == 6
end

# --------------------------------------------------------------------------
@testset "A8. release_optional на DAW                     " begin
    #  Производитель необязательного порта упал. Топологический порядок
    #  уже гарантирует, что свой шанс он использовал, поэтому ждать его
    #  нечего — но без флага потребитель всё равно пропускается.
    REL_OPT[] = :none
    g = relfailgraph(true)
    scheduler!(g.w)
    @test getstatus(getnode(g.w, g.b)) === :failed
    @test getstatus(getnode(g.w, g.k)) === :dirty      # не исполнялся
    @test getnode(g.w, g.k).state.exec_n == 0
    @test REL_OPT[] === :none
    @test getdata(g.w, g.k, :out) === nothing

    #  С флагом тот же граф досчитывается, и потребитель читает nothing
    REL_OPT[] = :none
    g = relfailgraph(true)
    scheduler!(g.w; release_optional = true)
    @test getstatus(getnode(g.w, g.b)) === :failed     # упавший так и упал
    @test getstatus(getnode(g.w, g.k)) === :clean
    @test getnode(g.w, g.k).state.exec_n == 1
    @test REL_OPT[] === nothing                        # именно отсутствие
    @test getdata(g.w, g.k, :out) == 7                 # 7 + 0

    #  Флаг не меняет ничего там, где никто не заблокирован
    for rel in (false, true)
        REL_OPT[] = :none
        g = relfailgraph(false)
        scheduler!(g.w; release_optional = rel)
        @test getstatus(getnode(g.w, g.k)) === :clean
        @test REL_OPT[] == 107
        @test getdata(g.w, g.k, :out) == 114
    end

    #  Обязательный порт флаг НЕ ослабляет: тот же граф, но вход :opt
    #  объявлен обязательным — потребитель остаётся непосчитанным.
    w = Workflow(0; type = :DAW)
    s = add_node!(w, DataNode(AbSrc,   sp_absrc()));   setsettings!(w, s, Dict(:value => 7))
    b = add_node!(w, DataNode(RelBoom, sp_relboom())); setsettings!(w, b, Dict(:fail => true))
    k = add_node!(w, DataNode(AbReq,   sp_abreq()))    # оба порта обязательны
    add_connection!(w, s, :out, b, :in)
    add_connection!(w, s, :out, k, :q)
    add_connection!(w, b, :out, k, :p)
    scheduler!(w; release_optional = true)
    @test getstatus(getnode(w, k)) === :dirty
    @test getnode(w, k).state.exec_n == 0
end

# --------------------------------------------------------------------------
@testset "A9. release_optional на ABW: условная ветвь      " begin
    #  Сторож глушит ветвь удвоения на чётных витках. Без флага граф
    #  встаёт на первом же из них: потребитель ждёт `:clean` от узла,
    #  который не исполнялся. Прогон не падает — очередь просто пустеет.
    g = relaccgraph(6)
    scheduler!(g.w; maxiter = 10_000)
    @test getdata(g.w, g.k, :total) === nothing
    @test getnode(g.w, g.h).state.exec_n == 1          # встал на первом витке
    @test getstatus(getnode(g.w, g.d)) === :dirty
    @test isempty(failed_nodes(g.w))                   # и это НЕ отказ

    #  С флагом та же ветвь срастается обратно, и сумма сходится с
    #  эталоном. Узел удвоения исполняется только на нечётных витках —
    #  это и есть экономия, которой сторож ради и ставится.
    #
    #  Счёт идёт по 0:lim, а не по 0:lim-1: проверка выхода стоит в
    #  воротах, то есть В КОНЦЕ витка, поэтому на завершающем витке
    #  (i == lim) ветвь считается и выбрасывается. На нечётном lim это
    #  одно лишнее удвоение — та же цена постпроверки, что лишнее
    #  возведение в квадрат в графе степени. В сумму оно не попадает:
    #  ворота публикуют только :total.
    for lim in (1, 2, 4, 6, 10, 21)
        g = relaccgraph(lim)
        scheduler!(g.w; maxiter = 10_000, release_optional = true)
        @test getdata(g.w, g.k, :total) == relref(lim)
        @test getnode(g.w, g.d).state.exec_n == count(isodd, 0:lim)
        #  но экономия всё равно есть: без сторожа узел считал бы каждый виток
        @test getnode(g.w, g.d).state.exec_n <= lim + 1
        @test getnode(g.w, g.h).state.exec_n == lim + 1
        #  один раз за прогон в журнал пишется, что кого-то выпустили
        @test count(m -> occursin("release_optional", m.message), g.w.log) == 1
    end

    #  release_optional_blocked! сама по себе: кого выпускает и кого нет
    g = relaccgraph(6)
    scheduler!(g.w; maxiter = 10_000)                  # довести до затишья
    queue = Int[]; queued = Set{Int}(); released = Set{Int}()
    n = release_optional_blocked!(g.w, queue, queued, released)
    @test n == 1
    @test queue == [g.k]                               # только ворота
    @test released == Set([g.k])
    @test !(g.d in released)                           # у удвоения вход обязательный
    #  повторный вызов на том же затишье выпускает то же самое
    @test release_optional_blocked!(g.w, Int[], Set{Int}(), Set{Int}()) == 1
end

# --------------------------------------------------------------------------
@testset "A10. протухший буфер и isready(wait_optional)   " begin
    #  Производитель не исполнялся вовсе, поэтому ни
    #  invalidate_unpublished!, ни mark_dirty_downstream! его значение с
    #  потребителя не снимают. Снимает invalidate_stale_optional!.
    g = relaccgraph(6)
    scheduler!(g.w; maxiter = 10_000)                  # встало на витке 1
    #  на первом витке i = 0, чётное: удвоение не исполнялось, буфер пуст
    @test isempty(getnode(g.w, g.k).input_buffer[:add])

    #  Доведём граф до состояния, где в буфере ЕСТЬ значение прошлого
    #  витка: два витка с флагом, затем проверим, что на чётном витке
    #  ворота читают nothing, а не прошлое удвоение.
    g = relaccgraph(4)
    scheduler!(g.w; maxiter = 10_000, release_optional = true)
    @test getdata(g.w, g.k, :total) == relref(4)       # 2 + 6 = 8
    @test relref(4) == 8

    #  invalidate_stale_optional! по отдельности: буфер набит вручную,
    #  производитель :dirty — значение снимается; :clean — остаётся.
    g  = relaccgraph(6)
    gk = getnode(g.w, g.k)
    cid = first(k for (k, c) in g.w.connections
                if c.input_id == g.k && c.input_port === :add)
    setinputbuffer!(gk, :add, cid, 999)
    @test getstatus(getnode(g.w, g.d)) !== :clean
    invalidate_stale_optional!(g.w, g.k)
    @test isempty(gk.input_buffer[:add])

    setinputbuffer!(gk, :add, cid, 999)
    MetidaFlows.setstatus!(getnode(g.w, g.d), :clean)
    invalidate_stale_optional!(g.w, g.k)
    @test gk.input_buffer[:add][cid] == 999            # родитель :clean — не наше дело

    #  обязательный порт функция не трогает ни при каком статусе родителя
    gq = getnode(g.w, g.k)
    cidq = first(k for (k, c) in g.w.connections
                 if c.input_id == g.k && c.input_port === :i)
    setinputbuffer!(gq, :i, cidq, 555)
    MetidaFlows.setstatus!(getnode(g.w, g.h), :dirty)
    invalidate_stale_optional!(g.w, g.k)
    @test gq.input_buffer[:i][cidq] == 555

    #  isready(; wait_optional = false) ослабляет ТОЛЬКО необязательные
    g = relaccgraph(6)
    scheduler!(g.w; maxiter = 10_000)
    @test !isready(g.w, g.k)                           # ждёт удвоение
    @test isready(g.w, g.k; wait_optional = false)     # а ждать нечего
    @test !isready(g.w, g.d)                           # вход обязательный
    @test !isready(g.w, g.d; wait_optional = false)    # флаг тут не помогает
end

end
