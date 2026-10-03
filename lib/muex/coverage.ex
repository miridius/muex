defmodule Muex.Coverage do
  @moduledoc """
  A line-level coverage index: which test files execute which source lines.

  Used to run, for each mutant, only the tests that actually exercise the
  mutated line — and to skip mutants on lines no test covers (`:no_coverage`)
  rather than wasting a full test run on a mutant nothing can catch.

  The index is a plain map (`%{file => %{line => MapSet of test files}}`); build
  it with `new/0` + `put/4` and query it with `tests_for/3` / `covered?/3`.
  """

  @type t :: %{Path.t() => %{pos_integer() => MapSet.t(Path.t())}}

  @doc "Returns an empty index."
  @spec new() :: t()
  def new, do: %{}

  @doc "Records that `test_file` executes `line` of `file`."
  @spec put(t(), Path.t(), pos_integer(), Path.t()) :: t()
  def put(index, file, line, test_file) do
    Map.update(index, file, %{line => MapSet.new([test_file])}, fn lines ->
      Map.update(lines, line, MapSet.new([test_file]), &MapSet.put(&1, test_file))
    end)
  end

  @doc "Records that `line` of `file` is executable (even if no test runs it)."
  @spec put_executable(t(), Path.t(), pos_integer()) :: t()
  def put_executable(index, file, line) do
    Map.update(index, file, %{line => MapSet.new()}, &Map.put_new(&1, line, MapSet.new()))
  end

  @doc """
  Returns the coverage status of `file:line`:

    * `{:covered, sorted_test_files}` — at least one test executes the line;
    * `:no_coverage` — the line is executable but no test runs it;
    * `:unknown` — there is no coverage data for the line (e.g. it is not an
      executable line, like a `defmodule`/`def` header), so coverage can't
      decide and the caller should run the mutant normally.
  """
  @spec tests_for(t(), Path.t(), pos_integer()) ::
          {:covered, [Path.t()]} | :no_coverage | :unknown
  def tests_for(index, file, line) do
    case get_in(index, [file, line]) do
      nil ->
        :unknown

      set ->
        if MapSet.size(set) == 0,
          do: :no_coverage,
          else: {:covered, set |> MapSet.to_list() |> Enum.sort()}
    end
  end

  @doc "Records that `test_file` executes every line in `lines` of `file`."
  @spec put_lines(t(), Path.t(), [pos_integer()], Path.t()) :: t()
  def put_lines(index, file, lines, test_file) do
    Enum.reduce(lines, index, fn line, idx -> put(idx, file, line, test_file) end)
  end

  @doc "Whether any test covers `file:line`."
  @spec covered?(t(), Path.t(), pos_integer()) :: boolean()
  def covered?(index, file, line), do: match?({:covered, _}, tests_for(index, file, line))

  @doc """
  Extracts the executed line numbers from a `:cover.analyse(_, :calls, :line)`
  result, i.e. the lines with a non-zero call count.
  """
  @spec covered_lines([{{module(), pos_integer()}, non_neg_integer()}]) :: [pos_integer()]
  def covered_lines(line_analysis) do
    for {{_module, line}, calls} <- line_analysis, calls > 0, do: line
  end

  @doc """
  Builds a coverage index by running each test file under `:cover` and recording
  which source lines it executes.

  For every file in `test_files`, runs `mix test <file> --cover --export-coverage`
  in a subprocess, then analyses each module in `file_to_module` and attributes
  its executed lines to that test file. Returns a `t()` index.

  Options: `:cd` (project root, default `File.cwd!/0`); `:run`, a function
  `(test_file, cd) -> {:ok, coverdata_path} | :error` that produces a test
  file's coverage export, which is deleted once merged (default: the
  `mix test` subprocess above);
  `:concurrency`, how many of those run at once (default
  `System.schedulers_online/0`).
  """
  @spec collect([Path.t()], %{Path.t() => module()}, keyword()) :: t()
  def collect(test_files, file_to_module, opts \\ []) do
    cd = Keyword.get(opts, :cd, File.cwd!())
    run = Keyword.get(opts, :run, &run_with_coverage/2)
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    module_to_path = invert(file_to_module)
    ensure_cover_started()
    cover_dir = Path.join(cd, "cover")
    cover_dir_existed? = File.dir?(cover_dir)

    # The test files run side by side, each in its own VM. Their exports are
    # merged one at a time: `:cover` is one server per node, and each merge
    # resets and re-imports the same modules.
    index =
      test_files
      |> Task.async_stream(&{&1, run.(&1, cd)}, max_concurrency: concurrency, timeout: :infinity)
      |> Enum.reduce(new(), fn
        {:ok, {test_file, {:ok, coverdata}}}, index ->
          try do
            merge_coverage(index, test_file, coverdata, module_to_path)
          after
            File.rm(coverdata)
          end

        {:ok, {_test_file, :error}}, index ->
          index
      end)

    # Removes `cover/` only when this run created it and nothing else is in it.
    if not cover_dir_existed?, do: File.rmdir(cover_dir)
    index
  end

  defp invert(file_to_module) do
    for {path, module} <- file_to_module, not is_nil(module), into: %{}, do: {module, path}
  end

  defp ensure_cover_started do
    case :cover.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp run_with_coverage(test_file, cd) do
    name = "muex_cov_#{System.unique_integer([:positive])}"
    path = Path.join([cd, "cover", "#{name}.coverdata"])

    result =
      try do
        System.cmd("mix", ["test", test_file, "--cover", "--export-coverage", name],
          cd: cd,
          env: Muex.GitEnv.cmd_env([{"MIX_ENV", "test"}]),
          stderr_to_stdout: true
        )
      rescue
        _ -> :error
      end

    case result do
      # 0 = all passed, 1 = some failed; both still produce coverage data.
      {_out, code} when code in [0, 1] ->
        if File.exists?(path), do: {:ok, path}, else: :error

      _ ->
        File.rm(path)
        :error
    end
  end

  # `:cover.reset/0` resets only cover-compiled modules and leaves the data of
  # imported ones in place, so each import would add to the previous test
  # file's data. `:cover.reset/1` clears an imported module's data; it returns
  # an error for a module with no data yet, which is fine to ignore.
  defp merge_coverage(index, test_file, coverdata, module_to_path) do
    Enum.each(Map.keys(module_to_path), &:cover.reset/1)
    :cover.import(String.to_charlist(coverdata))

    Enum.reduce(module_to_path, index, fn {module, path}, idx ->
      case :cover.analyse(module, :calls, :line) do
        {:ok, line_analysis} -> merge_module(idx, path, line_analysis, test_file)
        _ -> idx
      end
    end)
  end

  # Register every executable line of the module (so an uncovered line reads as
  # :no_coverage, not :unknown), and attribute the lines this test executed.
  # `:cover` sometimes reports line 0 for module-level entries; those are not
  # real lines, so they are skipped (and read back as :unknown).
  defp merge_module(index, path, line_analysis, test_file) do
    Enum.reduce(line_analysis, index, fn {{_module, line}, calls}, idx ->
      cond do
        line < 1 -> idx
        calls > 0 -> put(put_executable(idx, path, line), path, line, test_file)
        true -> put_executable(idx, path, line)
      end
    end)
  end
end
