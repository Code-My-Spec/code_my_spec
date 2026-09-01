defmodule CodeMySpec.McpServers.Stories.Tools.ListWorkingCopies do
  @moduledoc """
  The checkouts this project has, and what is running on each.

  So that deciding where an epic goes can be a decision. John: *"if there's an
  appropriate working copy and agent then it should get assigned that, or maybe
  the agent wants a fresh working copy ... the user should be able to decide
  where to assign it or the agent should be able to decide."*

  Neither could, before this: there was no agent-facing way to see a project's
  checkouts at all, so "an appropriate one" was not a judgement anything could
  make.

  ## What to look at

  `root` is the only thing that makes a row a checkout — a row with none has no
  disk behind it and nothing can be built there. `agents` is what is already
  running, which is the difference between assigning to a copy that can pick the
  work up and assigning to an idle one that needs an agent started first.

  `main` is the project's own checkout, the one story 963's agent runs in. It is
  a fine destination and not automatically the right one; a copy already holding
  a related epic often is.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.WorkingCopies

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      {:reply, Response.text(Response.tool(), render(scope)), frame}
    else
      {:error, atom} -> {:reply, Response.error(Response.tool(), inspect(atom)), frame}
    end
  end

  defp render(scope) do
    case WorkingCopies.list_harnesses(scope) do
      [] ->
        "This project has no checkouts. Nothing can be built until one reports in."

      copies ->
        running = running_by_copy(scope)

        copies
        |> Enum.map(&line(&1, Map.get(running, &1.id, [])))
        |> Enum.join("\n")
    end
  end

  defp line(copy, agents) do
    [
      copy.id,
      describe_root(copy.root),
      if(copy.main, do: "main", else: "—"),
      describe_agents(agents)
    ]
    |> Enum.join("  |  ")
  end

  # Said in words rather than left blank, because a row with no root is the one
  # a reader is most likely to pick by mistake — it looks like a checkout in a
  # list of checkouts. Issue 28e838cc is that mistake made by code.
  defp describe_root(root) when is_binary(root) and root != "", do: root
  defp describe_root(_), do: "no checkout on disk — nothing can be built here"

  defp describe_agents([]), do: "nothing running"

  defp describe_agents(agents) do
    agents
    |> Enum.map(&"#{&1.role} (#{&1.status})")
    |> Enum.join(", ")
  end

  defp running_by_copy(scope) do
    scope
    |> Agents.list_running()
    |> Enum.group_by(& &1.working_copy_id)
  end
end
