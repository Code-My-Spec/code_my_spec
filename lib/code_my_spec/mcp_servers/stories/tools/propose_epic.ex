defmodule CodeMySpec.McpServers.Stories.Tools.ProposeEpic do
  @moduledoc """
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

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :epic_id, :string, required: true, doc: "Id of the epic to send for approval"
  end

  @impl true
  def execute(%{epic_id: epic_id}, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, epic} <- EpicDispatch.propose(scope, epic_id) do
      response =
        Response.tool()
        |> Response.text(
          "Sent \"#{epic.name}\" for approval. Nothing starts until the user agrees to it — " <>
            "they will see it on the project's epics screen."
        )

      {:reply, response, frame}
    else
      {:error, :not_draft} ->
        {:reply,
         Response.error(
           Response.tool(),
           "That epic has already been sent or is already being built. Proposing it again " <>
             "would put a second card in front of somebody for work they have been asked about."
         ), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
