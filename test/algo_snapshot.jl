############################################################################
#
#  ЗООПАРК АЛГОРИТМОВ: СНИМОК И ПРОДОЛЖЕНИЕ
#
#
############################################################################

import MetidaFlows: NODE_REGISTER, register_node!, unregister_all!, isregistered,
    workflow_to_dict, dict_to_workflow, node_to_dict, getstate, getstatus,
    getnode, getconnection, nodetypestr, getportspec, setinputbuffer!,
    invalidate_buffer!, reset!, settings_schema

# --------------------------------------------------------------------------
#  Расширенный снимок: то, чего в `workflow_to_dict` нет. Написан на
#  уровне пользователя, движок не меняется — это предложение формата, а не
#  обход ограничения.
#
#  Значения здесь — Float64, Int и Bool, то есть JSON-овые как есть. Для
#  произвольных настроек понадобился бы кодек с тегами (Symbol, Tuple и
#  прочее), но это ортогонально сценарию.
# --------------------------------------------------------------------------

function full_snapshot(w)
    d = workflow_to_dict(w)
    d["__settings"] = Dict(string(id) => Dict(string(k) => v for (k, v) in n.settings)
                           for (id, n) in w.nodes)
    d["__buffers"]  = Dict(string(id) =>
                             Dict(string(port) => Dict(string(con) => v for (con, v) in buf)
                                  for (port, buf) in n.input_buffer)
                           for (id, n) in w.nodes)
    return d
end

function full_restore(d)
    w = dict_to_workflow(d)
    # сначала настройки: setsettings! инвалидирует потомков и может
    # очистить буферы, поэтому буферы восстанавливаем после
    for (sid, kv) in d["__settings"]
        isempty(kv) && continue
        setsettings!(w, parse(Int, sid), Dict(Symbol(k) => v for (k, v) in kv))
    end
    for (sid, ports) in d["__buffers"]
        node = getnode(w, parse(Int, sid))
        for (port, buf) in ports, (con, value) in buf
            setinputbuffer!(node, Symbol(port), parse(Int, con), value)
        end
    end
    return w
end

# Настройки графа спуска, одни на все группы файла.
snapshot_params() = (x0 = 0.0, rate = 0.1, tol = 1e-6, h = 1e-5, c = 3.0)

# Зарегистрировать все типы узлов графа: без этого dict_to_workflow не
# восстановит ни один узел. Типов тринадцать, узлов двадцать шесть,
# поэтому skipmode обязателен.
function registered_descent(; maxiter = 1000)
    g = build_descent(; snapshot_params()..., maxiter = maxiter)
    register_node!(g.w; skipmode = true)
    return g
end

# ==========================================================================

@testset verbose = true "СНИМОК И ПРОДОЛЖЕНИЕ                             " begin

# --------------------------------------------------------------------------
@testset "S1. что снимок несёт, а что нет                  " begin
    unregister_all!()
    g = registered_descent()
    resetdescent!(); scheduler!(g.w; maxiter = 200_000)
    @test getdata(g.w, g.gate, :reason) === :converged   # граф посчитан

    # все тринадцать типов в реестре
    @test length(NODE_REGISTER) == 13
    @test all(isregistered(n) for (_, n) in g.w.nodes)

    w2 = dict_to_workflow(workflow_to_dict(g.w))

    # --- СТРУКТУРА восстановлена полностью
    @test length(w2.nodes)       == length(g.w.nodes)
    @test length(w2.connections) == length(g.w.connections)
    @test w2.incoming == g.w.incoming
    @test w2.outgoing == g.w.outgoing
    @test w2.n_iter == g.w.n_iter
    @test w2.name   == g.w.name
    @test w2 isa Workflow{ABW}
    for id in keys(g.w.nodes)
        @test nodetypestr(getnode(w2, id)) == nodetypestr(getnode(g.w, id))
    end
    # спеки пришли из реестра, вид портов сохранён
    @test getportspec(getnode(w2, g.head), :x, :input).kind      == :feedback
    @test getportspec(getnode(w2, g.gate), :reason, :output).kind == :terminal
    @test getporttype(getnode(w2, g.head), :x, :output) === Float64

    # --- ЧЕГО В СНИМКЕ НЕТ
    # 1. значения настроек: под ключом "settings" лежит схема
    nd = node_to_dict(getnode(g.w, g.cx0))
    @test nd["settings"] == settings_schema(getnode(g.w, g.cx0))
    @test haskey(nd["settings"], "settingslist")
    @test all(isempty(n.settings) for (_, n) in w2.nodes)
    # 2. содержимое входных буферов — в том числе обратных портов головы
    @test all(all(isempty(b) for (_, b) in n.input_buffer) for (_, n) in w2.nodes)
    # 3. кеш выходных данных
    @test all(isempty(n.data) for (_, n) in w2.nodes)
    # 4. состояние исполнения и журнал
    @test all(getstate(n, :exec_n) == 0 for (_, n) in w2.nodes)
    @test all(getstatus(n) == :dirty for (_, n) in w2.nodes)
    @test w2.run_id == 0
    @test isempty(w2.log)
end

# --------------------------------------------------------------------------
@testset "S2. загруженный граф не может считать            " begin
    unregister_all!()
    g = registered_descent()
    resetdescent!(); scheduler!(g.w; maxiter = 200_000)

    w2 = dict_to_workflow(workflow_to_dict(g.w))
    resetdescent!()
    @test scheduler!(w2; maxiter = 200_000) === true     # не ошибка, просто ничего

    # источники падают: settings[:value] нет
    for id in (g.cx0, g.crate, g.ctol, g.ch, g.cc, g.ci0, g.cone, g.cmax)
        @test getstatus(getnode(w2, id)) == :failed
    end
    # тело так и не запустилось
    @test getstate(getnode(w2, g.head), :exec_n) == 0
    @test isempty(DESCENT_TRACE)
    @test getdata(w2, g.gate, :minimum) === nothing
    @test getdata(w2, g.gate, :reason)  === nothing

    # отказ записан в журнал, и в нём виден KeyError по ключу настройки
    @test !isempty(w2.log)
    @test any(occursin("KeyError", m.message) for m in w2.log)
    @test any(occursin("value", m.message) for m in w2.log)
end

# --------------------------------------------------------------------------
@testset "S3. продолжения нет: цикл начинается заново      " begin
    unregister_all!()
    # эталон: непрерывный прогон
    gfull = registered_descent()
    resetdescent!(); scheduler!(gfull.w; maxiter = 200_000)
    full_trace = copy(DESCENT_TRACE)
    full_iter  = getdata(gfull.w, gfull.gate, :iterations)
    @test full_iter == 71
    @test length(full_trace) == 71

    # прогон, оборванный на двадцатой итерации лимитом САМОГО АЛГОРИТМА
    gcut = registered_descent(maxiter = 20)
    resetdescent!(); scheduler!(gcut.w; maxiter = 200_000)
    cut_trace = copy(DESCENT_TRACE)
    @test getdata(gcut.w, gcut.gate, :reason) === :exhausted
    @test length(cut_trace) == 20
    @test cut_trace == full_trace[1:20]              # до обрыва шли одинаково

    # снимок, загрузка, руками возвращаем настройки (их в снимке нет) и
    # поднимаем лимит алгоритма, чтобы он мог дойти до сходимости
    w3 = dict_to_workflow(workflow_to_dict(gcut.w))
    for (id, value) in ((gcut.cx0, 0.0), (gcut.crate, 0.1), (gcut.ctol, 1e-6),
                        (gcut.ch, 1e-5), (gcut.cc, 3.0))
        setsettings!(w3, id, Dict(:value => value))
    end
    setsettings!(w3, gcut.ci0,  Dict(:value => 0))
    setsettings!(w3, gcut.cone, Dict(:value => 1))
    setsettings!(w3, gcut.cmax, Dict(:value => 1000))

    resetdescent!(); scheduler!(w3; maxiter = 200_000)
    resumed = copy(DESCENT_TRACE)

    # ПОШЁЛ С НАЧАЛА: обратный буфер головы пуст, взята начальная точка
    @test resumed[1] === full_trace[1]
    @test resumed == full_trace                      # полный повтор, не продолжение
    @test getdata(w3, gcut.gate, :iterations) == 71
    # итого работы: 20 + 71 вместо 71
    @test length(cut_trace) + length(resumed) == 91
end

# --------------------------------------------------------------------------
@testset "S4. минимальное расширение снимка                " begin
    unregister_all!()
    gfull = registered_descent()
    resetdescent!(); scheduler!(gfull.w; maxiter = 200_000)
    full_trace = copy(DESCENT_TRACE)
    full_x     = getdata(gfull.w, gfull.gate, :minimum)

    # обрываем на двадцатой итерации и снимаем РАСШИРЕННЫЙ снимок
    gcut = registered_descent(maxiter = 20)
    resetdescent!(); scheduler!(gcut.w; maxiter = 200_000)
    cut_trace = copy(DESCENT_TRACE)
    d = full_snapshot(gcut.w)

    # в расширенном снимке появилось ровно две вещи
    @test haskey(d, "__settings")
    @test haskey(d, "__buffers")
    @test d["__settings"][string(gcut.cx0)]["value"] === 0.0
    # обратный порт головы заполнен состоянием цикла
    head_x = d["__buffers"][string(gcut.head)]["x"]
    @test !isempty(head_x)
    @test only(values(head_x)) === cut_trace[19]     # состояние ПРЕДЫДУЩЕГО витка

    # загрузка и продолжение. Статусы и кеш данных НЕ восстанавливаем:
    # :soft помечает всё :dirty и пересчитывает из состояния цикла.
    w4 = full_restore(d)
    setsettings!(w4, gcut.cmax, Dict(:value => 1000))  # поднять лимит алгоритма
    @test !isempty(getnode(w4, gcut.head).input_buffer[:x])

    resetdescent!()
    scheduler!(w4; reset_mode = :soft, maxiter = 200_000)
    resumed = copy(DESCENT_TRACE)

    # ПРОДОЛЖЕНИЕ РАБОТАЕТ: та же точка, то же число итераций
    @test getdata(w4, gcut.gate, :reason) === :converged
    @test getdata(w4, gcut.gate, :minimum) === full_x
    @test getdata(w4, gcut.gate, :iterations) == 71

    # и траектория склеивается с непрерывной побитово. Последний виток
    # повторяется: останавливаясь, ворота публикуют терминальные порты и
    # НЕ пишут в обратный, поэтому в буфере осталось состояние витка 19.
    @test length(resumed) == 71 - 19
    @test [cut_trace[1:19]; resumed] == full_trace
    @test resumed[1] === cut_trace[20]               # виток 20 посчитан заново

    # без обратных буферов то же расширение не помогает — проверяем, что
    # работает именно состояние цикла, а не возвращённые настройки
    d2 = full_snapshot(gcut.w)
    for (_, ports) in d2["__buffers"]
        for (port, buf) in ports
            port == "x" && empty!(buf)
            port == "iter" && empty!(buf)
        end
    end
    w5 = full_restore(d2)
    setsettings!(w5, gcut.cmax, Dict(:value => 1000))
    resetdescent!()
    scheduler!(w5; reset_mode = :soft, maxiter = 200_000)
    @test DESCENT_TRACE == full_trace                # снова с начала
end

# --------------------------------------------------------------------------
@testset "S5. проверка связей при загрузке                 " begin
    # `dict_to_workflow` зовёт check_connection_validity на каждую связь.
    # Что это ловит, а что нет.
    unregister_all!()
    g = registered_descent()
    base() = workflow_to_dict(g.w)

    raised(f) = try (f(); false) catch; true end

    # ловит: порта нет в спецификации
    bad = base()
    first(values(bad["connections"]))["output_port"] = :nosuch
    @test raised(() -> dict_to_workflow(bad))

    # ловит: ссылка на отсутствующую ноду
    ghost = base()
    ghost["connections"]["9999"] = Dict{String, Any}(
        "output_id" => 777, "output_port" => :out,
        "input_id"  => g.gate, "input_port" => :stop)
    @test raised(() -> dict_to_workflow(ghost))

    # НЕ ЛОВИТ: вторая связь в SinglePort. check_connection_validity ищет
    # занятость порта в model.incoming, а индекс наполняется только
    # refreshind! в самом конце — во время цикла он пуст.
    two = base()
    two["connections"]["9999"] = Dict{String, Any}(
        "output_id" => g.stop, "output_port" => :out,
        "input_id"  => g.gate, "input_port"  => :stop)
    w = dict_to_workflow(two)
    @test length(w.connections) == length(g.w.connections) + 1
    @test length(w.incoming[g.gate]) == length(g.w.incoming[g.gate]) + 1
    # add_connection! ту же связь отвергает — проверка есть, на загрузке молчит
    @test raised(() -> add_connection!(g.w, g.stop, :out, g.gate, :stop))

    # с throw_error = false негодные связи молча отбрасываются
    dropped = base()
    first(values(dropped["connections"]))["output_port"] = :nosuch
    w2 = dict_to_workflow(dropped; check_connection_throw_error = false)
    @test length(w2.connections) == length(g.w.connections) - 1

    # с check_connection = false не проверяется ничего
    w3 = dict_to_workflow(ghost; check_connection = false)
    @test length(w3.connections) == length(g.w.connections) + 1
    @test haskey(w3.outgoing, 777)                   # призрак в индексе
end

end # @testset "СНИМОК И ПРОДОЛЖЕНИЕ"
