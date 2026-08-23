defmodule CodeMySpecWeb.WorkingCopyLive.Rows do
  @moduledoc """
  The shape three pages agree on: a working copy, the agents on it, and the
  transcript they share.

  Index, Show and Form all have to answer "what is this copy" the same way, and
  a page that composes it for itself drifts from the other two on the first
  change — the Index saying Running while the Show says Idle is worse than
  either being wrong, because the reader has no way to pick.

  ## The hierarchy this exists to make visible

  A **harness is a working copy** — `WorkingCopies.issue/3` mints one id per
  checkout. A copy runs **one or more agents**, told apart by the lane's role.
  The copy's turns land in **one conversation**, keyed `pi:<root>`, because that
  is how the harness keys itself: every lane on a copy joins
  `harness:session:pi:<cwd>` and the team's transcript lands together. So the
  chat link belongs to the copy, and the liveness belongs to each agent.

  Reading, not writing. The conversation is looked up and never created here:
  these run on mount and on every broadcast, and a read that writes makes the
  list of copies grow a row every time somebody opens it.

  ## `label` and `heading` are not the same string

  `label` is the copy's stored name, falling back to the whole root — what a
  list row needs, because the path is the only thing distinguishing two unnamed
  copies and a row can truncate it.

  `heading` is `WorkingCopies.display_name/1`: the shortest string that still
  identifies the copy. A harness that names itself gets "the harness at <root>
  on <host>", which reads as a name and identifies like a path, and set as a
  3xl page title it renders four lines and pushes the page off the screen. The
  full root is on the page either way; this only decides which part is shouted.
  """

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.WorkingCopyLive.Liveness

  @type row :: %{
          harness: struct(),
          label: String.t(),
          agents: [struct()],
          conversation: struct() | nil,
          heading: String.t(),
          device: struct() | nil,
          device_name: String.t() | nil,
          message_count: non_neg_integer(),
          last_message_at: DateTime.t() | nil,
          liveness: Liveness.summary(),
          missing: %{since: String.t() | nil} | nil,
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
    |> WorkingCopies.list_harnesses()
    |> Enum.map(&build(&1, agents, transcripts, now))
  end

  @doc """
  One working copy by its harness id, or nil.

  Found inside the project's own list rather than by a bare id lookup: the id
  arrives on a URL, and `WorkingCopies.fetch/1` answers for any harness on any
  project.
  """
  @spec get(map(), struct(), String.t(), DateTime.t()) :: row() | nil
  def get(scope, project, working_copy_id, now) do
    scope
    |> list(project, now)
    |> Enum.find(&(&1.harness.id == working_copy_id))
  end

  # Keyed the way a lane keys itself, so the transcript a copy's agents write to
  # is the one the page links at.
  defp transcripts(scope, project) do
    scope
    |> Conversations.list_agent_conversations(project.id)
    |> Map.new(&{&1.conversation.session_external_id, &1})
  end

  defp build(harness, agents, transcripts, now) do
    on_this_copy = Enum.filter(agents, &(&1.working_copy_id == harness.id))
    transcript = Map.get(transcripts, "pi:#{harness.root}")

    %{
      harness: harness,
      device: device(harness),
      device_name: device_name(harness),
      label: harness.label || harness.root,
      heading: WorkingCopies.display_name(harness),
      agents: Enum.sort_by(on_this_copy, & &1.role),
      conversation: transcript && transcript.conversation,
      message_count: (transcript && transcript.message_count) || 0,
      last_message_at: transcript && transcript.last_message_at,
      last_message: transcript && Liveness.since(transcript.last_message_at, now),
      liveness: Liveness.working_copy(on_this_copy, now),
      missing: missing(harness, now)
    }
  end

  # Whether the checkout is still at its root, as its own machine last reported.
  #
  # Deliberately separate from `liveness`, which is about agents. A copy can be
  # missing and have an agent that still looks alive — a lane whose process
  # outlived the directory it was working in — and collapsing the two into one
  # verdict would hide exactly the case worth showing.
  #
  # `nil` means nothing to say: either the path is there, or no harness has
  # looked. Those are one state on purpose, because neither is a reason to warn
  # anybody, and distinguishing them would put "we have not checked" on every
  # row of a page that is mostly fine.
  defp missing(%{path_missing_since: nil}, _now), do: nil
  defp missing(%{path_missing_since: at}, now), do: %{since: Liveness.since(at, now)}

  # The machine this copy is on, when we have been told.
  #
  # `nil` is a real answer with two histories behind it — never reported, or the
  # machine was destroyed and `device_id` nullified — and they are
  # indistinguishable from here. Neither is claimed: the row says it has no
  # machine and stops there.
  defp device(%{device: %Device{} = device}), do: device
  defp device(_working_copy), do: nil

  defp device_name(working_copy) do
    case device(working_copy) do
      nil -> nil
      device -> Device.display_name(device)
    end
  end
end
