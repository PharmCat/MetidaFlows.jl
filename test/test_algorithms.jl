############################################################################
#
#  КАТЕГОРИЯ: ЗООПАРК АЛГОРИТМОВ
#
#  Назначение: показать, что на графе собирается настоящий алгоритм — не
#  обёртка вокруг готовой функции, а разложение на элементарные операции,
#  где каждая операция это отдельный узел.
#
#  Первый алгоритм — пузырьковая сортировка. Движок ABW, цикл замкнут
#  обратным ребром. Один виток графа = одно сравнение пары соседей.
#
#  ПОЧЕМУ ГРАФ ВЫГЛЯДИТ КАК КОНВЕЙЕР
#
#  Это выбор стиля, а не требование движка. Тело разложено цепочкой: у
#  каждого узла все входы приходят от ОДНОГО предыдущего, а значения,
#  нужные позже, идут по «рельсам» сквозь узлы. Так виток читается как
#  список шагов алгоритма, и каждый узел делает ровно одну операцию.
#
#  Естественная раскладка — когда узел берёт только нужные ему входы, с
#  любой глубины — работает так же: планировщик помечает `:dirty` весь
#  конус вниз от исполнившегося узла, поэтому `isready` держит узел до
#  того, как пересчитаны все его обычные предки. Группа Z9 проверяет это
#  как регрессию: порядок создания связей на результат не влияет.
#
#  До этой правки планировщика порядок был значим: узел, до которого есть
#  короткое ребро от головы цикла и длинный путь, успевал исполниться на
#  устаревших входах, если короткое ребро зарегистрировали раньше.
#
#  ГРАФ
#
#   ConstArray ─┬─▶ ArrayLength ──┐
#               └─────────────────┤
#                                 ├─▶ LoopState ─▶ MoreWork ─▶ LoopGate ──▶ :sorted
#   ConstOne ─────────────────────┘        ▲                       │
#                                          │                       ▼
#                                          │                   ReadLeft
#                                          │                       │
#     ConstOne ────────────────────────────┼──────────────▶  NextIndex
#                                          │                       │
#                                          │                   ReadRight
#                                          │                       │
#                                          │                  ComparePair
#                                          │                       │
#                                          │                  AssignLeft
#                                          │                       │
#                                          │                  AssignRight
#                                          │                       │
#                                          │                  ChooseArray
#                                          │                       │
#                                          │                    PassEnd
#                                          │                       │
#     ConstOne ────────────────────────────┼──────────────▶ AdvanceIndex
#                                          │                       │
#     ConstOne ────────────────────────────┼──────────────▶  LowerLimit
#                                          │                       │
#                                          └─── :feedback ─── ShrinkLimit
#
#  Тело — прямая цепочка: каждая ступень получает всё от предыдущей.
#  ConstOne (одна нода, показана четыре раза) питает те четыре ступени,
#  которым нужна литеральная единица.
#
#  Состояние цикла — тройка (array, index, limit): массив, текущий индекс
#  и граница текущего прохода. Цикл с предпроверкой: `MoreWork` считает
#  `limit > 1`, и `LoopGate` либо пускает виток в тело, либо публикует
#  результат в терминальный порт. Поэтому массив из нуля и одного
#  элемента обрабатывается без обращения к a[j+1].
#
############################################################################

import MetidaFlows: PortSpec, SinglePort, DAW, ABW, NodeState, NodeProperties,
    getnode, getconnection, nodetypestr, getstate, getportspec, getporttype,
    getposition, setposition!, getid, makegraph, get_children, get_parents,
    isportexist, ismultiport, haveinputs, invalidate_buffer!, setinputbuffer!

# --------------------------------------------------------------------------
#  Инструментовка: след массива по виткам. Узел `ChooseArray` дописывает
#  состояние массива сразу после возможного обмена — ровно там, где его
#  фиксирует эталонная реализация ниже.
# --------------------------------------------------------------------------

ALGO_TRACE = Vector{Vector{Int}}()
tracestep!(v) = push!(ALGO_TRACE, copy(v))
resettrace!() = empty!(ALGO_TRACE)

# --------------------------------------------------------------------------
#  Эталон: та же пузырьковая сортировка обычным кодом. Структура витка
#  повторена один в один, чтобы след можно было сравнивать пошагово.
# --------------------------------------------------------------------------

function bubble_reference(v::Vector{Int})
    a = copy(v)
    trace = Vector{Vector{Int}}()
    j = 1
    limit = length(a)
    while limit > 1
        if a[j] > a[j + 1]
            a[j], a[j + 1] = a[j + 1], a[j]
        end
        push!(trace, copy(a))
        done  = (j + 1) >= limit
        j     = done ? 1 : j + 1
        limit = done ? limit - 1 : limit
    end
    return a, trace
end

# ==========================================================================
#  Элементарные узлы
#
#  Один тип — одна операция алгоритма. Ниже у каждого указано, что он
#  вычисляет и какие рельсы пропускает дальше.
# ==========================================================================

struct ConstArray   <: AbstractNodeType end  # источник массива
struct ConstOne     <: AbstractNodeType end  # источник единицы
struct ArrayLength  <: AbstractNodeType end  # n = length(a)
struct LoopState     <: AbstractNodeType end  # состояние цикла (array, index, limit)
struct MoreWork     <: AbstractNodeType end  # go = limit > 1
struct LoopGate     <: AbstractNodeType end  # ветвление: виток или результат
struct ReadLeft     <: AbstractNodeType end  # left = a[index]
struct NextIndex    <: AbstractNodeType end  # next = index + 1
struct ReadRight    <: AbstractNodeType end  # right = a[next]
struct ComparePair  <: AbstractNodeType end  # greater = left > right
struct AssignLeft   <: AbstractNodeType end  # work[index] = right
struct AssignRight  <: AbstractNodeType end  # work[next]  = left
struct ChooseArray  <: AbstractNodeType end  # a' = greater ? work : a
struct PassEnd      <: AbstractNodeType end  # done = next >= limit
struct AdvanceIndex <: AbstractNodeType end  # index' = done ? 1 : next
struct LowerLimit   <: AbstractNodeType end  # lower = limit - 1
struct ShrinkLimit  <: AbstractNodeType end  # limit' = done ? lower : limit

IntVec = Vector{Int}

# --- спецификации ---------------------------------------------------------

spec_constarray() = NodeSpec("Const array", PortSpec[],
    [PortSpec("Array", IntVec, :array)], [:values])

spec_constone() = NodeSpec("Const one", PortSpec[],
    [PortSpec("One", Int, :one)], [:value])

spec_arraylength() = NodeSpec("Array length",
    [PortSpec("Array", IntVec, :array)],
    [PortSpec("Length", Int, :length)])

# Голова цикла: обычные входы — начальные значения, обратные — состояние с
# прошлого витка. На первом витке буферы обратных портов пусты, поэтому
# берутся начальные.
spec_loopstate() = NodeSpec("Loop head",
    [PortSpec("Initial array", IntVec, :init_array),
     PortSpec("Initial index", Int,    :init_index),
     PortSpec("Initial limit", Int,    :init_limit),
     PortSpec("Array",         IntVec, :array; kind = :feedback, required = false),
     PortSpec("Index",         Int,    :index; kind = :feedback, required = false),
     PortSpec("Limit",         Int,    :limit; kind = :feedback, required = false)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit)])

spec_morework() = NodeSpec("More work",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit),
     PortSpec("One",   Int,    :one)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Go",    Bool,   :go)])

spec_loopgate() = NodeSpec("Loop gate",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Go",    Bool,   :go)],
    [PortSpec("Array",  IntVec, :array),
     PortSpec("Index",  Int,    :index),
     PortSpec("Limit",  Int,    :limit),
     PortSpec("Sorted", IntVec, :sorted; kind = :terminal)])

spec_readleft() = NodeSpec("Read left",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Left",  Int,    :left)])

spec_nextindex() = NodeSpec("Next index",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Left",  Int,    :left),
     PortSpec("One",   Int,    :one)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Next",  Int,    :next),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Left",  Int,    :left)])

spec_readright() = NodeSpec("Read right",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Next",  Int,    :next),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Left",  Int,    :left)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Next",  Int,    :next),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Left",  Int,    :left),
     PortSpec("Right", Int,    :right)])

spec_comparepair() = NodeSpec("Compare pair",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Next",  Int,    :next),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Left",  Int,    :left),
     PortSpec("Right", Int,    :right)],
    [PortSpec("Array",   IntVec, :array),
     PortSpec("Index",   Int,    :index),
     PortSpec("Next",    Int,    :next),
     PortSpec("Limit",   Int,    :limit),
     PortSpec("Left",    Int,    :left),
     PortSpec("Right",   Int,    :right),
     PortSpec("Greater", Bool,   :greater)])

# Оба присваивания делаются всегда, на рабочей копии; выбор между копией и
# исходным массивом — отдельный узел. Так присваивание остаётся
# элементарной операцией, без спрятанного внутрь условия.
spec_assignleft() = NodeSpec("Assign left",
    [PortSpec("Array",   IntVec, :array),
     PortSpec("Index",   Int,    :index),
     PortSpec("Next",    Int,    :next),
     PortSpec("Limit",   Int,    :limit),
     PortSpec("Left",    Int,    :left),
     PortSpec("Right",   Int,    :right),
     PortSpec("Greater", Bool,   :greater)],
    [PortSpec("Source",  IntVec, :source),
     PortSpec("Work",    IntVec, :work),
     PortSpec("Next",    Int,    :next),
     PortSpec("Limit",   Int,    :limit),
     PortSpec("Left",    Int,    :left),
     PortSpec("Greater", Bool,   :greater)])

spec_assignright() = NodeSpec("Assign right",
    [PortSpec("Source",  IntVec, :source),
     PortSpec("Work",    IntVec, :work),
     PortSpec("Next",    Int,    :next),
     PortSpec("Limit",   Int,    :limit),
     PortSpec("Left",    Int,    :left),
     PortSpec("Greater", Bool,   :greater)],
    [PortSpec("Source",  IntVec, :source),
     PortSpec("Work",    IntVec, :work),
     PortSpec("Next",    Int,    :next),
     PortSpec("Limit",   Int,    :limit),
     PortSpec("Greater", Bool,   :greater)])

spec_choosearray() = NodeSpec("Choose array",
    [PortSpec("Source",  IntVec, :source),
     PortSpec("Work",    IntVec, :work),
     PortSpec("Next",    Int,    :next),
     PortSpec("Limit",   Int,    :limit),
     PortSpec("Greater", Bool,   :greater)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Next",  Int,    :next),
     PortSpec("Limit", Int,    :limit)])

spec_passend() = NodeSpec("Pass end",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Next",  Int,    :next),
     PortSpec("Limit", Int,    :limit)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Next",  Int,    :next),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Done",  Bool,   :done)])

spec_advanceindex() = NodeSpec("Advance index",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Next",  Int,    :next),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Done",  Bool,   :done),
     PortSpec("One",   Int,    :one)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Done",  Bool,   :done)])

spec_lowerlimit() = NodeSpec("Lower limit",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Done",  Bool,   :done),
     PortSpec("One",   Int,    :one)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Lower", Int,    :lower),
     PortSpec("Done",  Bool,   :done)])

spec_shrinklimit() = NodeSpec("Shrink limit",
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit),
     PortSpec("Lower", Int,    :lower),
     PortSpec("Done",  Bool,   :done)],
    [PortSpec("Array", IntVec, :array),
     PortSpec("Index", Int,    :index),
     PortSpec("Limit", Int,    :limit)])

# --- реализации -----------------------------------------------------------

function MetidaFlows.execute_unsafe!(node::DataNode{ConstArray})
    setdata!(node, :array, Vector{Int}(node.settings[:values]))
    return [:array]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ConstOne})
    setdata!(node, :one, node.settings[:value])
    return [:one]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ArrayLength})
    setdata!(node, :length, length(getinputdata(node, :array)))
    return [:length]
end

function MetidaFlows.execute_unsafe!(node::DataNode{LoopState})
    back = getinputdata(node, :array)
    if back === nothing                       # первый виток: берём начальные
        setdata!(node, :array, getinputdata(node, :init_array))
        setdata!(node, :index, getinputdata(node, :init_index))
        setdata!(node, :limit, getinputdata(node, :init_limit))
    else                                      # дальше — состояние с прошлого витка
        setdata!(node, :array, back)
        setdata!(node, :index, getinputdata(node, :index))
        setdata!(node, :limit, getinputdata(node, :limit))
    end
    return [:array, :index, :limit]
end

function MetidaFlows.execute_unsafe!(node::DataNode{MoreWork})
    setdata!(node, :array, getinputdata(node, :array))
    setdata!(node, :index, getinputdata(node, :index))
    setdata!(node, :limit, getinputdata(node, :limit))
    setdata!(node, :go, getinputdata(node, :limit) > getinputdata(node, :one))
    return [:array, :index, :limit, :go]
end

function MetidaFlows.execute_unsafe!(node::DataNode{LoopGate})
    if getinputdata(node, :go)
        setdata!(node, :array, getinputdata(node, :array))
        setdata!(node, :index, getinputdata(node, :index))
        setdata!(node, :limit, getinputdata(node, :limit))
        return [:array, :index, :limit]       # ещё виток
    end
    setdata!(node, :sorted, getinputdata(node, :array))
    return [:sorted]                          # терминальный порт: очередь иссякнет
end

function MetidaFlows.execute_unsafe!(node::DataNode{ReadLeft})
    a = getinputdata(node, :array)
    i = getinputdata(node, :index)
    setdata!(node, :array, a)
    setdata!(node, :index, i)
    setdata!(node, :limit, getinputdata(node, :limit))
    setdata!(node, :left, a[i])
    return [:array, :index, :limit, :left]
end

function MetidaFlows.execute_unsafe!(node::DataNode{NextIndex})
    setdata!(node, :array, getinputdata(node, :array))
    setdata!(node, :index, getinputdata(node, :index))
    setdata!(node, :next,  getinputdata(node, :index) + getinputdata(node, :one))
    setdata!(node, :limit, getinputdata(node, :limit))
    setdata!(node, :left,  getinputdata(node, :left))
    return [:array, :index, :next, :limit, :left]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ReadRight})
    a = getinputdata(node, :array)
    n = getinputdata(node, :next)
    setdata!(node, :array, a)
    setdata!(node, :index, getinputdata(node, :index))
    setdata!(node, :next,  n)
    setdata!(node, :limit, getinputdata(node, :limit))
    setdata!(node, :left,  getinputdata(node, :left))
    setdata!(node, :right, a[n])
    return [:array, :index, :next, :limit, :left, :right]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ComparePair})
    setdata!(node, :array,   getinputdata(node, :array))
    setdata!(node, :index,   getinputdata(node, :index))
    setdata!(node, :next,    getinputdata(node, :next))
    setdata!(node, :limit,   getinputdata(node, :limit))
    setdata!(node, :left,    getinputdata(node, :left))
    setdata!(node, :right,   getinputdata(node, :right))
    setdata!(node, :greater, getinputdata(node, :left) > getinputdata(node, :right))
    return [:array, :index, :next, :limit, :left, :right, :greater]
end

function MetidaFlows.execute_unsafe!(node::DataNode{AssignLeft})
    a    = getinputdata(node, :array)
    work = copy(a)
    work[getinputdata(node, :index)] = getinputdata(node, :right)
    setdata!(node, :source,  a)
    setdata!(node, :work,    work)
    setdata!(node, :next,    getinputdata(node, :next))
    setdata!(node, :limit,   getinputdata(node, :limit))
    setdata!(node, :left,    getinputdata(node, :left))
    setdata!(node, :greater, getinputdata(node, :greater))
    return [:source, :work, :next, :limit, :left, :greater]
end

function MetidaFlows.execute_unsafe!(node::DataNode{AssignRight})
    work = copy(getinputdata(node, :work))
    work[getinputdata(node, :next)] = getinputdata(node, :left)
    setdata!(node, :source,  getinputdata(node, :source))
    setdata!(node, :work,    work)
    setdata!(node, :next,    getinputdata(node, :next))
    setdata!(node, :limit,   getinputdata(node, :limit))
    setdata!(node, :greater, getinputdata(node, :greater))
    return [:source, :work, :next, :limit, :greater]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ChooseArray})
    a = getinputdata(node, :greater) ? getinputdata(node, :work) :
                                       getinputdata(node, :source)
    setdata!(node, :array, a)
    setdata!(node, :next,  getinputdata(node, :next))
    setdata!(node, :limit, getinputdata(node, :limit))
    tracestep!(a)                             # инструментовка теста
    return [:array, :next, :limit]
end

function MetidaFlows.execute_unsafe!(node::DataNode{PassEnd})
    setdata!(node, :array, getinputdata(node, :array))
    setdata!(node, :next,  getinputdata(node, :next))
    setdata!(node, :limit, getinputdata(node, :limit))
    setdata!(node, :done,  getinputdata(node, :next) >= getinputdata(node, :limit))
    return [:array, :next, :limit, :done]
end

function MetidaFlows.execute_unsafe!(node::DataNode{AdvanceIndex})
    done = getinputdata(node, :done)
    setdata!(node, :array, getinputdata(node, :array))
    setdata!(node, :index, done ? getinputdata(node, :one) : getinputdata(node, :next))
    setdata!(node, :limit, getinputdata(node, :limit))
    setdata!(node, :done,  done)
    return [:array, :index, :limit, :done]
end

function MetidaFlows.execute_unsafe!(node::DataNode{LowerLimit})
    setdata!(node, :array, getinputdata(node, :array))
    setdata!(node, :index, getinputdata(node, :index))
    setdata!(node, :limit, getinputdata(node, :limit))
    setdata!(node, :lower, getinputdata(node, :limit) - getinputdata(node, :one))
    setdata!(node, :done,  getinputdata(node, :done))
    return [:array, :index, :limit, :lower, :done]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ShrinkLimit})
    done = getinputdata(node, :done)
    setdata!(node, :array, getinputdata(node, :array))
    setdata!(node, :index, getinputdata(node, :index))
    setdata!(node, :limit, done ? getinputdata(node, :lower) :
                                  getinputdata(node, :limit))
    return [:array, :index, :limit]
end

# ==========================================================================
#  Узлы для группы Z9: минимальная демонстрация того, зачем раскладка
#  синхронная. Голова рассылает ОДНО И ТО ЖЕ число по двум путям; узел
#  слияния сверяет, пришли ли оба значения с одного витка.
# ==========================================================================

struct ZSeed <: AbstractNodeType end
struct ZHead <: AbstractNodeType end
struct ZStep <: AbstractNodeType end
struct ZJoin <: AbstractNodeType end
struct ZCtrl <: AbstractNodeType end

ZCOUNT = Dict{Symbol, Int}()
zcount!(k) = (ZCOUNT[k] = get(ZCOUNT, k, 0) + 1)

spec_zseed() = NodeSpec("Z seed", PortSpec[], [PortSpec("Out", Int, :out)], [:value])

spec_zhead() = NodeSpec("Z head",
    [PortSpec("Init", Int, :init),
     PortSpec("Back", Int, :back; kind = :feedback, required = false)],
    [PortSpec("Near", Int, :near), PortSpec("Far", Int, :far)])

spec_zstep() = NodeSpec("Z step",
    [PortSpec("In", Int, :in)], [PortSpec("Out", Int, :out)])

spec_zjoin() = NodeSpec("Z join",
    [PortSpec("Near", Int, :near), PortSpec("Far", Int, :far)],
    [PortSpec("Out", Int, :out)])

spec_zctrl() = NodeSpec("Z ctrl",
    [PortSpec("In", Int, :in)],
    [PortSpec("Next",  Int, :next),
     PortSpec("Total", Int, :total; kind = :terminal)],
    [:turns])

function MetidaFlows.execute_unsafe!(node::DataNode{ZSeed})
    setdata!(node, :out, node.settings[:value])
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ZHead})
    back = getinputdata(node, :back)
    v    = back === nothing ? getinputdata(node, :init) : back
    setdata!(node, :near, v)
    setdata!(node, :far,  v)                  # то же значение по второму пути
    return [:near, :far]
end

# Ступень ничего не меняет: важна только её ГЛУБИНА от головы.
function MetidaFlows.execute_unsafe!(node::DataNode{ZStep})
    setdata!(node, :out, getinputdata(node, :in))
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ZJoin})
    zcount!(:join)
    near = getinputdata(node, :near)
    far  = getinputdata(node, :far)
    # Голова рассылает одинаковые значения, поэтому расхождение означает
    # только одно: входы пришли с разных витков.
    near == far || zcount!(:join_mismatch)
    setdata!(node, :out, near)
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{ZCtrl})
    zcount!(:ctrl)
    v = getinputdata(node, :in)
    if v >= node.settings[:turns]
        setdata!(node, :total, v)
        return [:total]                       # останов
    end
    setdata!(node, :next, v + 1)              # останов по значению, не по счётчику
    return [:next]
end

# ==========================================================================
#  Сборка графа
# ==========================================================================

"""
    build_bubble_sort(values) -> NamedTuple

Собрать граф пузырьковой сортировки для `values`. Возвращает workflow и
идентификаторы всех узлов.
"""
function build_bubble_sort(values::Vector{Int})
    w = Workflow(0; type = :ABW)
    w.name = "Bubble sort"

    src   = add_node!(w, DataNode(ConstArray,   spec_constarray()))
    one   = add_node!(w, DataNode(ConstOne,     spec_constone()))
    len   = add_node!(w, DataNode(ArrayLength,  spec_arraylength()))
    head  = add_node!(w, DataNode(LoopState,     spec_loopstate()))
    more  = add_node!(w, DataNode(MoreWork,     spec_morework()))
    gate  = add_node!(w, DataNode(LoopGate,     spec_loopgate()))
    rleft = add_node!(w, DataNode(ReadLeft,     spec_readleft()))
    nidx  = add_node!(w, DataNode(NextIndex,    spec_nextindex()))
    rrght = add_node!(w, DataNode(ReadRight,    spec_readright()))
    cmp   = add_node!(w, DataNode(ComparePair,  spec_comparepair()))
    aleft = add_node!(w, DataNode(AssignLeft,   spec_assignleft()))
    argt  = add_node!(w, DataNode(AssignRight,  spec_assignright()))
    choos = add_node!(w, DataNode(ChooseArray,  spec_choosearray()))
    pend  = add_node!(w, DataNode(PassEnd,      spec_passend()))
    adv   = add_node!(w, DataNode(AdvanceIndex, spec_advanceindex()))
    lower = add_node!(w, DataNode(LowerLimit,   spec_lowerlimit()))
    shrnk = add_node!(w, DataNode(ShrinkLimit,  spec_shrinklimit()))

    # начальные значения
    add_connection!(w, src, :array,  len,  :array)
    add_connection!(w, src, :array,  head, :init_array)
    add_connection!(w, one, :one,    head, :init_index)
    add_connection!(w, len, :length, head, :init_limit)

    # предпроверка цикла и ветвление
    for p in (:array, :index, :limit)
        add_connection!(w, head, p, more, p)
    end
    add_connection!(w, one, :one, more, :one)
    for p in (:array, :index, :limit, :go)
        add_connection!(w, more, p, gate, p)
    end

    # тело витка: каждый узел получает всё от одного предыдущего
    for p in (:array, :index, :limit)
        add_connection!(w, gate, p, rleft, p)
    end
    for p in (:array, :index, :limit, :left)
        add_connection!(w, rleft, p, nidx, p)
    end
    add_connection!(w, one, :one, nidx, :one)
    for p in (:array, :index, :next, :limit, :left)
        add_connection!(w, nidx, p, rrght, p)
    end
    for p in (:array, :index, :next, :limit, :left, :right)
        add_connection!(w, rrght, p, cmp, p)
    end
    for p in (:array, :index, :next, :limit, :left, :right, :greater)
        add_connection!(w, cmp, p, aleft, p)
    end
    for p in (:source, :work, :next, :limit, :left, :greater)
        add_connection!(w, aleft, p, argt, p)
    end
    for p in (:source, :work, :next, :limit, :greater)
        add_connection!(w, argt, p, choos, p)
    end
    for p in (:array, :next, :limit)
        add_connection!(w, choos, p, pend, p)
    end
    for p in (:array, :next, :limit, :done)
        add_connection!(w, pend, p, adv, p)
    end
    add_connection!(w, one, :one, adv, :one)
    for p in (:array, :index, :limit, :done)
        add_connection!(w, adv, p, lower, p)
    end
    add_connection!(w, one, :one, lower, :one)
    for p in (:array, :index, :limit, :lower, :done)
        add_connection!(w, lower, p, shrnk, p)
    end

    # обратное ребро замыкает цикл
    for p in (:array, :index, :limit)
        add_connection!(w, shrnk, p, head, p)
    end

    setsettings!(w, src, Dict(:values => values))
    setsettings!(w, one, Dict(:value => 1))

    return (w = w, src = src, one = one, len = len, head = head, more = more,
            gate = gate, rleft = rleft, nidx = nidx, rrght = rrght, cmp = cmp,
            aleft = aleft, argt = argt, choos = choos, pend = pend, adv = adv,
            lower = lower, shrnk = shrnk)
end

"Отсортировать массив графом. Возвращает результат и число витков."
function graph_sort(values::Vector{Int}; maxiter = 20_000)
    resettrace!()
    g = build_bubble_sort(values)
    scheduler!(g.w; maxiter = maxiter)
    return getdata(g.w, g.gate, :sorted), length(ALGO_TRACE), g
end

# ==========================================================================

@testset verbose = true "ЗООПАРК АЛГОРИТМОВ                               " begin

# --------------------------------------------------------------------------
@testset "Z1. элементарные узлы по отдельности             " begin
    # Каждый узел проверяется один, вне графа: вызываем execute_unsafe!
    # напрямую, подложив входной буфер.
    function run1(type, spec, inputs::Dict{Symbol, Any}; settings = Dict{Symbol, Any}())
        node = DataNode(type, spec; settings = settings)
        for (port, value) in inputs
            setinputbuffer!(node, port, 1, value)
        end
        ports = MetidaFlows.execute_unsafe!(node)
        return node, ports
    end

    n, p = run1(ConstArray, spec_constarray(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:values => [3, 1, 2]))
    @test p == [:array]
    @test getdata(n, :array) == [3, 1, 2]

    n, _ = run1(ConstOne, spec_constone(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => 1))
    @test getdata(n, :one) == 1

    n, _ = run1(ArrayLength, spec_arraylength(), Dict{Symbol, Any}(:array => [5, 6, 7]))
    @test getdata(n, :length) == 3

    # left = a[index]
    n, _ = run1(ReadLeft, spec_readleft(),
                Dict{Symbol, Any}(:array => [10, 20, 30], :index => 2, :limit => 3))
    @test getdata(n, :left) == 20
    @test getdata(n, :array) == [10, 20, 30]      # рельсы проходят без изменений
    @test getdata(n, :index) == 2
    @test getdata(n, :limit) == 3

    # next = index + 1
    n, _ = run1(NextIndex, spec_nextindex(),
                Dict{Symbol, Any}(:array => [1], :index => 4, :limit => 9, :left => 0, :one => 1))
    @test getdata(n, :next) == 5
    @test getdata(n, :index) == 4

    # right = a[next]
    n, _ = run1(ReadRight, spec_readright(),
                Dict{Symbol, Any}(:array => [10, 20, 30], :index => 1, :next => 3,
                                  :limit => 3, :left => 10))
    @test getdata(n, :right) == 30

    # greater = left > right
    for (l, r, expected) in ((5, 3, true), (3, 5, false), (4, 4, false))
        n, _ = run1(ComparePair, spec_comparepair(),
                    Dict{Symbol, Any}(:array => [0], :index => 1, :next => 2,
                                      :limit => 2, :left => l, :right => r))
        @test getdata(n, :greater) === expected
    end

    # присваивания: работают на копии, исходный массив цел
    source = [1, 2, 3]
    n, _ = run1(AssignLeft, spec_assignleft(),
                Dict{Symbol, Any}(:array => source, :index => 1, :next => 2, :limit => 3,
                                  :left => 1, :right => 2, :greater => true))
    @test getdata(n, :work)   == [2, 2, 3]
    @test getdata(n, :source) == [1, 2, 3]
    @test source == [1, 2, 3]                     # вход не испорчен

    n, _ = run1(AssignRight, spec_assignright(),
                Dict{Symbol, Any}(:source => [1, 2, 3], :work => [2, 2, 3], :next => 2,
                                  :limit => 3, :left => 1, :greater => true))
    @test getdata(n, :work) == [2, 1, 3]

    # выбор массива
    for (greater, expected) in ((true, [2, 1, 3]), (false, [1, 2, 3]))
        resettrace!()
        n, _ = run1(ChooseArray, spec_choosearray(),
                    Dict{Symbol, Any}(:source => [1, 2, 3], :work => [2, 1, 3],
                                      :next => 2, :limit => 3, :greater => greater))
        @test getdata(n, :array) == expected
    end
    resettrace!()

    # done = next >= limit
    for (next, limit, expected) in ((2, 5, false), (5, 5, true), (6, 5, true))
        n, _ = run1(PassEnd, spec_passend(),
                    Dict{Symbol, Any}(:array => [0], :next => next, :limit => limit))
        @test getdata(n, :done) === expected
    end

    # index' = done ? 1 : next
    n, _ = run1(AdvanceIndex, spec_advanceindex(),
                Dict{Symbol, Any}(:array => [0], :next => 7, :limit => 9,
                                  :done => false, :one => 1))
    @test getdata(n, :index) == 7
    n, _ = run1(AdvanceIndex, spec_advanceindex(),
                Dict{Symbol, Any}(:array => [0], :next => 7, :limit => 9,
                                  :done => true, :one => 1))
    @test getdata(n, :index) == 1

    # lower = limit - 1
    n, _ = run1(LowerLimit, spec_lowerlimit(),
                Dict{Symbol, Any}(:array => [0], :index => 1, :limit => 9,
                                  :done => true, :one => 1))
    @test getdata(n, :lower) == 8

    # limit' = done ? lower : limit
    n, _ = run1(ShrinkLimit, spec_shrinklimit(),
                Dict{Symbol, Any}(:array => [0], :index => 1, :limit => 9,
                                  :lower => 8, :done => true))
    @test getdata(n, :limit) == 8
    n, _ = run1(ShrinkLimit, spec_shrinklimit(),
                Dict{Symbol, Any}(:array => [0], :index => 1, :limit => 9,
                                  :lower => 8, :done => false))
    @test getdata(n, :limit) == 9

    # go = limit > 1
    n, _ = run1(MoreWork, spec_morework(),
                Dict{Symbol, Any}(:array => [0], :index => 1, :limit => 1, :one => 1))
    @test getdata(n, :go) === false
    n, _ = run1(MoreWork, spec_morework(),
                Dict{Symbol, Any}(:array => [0], :index => 1, :limit => 2, :one => 1))
    @test getdata(n, :go) === true

    # голова цикла: пустой обратный буфер -> начальные значения
    n, p = run1(LoopState, spec_loopstate(),
                Dict{Symbol, Any}(:init_array => [9, 8], :init_index => 1, :init_limit => 2))
    @test sort(p) == sort([:array, :index, :limit])
    @test getdata(n, :array) == [9, 8]
    @test getdata(n, :index) == 1
    @test getdata(n, :limit) == 2
    # обратный буфер заполнен -> берётся он
    n, _ = run1(LoopState, spec_loopstate(),
                Dict{Symbol, Any}(:init_array => [9, 8], :init_index => 1, :init_limit => 2,
                                  :array => [8, 9], :index => 2, :limit => 5))
    @test getdata(n, :array) == [8, 9]
    @test getdata(n, :index) == 2
    @test getdata(n, :limit) == 5

    # ворота: открыты и закрыты
    n, p = run1(LoopGate, spec_loopgate(),
                Dict{Symbol, Any}(:array => [1, 2], :index => 1, :limit => 2, :go => true))
    @test sort(p) == sort([:array, :index, :limit])
    @test getdata(n, :sorted) === nothing
    n, p = run1(LoopGate, spec_loopgate(),
                Dict{Symbol, Any}(:array => [1, 2], :index => 1, :limit => 1, :go => false))
    @test p == [:sorted]
    @test getdata(n, :sorted) == [1, 2]
end

# --------------------------------------------------------------------------
@testset "Z2. структура графа                             " begin
    g = build_bubble_sort([3, 1, 2])

    @test g.w isa Workflow{ABW}
    @test g.w.name == "Bubble sort"
    @test length(g.w.nodes) == 17                 # 17 узлов = 17 операций
    @test length(g.w.connections) == 70

    # засевается ровно двумя источниками: только у них нет входных портов
    seeds = [id for (id, n) in g.w.nodes if !haveinputs(n)]
    @test sort(seeds) == sort([g.src, g.one])

    # цикл замкнут ровно тремя обратными рёбрами, все из ShrinkLimit в голову
    feedback = [c for c in values(g.w.connections)
                if getportspec(getnode(g.w, c.input_id), c.input_port, :input).kind == :feedback]
    @test length(feedback) == 3
    @test all(c -> c.output_id == g.shrnk && c.input_id == g.head, feedback)
    @test sort([c.input_port for c in feedback]) == [:array, :index, :limit]

    # результат отдаётся через терминальный порт, он никуда не подключён
    @test getportspec(getnode(g.w, g.gate), :sorted, :output).kind == :terminal
    @test isempty([c for c in values(g.w.connections)
                   if c.output_id == g.gate && c.output_port == :sorted])

    # ГЛАВНОЕ СВОЙСТВО РАСКЛАДКИ: у каждого узла тела все входы приходят от
    # одного узла — не считая константы. Именно это делает виток
    # детерминированным (см. шапку файла и Z9).
    body = (g.rleft, g.nidx, g.rrght, g.cmp, g.aleft, g.argt,
            g.choos, g.pend, g.adv, g.lower, g.shrnk)
    for id in body
        parents = unique([p for (_, p) in get_parents(g.w, id) if p != g.one])
        @test length(parents) == 1
    end

    # граф циклический, поэтому DAW его не возьмёт
    @test MetidaFlows.is_cyclic(makegraph(g.w))
end

# --------------------------------------------------------------------------
@testset "Z3. сортировка и число витков                    " begin
    input = [5, 1, 4, 2, 8]
    sorted, turns, g = graph_sort(input)

    @test sorted == sort(input)
    @test sorted == [1, 2, 4, 5, 8]

    # витков ровно n(n-1)/2: по одному сравнению на виток
    n = length(input)
    @test turns == n * (n - 1) ÷ 2
    @test turns == 10

    # исходный массив не тронут
    @test getdata(g.w, g.src, :array) == input

    # Узлы до ворот доезжают до :clean, тело остаётся :dirty: на последнем
    # проходе голова пометила конус, ворота закрылись и тело честно не
    # пересчитывалось. Для циклического графа «все :clean» не признак
    # завершённости — см. докстринг scheduler!.
    for id in (g.src, g.one, g.len, g.head, g.more, g.gate)
        @test getstatus(getnode(g.w, id)) == :clean
    end
    for id in (g.rleft, g.nidx, g.rrght, g.cmp, g.aleft, g.argt,
               g.choos, g.pend, g.adv, g.lower, g.shrnk)
        @test getstatus(getnode(g.w, id)) == :dirty
    end
    @test isempty(g.w.log)
end

# --------------------------------------------------------------------------
@testset "Z4. след витков совпадает с эталоном             " begin
    # Самая сильная проверка: граф не просто возвращает отсортированный
    # массив, а проходит те же состояния, что обычная пузырьковая
    # сортировка — то есть делает именно её, а не что-то своё.
    for input in ([5, 1, 4, 2, 8], [3, 2, 1], [1, 2, 3, 4], [2, 2, 1, 3, 1])
        sorted, _, _ = graph_sort(input)
        ref, reftrace = bubble_reference(input)
        @test sorted == ref
        @test length(ALGO_TRACE) == length(reftrace)
        @test ALGO_TRACE == reftrace
    end
end

# --------------------------------------------------------------------------
@testset "Z5. краевые входы                                " begin
    # Предпроверка цикла: при limit <= 1 тело не исполняется ни разу,
    # поэтому обращения к a[j+1] не происходит.
    sorted, turns, g = graph_sort(Int[])
    @test sorted == Int[]
    @test turns == 0
    @test getstate(getnode(g.w, g.rleft), :exec_n) == 0
    @test getstatus(getnode(g.w, g.rleft)) == :dirty    # тело так и не запускалось

    sorted, turns, _ = graph_sort([42])
    @test sorted == [42]
    @test turns == 0

    sorted, turns, _ = graph_sort([2, 1])
    @test sorted == [1, 2]
    @test turns == 1

    sorted, turns, _ = graph_sort([1, 2])
    @test sorted == [1, 2]
    @test turns == 1

    # уже отсортированный, обратный, с повторами, отрицательные
    for input in ([1, 2, 3, 4, 5], [5, 4, 3, 2, 1], [7, 7, 7], [0, -1, 3, -2],
                  [10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
        sorted, turns, _ = graph_sort(input)
        @test sorted == sort(input)
        @test turns == length(input) * (length(input) - 1) ÷ 2
    end
end

# --------------------------------------------------------------------------
@testset "Z6. каждый узел исполняется один раз за виток    " begin
    # Это и есть синхронность раскладки: ни одного лишнего пересчёта.
    input = [5, 1, 4, 2, 8]
    _, turns, g = graph_sort(input)

    # тело работает столько раз, сколько витков
    for id in (g.rleft, g.nidx, g.rrght, g.cmp, g.aleft, g.argt,
               g.choos, g.pend, g.adv, g.lower, g.shrnk)
        @test getstate(getnode(g.w, id), :exec_n) == turns
    end

    # голова, предпроверка и ворота — на один раз больше: последний проход
    # закрывает цикл
    for id in (g.head, g.more, g.gate)
        @test getstate(getnode(g.w, id), :exec_n) == turns + 1
    end

    # источники считаются один раз на весь прогон
    @test getstate(getnode(g.w, g.src), :exec_n) == 1
    @test getstate(getnode(g.w, g.one), :exec_n) == 1
    @test getstate(getnode(g.w, g.len), :exec_n) == 1
end

# --------------------------------------------------------------------------
@testset "Z7. страховка по числу итераций                  " begin
    # Витков у графа n(n-1)/2, а итераций планировщика примерно по узлу
    # тела на виток — поэтому дефолтного maxiter = 1000 на пяти элементах
    # хватает, а на большом массиве нет.
    g = build_bubble_sort([5, 1, 4, 2, 8])
    resettrace!()
    @test scheduler!(g.w) === true
    @test getdata(g.w, g.gate, :sorted) == [1, 2, 4, 5, 8]

    big = collect(20:-1:1)
    g2 = build_bubble_sort(big)
    resettrace!()
    @test_throws ErrorException scheduler!(g2.w; maxiter = 100)

    g3 = build_bubble_sort(big)
    resettrace!()
    @test scheduler!(g3.w; maxiter = 20_000) === true
    @test getdata(g3.w, g3.gate, :sorted) == sort(big)
    @test length(ALGO_TRACE) == 190               # 20*19/2
end

# --------------------------------------------------------------------------
@testset "Z8. повторный прогон цикла                      " begin
    # `:full` снимает состояние цикла: reset! чистит буферы обратных портов,
    # поэтому повторный прогон того же графа повторяет сортировку с начала,
    # а не продолжает с места остановки.
    g = build_bubble_sort([4, 3, 2, 1])
    resettrace!()
    scheduler!(g.w; maxiter = 5000)
    first_result = getdata(g.w, g.gate, :sorted)
    first_turns  = length(ALGO_TRACE)
    @test first_result == [1, 2, 3, 4]
    @test first_turns == 6

    # после прогона обратные буферы заполнены итоговым состоянием витка
    head = getnode(g.w, g.head)
    @test all(!isempty(head.input_buffer[p]) for p in (:array, :index, :limit))

    # повторный прогон: reset! их очистил, голова взяла начальные значения
    resettrace!()
    scheduler!(g.w; maxiter = 5000)
    @test length(ALGO_TRACE) == first_turns
    @test ALGO_TRACE == bubble_reference([4, 3, 2, 1])[2]
    @test getdata(g.w, g.gate, :sorted) == first_result

    # и так сколько угодно раз
    resettrace!()
    scheduler!(g.w; maxiter = 5000)
    @test length(ALGO_TRACE) == first_turns

    # reset! с soft = true обратные буферы СОХРАНЯЕТ: так состояние
    # переносится между вызовами
    reset!(g.w; soft = true)
    @test all(!isempty(head.input_buffer[p]) for p in (:array, :index, :limit))
    reset!(g.w)
    @test all(isempty(head.input_buffer[p]) for p in (:array, :index, :limit))

    # а буферы обычных портов полный сброс не трогает
    @test !isempty(getnode(g.w, g.head).input_buffer[:init_array])

    # `:none` ничего не считает: все узлы :clean, а голова, если её всё же
    # пересчитать, нашла бы в обратном буфере limit = 1 и сразу закрыла цикл
    resettrace!()
    scheduler!(g.w; maxiter = 5000)              # вернуть граф в посчитанное состояние
    resettrace!()
    @test scheduler!(g.w; reset_mode = :none, throw_warn = false) === true
    @test isempty(ALGO_TRACE)
    @test getdata(g.w, g.gate, :sorted) == first_result
end

# --------------------------------------------------------------------------
@testset "Z9. порядок создания связей не значим            " begin
    # Регрессия на правку планировщика. Граф: голова рассылает ОДНО И ТО ЖЕ
    # число по двум путям разной длины, узел слияния сверяет, пришли ли оба
    # значения с одного витка.
    #
    #                     ┌──────── :near ────────────┐
    #   ZSeed ─▶ ZHead ───┤                           ├─▶ ZJoin ─▶ ZCtrl ─┐
    #              ▲      └─ ZStep ─▶ ZStep ─ :far ───┘                   │
    #              └──────────────────── :feedback ───────────────────────┘
    #
    # Раньше результат зависел от того, какое ребро зарегистрировали раньше:
    # если короткое, слияние попадало в очередь на первой волне и считало
    # смесь нового значения со старым. Теперь планировщик помечает `:dirty`
    # весь конус вниз, `isready` держит слияние до пересчёта обеих ступеней,
    # и оба порядка дают одно и то же.
    function zgraph(; short_edge_first::Bool)
        w    = Workflow(0; type = :ABW)
        seed = add_node!(w, DataNode(ZSeed, spec_zseed()))
        head = add_node!(w, DataNode(ZHead, spec_zhead()))
        join = add_node!(w, DataNode(ZJoin, spec_zjoin()))
        st1  = add_node!(w, DataNode(ZStep, spec_zstep()))
        st2  = add_node!(w, DataNode(ZStep, spec_zstep()))
        ctrl = add_node!(w, DataNode(ZCtrl, spec_zctrl()))

        add_connection!(w, seed, :out, head, :init)
        short_edge_first && add_connection!(w, head, :near, join, :near)
        add_connection!(w, head, :far, st1, :in)
        add_connection!(w, st1,  :out, st2, :in)
        add_connection!(w, st2,  :out, join, :far)
        short_edge_first || add_connection!(w, head, :near, join, :near)
        add_connection!(w, join, :out,  ctrl, :in)
        add_connection!(w, ctrl, :next, head, :back)

        setsettings!(w, seed, Dict(:value => 1))
        setsettings!(w, ctrl, Dict(:turns => 4))
        return (w = w, ctrl = ctrl, join = join)
    end

    outcome = Dict{Bool, NamedTuple}()
    for first in (false, true)
        empty!(ZCOUNT)
        g = zgraph(short_edge_first = first)
        @test scheduler!(g.w; maxiter = 1000) === true
        outcome[first] = (join     = get(ZCOUNT, :join, 0),
                          ctrl     = get(ZCOUNT, :ctrl, 0),
                          mismatch = get(ZCOUNT, :join_mismatch, 0),
                          total    = getdata(g.w, g.ctrl, :total))
    end

    # оба порядка неразличимы по результату
    @test outcome[true] == outcome[false]
    # входы слияния всегда с одного витка
    @test outcome[true].mismatch == 0
    # и ни одного лишнего пересчёта: по разу за виток
    @test outcome[true].join == outcome[true].ctrl
    @test outcome[true].join == 4
    @test outcome[true].total == 4
end

end # @testset "ЗООПАРК АЛГОРИТМОВ"
