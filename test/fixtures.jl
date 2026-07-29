############################################################################
#
#  fixtures.jl — общие фикстуры для всех категорий тестов
#
#  Здесь один раз объявлены:
#    * типы поведения нод (подтипы AbstractNodeType);
#    * спецификации портов (функции, возвращающие свежий NodeSpec);
#    * реализации execute_unsafe! и хуков валидации;
#    * счётчик фактических исполнений CALLS;
#    * вспомогательные конструкторы графов.
#
#  Файл подключается один раз из runtests.jl ДО категорий тестов.
#  Ничего не выполняет и не содержит @testset.
#
#  Данные: test/csv/pkdata2.csv — 160 строк, 4 колонки (TSV):
#    Subject::Int (10 уникальных), Formulation::String ("T"/"R"),
#    Time::Float64, Concentration::Float64 (8 значений > 200).
#
############################################################################

const CSV_PATH = joinpath(TEST_DIR, "csv", "pkdata2.csv")

# --------------------------------------------------------------------------
# Счётчик исполнений: делает кеширование и инвалидацию наблюдаемыми.
# --------------------------------------------------------------------------

const CALLS = Dict{Symbol, Int}()

countcall!(k::Symbol) = (CALLS[k] = get(CALLS, k, 0) + 1)
calls(k::Symbol)      = get(CALLS, k, 0)
resetcalls!()         = empty!(CALLS)

# --------------------------------------------------------------------------
# Типы поведения нод
# --------------------------------------------------------------------------

# --- источники --------------------------------------------------------
struct ConstNode      <: AbstractNodeType end  # settings[:value] -> :out::Int
struct TextNode       <: AbstractNodeType end  # -> :out::String
struct LoadCSVNode    <: AbstractNodeType end  # settings[:file] -> :csv::CSV.File

# --- преобразователи --------------------------------------------------
struct DoubleNode     <: AbstractNodeType end  # :in -> :out, значение * 2
struct AddNode        <: AbstractNodeType end  # :a + :b -> :out (пустой вход = 0)
struct CollectNode    <: AbstractNodeType end  # MultiPort :ins -> :out, сумма
struct OptionalNode   <: AbstractNodeType end  # необязательный :maybe -> :out
struct AnyInNode      <: AbstractNodeType end  # вход типа Any
struct ToDataFrameNode<: AbstractNodeType end  # :csv -> :dataframe
struct FilterRowsNode <: AbstractNodeType end  # :dataframe -> :dataframe по порогу
struct SummaryNode    <: AbstractNodeType end  # :dataframe -> :nrows, :nsubjects
struct PartialOutNode <: AbstractNodeType end  # два выхода, отдаёт только один

# --- поведение при отказах -------------------------------------------
struct ErrorNode      <: AbstractNodeType end  # execute_unsafe! бросает исключение
struct UndefinedNode  <: AbstractNodeType end  # НЕТ метода execute_unsafe!
struct BadResultNode  <: AbstractNodeType end  # validate_result   -> false
struct BadStructNode  <: AbstractNodeType end  # validate_node     -> false
struct NeedsCfgNode   <: AbstractNodeType end  # validate_settings -> требует :k

# --- служебные --------------------------------------------------------
struct SelfLoopNode   <: AbstractNodeType end  # :in -> :out, для защиты от рекурсии
struct SchemaNode     <: AbstractNodeType end  # пользовательские хуки схемы

# Неизменяемое состояние: проверка Dict-подобного доступа на immutable-типе.
struct FrozenState <: AbstractNodeState
    value::Int
end

# --------------------------------------------------------------------------
# Спецификации
#
# Возвращаются функциями, а не константами: каждый тест получает свежий
# NodeSpec и не может испортить данные соседнего теста.
# --------------------------------------------------------------------------

spec_const()      = NodeSpec("Const", PortSpec[], [PortSpec("value", Int, :out)], [:value])
spec_text()       = NodeSpec("Text", PortSpec[], [PortSpec("text", String, :out)])
spec_plain(name)  = NodeSpec(name, PortSpec[], [PortSpec("value", Int, :out)])
spec_noports()    = NodeSpec("NoPorts", PortSpec[], PortSpec[])
spec_sink()       = NodeSpec("Sink", [PortSpec("value", Int, :in)], PortSpec[])

spec_double()     = NodeSpec("Double",
                             [PortSpec("value", Int, :in)],
                             [PortSpec("doubled", Int, :out)])

spec_add()        = NodeSpec("Add",
                             [PortSpec("a", Int, :a), PortSpec("b", Int, :b)],
                             [PortSpec("sum", Int, :out)])

spec_collect()    = NodeSpec("Collect",
                             [PortSpec("values", Int, :ins, MultiPort())],
                             [PortSpec("sum", Int, :out)])

spec_optional()   = NodeSpec("Optional",
                             [PortSpec("maybe", Int, :maybe, SinglePort(); required = false)],
                             [PortSpec("value", Int, :out)])

spec_anyin()      = NodeSpec("AnyIn",
                             [PortSpec("anything", Any, :in)],
                             [PortSpec("value", Int, :out)])

spec_loop()       = NodeSpec("Loop",
                             [PortSpec("in", Int, :in)],
                             [PortSpec("out", Int, :out)])

spec_partial()    = NodeSpec("Partial", PortSpec[],
                             [PortSpec("first", Int, :first), PortSpec("second", Int, :second)])

spec_cfg()        = NodeSpec("NeedsCfg", PortSpec[], [PortSpec("value", Int, :out)], [:k])
spec_schema()     = NodeSpec("Schema", PortSpec[], [PortSpec("x", Int, :out)], [:alpha, :beta])

# --- спецификации конвейера CSV -> DataFrame -------------------------
spec_loadcsv()    = NodeSpec("Load CSV", PortSpec[],
                             [PortSpec("CSV File", CSV.File, :csv)], [:file])

spec_todf()       = NodeSpec("DataFrame",
                             [PortSpec("CSV File", CSV.File, :csv)],
                             [PortSpec("DataFrame", DataFrame, :dataframe)])

spec_filter()     = NodeSpec("Filter rows",
                             [PortSpec("DataFrame", DataFrame, :dataframe)],
                             [PortSpec("DataFrame", DataFrame, :dataframe)],
                             [:column, :threshold])

spec_summary()    = NodeSpec("Summary",
                             [PortSpec("DataFrame", DataFrame, :dataframe)],
                             [PortSpec("Row count", Int, :nrows),
                              PortSpec("Subject count", Int, :nsubjects)])

# --------------------------------------------------------------------------
# Реализации execute_unsafe!
#
# Контракт: прочитать входы через getinputdata, записать выходы через
# setdata!, вернуть вектор меток фактически заполненных выходных портов.
# --------------------------------------------------------------------------

function MetidaFlows.execute_unsafe!(node::DataNode{ConstNode})
    countcall!(:const)
    setdata!(node, :out, get(node.settings, :value, 0))
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{TextNode})
    countcall!(:text)
    setdata!(node, :out, "text")
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{DoubleNode})
    countcall!(:double)
    x = getinputdata(node, :in)
    setdata!(node, :out, (x === nothing ? 0 : x) * 2)
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{AddNode})
    countcall!(:add)
    a = getinputdata(node, :a)
    b = getinputdata(node, :b)
    setdata!(node, :out, (a === nothing ? 0 : a) + (b === nothing ? 0 : b))
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{CollectNode})
    countcall!(:collect)
    # MultiPort: getinputdata возвращает весь словарь {id связи => значение}
    buffer = getinputdata(node, :ins)
    setdata!(node, :out, sum(values(buffer); init = 0))
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{OptionalNode})
    countcall!(:optional)
    v = getinputdata(node, :maybe)
    setdata!(node, :out, v === nothing ? -1 : v)
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{AnyInNode})
    countcall!(:anyin)
    setdata!(node, :out, 0)
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{PartialOutNode})
    countcall!(:partial)
    setdata!(node, :first, 1)
    # порт :second объявлен, но намеренно не заполняется и не возвращается
    return [:first]
end

function MetidaFlows.execute_unsafe!(node::DataNode{SelfLoopNode})
    countcall!(:selfloop)
    x = getinputdata(node, :in)
    setdata!(node, :out, x === nothing ? 0 : x)
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{SchemaNode})
    countcall!(:schema)
    setdata!(node, :out, 0)
    return [:out]
end

# --- конвейер CSV -> DataFrame ---------------------------------------

function MetidaFlows.execute_unsafe!(node::DataNode{LoadCSVNode})
    countcall!(:loadcsv)
    setdata!(node, :csv, CSV.File(node.settings[:file]))
    return [:csv]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ToDataFrameNode})
    countcall!(:todf)
    setdata!(node, :dataframe, DataFrame(getinputdata(node, :csv)))
    return [:dataframe]
end

function MetidaFlows.execute_unsafe!(node::DataNode{FilterRowsNode})
    countcall!(:filter)
    df   = getinputdata(node, :dataframe)
    col  = node.settings[:column]
    thr  = node.settings[:threshold]
    setdata!(node, :dataframe, df[df[!, col] .> thr, :])
    return [:dataframe]
end

function MetidaFlows.execute_unsafe!(node::DataNode{SummaryNode})
    countcall!(:summary)
    df = getinputdata(node, :dataframe)
    setdata!(node, :nrows, size(df, 1))
    setdata!(node, :nsubjects, length(unique(df.Subject)))
    return [:nrows, :nsubjects]
end

# --- отказы -----------------------------------------------------------

function MetidaFlows.execute_unsafe!(::DataNode{ErrorNode})
    countcall!(:error)
    error("node failed on purpose")
end

# UndefinedNode намеренно НЕ имеет метода: попадает в реализацию по
# умолчанию execute_unsafe!(::AbstractDataNode), которая бросает ошибку.

function MetidaFlows.execute_unsafe!(node::DataNode{BadResultNode})
    countcall!(:badresult)
    setdata!(node, :out, 1)
    return [:out]
end
MetidaFlows.validate_result(::DataNode{BadResultNode}) = false

function MetidaFlows.execute_unsafe!(node::DataNode{BadStructNode})
    countcall!(:badstruct)
    setdata!(node, :out, 1)
    return [:out]
end
MetidaFlows.validate_node(::DataNode{BadStructNode}) = false

function MetidaFlows.execute_unsafe!(node::DataNode{NeedsCfgNode})
    countcall!(:needscfg)
    setdata!(node, :out, node.settings[:k])
    return [:out]
end
MetidaFlows.validate_settings(node::DataNode{NeedsCfgNode}) = haskey(node.settings, :k)

# --- пользовательские хуки схемы --------------------------------------

function MetidaFlows.settings_schema_usermod!(d, node::DataNode{SchemaNode})
    d["schema"] = Dict{Symbol, Any}(:alpha => Dict{Symbol, Any}(:type => Int, :default => 0))
    return d
end

function MetidaFlows.node_schema_usermod!(d, node::DataNode{SchemaNode})
    d["color"] = "#8b5cf6"
    return d
end

# --------------------------------------------------------------------------
# Конструкторы типовых графов
#
# Возвращают именованный кортеж с workflow и идентификаторами нод,
# чтобы тесты не повторяли одну и ту же сборку.
# --------------------------------------------------------------------------

"""
Источник -> удвоитель. Настройка источника задана, ничего не исполнено.
"""
function build_linear(value::Int = 21; type::Symbol = :DAW)
    w   = Workflow(0; type = type)
    src = add_node!(w, DataNode(ConstNode, spec_const()))
    dbl = add_node!(w, DataNode(DoubleNode, spec_double()))
    con = add_connection!(w, src, :out, dbl, :in)
    setsettings!(w, src, Dict(:value => value))
    return (w = w, src = src, dbl = dbl, con = con)
end

"""
Ромб: один источник -> два удвоителя -> сумматор.
"""
function build_diamond(value::Int = 3; type::Symbol = :DAW)
    w = Workflow(0; type = type)
    s = add_node!(w, DataNode(ConstNode, spec_const()))
    l = add_node!(w, DataNode(DoubleNode, spec_double()))
    r = add_node!(w, DataNode(DoubleNode, spec_double()))
    j = add_node!(w, DataNode(AddNode, spec_add()))
    add_connection!(w, s, :out, l, :in)
    add_connection!(w, s, :out, r, :in)
    add_connection!(w, l, :out, j, :a)
    add_connection!(w, r, :out, j, :b)
    setsettings!(w, s, Dict(:value => value))
    return (w = w, src = s, left = l, right = r, join = j)
end

"""
Конвейер CSV -> DataFrame -> сводка. Путь к файлу уже задан.
"""
function build_pipeline(; type::Symbol = :DAW, file = CSV_PATH)
    w    = Workflow(0; type = type)
    load = add_node!(w, DataNode(LoadCSVNode, spec_loadcsv()))
    todf = add_node!(w, DataNode(ToDataFrameNode, spec_todf()))
    summ = add_node!(w, DataNode(SummaryNode, spec_summary()))
    add_connection!(w, load, :csv, todf, :csv)
    add_connection!(w, todf, :dataframe, summ, :dataframe)
    setsettings!(w, load, Dict(:file => file))
    return (w = w, load = load, todf = todf, summ = summ)
end
