defmodule Muex.Ignore do
  @moduledoc """
  `# muex:ignore <reason>` comments, which mark the mutants of a line as known
  to be harmless.

  A comment on line `n` covers the mutants on line `n` and on line `n + 1`, so
  it can sit at the end of the mutated line or on its own line directly above.
  Those mutants are not run; each is reported as `:ignored` with the reason,
  and the score leaves them out. The reason is required: a bare
  `# muex:ignore` refuses the run.

  Comments are read with Elixir's parser, so the text inside a string is never
  taken for one. Only Elixir source is scanned.
  """

  @directive ~r/^#\s*muex:ignore(?=\s|$)\s*(.*)$/

  @type t :: %{Path.t() => %{pos_integer() => String.t()}}

  @doc """
  Reads the `# muex:ignore` comments of `files` (loader entries), whose paths
  are relative to `project_root`.

  Returns `{:ok, %{path => %{line => reason}}}`, keyed by each entry's own
  path, or `{:error, reason}` naming every comment that has no reason.
  """
  @spec directives([map()], Path.t()) :: {:ok, t()} | {:error, String.t()}
  def directives(files, project_root) do
    found = Map.new(files, fn file -> {file.path, scan(file.path, project_root)} end)

    case for {path, comments} <- found, {line, ""} <- comments, do: "#{path}:#{line}" do
      [] ->
        {:ok, Map.new(found, fn {path, comments} -> {path, covered_lines(comments)} end)}

      bare ->
        {:error,
         "# muex:ignore needs a reason saying why the mutant is harmless, " <>
           "as in `# muex:ignore <reason>`: #{bare |> Enum.sort() |> Enum.join(", ")}"}
    end
  end

  @doc """
  Splits `mutations` into those to run and the results of those an ignore
  comment covers.
  """
  @spec split([map()], t()) :: {[map()], [map()]}
  def split(mutations, directives) do
    {ignored, kept} = Enum.split_with(mutations, &reason_for(&1, directives))
    {kept, Enum.map(ignored, &ignored_result(&1, reason_for(&1, directives)))}
  end

  defp reason_for(mutation, directives),
    do: get_in(directives, [mutation.location.file, mutation.location.line])

  defp ignored_result(mutation, reason) do
    %{
      mutation: mutation,
      result: :ignored,
      duration_ms: 0,
      error: nil,
      ignore_reason: reason,
      test_files: []
    }
  end

  # A comment covers its own line first; the line below takes it only when that
  # line has no comment of its own.
  defp covered_lines(comments) do
    Enum.reduce(comments, Map.new(comments), fn {line, reason}, acc ->
      Map.put_new(acc, line + 1, reason)
    end)
  end

  defp scan(path, project_root) do
    with ext when ext in [".ex", ".exs"] <- Path.extname(path),
         {:ok, source} <- File.read(Path.expand(path, project_root)),
         {:ok, _ast, comments} <- Code.string_to_quoted_with_comments(source) do
      for %{line: line, text: text} <- comments,
          [_, reason] <- [Regex.run(@directive, text)],
          do: {line, String.trim(reason)}
    else
      _ -> []
    end
  end
end
