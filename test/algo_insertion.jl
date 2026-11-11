############################################################################
#
#  ЗООПАРК АЛГОРИТМОВ: СОРТИРОВКА ВСТАВКАМИ (ВЛОЖЕННЫЕ ЦИКЛЫ)
#
#
############################################################################

import MetidaFlows: PortSpec, DAW, ABW, getnode, getconnection, nodetypestr,
    getportspec, getporttype, getid, makegraph, get_children, get_parents,
    isportexist, ismultiport, setinputbuffer!, invalidate_buffer!, reset!,
    mark_dirty!, isready

# --------------------------------------------------------------------------
#  Инструментовка: след массива и ветка, выбранная на каждом витке. Пишет
#  `InsertGate` — ровно там же, где фиксирует эталон ниже.
# --------------------------------------------------------------------------

INS_TRACE  = Vector{Vector{Int}}()
INS_BRANCH = Symbol[]
traceins!(v, b) = (push!(INS_TRACE, copy(v)); push!(INS_BRANCH, b))
resetins!()     = (empty!(INS_TRACE); empty!(INS_BRANCH))

# --------------------------------------------------------------------------
#  Эталон: тот же развёрнутый цикл обычным кодом. Структура витка повторена
#  один в один, чтобы след сравнивался пошагово.
# --------------------------------------------------------------------------

function insertion_reference(v::Vector{Int})
    a      = copy(v)
    n      = length(a)
    i      = 2
    j      = 1
    epochs = 0
    trace  = Vector{Vector{Int}}()
    branch = Symbol[]
    while i <= n
        if j >= 1 && a[j] > a[j + 1]
            a[j], a[j + 1] = a[j + 1], a[j]
            j -= 1
            push!(branch, :swap)
        else
            i += 1
            j  = i - 1
            epochs += 1
            push!(branch, :epoch)
        end
        push!(trace, copy(a))
    end
    return (sorted = a, trace = trace, branch = branch, epochs = epochs)
end

# ==========================================================================
#  Элементарные узлы
# ==========================================================================

struct InsConstArray <: AbstractNodeType end  # источник массива
struct InsConstInt   <: AbstractNodeType end  # источник целой константы
struct InsLength     <: AbstractNodeType end  # n = length(a)
struct InsertState   <: AbstractNodeType end  # состояние цикла
struct InsAdd        <: AbstractNodeType end  # a + b
struct InsSub        <: AbstractNodeType end  # a − b
struct InsGreater    <: AbstractNodeType end  # a > b
struct InsNotLess    <: AbstractNodeType end  # a >= b
struct InsAnd        <: AbstractNodeType end  # a && b
struct InsReadAt     <: AbstractNodeType end  # a[k], тотально
struct InsSwapAt     <: AbstractNodeType end  # обмен a[k], a[k+1], тотально
struct InsertGate    <: AbstractNodeType end  # ветвление витка

InsVec = Vector{Int}

# --- спецификации ---------------------------------------------------------

spec_insconstarray() = NodeSpec("Ins const array", PortSpec[],
    [PortSpec("Array", InsVec, :array)], [:values])

spec_insconstint() = NodeSpec("Ins const int", PortSpec[],
    [PortSpec("Out", Int, :out)], [:value])

spec_inslength() = NodeSpec("Ins length",
    [PortSpec("Array", InsVec, :array)],
    [PortSpec("Length", Int, :length)])

#  Обычные входы — начальное состояние, обратные — состояние прошлого
#  витка. На первом витке обратные буферы пусты, поэтому они не required.
spec_insertstate() = NodeSpec("Insert state",
    [PortSpec("Initial array",  InsVec, :init_array),
     PortSpec("Initial i",      Int,    :init_i),
     PortSpec("Initial j",      Int,    :init_j),
     PortSpec("Initial epochs", Int,    :init_epochs),
     PortSpec("Array",  InsVec, :array;  kind = :feedback, required = false),
     PortSpec("I",      Int,    :i;      kind = :feedback, required = false),
     PortSpec("J",      Int,    :j;      kind = :feedback, required = false),
     PortSpec("Epochs", Int,    :epochs; kind = :feedback, required = false)],
    [PortSpec("Array",  InsVec, :array),
     PortSpec("I",      Int,    :i),
     PortSpec("J",      Int,    :j),
     PortSpec("Epochs", Int,    :epochs)])

ins_binary_int(name) = NodeSpec(name,
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
    [PortSpec("Out", Int, :out)])

ins_predicate_int(name) = NodeSpec(name,
    [PortSpec("A", Int, :a), PortSpec("B", Int, :b)],
    [PortSpec("Out", Bool, :out)])

spec_insadd()     = ins_binary_int("Ins add")
spec_inssub()     = ins_binary_int("Ins sub")
spec_insgreater() = ins_predicate_int("Ins greater")
spec_insnotless() = ins_predicate_int("Ins not less")

spec_insand() = NodeSpec("Ins and",
    [PortSpec("A", Bool, :a), PortSpec("B", Bool, :b)],
    [PortSpec("Out", Bool, :out)])

spec_insreadat() = NodeSpec("Ins read at",
    [PortSpec("Array", InsVec, :array), PortSpec("Index", Int, :index)],
    [PortSpec("Out", Int, :out)])

spec_insswapat() = NodeSpec("Ins swap at",
    [PortSpec("Array", InsVec, :array), PortSpec("Index", Int, :index)],
    [PortSpec("Out", InsVec, :out)])

#  Трёхходовые ворота: массив отсортирован, шаг внутреннего цикла или
#  новая эпоха. Оба кандидата приходят готовыми, потому что в графе
#  ветвление происходит ПОСЛЕ вычисления обеих сторон.
spec_insertgate() = NodeSpec("Insert gate",
    [PortSpec("Done",        Bool,   :done),
     PortSpec("Step",        Bool,   :step),
     PortSpec("Array",       InsVec, :array),
     PortSpec("Array swap",  InsVec, :array_swap),
     PortSpec("I",           Int,    :i),
     PortSpec("I next",      Int,    :i_next),
     PortSpec("J dec",       Int,    :j_dec),
     PortSpec("Epochs",      Int,    :epochs),
     PortSpec("Epochs next", Int,    :epochs_next)],
    [PortSpec("Array",  InsVec, :array),
     PortSpec("I",      Int,    :i),
     PortSpec("J",      Int,    :j),
     PortSpec("Epochs", Int,    :epochs),
     PortSpec("Sorted", InsVec, :sorted;       kind = :terminal),
     PortSpec("Total epochs", Int, :total_epochs; kind = :terminal)])

# --- реализации -----------------------------------------------------------

MetidaFlows.execute_unsafe!(n::DataNode{InsConstArray}) =
    (setdata!(n, :array, Vector{Int}(n.settings[:values])); [:array])
MetidaFlows.execute_unsafe!(n::DataNode{InsConstInt}) =
    (setdata!(n, :out, Int(n.settings[:value])); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{InsLength}) =
    (setdata!(n, :length, length(getinputdata(n, :array))); [:length])

MetidaFlows.execute_unsafe!(n::DataNode{InsAdd}) =
    (setdata!(n, :out, getinputdata(n, :a) + getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{InsSub}) =
    (setdata!(n, :out, getinputdata(n, :a) - getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{InsGreater}) =
    (setdata!(n, :out, getinputdata(n, :a) > getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{InsNotLess}) =
    (setdata!(n, :out, getinputdata(n, :a) >= getinputdata(n, :b)); [:out])
MetidaFlows.execute_unsafe!(n::DataNode{InsAnd}) =
    (setdata!(n, :out, getinputdata(n, :a) && getinputdata(n, :b)); [:out])

#  Тотальное чтение: индекс за границами даёт typemin(Int). См. заголовок —
#  в графе нет короткого замыкания, поэтому такой виток случается, и
#  результат из него ворота отбрасывают.
function MetidaFlows.execute_unsafe!(node::DataNode{InsReadAt})
    a = getinputdata(node, :array)
    k = getinputdata(node, :index)
    setdata!(node, :out, (1 <= k <= length(a)) ? a[k] : typemin(Int))
    return [:out]
end

#  Тотальный обмен: пары за границами массива нет — возвращается копия как
#  есть.
function MetidaFlows.execute_unsafe!(node::DataNode{InsSwapAt})
    a = copy(getinputdata(node, :array))
    k = getinputdata(node, :index)
    if 1 <= k < length(a)
        a[k], a[k + 1] = a[k + 1], a[k]
    end
    setdata!(node, :out, a)
    return [:out]
end

function MetidaFlows.execute_unsafe!(node::DataNode{InsertGate})
    array = getinputdata(node, :array)
    if getinputdata(node, :done)                      # i > n, внешний цикл кончился
        setdata!(node, :sorted,       array)
        setdata!(node, :total_epochs, getinputdata(node, :epochs))
        return [:sorted, :total_epochs]
    end
    if getinputdata(node, :step)                      # шаг внутреннего цикла
        swapped = getinputdata(node, :array_swap)
        traceins!(swapped, :swap)
        setdata!(node, :array,  swapped)
        setdata!(node, :i,      getinputdata(node, :i))
        setdata!(node, :j,      getinputdata(node, :j_dec))
        setdata!(node, :epochs, getinputdata(node, :epochs))
    else                                              # новая эпоха
        traceins!(array, :epoch)
        setdata!(node, :array,  array)
        setdata!(node, :i,      getinputdata(node, :i_next))
        setdata!(node, :j,      getinputdata(node, :i))   # j = (i+1) - 1 = i
        setdata!(node, :epochs, getinputdata(node, :epochs_next))
    end
    return [:array, :i, :j, :epochs]
end

function MetidaFlows.execute_unsafe!(node::DataNode{InsertState})
    back = getinputdata(node, :array)
    if back === nothing                               # первый виток
        setdata!(node, :array,  getinputdata(node, :init_array))
        setdata!(node, :i,      getinputdata(node, :init_i))
        setdata!(node, :j,      getinputdata(node, :init_j))
        setdata!(node, :epochs, getinputdata(node, :init_epochs))
    else                                              # состояние прошлого витка
        setdata!(node, :array,  back)
        setdata!(node, :i,      getinputdata(node, :i))
        setdata!(node, :j,      getinputdata(node, :j))
        setdata!(node, :epochs, getinputdata(node, :epochs))
    end
    return [:array, :i, :j, :epochs]
end

# ==========================================================================
#  Сборка графа
# ==========================================================================

"""
    build_insertion_sort(values) -> NamedTuple

Граф сортировки вставками: вложенные циклы, развёрнутые в один плоский
цикл по паттерну эпохи. Возвращает workflow и идентификаторы узлов.
"""
function build_insertion_sort(values::Vector{Int}; type::Symbol = :ABW,
                              reverse_connections::Bool = false)
    w      = Workflow(0; type = type)
    w.name = "Insertion sort"

    a0    = add_node!(w, DataNode(InsConstArray, spec_insconstarray()))
    two   = add_node!(w, DataNode(InsConstInt,   spec_insconstint()))
    one   = add_node!(w, DataNode(InsConstInt,   spec_insconstint()))
    zero  = add_node!(w, DataNode(InsConstInt,   spec_insconstint()))
    len   = add_node!(w, DataNode(InsLength,     spec_inslength()))

    head  = add_node!(w, DataNode(InsertState,   spec_insertstate()))

    done  = add_node!(w, DataNode(InsGreater,    spec_insgreater()))   # i > n
    alive = add_node!(w, DataNode(InsNotLess,    spec_insnotless()))   # j >= 1
    jnext = add_node!(w, DataNode(InsAdd,        spec_insadd()))       # j + 1
    left  = add_node!(w, DataNode(InsReadAt,     spec_insreadat()))    # a[j]
    right = add_node!(w, DataNode(InsReadAt,     spec_insreadat()))    # a[j+1]
    gt    = add_node!(w, DataNode(InsGreater,    spec_insgreater()))   # a[j] > a[j+1]
    step  = add_node!(w, DataNode(InsAnd,        spec_insand()))       # alive && gt
    swap  = add_node!(w, DataNode(InsSwapAt,     spec_insswapat()))    # обмен
    inext = add_node!(w, DataNode(InsAdd,        spec_insadd()))       # i + 1
    jdec  = add_node!(w, DataNode(InsSub,        spec_inssub()))       # j - 1
    enext = add_node!(w, DataNode(InsAdd,        spec_insadd()))       # epochs + 1

    gate  = add_node!(w, DataNode(InsertGate,    spec_insertgate()))

    setsettings!(w, a0,   Dict(:values => copy(values)))
    setsettings!(w, two,  Dict(:value  => 2))
    setsettings!(w, one,  Dict(:value  => 1))
    setsettings!(w, zero, Dict(:value  => 0))

    #  Связи перечислены списком, а не вызовами: порядок их создания —
    #  предмет теста I7, и обратный порядок должен получаться тем же
    #  построителем, через add_connection!. Прямой записи в
    #  w.connections здесь быть не должно: версия графа не поднимется.
    cons = [
        #  Начальное состояние
        (a0,   :array, head, :init_array),
        (two,  :out,   head, :init_i),
        (one,  :out,   head, :init_j),
        (zero, :out,   head, :init_epochs),

        #  Длина считается один раз по исходному массиву: обмены её не меняют
        (a0,   :array, len,  :array),

        #  Условие внешнего цикла
        (head, :i,     done, :a),
        (len,  :length, done, :b),

        #  Условие внутреннего цикла: j >= 1 и a[j] > a[j+1]
        (head, :j,     alive, :a),
        (one,  :out,   alive, :b),
        (head, :j,     jnext, :a),
        (one,  :out,   jnext, :b),
        (head, :array, left,  :array),
        (head, :j,     left,  :index),
        (head, :array, right, :array),
        (jnext, :out,  right, :index),
        (left,  :out,  gt,    :a),
        (right, :out,  gt,    :b),
        (alive, :out,  step,  :a),
        (gt,    :out,  step,  :b),

        #  Кандидаты обеих ветвей считаются каждый виток
        (head, :array,  swap,  :array),
        (head, :j,      swap,  :index),
        (head, :i,      inext, :a),
        (one,  :out,    inext, :b),
        (head, :j,      jdec,  :a),
        (one,  :out,    jdec,  :b),
        (head, :epochs, enext, :a),
        (one,  :out,    enext, :b),

        #  Ворота
        (done,  :out,    gate, :done),
        (step,  :out,    gate, :step),
        (head,  :array,  gate, :array),
        (swap,  :out,    gate, :array_swap),
        (head,  :i,      gate, :i),
        (inext, :out,    gate, :i_next),
        (jdec,  :out,    gate, :j_dec),
        (head,  :epochs, gate, :epochs),
        (enext, :out,    gate, :epochs_next),

        #  Замыкание цикла
        (gate, :array,  head, :array),
        (gate, :i,      head, :i),
        (gate, :j,      head, :j),
        (gate, :epochs, head, :epochs),
    ]
    for c in (reverse_connections ? Iterators.reverse(cons) : cons)
        add_connection!(w, c...)
    end

    return (w = w, a0 = a0, two = two, one = one, zero = zero, len = len,
            head = head, done = done, alive = alive, jnext = jnext,
            left = left, right = right, gt = gt, step = step, swap = swap,
            inext = inext, jdec = jdec, enext = enext, gate = gate)
end

"Отсортировать массив графом. Возвращает результат, число витков, эпох и граф."
function graph_insertion(values::Vector{Int}; maxiter = 100_000)
    resetins!()
    g = build_insertion_sort(values)
    scheduler!(g.w; maxiter = maxiter)
    return (sorted = getdata(g.w, g.gate, :sorted),
            turns  = length(INS_TRACE),
            epochs = getdata(g.w, g.gate, :total_epochs),
            g      = g)
end

# ==========================================================================

@testset verbose = true "СОРТИРОВКА ВСТАВКАМИ                             " begin

# --------------------------------------------------------------------------
@testset "I1. элементарные узлы по отдельности             " begin
    function run1(type, spec, inputs::Dict{Symbol, Any}; settings = Dict{Symbol, Any}())
        node = DataNode(type, spec; settings = settings)
        for (port, value) in inputs
            setinputbuffer!(node, port, 1, value)
        end
        ports = MetidaFlows.execute_unsafe!(node)
        return node, ports
    end

    n, p = run1(InsConstArray, spec_insconstarray(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:values => [3, 1, 2]))
    @test p == [:array]
    @test getdata(n, :array) == [3, 1, 2]
    @test getdata(n, :array) isa Vector{Int}

    n, _ = run1(InsConstInt, spec_insconstint(), Dict{Symbol, Any}();
                settings = Dict{Symbol, Any}(:value => 7))
    @test getdata(n, :out) === 7

    n, _ = run1(InsLength, spec_inslength(), Dict{Symbol, Any}(:array => [5, 4]))
    @test getdata(n, :length) === 2
    n, _ = run1(InsLength, spec_inslength(), Dict{Symbol, Any}(:array => Int[]))
    @test getdata(n, :length) === 0

    n, _ = run1(InsAdd, spec_insadd(), Dict{Symbol, Any}(:a => 4, :b => 1))
    @test getdata(n, :out) === 5
    n, _ = run1(InsSub, spec_inssub(), Dict{Symbol, Any}(:a => 4, :b => 1))
    @test getdata(n, :out) === 3
    n, _ = run1(InsGreater, spec_insgreater(), Dict{Symbol, Any}(:a => 4, :b => 1))
    @test getdata(n, :out) === true
    n, _ = run1(InsGreater, spec_insgreater(), Dict{Symbol, Any}(:a => 1, :b => 1))
    @test getdata(n, :out) === false
    n, _ = run1(InsNotLess, spec_insnotless(), Dict{Symbol, Any}(:a => 1, :b => 1))
    @test getdata(n, :out) === true
    n, _ = run1(InsNotLess, spec_insnotless(), Dict{Symbol, Any}(:a => 0, :b => 1))
    @test getdata(n, :out) === false
    n, _ = run1(InsAnd, spec_insand(), Dict{Symbol, Any}(:a => true, :b => true))
    @test getdata(n, :out) === true
    n, _ = run1(InsAnd, spec_insand(), Dict{Symbol, Any}(:a => false, :b => true))
    @test getdata(n, :out) === false

    #  ТОТАЛЬНОСТЬ: вот то, из-за чего граф не падает в вырожденный виток
    n, _ = run1(InsReadAt, spec_insreadat(), Dict{Symbol, Any}(:array => [9, 8], :index => 1))
    @test getdata(n, :out) === 9
    for k in (0, 3, -1)
        n, _ = run1(InsReadAt, spec_insreadat(), Dict{Symbol, Any}(:array => [9, 8], :index => k))
        @test getdata(n, :out) === typemin(Int)
    end
    n, _ = run1(InsReadAt, spec_insreadat(), Dict{Symbol, Any}(:array => Int[], :index => 1))
    @test getdata(n, :out) === typemin(Int)

    n, _ = run1(InsSwapAt, spec_insswapat(), Dict{Symbol, Any}(:array => [9, 8, 7], :index => 1))
    @test getdata(n, :out) == [8, 9, 7]
    n, _ = run1(InsSwapAt, spec_insswapat(), Dict{Symbol, Any}(:array => [9, 8, 7], :index => 3))
    @test getdata(n, :out) == [9, 8, 7]          # пары нет, массив как есть
    n, _ = run1(InsSwapAt, spec_insswapat(), Dict{Symbol, Any}(:array => Int[], :index => 1))
    @test getdata(n, :out) == Int[]
    #  узел не портит вход
    src = [9, 8]
    n, _ = run1(InsSwapAt, spec_insswapat(), Dict{Symbol, Any}(:array => src, :index => 1))
    @test src == [9, 8]

    #  Голова: пустой обратный буфер = первый виток
    node = DataNode(InsertState, spec_insertstate())
    for (port, value) in (:init_array => [3, 1], :init_i => 2, :init_j => 1,
                          :init_epochs => 0)
        setinputbuffer!(node, port, 1, value)
    end
    p = MetidaFlows.execute_unsafe!(node)
    @test p == [:array, :i, :j, :epochs]
    @test getdata(node, :array) == [3, 1]
    @test getdata(node, :i) === 2 && getdata(node, :j) === 1
    @test getdata(node, :epochs) === 0
    #  заполненный обратный буфер перекрывает начальные значения
    for (port, value) in (:array => [1, 3], :i => 3, :j => 2, :epochs => 1)
        setinputbuffer!(node, port, 2, value)
    end
    MetidaFlows.execute_unsafe!(node)
    @test getdata(node, :array) == [1, 3]
    @test getdata(node, :i) === 3 && getdata(node, :j) === 2
    @test getdata(node, :epochs) === 1

    #  Ворота: три исхода
    function gate1(; done, step)
        node = DataNode(InsertGate, spec_insertgate())
        for (port, value) in (:done => done, :step => step,
                              :array => [5, 4], :array_swap => [4, 5],
                              :i => 2, :i_next => 3, :j_dec => 0,
                              :epochs => 1, :epochs_next => 2)
            setinputbuffer!(node, port, 1, value)
        end
        node, MetidaFlows.execute_unsafe!(node)
    end
    resetins!()
    n, p = gate1(done = true, step = true)           # done сильнее step
    @test p == [:sorted, :total_epochs]
    @test getdata(n, :sorted) == [5, 4] && getdata(n, :total_epochs) === 1
    @test isempty(INS_TRACE)                          # завершающий виток не след
    n, p = gate1(done = false, step = true)           # шаг внутреннего цикла
    @test p == [:array, :i, :j, :epochs]
    @test getdata(n, :array) == [4, 5]
    @test getdata(n, :i) === 2 && getdata(n, :j) === 0
    @test getdata(n, :epochs) === 1                   # эпоха не выросла
    n, p = gate1(done = false, step = false)          # новая эпоха
    @test getdata(n, :array) == [5, 4]                # массив не тронут
    @test getdata(n, :i) === 3 && getdata(n, :j) === 2 # j = i
    @test getdata(n, :epochs) === 2
    @test INS_BRANCH == [:swap, :epoch]
end

# --------------------------------------------------------------------------
@testset "I2. структура графа                             " begin
    g = build_insertion_sort([3, 1, 2])
    @test length(g.w.nodes) == 18
    @test length(g.w.connections) == 40
    @test g.w isa Workflow{ABW}

    #  замыкание цикла — ровно четыре обратных ребра, все в голову
    fb = [c for (_, c) in g.w.connections
          if getportspec(getnode(g.w, c.input_id), c.input_port, :input).kind == :feedback]
    @test length(fb) == 4
    @test all(c -> c.input_id == g.head && c.output_id == g.gate, fb)
    @test Set(c.input_port for c in fb) == Set([:array, :i, :j, :epochs])

    #  всё состояние цикла и только оно лежит в обратных портах
    hspec = getnode(g.w, g.head).spec
    @test Set(p.label for p in hspec.input_ports if p.kind == :feedback) ==
          Set([:array, :i, :j, :epochs])
    @test all(!p.required for p in hspec.input_ports if p.kind == :feedback)

    #  терминальные порты не участвуют в цикле
    gspec = getnode(g.w, g.gate).spec
    @test Set(p.label for p in gspec.output_ports if p.kind == :terminal) ==
          Set([:sorted, :total_epochs])

    #  граф циклический, и DAW его не берёт. Та же структура собирается тем
    #  же построителем под :DAW — копировать словари узлов и связей в новую
    #  модель нельзя: прямая запись не поднимает версию графа, и кеш
    #  остаётся от пустой модели (пустой граф, is_cyclic = false).
    gd = build_insertion_sort([3, 1, 2]; type = :DAW)
    @test_throws ErrorException scheduler!(gd.w)

    #  длина берётся от источника, а не от головы: обмены её не меняют
    @test getconnection(g.w, first(c for (c, con) in g.w.connections
                                   if con.input_id == g.len)).output_id == g.a0

    #  у головы четыре обычных входа — начальное состояние
    @test length([p for p in hspec.input_ports if p.kind == :normal]) == 4
end

# --------------------------------------------------------------------------
@testset "I3. сортировка и след совпадают с эталоном       " begin
    for v in ([3, 1, 2], [5, 2, 9, 1, 7, 3], [1, 2, 3, 4], [4, 3, 2, 1],
              [2, 2, 1, 2], [10, -3, 0, 7, -3], collect(8:-1:1))
        r = graph_insertion(copy(v))
        ref = insertion_reference(v)
        @test r.sorted == sort(v)
        @test r.sorted == ref.sorted
        @test r.turns  == length(ref.trace)
        @test r.epochs == ref.epochs
        @test INS_TRACE  == ref.trace           # пошагово, не только итог
        @test INS_BRANCH == ref.branch
    end
end

# --------------------------------------------------------------------------
@testset "I4. вложенность: эпохи фиксированы, витки нет    " begin
    #  ГЛАВНОЕ ИЗМЕРЕНИЕ ФАЙЛА. Внешний цикл всегда делает n-1 итераций,
    #  сколько бы работы ни было внутри, а число витков графа зависит от
    #  данных. Так снаружи видно, что вложенность настоящая, хотя цикл в
    #  графе один.
    for n in 2:7
        sorted   = graph_insertion(collect(1:n))
        reversed = graph_insertion(collect(n:-1:1))

        @test sorted.epochs   == n - 1
        @test reversed.epochs == n - 1          # эпох столько же
        @test sorted.turns    == n - 1          # внутренний цикл не работал
        @test reversed.turns  == (n - 1) + n * (n - 1) ÷ 2
        @test count(==(:swap),  INS_BRANCH) == n * (n - 1) ÷ 2
        @test count(==(:epoch), INS_BRANCH) == n - 1
    end

    #  витки = эпохи + обмены, всегда
    for v in ([3, 1, 2], [5, 2, 9, 1, 7, 3], [2, 2, 2], collect(6:-1:1))
        r = graph_insertion(copy(v))
        @test r.turns == r.epochs + count(==(:swap), INS_BRANCH)
        @test count(==(:swap), INS_BRANCH) == insertion_reference(v) |>
              x -> count(==(:swap), x.branch)
    end

    #  на обратном входе каждая эпоха делает ровно на один шаг больше
    r = graph_insertion(collect(6:-1:1))
    steps = Int[]
    cur   = 0
    for b in INS_BRANCH
        b === :swap ? (cur += 1) : (push!(steps, cur); cur = 0)
    end
    @test steps == [1, 2, 3, 4, 5]
end

# --------------------------------------------------------------------------
@testset "I5. вырожденные входы                           " begin
    #  Пустой и одноэлементный: внешний цикл не запускается, витков нет.
    #  В графе при этом голова и всё тело ОДИН РАЗ считаются — и чтение за
    #  концом происходит. Именно поэтому ReadAt тотальный.
    for v in (Int[], [42])
        r = graph_insertion(copy(v))
        @test r.sorted == v
        @test r.turns  == 0
        @test r.epochs == 0
        @test isempty(INS_TRACE)
    end

    #  тело на пустом массиве всё-таки отработало
    r = graph_insertion(Int[])
    @test getdata(r.g.w, r.g.left,  :out) === typemin(Int)
    @test getdata(r.g.w, r.g.right, :out) === typemin(Int)
    @test getdata(r.g.w, r.g.swap,  :out) == Int[]
    @test getdata(r.g.w, r.g.done,  :out) === true     # 2 > 0

    #  все элементы равны: обменов нет, эпох n-1
    r = graph_insertion(fill(4, 5))
    @test r.sorted == fill(4, 5)
    @test r.turns == 4 && r.epochs == 4
    @test all(==(:epoch), INS_BRANCH)

    #  две точки, худший случай
    r = graph_insertion([2, 1])
    @test r.sorted == [1, 2]
    @test r.turns == 2 && r.epochs == 1
    @test INS_BRANCH == [:swap, :epoch]
end

# --------------------------------------------------------------------------
@testset "I6. состояние цикла целиком в обратных портах    " begin
    r = graph_insertion([5, 2, 9, 1])
    head = getnode(r.g.w, r.g.head)

    #  В обратных буферах лежит то состояние, на котором цикл и
    #  остановился: i = n+1. Завершающий виток его прочитал, увидел
    #  done и написал только терминальные порты, не тронув обратные.
    @test getinputdata(head, :i) == length([5, 2, 9, 1]) + 1
    @test getinputdata(head, :array) == [1, 2, 5, 9]

    #  :full чистит обратные буферы, :soft оставляет
    reset!(r.g.w)
    @test isempty(head.input_buffer[:array])
    @test isempty(head.input_buffer[:i])

    r2 = graph_insertion([5, 2, 9, 1])
    head2 = getnode(r2.g.w, r2.g.head)
    reset!(r2.g.w; soft = true)
    @test !isempty(head2.input_buffer[:array])
    #  с :soft прогон продолжает с того же состояния: массив уже
    #  отсортирован, поэтому идут только эпохи — но i уже на конце, значит
    #  первый же виток завершающий
    resetins!()
    scheduler!(r2.g.w; reset_mode = :soft, maxiter = 100_000)
    @test getdata(r2.g.w, r2.g.gate, :sorted) == [1, 2, 5, 9]
    @test length(INS_TRACE) <= 1

    #  а после :full тот же граф считает заново с начала
    resetins!()
    scheduler!(r.g.w; maxiter = 100_000)
    @test getdata(r.g.w, r.g.gate, :sorted) == [1, 2, 5, 9]
    @test length(INS_TRACE) == insertion_reference([5, 2, 9, 1]).trace |> length
end

# --------------------------------------------------------------------------
@testset "I7. порядок создания связей не влияет            " begin
    #  Граф построен в порядке зависимостей. Проверяем, что результат не
    #  зависит от него: собираем тот же граф, добавляя обратные рёбра
    #  ПЕРВЫМИ. Без распространения :dirty по всему конусу вниз такой граф
    #  шёл бы другой траекторией.
    v = [5, 2, 9, 1, 7, 3]
    ref = graph_insertion(copy(v))
    reftrace = copy(INS_TRACE)

    #  Тот же граф, но связи создаются в обратном порядке: номера связей
    #  растут так же, а порядок вставки другой. Собирается тем же
    #  построителем, через add_connection!: переносить узлы записью в
    #  w2.nodes нельзя — версия графа не поднимется, и обе модели будут
    #  держать одни и те же объекты узлов.
    g2 = build_insertion_sort(copy(v); reverse_connections = true)
    @test length(g2.w.connections) == 40

    resetins!()
    scheduler!(g2.w; maxiter = 100_000)
    @test getdata(g2.w, g2.gate, :sorted) == sort(v)
    @test INS_TRACE == reftrace
end

# --------------------------------------------------------------------------
@testset "I8. вставки против пузырька                     " begin
    #  Два алгоритма на одном входе: у пузырька число витков зависит
    #  только от n, у вставок — от данных. Это и есть разница между
    #  фиксированной вложенностью и работой по надобности.
    for v in ([1, 2, 3, 4, 5], [5, 4, 3, 2, 1], [3, 1, 4, 1, 5])
        ins = graph_insertion(copy(v))
        bub_sorted, bub_turns, _ = graph_sort(copy(v))
        @test ins.sorted == bub_sorted == sort(v)
        @test bub_turns == length(v) * (length(v) - 1) ÷ 2   # от данных не зависит
    end

    #  на отсортированном входе вставки дешевле пузырька
    v = collect(1:6)
    ins = graph_insertion(copy(v))
    _, bub_turns, _ = graph_sort(copy(v))
    @test ins.turns == 5
    @test bub_turns == 15
end

end
