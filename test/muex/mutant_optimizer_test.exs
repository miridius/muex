defmodule Muex.MutantOptimizerTest do
  use ExUnit.Case, async: true

  alias Muex.MutantOptimizer

  defp mutations(source) do
    {:ok, config} = Muex.Config.from_args([])

    source
    |> Code.string_to_quoted!()
    |> Muex.Mutator.walk(config.mutators, %{file: "lib/m.ex"})
  end

  describe "filter_by_complexity/2" do
    # Every mutant used to be scored on its replacement node alone, so a literal
    # or a removed call scored 1 wherever it sat and the balanced level (2)
    # dropped it.
    test "scores a mutant by its enclosing function" do
      all =
        mutations("""
        defmodule M do
          defp fence?(text) do
            trimmed = String.trim_leading(text)
            String.starts_with?(trimmed, "```") or String.starts_with?(trimmed, "~~~")
          end
        end
        """)

      assert MutantOptimizer.filter_by_complexity(all, 2) == all
    end

    test "still drops a function with no decision point" do
      all = mutations("defmodule M do\n  def add(a, b), do: a + b\nend\n")

      assert [_ | _] = all
      assert MutantOptimizer.filter_by_complexity(all, 2) == []
    end
  end

  describe "complexity/1" do
    test "counts the decision points in a function body" do
      ast = Code.string_to_quoted!("def f(x), do: if(x, do: x and 1, else: 2)")
      assert MutantOptimizer.complexity(ast) == 3
    end
  end
end
