defmodule CodeMySpec.McpServers.Bootstrap.Installers do
  @moduledoc """
  Runs the deterministic harness installers as a group.

  `AGENTS.md`, `CLAUDE.md`, `.code_my_spec/rules/`, and
  `.code_my_spec/credo_checks/` are all generated from content the harness
  already owns — nothing about them requires judgement. They were still
  costing a model turn each, because the only way to run them was for an
  agent to call the matching MCP tool. `init_project` calls this instead, so
  linking a project installs them outright.

  That closes the last gap in generating a project that satisfies every
  `CodeMySpec.AgentTasks.ProjectSetup` check with no agent involvement: the
  `cms.new` generator emits the other eight steps, and these four land here.
  The MCP tools stay — they are how you *re*-install into an existing project
  — and both paths call the same `install/1`, so there is one source of truth.

  Best-effort by design: a failure here must not abort project linking. The
  setup requirement will simply stay unsatisfied and the agent can run the
  individual tool to see the real error.
  """

  alias CodeMySpec.McpServers.Bootstrap.Tools.{
    InstallAgentsMd,
    InstallClaudeMd,
    InstallCredoChecks,
    InstallRules
  }

  require Logger

  @installers [
    {"rules", InstallRules},
    {"credo_checks", InstallCredoChecks},
    {"AGENTS.md", InstallAgentsMd},
    {"CLAUDE.md", InstallClaudeMd}
  ]

  @doc """
  Run every harness installer against `env`.

  Returns `{installed, failed}` where each element is a `{label, reason}` for
  failures. Never raises and never returns an error tuple — see the module
  doc on why linking must survive a failed install.
  """
  @spec install_all(term()) :: {[String.t()], [{String.t(), term()}]}
  def install_all(env) do
    {ok, failed} =
      @installers
      |> Enum.map(fn {label, mod} -> {label, run(mod, env)} end)
      |> Enum.split_with(fn {_label, result} -> result == :ok end)

    failures = Enum.map(failed, fn {label, {:error, reason}} -> {label, reason} end)

    for {label, reason} <- failures do
      Logger.warning("bootstrap installer #{label} failed: #{inspect(reason)}")
    end

    {Enum.map(ok, fn {label, _} -> label end), failures}
  end

  # Every installer already reports failure as an error tuple (a stale server
  # binary that can't find its own priv/ is the common one), so there is
  # nothing to rescue here. If one of them ever raises, that is a real bug in
  # the installer and should surface, not be swallowed.
  defp run(mod, env) do
    case mod.install(env) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end
end
