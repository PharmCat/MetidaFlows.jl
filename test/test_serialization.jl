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
end

end # @testset "СЕРИАЛИЗАЦИЯ"
