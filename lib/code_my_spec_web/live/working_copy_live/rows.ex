defmodule CodeMySpecWeb.WorkingCopyLive.Rows do
  @moduledoc """
  The shape three pages agree on: a working copy, the agents on it, and the
  transcript they share.

  Index, Show and Form all have to answer "what is this copy" the same way, and
  a page that composes it for itself drifts from the other two on the first
  change — the Index saying Running while the Show says Idle is worse than
  either being wrong, because the reader has no way to pick.

  ## The hierarchy this exists to make visible

  A **harness is a working copy** — `Harnesses.issue/3` mints one id per
  checkout. A copy runs **one or more agents**, told apart by the lane's role.
  The copy's turns land in **one conversation**, keyed `pi:<root>`, because that
  is how the harness keys itself: every lane on a copy joins
  `harness:session:pi:<cwd>` and the team's transcript lands together. So the
  chat link belongs to the copy, and the liveness belongs to each agent.

  Reading, not writing. The conversation is looked up and never created here:
  these run on mount and on every broadcast, and a read that writes makes the
  list of copies grow a row every time somebody opens it.
  """

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Harnesses
  alias CodeMySpecWeb.WorkingCopyLive.Liveness

  @type row :: %{
          harness: struct(),
          label: String.t(),
          agents: [struct()],
          conversation: struct() | nil,
          message_count: non_neg_integer(),
          last_message_at: DateTime.t() | nil,
          liveness: Liveness.summary(),
          last_message: String.t() | nil
        }

  @doc """
  Every working copy on the project, newest first.
  """
  @spec list(map(), struct(), DateTime.t()) :: [row()]
  def list(scope, project, now) do
    agents = Agents.list_running(scope)
    transcripts = transcripts(scope, project)

    scope
    |> Harnesses.list_harnesses()
    |> Enum.map(&build(&1, agents, transcripts, now))
  end

  @doc """
  One working copy by its harness id, or nil.

  Found inside the project's own list rather than by a bare id lookup: the id
  arrives on a URL, and `Harnesses.fetch/1` answers for any harness on any
  project.
  """
  @spec get(map(), struct(), String.t(), DateTime.t()) :: row() | nil
  def get(scope, project, harness_id, now) do
    scope
    |> list(project, now)
    |> Enum.find(&(&1.harness.id == harness_id))
  end

  # Keyed the way a lane keys itself, so the transcript a copy's agents write to
  # is the one the page links at.
  defp transcripts(scope, project) do
    scope
    |> Conversations.list_agent_conversations(project.id)
    |> Map.new(&{&1.conversation.session_external_id, &1})
  end

  defp build(harness, agents, transcripts, now) do
    on_this_copy = Enum.filter(agents, &(&1.working_copy == harness.root))
    transcript = Map.get(transcripts, "pi:#{harness.root}")

    %{
      harness: harness,
      label: harness.label || harness.root,
      agents: Enum.sort_by(on_this_copy, & &1.role),
      conversation: transcript && transcript.conversation,
      message_count: (transcript && transcript.message_count) || 0,
      last_message_at: transcript && transcript.last_message_at,
      last_message: transcript && Liveness.since(transcript.last_message_at, now),
      liveness: Liveness.working_copy(on_this_copy, now)
    }
  end
end
