defmodule Muex.CoverageTest do
  use ExUnit.Case, async: true

  alias Muex.Coverage

  describe "building and querying an index" do
    setup do
      index =
        Coverage.new()
        |> Coverage.put("lib/a.ex", 10, "test/a_test.exs")
        |> Coverage.put("lib/a.ex", 10, "test/b_test.exs")
        |> Coverage.put("lib/a.ex", 11, "test/a_test.exs")

      %{index: index}
    end

    test "tests_for returns the covering test files for a line, sorted", %{index: index} do
      assert Coverage.tests_for(index, "lib/a.ex", 10) ==
               {:covered, ["test/a_test.exs", "test/b_test.exs"]}

      assert Coverage.tests_for(index, "lib/a.ex", 11) == {:covered, ["test/a_test.exs"]}
    end

    test "tests_for returns :unknown for a line with no coverage data", %{index: index} do
      assert Coverage.tests_for(index, "lib/a.ex", 99) == :unknown
      assert Coverage.tests_for(index, "lib/other.ex", 10) == :unknown
    end

    test "tests_for returns :no_coverage for an executable line no test runs", %{index: index} do
      index = Coverage.put_executable(index, "lib/a.ex", 50)
      assert Coverage.tests_for(index, "lib/a.ex", 50) == :no_coverage
    end

    test "put_executable does not downgrade an already-covered line", %{index: index} do
      index = Coverage.put_executable(index, "lib/a.ex", 10)

      assert Coverage.tests_for(index, "lib/a.ex", 10) ==
               {:covered, ["test/a_test.exs", "test/b_test.exs"]}
    end

    test "put is idempotent for the same (file, line, test)", %{index: index} do
      index = Coverage.put(index, "lib/a.ex", 10, "test/a_test.exs")

      assert Coverage.tests_for(index, "lib/a.ex", 10) ==
               {:covered, ["test/a_test.exs", "test/b_test.exs"]}
    end

    test "covered?/3 reflects whether any test covers the line", %{index: index} do
      assert Coverage.covered?(index, "lib/a.ex", 10)
      refute Coverage.covered?(index, "lib/a.ex", 99)
    end
  end

  test "new/0 is empty" do
    assert Coverage.tests_for(Coverage.new(), "lib/a.ex", 1) == :unknown
  end

  describe "covered_lines/1" do
    test "keeps only the lines a `:cover` line analysis recorded as executed" do
      analysis = [{{SomeMod, 10}, 3}, {{SomeMod, 11}, 0}, {{SomeMod, 12}, 1}]
      assert Coverage.covered_lines(analysis) == [10, 12]
    end

    test "is empty when nothing ran" do
      assert Coverage.covered_lines([{{SomeMod, 5}, 0}]) == []
      assert Coverage.covered_lines([]) == []
    end
  end

  describe "put_lines/4" do
    test "records many lines for one (file, test) at once" do
      index = Coverage.put_lines(Coverage.new(), "lib/a.ex", [10, 12], "test/a_test.exs")

      assert Coverage.tests_for(index, "lib/a.ex", 10) == {:covered, ["test/a_test.exs"]}
      assert Coverage.tests_for(index, "lib/a.ex", 12) == {:covered, ["test/a_test.exs"]}
      assert Coverage.tests_for(index, "lib/a.ex", 11) == :unknown
    end
  end

  describe "collect/3" do
    # Exports are written by a separate VM, so the fixture module is never
    # cover-compiled in this one: `collect/3` sees it only as imported data,
    # as it does for a project's modules during a real run.
    @tag :tmp_dir
    test "credits each test file with only the lines it executed", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "muex_cov_fixture.erl")

      File.write!(source, """
      -module(muex_cov_fixture).
      -export([a/0, b/0]).
      a() ->
          a.
      b() ->
          b.
      """)

      a_export = Path.join(tmp_dir, "a.coverdata")
      b_export = Path.join(tmp_dir, "b.coverdata")

      script = """
      [source, a_export, b_export] = System.argv()
      {:ok, _} = :cover.start()
      {:ok, mod} = :cover.compile_module(String.to_charlist(source))
      mod.a()
      :ok = :cover.export(String.to_charlist(a_export), mod)
      :ok = :cover.reset(mod)
      mod.b()
      :ok = :cover.export(String.to_charlist(b_export), mod)
      """

      {_, 0} =
        System.cmd("elixir", ["-e", script, source, a_export, b_export], stderr_to_stdout: true)

      exports = %{"a_test.exs" => a_export, "b_test.exs" => b_export}

      index =
        Coverage.collect(
          ["a_test.exs", "b_test.exs"],
          %{"muex_cov_fixture.erl" => :muex_cov_fixture},
          run: fn test_file, _cd -> {:ok, Map.fetch!(exports, test_file)} end
        )

      assert Coverage.tests_for(index, "muex_cov_fixture.erl", 4) == {:covered, ["a_test.exs"]}
      assert Coverage.tests_for(index, "muex_cov_fixture.erl", 6) == {:covered, ["b_test.exs"]}
    end

    test "runs up to :concurrency test files at once" do
      test_pid = self()

      run = fn test_file, _cd ->
        send(test_pid, {:running, test_file, self()})

        receive do
          :go -> :error
        end
      end

      collecting =
        Task.async(fn ->
          Coverage.collect(["a_test.exs", "b_test.exs", "c_test.exs"], %{},
            run: run,
            concurrency: 2
          )
        end)

      assert_receive {:running, "a_test.exs", a}
      assert_receive {:running, "b_test.exs", b}
      refute_receive {:running, "c_test.exs", _}

      send(a, :go)
      assert_receive {:running, "c_test.exs", c}

      Enum.each([b, c], &send(&1, :go))
      assert Task.await(collecting) == Coverage.new()
    end
  end
end
