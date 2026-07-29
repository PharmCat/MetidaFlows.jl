############################################################################
#
#  КАТЕГОРИЯ: СЦЕНАРИИ
#
#  Назначение: проверить пакет так, как им пользуются — целыми конвейерами
#  на реальных данных. Каждый сценарий собирает граф, прогоняет его и
#  проверяет не только результат, но и то, сколько раз реально исполнилась
#  каждая нода (счётчик CALLS): именно это отличает работающий движок
#  инкрементальных вычислений от простого обхода графа.
#
#  Данные: test/csv/pkdata2.csv — 160 строк x 4 колонки,
#  10 субъектов, 2 формулировки, 8 строк с Concentration > 200
#  (из них 2 разных субъекта), 115 строк с Concentration > 100.
#
############################################################################

@testset "СЦЕНАРИИ                                         " begin

# --------------------------------------------------------------------------
@testset "S1. CSV -> DataFrame -> сводка (DAW)             " begin
    # Базовый аналитический конвейер: загрузка файла, преобразование в
    # DataFrame, подсчёт агрегатов. Проверяется сквозной проход данных
    # через типизированные порты и итоговые статусы.
    resetcalls!()
    p = build_pipeline()

    @test scheduler!(p.w) === true

    @test getdata(p.w, p.summ, :nrows)     == 160
    @test getdata(p.w, p.summ, :nsubjects) == 10

    # Промежуточные результаты остаются доступными на своих нодах.
    df = getdata(p.w, p.todf, :dataframe)
    @test df isa DataFrame
    @test size(df) == (160, 4)
    @test getdata(p.w, p.load, :csv) isa CSV.File

    @test all(getstatus(getnode(p.w, i)) == :clean for i in (p.load, p.todf, p.summ))
    @test calls(:loadcsv) == 1 && calls(:todf) == 1 && calls(:summary) == 1
end

# --------------------------------------------------------------------------
@testset "S2. тот же конвейер под ABW                      " begin
    # Планировщик ABW строит порядок исполнения по готовности, а не по
    # топологии. Результат обязан совпасть с DAW.
    resetcalls!()
    p = build_pipeline(type = :ABW)

    @test scheduler!(p.w) === true
    @test getdata(p.w, p.summ, :nrows)     == 160
    @test getdata(p.w, p.summ, :nsubjects) == 10
    @test calls(:loadcsv) == 1 && calls(:todf) == 1 && calls(:summary) == 1
end

# --------------------------------------------------------------------------
@testset "S3. инкрементальный пересчёт по execute!         " begin
    # Ключевой сценарий пакета: после изменения настройки одной ноды
    # пересчитывается только она и то, что ниже по графу. Всё, что выше,
    # остаётся :clean и повторно не исполняется.
    resetcalls!()
    w    = Workflow(0)
    load = add_node!(w, DataNode(LoadCSVNode, spec_loadcsv()))
    todf = add_node!(w, DataNode(ToDataFrameNode, spec_todf()))
    filt = add_node!(w, DataNode(FilterRowsNode, spec_filter()))
    summ = add_node!(w, DataNode(SummaryNode, spec_summary()))
    add_connection!(w, load, :csv, todf, :csv)
    add_connection!(w, todf, :dataframe, filt, :dataframe)
    add_connection!(w, filt, :dataframe, summ, :dataframe)
    setsettings!(w, load, Dict(:file => CSV_PATH))
    setsettings!(w, filt, Dict(:column => :Concentration, :threshold => 200.0))

    # Первый прогон: execute! на последней ноде подтягивает всю цепочку.
    @test execute!(w, summ) == [:nrows, :nsubjects]
    @test getdata(w, summ, :nrows)     == 8
    @test getdata(w, summ, :nsubjects) == 2
    @test (calls(:loadcsv), calls(:todf), calls(:filter), calls(:summary)) == (1, 1, 1, 1)

    # Повторный вызов не пересчитывает ничего: все ноды :clean.
    @test execute!(w, summ) == [:nrows, :nsubjects]
    @test (calls(:loadcsv), calls(:todf), calls(:filter), calls(:summary)) == (1, 1, 1, 1)

    # Меняем порог фильтра — инвалидируются только фильтр и сводка.
    setsettings!(w, filt, Dict(:threshold => 100.0))
    @test getstatus(getnode(w, load)) == :clean
    @test getstatus(getnode(w, todf)) == :clean
    @test getstatus(getnode(w, filt)) == :dirty
    @test getstatus(getnode(w, summ)) == :dirty

    execute!(w, summ)
    @test getdata(w, summ, :nrows)     == 115
    @test getdata(w, summ, :nsubjects) == 10
    @test (calls(:loadcsv), calls(:todf)) == (1, 1)     # верх графа не тронут
    @test (calls(:filter), calls(:summary)) == (2, 2)

    # Меняем источник — пересчитывается весь конвейер.
    setsettings!(w, load, Dict(:file => CSV_PATH))
    @test all(getstatus(getnode(w, i)) == :dirty for i in (load, todf, filt, summ))
    execute!(w, summ)
    @test (calls(:loadcsv), calls(:todf), calls(:filter), calls(:summary)) == (2, 2, 3, 3)
    @test getdata(w, summ, :nrows) == 115
end

# --------------------------------------------------------------------------
@testset "S4. ветвление: два фильтра от одного DataFrame   " begin
    # Один выходной порт питает нескольких потомков. Каждый получает
    # собственную запись в буфере, потомки не мешают друг другу.
    resetcalls!()
    w    = Workflow(0)
    load = add_node!(w, DataNode(LoadCSVNode, spec_loadcsv()))
    todf = add_node!(w, DataNode(ToDataFrameNode, spec_todf()))
    hi   = add_node!(w, DataNode(FilterRowsNode, spec_filter()))
    lo   = add_node!(w, DataNode(FilterRowsNode, spec_filter()))
    shi  = add_node!(w, DataNode(SummaryNode, spec_summary()))
    slo  = add_node!(w, DataNode(SummaryNode, spec_summary()))
    add_connection!(w, load, :csv, todf, :csv)
    add_connection!(w, todf, :dataframe, hi, :dataframe)
    add_connection!(w, todf, :dataframe, lo, :dataframe)
    add_connection!(w, hi, :dataframe, shi, :dataframe)
    add_connection!(w, lo, :dataframe, slo, :dataframe)
    setsettings!(w, load, Dict(:file => CSV_PATH))
    setsettings!(w, hi, Dict(:column => :Concentration, :threshold => 200.0))
    setsettings!(w, lo, Dict(:column => :Concentration, :threshold => 100.0))

    @test scheduler!(w) === true
    @test getdata(w, shi, :nrows) == 8
    @test getdata(w, slo, :nrows) == 115

    # Источник и преобразователь исполнились по одному разу на весь граф.
    @test calls(:loadcsv) == 1 && calls(:todf) == 1
    @test calls(:filter)  == 2 && calls(:summary) == 2
end

# --------------------------------------------------------------------------
@testset "S5. достройка графа между прогонами              " begin
    # Типичная работа в редакторе: посчитали часть графа, добавили ноду,
    # посчитали снова. Связь от уже посчитанного (:clean) родителя сразу
    # наполняет буфер потомка.
    resetcalls!()
    w    = Workflow(0)
    load = add_node!(w, DataNode(LoadCSVNode, spec_loadcsv()))
    todf = add_node!(w, DataNode(ToDataFrameNode, spec_todf()))
    add_connection!(w, load, :csv, todf, :csv)
    setsettings!(w, load, Dict(:file => CSV_PATH))

    @test execute!(w, todf) == [:dataframe]
    @test size(getdata(w, todf, :dataframe)) == (160, 4)

    # Достраиваем сводку.
    summ = add_node!(w, DataNode(SummaryNode, spec_summary()))
    con  = add_connection!(w, todf, :dataframe, summ, :dataframe)
    @test getinputdata(getnode(w, summ), :dataframe, con) isa DataFrame  # проброшено сразу
    @test getstatus(getnode(w, todf)) == :clean                          # родителя не трогали

    execute!(w, summ)
    @test getdata(w, summ, :nrows) == 160
    @test calls(:loadcsv) == 1 && calls(:todf) == 1     # верх графа не пересчитан
end

# --------------------------------------------------------------------------
@testset "S6. ромб: общий предок и узел слияния            " begin
    # Классическая проверка планировщика: общий предок исполняется один
    # раз, узел слияния — тоже один раз, после обоих родителей.
    for wftype in (:DAW, :ABW)
        resetcalls!()
        d = build_diamond(3; type = wftype)
        @test scheduler!(d.w) === true
        @test getdata(d.w, d.join, :out) == 12          # (3*2) + (3*2)
        @test calls(:const)  == 1
        @test calls(:double) == 2
        @test calls(:add)    == 1
    end
end

# --------------------------------------------------------------------------
@testset "S7. агрегация нескольких источников (MultiPort)  " begin
    # Три источника сходятся в один входной порт. Значения хранятся по
    # идентификаторам связей и не затирают друг друга.
    resetcalls!()
    w   = Workflow(0)
    m   = DataNode(CollectNode, spec_collect())
    mid = add_node!(w, m)
    ids = Int[]
    for v in (1, 2, 3)
        s = add_node!(w, DataNode(ConstNode, spec_const()))
        add_connection!(w, s, :out, mid, :ins)
        setsettings!(w, s, Dict(:value => v))
        push!(ids, s)
    end

    @test scheduler!(w) === true
    @test length(getinputdata(m, :ins)) == 3
    @test getdata(w, mid, :out) == 6
    @test calls(:const) == 3 && calls(:collect) == 1

    # Удаление одной связи убирает ровно её вклад.
    delete_connection!(w, find_connections(w, ids[3])[1])
    execute!(w, mid)
    @test getdata(w, mid, :out) == 3
end

# --------------------------------------------------------------------------
@testset "S8. перестроение графа                           " begin
    # Удаление и повторное добавление ноды. Идентификаторы не
    # переиспользуются, а посчитанная нода переживает переподключение.
    resetcalls!()
    lin = build_linear(5)
    w, src, dbl = lin.w, lin.src, lin.dbl
    scheduler!(w)
    @test getdata(w, dbl, :out) == 10

    srcnode = getnode(w, src)
    @test delete_node!(w, src)
    @test !isnodeexist(w, src)
    @test isempty(w.connections)

    # Нода в статусе :clean при повторном добавлении не сбрасывается.
    newid = add_node!(w, srcnode)
    @test newid == 3                       # 1 и 2 уже израсходованы
    @test getstatus(srcnode) == :clean
    @test getdata(srcnode, :out) == 5

    newcon = add_connection!(w, newid, :out, dbl, :in)
    @test getinputdata(getnode(w, dbl), :in, newcon) == 5   # проброшено сразу
    execute!(w, dbl)
    @test getdata(w, dbl, :out) == 10
    @test calls(:const) == 1               # источник больше не исполнялся
end

# --------------------------------------------------------------------------
@testset "S9. pull (execute!) против push (scheduler!)     " begin
    # execute! считает только то, что нужно запрошенной ноде;
    # scheduler! всегда обходит граф целиком.
    resetcalls!()
    w = Workflow(0)
    s = add_node!(w, DataNode(ConstNode, spec_const()))
    a = add_node!(w, DataNode(DoubleNode, spec_double()))
    b = add_node!(w, DataNode(DoubleNode, spec_double()))   # ветка, которая не нужна
    add_connection!(w, s, :out, a, :in)
    add_connection!(w, s, :out, b, :in)
    setsettings!(w, s, Dict(:value => 4))

    execute!(w, a)
    @test getdata(w, a, :out) == 8
    @test getstatus(getnode(w, b)) == :dirty     # вторая ветка не тронута
    @test calls(:double) == 1

    scheduler!(w)
    @test getdata(w, b, :out) == 8
    @test calls(:double) == 3                    # обе ветки после полного обхода
end

end # @testset "СЦЕНАРИИ"
