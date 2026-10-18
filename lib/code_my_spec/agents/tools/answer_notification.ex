defmodule CodeMySpec.Agents.Tools.AnswerNotification do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Tools.AnswerResponses, as: AnswerMapper
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def name, do: "answer_notification"

  @impl true
  def description do
    """
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
  end

  @impl true
  def params do
    %{
      tool: {:meta, :string, [description: "A tool you are using on that role's behalf."]},
      answer:
        {:meta, :string,
         [
           description:
             "What you found, in the agent's terms. For a question, the answer. For a denied tap_out, why it was denied — the agent is told this, and without it all it hears is 'declined', so it re-reads its own transcript and repeats whatever it last concluded."
         ]},
      basis:
        {:meta, :string,
         [
           description:
             "For a question: `record` (the project records it), `precedent`, or `inspected`."
         ]},
      decision:
        {:meta, :string, [description: "For a permission (e.g. `tap_out`): `allow` or `deny`."]},
      notification_id: {:required, {:meta, :string, [description: "From `list_notifications`."]}},
      precedent_id:
        {:meta, :string, [description: "With basis `precedent`: the question they answered."]},
      worked_around:
        {:meta, :string,
         [description: "The capability the asking role lacked, if you covered for one."]},
      on_behalf_of:
        {:meta, :string, [description: "A role you are acting as. Usually leave this out."]},
      citation:
        {:meta, :string,
         [
           description:
             "With basis `inspected`: the file path, commit, or tool call you actually made in this session — checked against your own turns, so it has to be close to how you actually wrote or called it, not a paraphrase."
         ]},
      capability:
        {:meta, :string,
         [
           description:
             "With `worked_around`: a short, stable name for what was missing — the tool name, normalized, not a sentence. Lets the same gap, described differently each time, still count as one."
         ]}
    }
  end

  @impl true
  def call(params, _context) when not is_map(params) do
    AnswerMapper.error(:missing_id)
  end

  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> settle(scope, params, context)
      {:error, reason} -> AnswerMapper.error(reason)
    end
  end

  # `decision` is what says this is a permission. Dispatching on the argument
  # rather than looking the id up first keeps the refusal honest: an id that is
  # neither is `:not_found` from whichever lookup was asked for, rather than a
  # tool guessing which store the caller meant and reporting the wrong absence.
  defp settle(scope, params, context) do
    case MapAccess.get(params, :decision) do
      nil -> answer(scope, params, context)
      decision -> decide(scope, params, decision, context)
    end
  end

  defp answer(scope, params, context) do
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
           by: caller_role(scope, context),
           inspector_id: inspector_id(context)
         ) do
      {:ok, answered} -> AnswerMapper.answered(answered)
      {:error, reason} -> AnswerMapper.error(reason)
    end
  end

  # Product answers the criteria questions routed to it (8c91d5bc); anybody
  # else answers as main always has.
  defp caller_role(scope, %{agent_id: id}) when is_binary(id) do
    case CodeMySpec.Agents.fetch_agent(scope, id) do
      {:ok, %{role: role}} -> role
      _ -> nil
    end
  end

  defp caller_role(_scope, _context), do: nil

  # `basis: "inspected"` is checked against *this* agent's own session, not
  # the asking agent's — the context is who is calling `answer_notification`.
  defp inspector_id(%{agent_id: id}) when is_binary(id), do: id
  defp inspector_id(_context), do: nil

  # Permissions (tap-outs) stay main's: product carries this tool to answer the
  # questions routed to it, not to staff the fleet.
  defp decide(scope, params, decision, context) do
    id = MapAccess.get(params, :notification_id)

    case decide_as(caller_role(scope, context), scope, id, decision, params) do
      {:ok, _resolved} -> AnswerMapper.decided(id, decision)
      {:error, reason} -> AnswerMapper.error(reason)
    end
  end

  defp decide_as(:product, _scope, _id, _decision, _params), do: {:error, :not_yours}

  defp decide_as(_role, scope, id, decision, params),
    do: MainAgent.decide_permission(scope, id, decision, MapAccess.get(params, :answer))
end
