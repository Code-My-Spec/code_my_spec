defmodule CodeMySpec.Stories.Tools.ProposeEpic do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper

  @impl true
  def name, do: "propose_epic"

  @impl true
  def description do
    """
    Send an epic to the user for approval.

    The main agent's half of the hand-off, and the only way work on an epic ever
    starts. Approving it is the user's act, on the epics screen — John: *"the
    agent sending it and the meatbags approving it are two different things."*
    This tool does the sending and nothing else: no working copy is chosen, no
    agent is started, nothing is spent.

    ## When to call it

    When the `work_dispatched` requirement is unsatisfied. That happens only when
    nothing is being built *and* there are ready stories nobody has been given —
    the one state that wants you to act. If something is already underway, leave
    it alone; an agent working on a story is a reason not to assign more.

    Group the ready stories into an epic with `create_epic` and
    `assign_story_to_epic` first, then propose it.

    ## What the user sees

    The epic appears on their epics screen with a control to agree to it, and the
    screen updates while they are looking at it. Until they agree, nothing
    happens — an epic they ignore changes nothing.
    """
  end

  @impl true
  def params do
    %{
      epic_id: {:required, {:meta, :string, [description: "Id of the epic to send for approval"]}}
    }
  end

  @impl true
  def call(%{epic_id: epic_id}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, epic} <- EpicDispatch.propose(scope, epic_id) do
      response =
        {:ok,
         "Sent \"#{epic.name}\" for approval. Nothing starts until the user agrees to it — " <>
           "they will see it on the project's epics screen."}

      response
    else
      {:error, :not_draft} ->
        {:error,
         "That epic has already been sent or is already being built. Proposing it again " <>
           "would put a second card in front of somebody for work they have been asked about."}

      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end
end
