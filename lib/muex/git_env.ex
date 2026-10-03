defmodule Muex.GitEnv do
  @moduledoc """
  The repository-local variables git exports to hooks (`GIT_DIR`,
  `GIT_INDEX_FILE`, `GIT_WORK_TREE`, ...), so the `mix` subprocesses muex starts
  can be run without them.

  Inherited by `mix test`, they would point a project's own tests that create
  throwaway git repositories at the repository being committed to.
  """

  @key {__MODULE__, :vars}

  @doc """
  The variables `git rev-parse --local-env-vars` names, or `[]` when git cannot
  be run. Asked once per VM.
  """
  @spec local_vars() :: [String.t()]
  def local_vars do
    case :persistent_term.get(@key, nil) do
      nil ->
        vars = ask_git()
        :persistent_term.put(@key, vars)
        vars

      vars ->
        vars
    end
  end

  @doc """
  An `env:` list for `System.cmd/3` that unsets every variable in
  `local_vars/0`, followed by `extra`.
  """
  @spec cmd_env([{String.t(), String.t() | nil}]) :: [{String.t(), String.t() | nil}]
  def cmd_env(extra \\ []), do: Enum.map(local_vars(), &{&1, nil}) ++ extra

  @doc """
  The same as `cmd_env/1`, as `Port.open/2` takes it: charlists, with `false`
  to unset.
  """
  @spec port_env([{String.t(), String.t() | nil}]) :: [{charlist(), charlist() | false}]
  def port_env(extra \\ []) do
    Enum.map(cmd_env(extra), fn
      {name, nil} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  # The list is git's own, so it stays right as git adds variables. Outside a
  # repository git still prints it.
  defp ask_git do
    case System.cmd("git", ["rev-parse", "--local-env-vars"], stderr_to_stdout: true) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> []
    end
  rescue
    _ -> []
  end
end
