defmodule CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification do
  @moduledoc """
  Settle one entry from `list_notifications`, whichever kind it is.

  A question takes `answer` and `basis`. A permission — a `tap_out`, or an
  agent asking to call something — takes `decision`: `allow` or `deny`.

  `basis` says what an answer rests on and is checked: `record` means the
  project records it, `precedent` means the user already decided it and takes
  `precedent_id`, `inspected` means you read it yourself and takes `citation`
  — a file path, commit, or tool call you actually made in this session, close
  enough to your own wording that it is checkable there. An answer with none
  of these is a guess and is refused — say what you found it in, or escalate.

  Say `worked_around` when you had to supply something the asking role should
  have been able to find itself; that gets counted as a gap in that role's
  tools. Say `capability` alongside it: a short, stable name for what was
  missing (usually the tool name), not a sentence. `worked_around` is written
  fresh each time and rarely matches word for word between occurrences of the
  same gap, so without `capability` the same gap can get filed as several
  issues instead of one counted repeatedly.
  """

  # Why one tool rather than two
  #
  # Both kinds stop an agent identically — `Notifications.awaiting_answer?/1` is
  # `pending_question? or pending_permission?` — so the reader works one queue
  # and settles entries from it. Two tools would mean knowing which store an id
  # came from before you could act on it, which is exactly what the caller has
  # just been told by `kind` and should not have to re-derive.
  #
  # A permission had no agent-facing route at all before this. The notifications
  # dropdown calls `Notifications.resolve_permission_request/2` and nothing else
  # did, so an agent could raise a `tap_out` and only a person at a browser
  # could answer it. `880c7713` spent seven hours unreachable on one (`8cb3f626`).

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.McpServers.MainAgent.AnswerMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :notification_id, :string, required: true, description: "From `list_notifications`."

    field :answer, :string,
      description:
        "What you found, in the agent's terms. For a question, the answer. For a " <>
          "denied tap_out, why it was denied — the agent is told this, and without it " <>
          "all it hears is 'declined', so it re-reads its own transcript and repeats " <>
          "whatever it last concluded."

    field :basis, :string,
      description: "For a question: `record` (the project records it), `precedent`, or `inspected`."

    field :precedent_id, :string, description: "With basis `precedent`: the question they answered."

    field :citation, :string,
      description:
        "With basis `inspected`: the file path, commit, or tool call you actually made in " <>
          "this session — checked against your own turns, so it has to be close to how you " <>
          "actually wrote or called it, not a paraphrase."

    field :worked_around, :string,
      description: "The capability the asking role lacked, if you covered for one."

    field :capability, :string,
      description:
        "With `worked_around`: a short, stable name for what was missing — the tool name, " <>
          "normalized, not a sentence. Lets the same gap, described differently each time, " <>
          "still count as one."

    field :on_behalf_of, :string, description: "A role you are acting as. Usually leave this out."
    field :tool, :string, description: "A tool you are using on that role's behalf."

    field :decision, :string, description: "For a permission (e.g. `tap_out`): `allow` or `deny`."
  end

  @impl true
  def execute(params, frame) when not is_map(params) do
    {:reply, AnswerMapper.error(:missing_id), frame}
  end

  def execute(params, frame) do
    case Validators.validate_local_scope(frame, params) do
      {:ok, scope} -> settle(scope, params, frame)
      {:error, reason} -> {:reply, AnswerMapper.error(reason), frame}
    end
  end

  # `decision` is what says this is a permission. Dispatching on the argument
  # rather than looking the id up first keeps the refusal honest: an id that is
  # neither is `:not_found` from whichever lookup was asked for, rather than a
  # tool guessing which store the caller meant and reporting the wrong absence.
  defp settle(scope, params, frame) do
    case MapAccess.get(params, :decision) do
      nil -> answer(scope, params, frame)
      decision -> decide(scope, params, decision, frame)
    end
  end

  defp answer(scope, params, frame) do
    case MainAgent.answer_question(
           scope,
           MapAccess.get(params, :notification_id),
           MapAccess.get(params, :answer),
           basis: MapAccess.get(params, :basis),
           precedent_id: MapAccess.get(params, :precedent_id),
           citation: MapAccess.get(params, :citation),
           worked_around: MapAccess.get(params, :worked_around),
           capability: MapAccess.get(params, :capability),
           on_behalf_of: MapAccess.get(params, :on_behalf_of),
           tool: MapAccess.get(params, :tool),
           by: caller_role(scope, frame),
           inspector_id: inspector_id(frame)
         ) do
      {:ok, answered} -> {:reply, AnswerMapper.answered(answered), frame}
      {:error, reason} -> {:reply, AnswerMapper.error(reason), frame}
    end
  end

  # Product answers the criteria questions routed to it (8c91d5bc); anybody
  # else answers as main always has.
  defp caller_role(scope, %{assigns: %{agent_id: id}}) when is_binary(id) do
    case CodeMySpec.Agents.fetch_agent(scope, id) do
      {:ok, %{role: role}} -> role
      _ -> nil
    end
  end

  defp caller_role(_scope, _frame), do: nil

  # `basis: "inspected"` is checked against *this* agent's own session, not
  # the asking agent's — the frame is who is calling `answer_notification`.
  defp inspector_id(%{assigns: %{agent_id: id}}) when is_binary(id), do: id
  defp inspector_id(_frame), do: nil

  # Permissions (tap-outs) stay main's: product carries this tool to answer the
  # questions routed to it, not to staff the fleet.
  defp decide(scope, params, decision, frame) do
    id = MapAccess.get(params, :notification_id)

    case decide_as(caller_role(scope, frame), scope, id, decision, params) do
      {:ok, _resolved} -> {:reply, AnswerMapper.decided(id, decision), frame}
      {:error, reason} -> {:reply, AnswerMapper.error(reason), frame}
    end
  end

  defp decide_as(:product, _scope, _id, _decision, _params), do: {:error, :not_yours}

  defp decide_as(_role, scope, id, decision, params),
    do: MainAgent.decide_permission(scope, id, decision, MapAccess.get(params, :answer))
end
