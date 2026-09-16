defmodule CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification do
  @moduledoc """
  Settle one entry from `list_notifications`, whichever kind it is.

  A question takes `answer` and `basis`. A permission — a `tap_out`, or an
  agent asking to call something — takes `decision`: `allow` or `deny`.

  `basis` says what an answer rests on and is checked: `record` means the
  project records it, `precedent` means the user already decided it and takes
  `precedent_id`. An answer with neither is a guess and is refused — say what
  you found it in, or escalate.

  Say `worked_around` when you had to supply something the asking role should
  have been able to find itself; that gets counted as a gap in that role's
  tools.
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

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.AnswerMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :id, :string, required: true, doc: "From `list_notifications`."

    field :answer, :string, doc: "For a question: what you found, in the agent's terms."

    field :basis, :string,
      doc: "For a question: `record` (the project records it) or `precedent`."

    field :precedent_id, :string, doc: "With basis `precedent`: the question they answered."

    field :worked_around, :string,
      doc: "The capability the asking role lacked, if you covered for one."

    field :on_behalf_of, :string, doc: "A role you are acting as. Usually leave this out."
    field :tool, :string, doc: "A tool you are using on that role's behalf."

    field :decision, :string,
      doc: "For a permission (e.g. `tap_out`): `allow` or `deny`."
  end

  @impl true
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
           MapAccess.get(params, :id),
           MapAccess.get(params, :answer),
           basis: MapAccess.get(params, :basis),
           precedent_id: MapAccess.get(params, :precedent_id),
           worked_around: MapAccess.get(params, :worked_around),
           on_behalf_of: MapAccess.get(params, :on_behalf_of),
           tool: MapAccess.get(params, :tool)
         ) do
      {:ok, answered} -> {:reply, AnswerMapper.answered(answered), frame}
      {:error, reason} -> {:reply, AnswerMapper.error(reason), frame}
    end
  end

  defp decide(scope, params, decision, frame) do
    id = MapAccess.get(params, :id)

    case MainAgent.decide_permission(scope, id, decision) do
      {:ok, _resolved} -> {:reply, AnswerMapper.decided(id, decision), frame}
      {:error, reason} -> {:reply, AnswerMapper.error(reason), frame}
    end
  end
end
