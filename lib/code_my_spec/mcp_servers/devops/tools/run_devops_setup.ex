defmodule CodeMySpec.McpServers.Devops.Tools.RunDevopsSetup do
  @moduledoc """
  Build the infrastructure that is missing, for the project this call is
  connected to.

  This provisions **real resources in real accounts** — servers, DNS records,
  buckets, sending domains — and they cost money and change where mail and
  traffic go. It is the same run the provisioning page's per-project button
  performs.

  No `project_id` parameter, on purpose. This used to take one, and
  separately accepted omitting it entirely as a bulk "build every project
  whose devops level is not off" mode — either shape let a caller name (or
  fail to name) a *different* project than the one this call is actually
  connected to, sometimes triggering real, costed provisioning on projects
  nobody asked to touch. Found during an audit prompted by a real,
  unrelated cross-project leak in `devops_status`. The only project this
  tool can ever act on now is `Validators.devops_project/1`'s answer —
  whichever project the connection itself identifies (the harness's own
  `X-Project-ID` header, or the configured project for stdio) — the same
  fix applied to every other devops tool.

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
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, %{}),
         {:ok, project} <- Validators.devops_project(scope) do
      {:reply, ok(one(project.id, Resources.fix_async(scope, project.id))), frame}
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp one(id, {:error, :not_found}),
    do: "No project #{id} on this account, or its devops level is `off` so it is not deployable."

  defp one(id, result), do: "#{id}: #{outcome(result)}"

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
