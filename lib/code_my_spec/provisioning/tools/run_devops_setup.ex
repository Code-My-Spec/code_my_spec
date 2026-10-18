defmodule CodeMySpec.Provisioning.Tools.RunDevopsSetup do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.Tools.Starter
  alias CodeMySpec.Provisioning.Truncate
  alias CodeMySpec.Resources

  @impl true
  def name, do: "run_devops_setup"

  @impl true
  def description do
    """
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

    An agent that started the run is messaged how it ended instead, and is not
    nudged meanwhile (`Starter`, `Agents.Waiting`).
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      starter = Starter.new(scope, context, "devops setup")

      result =
        Resources.fix_async(scope, project.id,
          holder: Starter.lock_holder(starter),
          on_finish: &Starter.tell(starter, outcome_message(&1, project.name))
        )

      ok(one(project.id, result, context))
    else
      {:error, reason} -> error(reason)
    end
  end

  defp one(id, {:error, :not_found}, _frame),
    do: "No project #{id} on this account, or its devops level is `off` so it is not deployable."

  defp one(id, {:ok, :started}, context),
    do: "#{id}: started — #{Starter.then_what(context[:agent_id])}"

  defp one(id, result, _frame), do: "#{id}: #{outcome(result)}"

  # Named per outcome rather than inspected, same as before — but the
  # outcomes are now about whether the run *started*, not whether it
  # *finished*. `run_devops_setup` returns long before a real run does, so
  # there is no "complete"/"halted at"/"failed" to report here any more —
  # only whether this call caused a run to begin, and if not, why not.
  defp outcome({:error, {:already_running, started_at}}) do
    since = started_at && " (started #{started_at})"
    "a run is already in progress#{since} — call devops_status rather than retrying"
  end

  defp outcome({:error, :lock_handshake_timeout}),
    do: "could not confirm the run started — check devops_status, or try again shortly"

  defp outcome({:error, reason}), do: "failed — #{inspect(reason)}"
  defp outcome(other), do: inspect(other)

  @doc false
  def outcome_message(%{halted_at: nil}, name),
    do: "Your devops setup for #{name} finished: every step is done. #{answer()}"

  def outcome_message(%{halted_at: key, reason: reason} = run, name) do
    reason = Truncate.head_and_tail(reason)

    case run.steps |> List.last() |> Map.get(:state) do
      :paused ->
        "Your devops setup for #{name} paused at #{key}: #{reason}\n\n" <>
          "It will not continue on its own. #{answer()}"

      :errored ->
        "Your devops setup for #{name} errored at #{key}: #{reason}\n\n" <>
          "It is no longer running. #{answer()}"

      state ->
        "Your devops setup for #{name} stopped at #{key}, still #{state}: #{reason}\n\n#{answer()}"
    end
  end

  defp answer, do: "This is the outcome of the run you started — act on it now."

  defp ok(summary), do: {:ok, summary}

  defp error(reason),
    do: {:error, "Could not run devops setup: #{inspect(reason)}"}
end
