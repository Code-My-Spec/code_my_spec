defmodule CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy do
  @moduledoc """
  Say which checkout an epic is built on.

  Its own action, deliberately. John: *"I think for the time being we should
  keep this flexible so let's have these as separate actions — creating the
  working copy and assigning an epic to a working copy."*

  So approving an epic is agreement, and this is placement, and neither implies
  the other. That leaves room for the decision to be made by whoever is best
  placed to make it: *"if there's an appropriate working copy and agent then it
  should get assigned that, or maybe the agent wants a fresh working copy ...
  the user should be able to decide where to assign it or the agent should be
  able to decide."*

  Call `list_working_copies` first. A copy with no `root` has no disk behind it
  and is refused here rather than accepted and discovered later — that failure
  already has an issue of its own (28e838cc), where an epic reported it was
  being built on a directory that did not exist.

  ## What it writes

  The epic's **stories**, not the epic. An epic has no place in the requirement
  graph — nothing in `RequirementCalculator` or `Predicates` mentions one — so a
  copy recorded on the epic was never consulted when deciding what an agent is
  offered. The column named a routing nothing performed, and an agent told to
  release an epic looked for the step that would do it and found none.

  The binding lives on `stories.working_copy_id`, which is the grain
  `get_next_requirement` actually reads. John: *"an epic is just basically a
  convenience measure to act on multiple stories ... these assignments need to
  go into the story because that's how the graph works."*

  So this stays one call and one act, and it now has an effect: the epic's
  stories go to that checkout, its agents are offered them, and no other copy
  is.

  ## What this does not do

  It does not start an agent. Assigning and starting are separate for the same
  reason approving and assigning are: an epic can sit on a checkout that already
  has an agent working, and giving it one of its own would be a second agent
  nobody asked for.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.Epics
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.WorkingCopies

  schema do
    field :epic_id, :string, required: true, doc: "Id of the epic to place"

    field :working_copy_id, :string,
      required: true,
      doc: "Id of the checkout to build it on, from list_working_copies"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, epic} <- fetch_epic(scope, params.epic_id),
         {:ok, copy} <- fetch_rooted_copy(scope, params.working_copy_id),
         {:ok, placed} <- EpicDispatch.place(scope, epic.id, copy.id) do
      {:reply,
       Response.text(
         Response.tool(),
         "#{placed} #{story_word(placed)} of \"#{epic.name}\" will be built on #{copy.root}. " <>
           "Agents there are offered them now, and no other checkout is. Nothing is running " <>
           "yet unless something already was — assigning is not starting."
       ), frame}
    else
      {:error, :rootless} ->
        {:reply,
         Response.error(
           Response.tool(),
           "That working copy has no checkout on disk, so nothing can be built on it. " <>
             "`list_working_copies` says which ones do."
         ), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end

  defp story_word(1), do: "story"
  defp story_word(_), do: "stories"

  defp fetch_epic(scope, epic_id) do
    case Epics.get_epic(scope, epic_id) do
      nil -> {:error, :not_found}
      epic -> {:ok, epic}
    end
  end

  # Same project as well as same id: `WorkingCopies.fetch/1` answers for any
  # checkout anywhere, and an epic placed on another project's copy would be a
  # cross-project write that nothing downstream would question.
  defp fetch_rooted_copy(scope, id) do
    with {:ok, copy} <- WorkingCopies.fetch(id),
         true <- copy.project_id == scope.active_project_id do
      case copy.root do
        root when is_binary(root) and root != "" -> {:ok, copy}
        _ -> {:error, :rootless}
      end
    else
      false -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end
end
