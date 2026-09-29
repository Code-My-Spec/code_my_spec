defmodule CmsHarness.Agents.Shell do
  @moduledoc """
  Runs an agent's bash command without the harness's own environment.

  Alloy's default bash tool inherits this BEAM's environment, so an agent
  running `mix test` in a project got the harness's `MIX_ENV=dev_cli`, a
  config that project does not have, and every `CMS_*` variable naming this
  harness (the same leak that sent spex harnesses to the real server).
  """

  @doc "The executor handed to Alloy as `:bash_executor`."
  @spec run(String.t(), String.t() | nil) :: {String.t(), non_neg_integer()}
  def run(command, dir) do
    opts = [stderr_to_stdout: true, env: scrubbed_env()]
    opts = if dir, do: Keyword.put(opts, :cd, dir), else: opts

    System.cmd("bash", ["-rc", command], opts)
  end

  @doc "Unsets every variable that describes the harness rather than the project."
  @spec scrubbed_env() :: [{String.t(), nil}]
  def scrubbed_env do
    for {name, _} <- System.get_env(), harness_only?(name), do: {name, nil}
  end

  defp harness_only?("MIX_ENV"), do: true
  defp harness_only?("CMS_" <> _), do: true
  defp harness_only?(_), do: false
end
