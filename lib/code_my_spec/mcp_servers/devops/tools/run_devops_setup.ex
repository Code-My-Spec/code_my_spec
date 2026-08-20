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

  ## This returns as soon as the run starts, not when it finishes

  A real run can take minutes — deploy alone has measured ~167s — which is
  longer than this tool's own transport waits for a reply. Calling and then
  waiting for a definitive "complete" here will time out even when the run is
  proceeding normally; call `devops_status` afterward to watch it converge
  instead of retrying this call. Retrying while a run is still going does not
  start a second one — the project is locked for the run's duration and the
  retry is told a run is already in progress, rather than racing the first
  run's writes against the same provider.
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
          {:reply, ok(one(id, Resources.fix_async(scope, id))), frame}

        _ ->
          {:reply, ok(all(Resources.fix_all_async(scope))), frame}
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
      "Started setup for #{length(results)} project(s). Call devops_status to watch them converge.\n\n" <>
        Enum.map_join(results, "\n", fn {id, result} -> "  - #{id}: #{outcome(result)}" end)

  # Named per outcome rather than inspected, same as before — but the
  # outcomes are now about whether the run *started*, not whether it
  # *finished*. `run_devops_setup` returns long before a real run does, so
  # there is no "complete"/"halted at"/"failed" to report here any more —
  # only whether this call caused a run to begin, and if not, why not.
  defp outcome({:ok, :started}), do: "started — call devops_status to watch it converge"

  defp outcome({:error, {:already_running, started_at}}) do
    since = started_at && " (started #{started_at})"
    "a run is already in progress#{since} — call devops_status rather than retrying"
  end

  defp outcome({:error, :lock_handshake_timeout}),
    do: "could not confirm the run started — check devops_status, or try again shortly"

  defp outcome({:error, reason}), do: "failed — #{inspect(reason)}"
  defp outcome(other), do: inspect(other)

  defp ok(summary), do: Response.tool() |> Response.text(summary)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not run devops setup: #{inspect(reason)}")
end
