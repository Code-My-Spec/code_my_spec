defmodule CodeMySpec.McpServers.Devops.Tools.RunDevopsSetup do
  @moduledoc """
  Build the infrastructure that is missing, for one project or for all of them.

  This provisions **real resources in real accounts** — servers, DNS records,
  buckets, sending domains — and they cost money and change where mail and
  traffic go. It is the same run the provisioning page's buttons perform.

  Each project runs on its own: a refusal halts that project and nothing else,
  so one provider saying no cannot decide what happens to the rest.

  The sequence is ordered and halts on the first failure, which is deliberate —
  the ordering *is* the dependency model. A step that pauses is waiting on a
  decision only a person can make (a credential that cannot be minted through
  an API, an apex that is already serving a live site); read what it says
  rather than retrying it.

  Call `devops_status` first. If it reports a provider unreachable, the answer
  is unknown rather than "not done", and running setup on that basis may build
  things that already exist.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Resources

  schema do
    field :project_id, :string,
      doc:
        "Build only this project's missing infrastructure. " <>
          "Omit to build every project whose devops level is not `off`."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params) do
      case Map.get(params, :project_id) do
        id when is_binary(id) and id != "" ->
          {:reply, ok(one(id, Resources.fix(scope, id))), frame}

        _ ->
          {:reply, ok(all(Resources.fix_all(scope))), frame}
      end
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp one(id, {:error, :not_found}),
    do: "No project #{id} on this account, or its devops level is `off` so it is not deployable."

  defp one(id, result), do: "#{id}: #{outcome(result)}"

  defp all([]),
    do:
      "Nothing to build: no project on this account has devops enabled. " <>
        "Turn it on for a project first — the graph filters these steps out at `off`."

  defp all(results),
    do:
      "Ran setup for #{length(results)} project(s).\n\n" <>
        Enum.map_join(results, "\n", fn {id, result} -> "  - #{id}: #{outcome(result)}" end)

  # Named per outcome rather than inspected. A paused run is waiting on a person
  # and a halted one stopped at a named step; reporting both as "error" would
  # invite a retry that cannot succeed.
  defp outcome({:ok, _}), do: "complete"
  defp outcome({:paused, instructions}), do: "paused — #{instructions}"
  defp outcome({:halt, key, reason}), do: "halted at #{key} — #{inspect(reason)}"
  defp outcome({:error, reason}), do: "failed — #{inspect(reason)}"
  defp outcome(other), do: inspect(other)

  defp ok(summary), do: Response.tool() |> Response.text(summary)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not run devops setup: #{inspect(reason)}")
end
