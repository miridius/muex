defmodule Muex.IgnoreTest do
  use ExUnit.Case, async: true

  alias Muex.Ignore

  @moduletag :tmp_dir

  defp entry!(root, path, source) do
    File.mkdir_p!(Path.dirname(Path.join(root, path)))
    File.write!(Path.join(root, path), source)
    %{path: path}
  end

  defp mutation(file, line), do: %{location: %{file: file, line: line}, description: "m#{line}"}

  describe "directives/2" do
    test "a comment covers its own line and the line below", %{tmp_dir: root} do
      file =
        entry!(root, "lib/a.ex", """
        defmodule A do
          # muex:ignore logging only
          def a(x), do: x + 1
          def b(x), do: x - 1 # muex:ignore   off by one is fine here
          def c(x), do: x * 2
        end
        """)

      assert Ignore.directives([file], root) ==
               {:ok,
                %{
                  "lib/a.ex" => %{
                    2 => "logging only",
                    3 => "logging only",
                    4 => "off by one is fine here",
                    5 => "off by one is fine here"
                  }
                }}
    end

    test "a line's own comment wins over the one above it", %{tmp_dir: root} do
      file =
        entry!(root, "lib/a.ex", """
        # muex:ignore first
        x = 1 # muex:ignore second
        """)

      assert {:ok, %{"lib/a.ex" => %{1 => "first", 2 => "second", 3 => "second"}}} =
               Ignore.directives([file], root)
    end

    test "refuses a comment with no reason, naming every one", %{tmp_dir: root} do
      a = entry!(root, "lib/a.ex", "x = 1 # muex:ignore\n# muex:ignore   \ny = 2\n")
      b = entry!(root, "lib/b.ex", "# muex:ignore fine\nz = 3\n")

      assert {:error, reason} = Ignore.directives([a, b], root)
      assert reason =~ "needs a reason"
      assert reason =~ "lib/a.ex:1, lib/a.ex:2"
      refute reason =~ "lib/b.ex"
    end

    test "text inside a string is not a comment", %{tmp_dir: root} do
      file = entry!(root, "lib/a.ex", ~s|x = "# muex:ignore not a comment"\n|)
      assert Ignore.directives([file], root) == {:ok, %{"lib/a.ex" => %{}}}
    end

    test "only the muex:ignore word counts", %{tmp_dir: root} do
      file = entry!(root, "lib/a.ex", "# muex:ignored maybe\nx = 1\n")
      assert Ignore.directives([file], root) == {:ok, %{"lib/a.ex" => %{}}}
    end

    test "Erlang source is not scanned", %{tmp_dir: root} do
      file = entry!(root, "src/a.erl", "% muex:ignore\na() -> 1.\n")
      assert Ignore.directives([file], root) == {:ok, %{"src/a.erl" => %{}}}
    end
  end

  test "Muex.run refuses a bare # muex:ignore before running anything", %{tmp_dir: root} do
    entry!(root, "lib/a.ex", "defmodule A do\n  def a(x), do: x + 1 # muex:ignore\nend\n")

    {:ok, config} =
      Muex.Config.from_opts(
        files: Path.join(root, "lib"),
        test_paths: Path.join(root, "test"),
        project_root: root,
        no_filter: true
      )

    assert {:error, reason} = Muex.run(config)
    assert reason =~ "lib/a.ex:2"
  end

  describe "split/2" do
    test "returns the mutations to run and an :ignored result for each covered one" do
      directives = %{"lib/a.ex" => %{3 => "harmless"}}
      kept = mutation("lib/a.ex", 4)
      ignored = mutation("lib/a.ex", 3)

      assert {[^kept], [result]} = Ignore.split([kept, ignored], directives)

      assert result == %{
               mutation: ignored,
               result: :ignored,
               duration_ms: 0,
               error: nil,
               ignore_reason: "harmless",
               test_files: []
             }
    end
  end
end
