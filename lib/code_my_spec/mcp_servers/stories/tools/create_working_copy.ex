defmodule CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy do
  @moduledoc """
  Make a working copy for this project and staff it.

  One call. The harness makes the checkout on its own disk and writes the
  identity into it; the server records the copy and starts the agents that will
  work in it. An agent asking for somewhere to work does not sequence a disk
  operation against a database write — the moment it does, every caller has to
  get the ordering and the failure handling right, and they each get it wrong
  differently.

  Story 891 grew this scope on 2026-09-04. Its question `2ec33878` had asked
  whether onboarding creates the worktree or runs inside one that already
  exists, and answered the second way — so making the copy belonged to nobody.
  Story 956's title says "a minted working copy" and none of its thirteen
  criteria mint anything; 964 hands an epic to a copy and assumes one. A
  project's first epic therefore had nowhere to go but the main checkout, where
  a roster is refused because the main copy holds one agent and it is the
  project's own.

  ## Refused rather than half-made

  A project with no harness connected has no machine to make a checkout on, and
  the answer is a refusal. Writing the row anyway would leave something every
  consumer downstream believes in — the failure `EpicDispatch` had to grow a
  guard against, where the page said "Being built on your project's checkout"
  about a directory that does not exist.

  That is the opposite of what `EpicDispatch.approve/2` does with an epic that
  has nowhere to go, and deliberately: agreeing to build something is a decision
  that survives having nowhere to build it. Asking for a checkout is a request
  for a thing.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects
  alias CodeMySpec.WorkingCopies

  schema do
    field :label, :string,
      description: "What this copy is for, e.g. the epic it will build. Names the directory."

    field :root, :string,
      description:
        "Where to put it. Defaults to a worktree beside the project's checkout; " <>
          "pass one only when it has to go somewhere specific."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        {:reply, create(scope, params), frame}

      # A sentence, not the bare atom. `inspect(reason)` answered
      # `:no_working_dir`, which names the problem to somebody who already knows
      # the codebase and to nobody else — and this is a tool an agent calls, so
      # the reply is the only thing standing between it and guessing.
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error(scope_refusal(reason)), frame}
    end
  end

  defp create(scope, params) do
    # Only copies that are checkouts. A row is not one until it reports a root
    # — `ensure_default/1` mints a rootless nil-object row — and a machine is
    # only a candidate host if it actually holds the repository. Passing those
    # ids on would ask a harness that is not there.
    candidates =
      scope
      |> WorkingCopies.list_harnesses()
      |> Enum.filter(&(is_binary(&1.root) and &1.root != ""))
      |> Enum.map(& &1.id)

    case Transport.impl().create_working_copy(candidates, request(scope, params), 60_000) do
      {:ok, made} -> record(scope, made, params)
      {:error, reason} -> Response.tool() |> Response.error(refusal(reason))
    end
  end

  # The identity travels *to* the harness rather than back from it, so the file
  # on disk and the row in the database hold the same value rather than two
  # derivations of it. The deploy key goes with it because a copy that cannot
  # authenticate is a copy that never joins.
  defp request(scope, params) do
    %{
      "project_id" => scope.active_project_id,
      "working_copy_id" => Ecto.UUID.generate(),
      "label" => params[:label],
      "root" => params[:root],
      "deploy_key" => deploy_key(scope)
    }
  end

  defp deploy_key(scope) do
    case Projects.ensure_deploy_key(scope, scope.active_project_id) do
      {:ok, key} when is_binary(key) -> key
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Recorded only once the disk half came back, and staffed only once the record
  # exists. A row without a root is not a checkout, and agents cannot start
  # against one — `start_agent/2` answers `:unknown_working_copy`.
  defp record(scope, %{root: root, working_copy_id: id}, params) do
    with {:ok, copy} <-
           WorkingCopies.issue(scope, id, root: root, label: params[:label], device: device(scope)),
         {:ok, copy} <- WorkingCopies.report_root(copy, root) do
      staffed = Agents.ensure_copy_agents(scope, copy)

      Response.tool() |> Response.text(report(copy, staffed))
    else
      {:error, reason} ->
        Logger.warning("[CreateWorkingCopy] made #{root} and could not record it: #{inspect(reason)}")

        Response.tool()
        |> Response.error(
          "The checkout was made at #{root} and could not be recorded (#{inspect(reason)}), " <>
            "so this project does not have a working copy there. Nothing is claiming to be one."
        )
    end
  end

  # The machine the host copy is on. A created copy is on the same filesystem as
  # the checkout it was made beside, so it is on the same device — and recording
  # that is what stops two machines' copies at one path being confused.
  defp device(scope) do
    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.find_value(fn copy -> copy.device_id end)
  end

  defp report(copy, %{started: started, failed: []}) do
    """
    Made a working copy at #{copy.root}.

    id: #{copy.id}
    agents: #{roles(started)}
    """
  end

  defp report(copy, %{started: started, failed: failed}) do
    """
    Made a working copy at #{copy.root}, and it is not fully staffed.

    id: #{copy.id}
    started: #{roles(started)}
    could not start: #{Enum.map_join(failed, ", ", fn {role, reason} -> "#{role} (#{inspect(reason)})" end)}

    The copy exists and the work it was made for cannot all be done on it yet.
    """
  end

  defp roles([]), do: "none"
  defp roles(agents), do: Enum.map_join(agents, ", ", &to_string(&1.role))

  defp refusal(:no_harness) do
    "No machine is connected for this project, so there is nowhere to make a checkout. " <>
      "A working copy is created on a machine that is running a harness — start one on the " <>
      "machine that holds this project, then ask again. Nothing was recorded."
  end

  defp refusal(:create_timed_out) do
    "The machine did not finish making the checkout in time. It may still be there; nothing " <>
      "has been recorded for it, so this project does not have a working copy at that path."
  end

  defp refusal(reason), do: "The working copy could not be created: #{inspect(reason)}"

  defp scope_refusal(:no_working_dir) do
    "This call names no project, so there is nothing to make a working copy for. " <>
      "The project is resolved from the working directory the call came from. " <>
      "Nothing was created and nothing was recorded."
  end

  defp scope_refusal(reason) do
    "The working copy could not be created because this call has no usable project " <>
      "scope (#{inspect(reason)}). Nothing was created and nothing was recorded."
  end
end
