############################################################################
#
#  MetidaFlows.jl — набор тестов
#
#  Тесты разбиты на категории, каждая в своём файле. Категория отвечает
#  на один вопрос о пакете:
#
#    api           — что делает каждая функция (контракт вызова);
#    scenarios     — работает ли пакет целиком на реальных данных;
#    semantics     — верна ли модель состояний и инвалидации;
#    errors        — сообщает ли пакет об ошибках и как именно;
#    edge          — не разваливается ли он на вырожденных данных;
#    serialization — корректно ли выгружается структура workflow;
#    display       — видно ли пользователю содержимое объектов.
#
#  Общие фикстуры (типы нод, спецификации, реализации execute_unsafe!)
#  объявлены один раз в fixtures.jl и переиспользуются всеми категориями.
#
############################################################################

using MetidaFlows
using Test, CSV, DataFrames, Dates

import MetidaFlows: PortSpec, MultiPort, SinglePort, DAW, ABW,
    NodeState, NodeProperties, LogMsg, AbstractNodeState, ExecuteSettings,
    setdata!,
    getnode, getconnection, isnodeexist, nodetypestr, makegraph,
    getid, setid!, getposition, setposition!, setstatus!,
    getstate, setstate!, setreadyports!,
    haveinputs, getportnumber, getporttype, getportspec,
    isportexist, isportinspec, ismultiport,
    setinputbuffer!, invalidate_buffer!, invalidate_downstream!,
    find_connections, getportconnections, get_parents, get_children,
    reset!, reset_status!, mark_dirty!, setsettings_unsafe!, isready,
    validate_node, validate_settings, validate_result, execution_node_validation,
    push_buffer!,
    settings_schema, settings_schema_usermod!, node_schema, node_schema_usermod!,
    node_to_dict, node_properties_to_dict, spec_to_dict,
    portspec_to_dict, portspec_to_dict_type, connection_to_dict, workflow_to_dict,
    exportmeta, getinputmeta

# Здесь и ниже намеренно без `const`: при повторном include в одной сессии
# переопределение const печатает WARNING: redefinition of constant.
TEST_DIR = dirname(@__FILE__)

include(joinpath(TEST_DIR, "fixtures.jl"))

TEST_GROUPS = (
    (id = "api",           file = "test_api.jl", descr = "контракт каждой публичной функции"),
    (id = "scenarios",     file = "test_scenarios.jl", descr = "сквозные конвейеры на CSV/DataFrames"),
    (id = "semantics",     file = "test_semantics.jl", descr = "статусы, инвалидация, кеширование"),
    (id = "errors",        file = "test_errors.jl", descr = "исключения, статусы отказа, предупреждения"),
    (id = "cycles",        file = "test_cycles.jl", descr = "циклические графы ABW, петли и ромб внутри цикла"),
    (id = "edge",          file = "test_edge.jl", descr = "нулевые, единичные и вырожденные случаи"),
    (id = "serialization", file = "test_serialization.jl", descr = "словарные представления и схемы"),
    (id = "display",       file = "test_display.jl", descr = "методы show"),
    (id = "exportmeta",    file = "test_exportmeta.jl", descr = "Export/query метаданных для портов"),
)

SELECTED = isempty(ARGS) ? [g.id for g in TEST_GROUPS] : ARGS

for g in TEST_GROUPS
    mark = g.id in SELECTED ? "+" : " "
    #println(" [$mark] $(rpad(g.id, 14)) $(g.descr)")
end
#println()

@testset "MetidaFlows.jl                                   " begin
    for g in TEST_GROUPS
        g.id in SELECTED || continue
        include(joinpath(TEST_DIR, g.file))
    end
end
