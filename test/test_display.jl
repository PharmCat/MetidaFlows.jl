############################################################################
#
#  КАТЕГОРИЯ: ОТОБРАЖЕНИЕ
#
#  Назначение: проверить методы show. Это единственный способ, которым
#  пользователь видит объект в REPL, поэтому в текст должны попадать
#  идентификатор, статус, имя спецификации и полный список портов —
#  включая вырожденный случай «портов нет».
#
#  Тесты проверяют наличие смысловых фрагментов, а не точную верстку:
#  форматирование может меняться, состав сведений — нет.
#
############################################################################

@testset "ОТОБРАЖЕНИЕ                                      " begin

# --------------------------------------------------------------------------
@testset "D1. порт                                         " begin
    out = sprint(show, PortSpec("Value", Int, :val))
    @test occursin("Port name: Value", out)
    @test occursin("label", out)
    @test occursin("val", out)
    @test occursin("datatype", out)
end

# --------------------------------------------------------------------------
@testset "D2. спецификация                                 " begin
    out = sprint(show, spec_add())
    @test occursin("Name: Add", out)
    @test occursin("Input ports", out)
    @test occursin("Output ports", out)
    @test occursin("Available settings", out)
    @test occursin("label: \"a\"", out)
    @test occursin("label: \"b\"", out)
    @test occursin("label: \"out\"", out)

    # Вырожденные списки портов помечаются явно.
    @test occursin("Input ports: empty",  sprint(show, spec_const()))
    @test occursin("Output ports: empty", sprint(show, spec_sink()))
    empty_spec = sprint(show, spec_noports())
    @test occursin("Input ports: empty",  empty_spec)
    @test occursin("Output ports: empty", empty_spec)
end

# --------------------------------------------------------------------------
@testset "D3. нода                                         " begin
    w  = Workflow(0)
    id = add_node!(w, DataNode(AddNode, spec_add()))
    n  = getnode(w, id)
    setsettings!(w, id, Dict(:alpha => 1))

    out = sprint(show, n)
    @test occursin("Node:", out)
    @test occursin("ID: $(id)", out)
    @test occursin("Status: dirty", out)
    @test occursin("Name: Add", out)          # спецификация выводится целиком
    @test occursin("Settings", out)
    @test occursin("alpha", out)

    # Статус в выводе отслеживает реальное состояние ноды.
    setstatus!(n, :clean)
    @test occursin("Status: clean", sprint(show, n))
end

# --------------------------------------------------------------------------
@testset "D4. связь                                        " begin
    out = sprint(show, NodeConnection(1, :x, 2, :y))
    @test occursin("Node Connection", out)
    @test occursin("Output node ID: 1", out)
    @test occursin("Input node ID: 2", out)
    @test occursin("x", out) && occursin("y", out)
end

end # @testset "ОТОБРАЖЕНИЕ"
