############################################################################
#
#  КАТЕГОРИЯ: СЕРИАЛИЗАЦИЯ И СХЕМЫ
#
#  Назначение: проверить слой преобразования объектов в словари —
#  то, через что workflow выгружается в JSON и описывается редактору.
#
#  Проверяется три вещи:
#    * состав и типы ключей каждого словаря;
#    * что сериализация описывает СТРУКТУРУ и не тянет за собой
#      состояние исполнения (run_id, логи, кеш данных);
#    * что пользовательские хуки *_usermod! действительно вызываются
#      и их результат попадает в итоговую схему.
#
############################################################################

@testset "СЕРИАЛИЗАЦИЯ                                     " begin

# --------------------------------------------------------------------------
@testset "R1. описание порта                               " begin
    d = portspec_to_dict(PortSpec("Value", Float64, :val, MultiPort(); required = false))
    @test d["name"]     == "Value"
    @test d["label"]    == "val"
    @test d["datatype"] == string(Float64)
    @test d["required"] == false
    @test d["type"]     == "MultiPort"

    s = portspec_to_dict(PortSpec("Single", Int, :s))
    @test s["type"]     == "SinglePort"
    @test s["required"] == true

    # Отдельная функция определения арности.
    @test portspec_to_dict_type(PortSpec("s", Int, :s))                == "SinglePort"
    @test portspec_to_dict_type(PortSpec("m", Int, :m, MultiPort()))   == "MultiPort"
end

# --------------------------------------------------------------------------
@testset "R2. описание спецификации                        " begin
    d = spec_to_dict(spec_add())
    @test d["name"] == "Add"
    @test length(d["input_ports"])  == 2
    @test length(d["output_ports"]) == 1
    @test d["settings"] == Symbol[]
    @test d["input_ports"][1]["label"]  == "a"     # метки сериализуются строками
    @test d["input_ports"][2]["label"]  == "b"
    @test d["output_ports"][1]["label"] == "out"

    @test spec_to_dict(spec_const())["settings"] == [:value]
    @test isempty(spec_to_dict(spec_noports())["input_ports"])
end

# --------------------------------------------------------------------------
@testset "R3. описание свойств и связи                     " begin
    p = node_properties_to_dict(NodeProperties(3, :clean, (5, 6)))
    @test p["id"]       == 3
    @test p["status"]   == :clean
    @test p["position"] == (5, 6)

    c = connection_to_dict(NodeConnection(1, :a, 2, :b))
    @test c["output_id"]   == 1
    @test c["output_port"] == :a
    @test c["input_id"]    == 2
    @test c["input_port"]  == :b
end

# --------------------------------------------------------------------------
@testset "R4. описание ноды                                " begin
    n = DataNode(ConstNode, spec_const())
    setsettings_unsafe!(n, Dict(:value => 42))
    setdata!(n, :out, 42)

    d = node_to_dict(n)
    @test d["id"]     == getid(n)
    @test d["status"] == :idle
    @test d["properties"]["position"] == (0, 0)
    @test haskey(d, "spec") && haskey(d, "settings")

    # ВАЖНО: ключ "settings" содержит СХЕМУ настроек, а не их значения.
    @test d["settings"]["settingslist"] == [:value]
    @test collect(keys(d["settings"])) == ["settingslist"]

    # Кеш выходных данных в словарь не попадает.
    @test !haskey(d, "data")

    # Обе части описания отключаются флагами.
    d2 = node_to_dict(n; specs = false, settings = false)
    @test !haskey(d2, "spec")
    @test !haskey(d2, "settings")
    @test haskey(d2, "id") && haskey(d2, "status")
    @test haskey(node_to_dict(n; specs = false), "settings")
end

# --------------------------------------------------------------------------
@testset "R5. схемы и пользовательские хуки                " begin
    plain_spec = spec_const()
    plain = DataNode(ConstNode, plain_spec)
    node  = DataNode(SchemaNode, spec_schema())

    # Реализация по умолчанию отдаёт только список ключей настроек.
    ss = settings_schema(plain)
    @test ss["settingslist"] == [:value]
    @test length(keys(ss)) == 1

    # Список копируется: мутация результата не затрагивает спецификацию.
    push!(ss["settingslist"], :injected)
    @test plain_spec.settings == [:value]

    # Специализация settings_schema_usermod! добавляет свои ключи.
    us = settings_schema(node)
    @test us["settingslist"] == [:alpha, :beta]
    @test haskey(us, "schema")
    @test us["schema"][:alpha][:type] === Int

    # node_schema собирает спецификацию и схему настроек вместе.
    ns = node_schema(node)
    @test ns["spec"]["name"] == "Schema"
    @test ns["settings_schema"]["settingslist"] == [:alpha, :beta]
    @test ns["color"] == "#8b5cf6"                    # хук node_schema_usermod!

    # Для ноды без специализаций хуки — тождественные.
    np = node_schema(plain)
    @test !haskey(np, "color")
    @test np["settings_schema"]["settingslist"] == [:value]
end

# --------------------------------------------------------------------------
@testset "R6. полный снимок workflow                       " begin
    p = build_pipeline()
    w = p.w
    w.name = "pipeline"
    scheduler!(w)

    d = workflow_to_dict(w)
    @test d["id"]     == 0
    @test d["name"]   == "pipeline"
    @test d["n_iter"] == 3
    @test d["c_iter"] == 2

    # Ноды и связи — по строковым ключам.
    @test Set(keys(d["nodes"]))       == Set(["1", "2", "3"])
    @test Set(keys(d["connections"])) == Set(["1", "2"])
    @test d["nodes"][string(p.load)]["spec"]["name"] == "Load CSV"
    @test d["connections"]["1"]["output_id"] == p.load

    # Индексы зависимостей — по числовым.
    @test d["incoming"][p.todf] == [1]
    @test d["outgoing"][p.load] == [1]

    # Состояние исполнения в снимок не входит.
    @test !haskey(d, "run_id")
    @test !haskey(d, "log")
    @test !haskey(d, "audit_log")

    # Копии индексов независимы от workflow.
    push!(d["outgoing"][p.load], 999)
    @test w.outgoing[p.load] == [1]

    unregister_all!()
    register_node!(w)
    @test_nowarn dict_to_workflow(d)
end

# --------------------------------------------------------------------------
@testset "R7. реестр: граф целиком                         " begin
    #  Реестр — шлюз загрузки, поэтому первое, что делает человек, —
    #  регистрирует типы целым графом. На графе с ДВУМЯ узлами одного
    #  типа это падало: второй узел считался повторной регистрацией.
    #  Теперь тип вносится один раз за вызов, из первого своего узла.
    w  = Workflow(0; type = :DAW)
    a  = add_node!(w, DataNode(LoadCSVNode, spec_loadcsv()))
    b  = add_node!(w, DataNode(LoadCSVNode, spec_loadcsv()))   # тот же тип
    c  = add_node!(w, DataNode(ToDataFrameNode, spec_todf()))
    add_connection!(w, a, :csv, c, :csv)

    unregister_all!()
    names = register_node!(w)                      # без skipmode — и не падает
    @test length(names) == 2                       # два РАЗНЫХ типа, не три узла
    @test names == sort(names)                     # порядок не зависит от обхода Dict
    @test allunique(names)
    @test isregistered(getnode(w, a)) && isregistered(getnode(w, c))

    #  Ключ, занятый ДО вызова, — по-прежнему ошибка с подсказкой
    @test_throws ErrorException register_node!(w)
    @test_nowarn register_node!(w; skipmode = true)
    @test register_node!(w; skipmode = true) == String[]   # добавлять нечего
    @test length(register_node!(w; overwrite = true)) == 2 # а перезаписать можно

    #  и граф из одних одинаковых узлов тоже регистрируется
    w2 = Workflow(0; type = :DAW)
    for _ in 1:5 add_node!(w2, DataNode(LoadCSVNode, spec_loadcsv())) end
    unregister_all!()
    @test length(register_node!(w2)) == 1

    #  после этого снимок такого графа загружается
    d2 = workflow_to_dict(w2)
    @test length(dict_to_workflow(d2).nodes) == 5
    unregister_all!()
end

# --------------------------------------------------------------------------
@testset "R8. кодек значений: нефинитные числа             " begin
    #  Первое прямое покрытие кодека. В JSON нет ни NaN, ни Inf: голое такое
    #  число строгий писатель отвергает целиком, нестрогий отдаёт текст,
    #  который уже не JSON. Поэтому нефинитное уходит строкой под своим тегом.
    for (x, s) in ((NaN, "NaN"), (Inf, "Inf"), (-Inf, "-Inf"))
        d = value_to_dict(x)
        @test d isa Dict
        @test d["t"] == "Float64"
        @test d["v"] == s                       # именно строка, не число
        back = dict_to_value(d)
        @test typeof(back) === Float64
        @test isnan(x) ? isnan(back) : back == x
    end
    #  Финитное остаётся голым, как было в формате 1.
    @test value_to_dict(1.5) === 1.5
    @test value_to_dict(0.0) === 0.0

    #  Узкие типы идут тем же путём.
    for T in (Float32, Float16)
        d = value_to_dict(T(Inf))
        @test d["t"] == string(T) && d["v"] == "Inf"
        @test dict_to_value(d) === T(Inf)
    end

    #  Набор строк закрыт: разбора произвольного текста нет.
    @test_throws ErrorException dict_to_value(Dict("t" => "Float64", "v" => "1e300"))
end

# --------------------------------------------------------------------------
@testset "R9. в снимке не остаётся незаписываемых чисел    " begin
    #  Инвариант без зависимости от JSON-пакета: пройти снимок насквозь и
    #  убедиться, что ни одного голого нефинитного числа в нём нет. Именно
    #  это и означает «готов к сериализации в текст».
    function badfloats(x, path = "", acc = String[])
        if x isa AbstractFloat
            isfinite(x) || push!(acc, path)
        elseif x isa AbstractDict
            for (k, v) in x; badfloats(v, path * "/" * string(k), acc); end
        elseif x isa Union{AbstractVector, Tuple}
            for (i, v) in enumerate(x); badfloats(v, path * "[$i]", acc); end
        end
        acc
    end

    #  Спека объявляет все ключи: settings_to_dict пишет только объявленные,
    #  и на узкой спеке проверка оказалась бы пустой.
    wide = NodeSpec("Const", PortSpec[], [PortSpec("value", Int, :out)],
                    [:value, :thr, :lo, :vec, :pair, :inner])
    unregister_all!()
    w = Workflow(7)
    n = add_node!(w, DataNode(ConstNode, wide))
    setsettings!(w, n, Dict(:value => 1,
                            :thr   => NaN,
                            :lo    => -Inf,
                            :vec   => [1.0, Inf],
                            :pair  => (NaN, 2.0),
                            :inner => Dict(:deep => Inf),
                            :undeclared => Inf))
    register_node!(DataNode(ConstNode, wide))
    d = workflow_to_dict(w)
    @test isempty(badfloats(d))
    #  Непустая проверка: нефинитные значения в снимке есть, просто тегами.
    sv = d["nodes"][string(n)]["settings_values"]
    @test sv["thr"] == Dict("t" => "Float64", "v" => "NaN")
    #  Необъявленный ключ в снимок не попадает вовсе.
    @test !haskey(sv, "undeclared")

    #  И всё это возвращается тем же.
    s = getnode(dict_to_workflow(d), n).settings
    @test isnan(s[:thr])
    @test s[:lo] == -Inf
    @test s[:vec][2] == Inf
    @test isnan(s[:pair][1]) && s[:pair][2] == 2.0
    @test s[:inner][:deep] == Inf
    unregister_all!()
end

# --------------------------------------------------------------------------
@testset "R10. снимок объявляет, что в нём есть            " begin
    unregister_all!()
    w = Workflow(8)
    add_node!(w, DataNode(ConstNode, spec_const()))

    d = workflow_to_dict(w)
    @test d["format_version"] == SNAPSHOT_FORMAT_VERSION == 4
    c = snapshot_contents(d)
    @test c.format_version == 4
    @test c.values === true          # значения пишутся по умолчанию
    @test c.state  === false         # состояние — нет
    @test c.audit_log === false

    c2 = snapshot_contents(workflow_to_dict(w; values = false, state = true))
    @test c2.values === false && c2.state === true

    #  Файл формата 1 ничего не объявляет, и честный ответ — «не известно»,
    #  а не догадка. Про журнал ответить можно: ключ либо есть, либо нет.
    d1 = workflow_to_dict(w)
    delete!(d1, "contents")
    d1["format_version"] = 1
    c3 = snapshot_contents(d1)
    @test c3.format_version == 1
    @test c3.values === missing && c3.state === missing
    @test c3.audit_log === false
    #  и он по-прежнему читается
    register_node!(DataNode(ConstNode, spec_const()))
    @test dict_to_workflow(d1) isa Workflow
    #  а из будущего — нет
    d1["format_version"] = SNAPSHOT_FORMAT_VERSION + 1
    @test_throws ErrorException dict_to_workflow(d1)
    unregister_all!()
end

end # @testset "СЕРИАЛИЗАЦИЯ"

include(joinpath(TEST_DIR, "serialization_state.jl"))
