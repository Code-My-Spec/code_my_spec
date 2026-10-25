defmodule CodeMySpec.Agents.Tools.MessageAgent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Tools.Responses, as: AgentsMapper
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.WorkingCopies

  @impl true
  def name, do: "message_agent"

  @impl true
  def description do
    """
    Give a running agent a message and return its delivery disposition.

    Terminal agents use their native transport: `codex queue` for Codex and
    Claude's messaging API for Claude Code. An unavailable native transport
    refuses a direct message; it is not handed over through the Stop hook.
    Delivery to a terminal session does not confirm that a turn has started.

    Without this an agent could be started, listed and stopped, and never asked
    to do anything — it came up idle and stayed idle until somebody stopped it.
    It cost nothing, which is why nothing complained, and it also did nothing.

    This is the capability the engine change was chosen for. Delivering a message
    to a detached `pi` process would have meant a named pipe with a writer inside
    the agent's own process group so it never saw EOF, plus a protocol nobody had
    written down. To a supervised process it is a call, and this is the surface
    on top of it.

    Wait only for admission: an idle agent starts, and a busy agent queues the
    message for its next turn boundary. The response arrives in the agent's
    conversation. Queuing does not count as delivery when judging its Offer.

    `send_now` stops a busy agent's running turn so the message is its next one
    (story 1051); the agent keeps what it did up to its last completed tool call.
    For a correction to work in progress, use it: queued, the message waits out
    the very work it corrects. A queued message's id is in the reply, so
    `withdraw_message` can take it back until the agent has it.
    """
  end

  @impl true
  def params do
    %{
      message:
        {:required,
         {:meta, :string,
          [
            description:
              "What to tell the agent — an instruction, a question, or the next piece of work"
          ]}},
      agent_id:
        {:required,
         {:meta, :string,
          [
            description:
              "Id of the agent to send this to, or `main` for the project's current main " <>
                "agent -- reachable from any working copy, unlike any other role's agent"
          ]}},
      send_now:
        {:meta, :boolean,
         [
           description:
             "Stop a busy agent's running turn so this message is its next one, instead of waiting for the turn to end. The agent keeps what it did up to its last completed tool call. Use it to correct work in progress."
         ]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, target_id} <- resolve_target(scope, agent_id(params)),
         :ok <- reachable(scope, context[:agent_id], target_id) do
      dispatch(scope, target_id, params, context)
    else
      {:error, reason} -> AgentsMapper.error(reason, nil)
    end
  end

  defp dispatch(scope, target_id, params, context) do
    case Agents.dispatch_message(scope, target_id, message(params), :operator_message,
           send_now: MapAccess.get(params, :send_now) == true
         ) do
      {:ok, reply, sent} ->
        scope
        |> delivery_reply(target_id, reply)
        |> withdrawable(reply, sent)
        |> with_pending_question(scope, context[:agent_id], target_id)
        |> not_interruptible(scope, target_id, MapAccess.get(params, :send_now) == true)

      {:error, :harness_not_connected} ->
        harness_not_connected_error(scope, target_id)

      {:error, reason} ->
        AgentsMapper.error(reason, nil)
    end
  end

  defp delivery_reply(scope, target_id, reply) do
    case Agents.fetch_agent(scope, target_id) do
      {:ok, %{engine: engine}} when engine in [:claude_code, :codex] ->
        transport = if engine == :codex, do: "codex queue", else: "Claude's messaging API"

        outcome =
          if reply == :started,
            do: "Message delivered through #{transport}. This does not confirm a turn started.",
            else: "Message pending native delivery through #{transport}; not yet delivered."

        {:ok, "Agent: #{target_id}\n\n#{outcome}"}

      _ ->
        AgentsMapper.replied(target_id, reply)
    end
  end

  # The dispatch itself only knows a working copy was unreachable, not what to
  # call it — naming the box is this tool's job, since it is the one place an
  # operator reads the refusal. A box never joins with a label is still named
  # by its root, or failing that its id; it is never left to a bare reason
  # atom (issue 739eb4bd).
  defp harness_not_connected_error(scope, target_id) do
    with {:ok, %{working_copy_id: working_copy_id}} <- Agents.fetch_agent(scope, target_id),
         {:ok, copy} <- WorkingCopies.fetch(working_copy_id) do
      {:error, "Message not delivered: #{box_name(copy)} is not connected."}
    else
      _ -> {:error, "Message not delivered: the target machine is not connected."}
    end
  end

  defp box_name(%{label: label}) when is_binary(label) and label != "", do: label
  defp box_name(%{root: root}) when is_binary(root) and root != "", do: root
  defp box_name(%{id: id}), do: id

  # "main" addresses the project's current main agent by role rather than by
  # id, since its id changes across restarts and nothing in an agent's own
  # context names it (issue 0ae29c2a) -- the caller that filed this one had
  # no other way to find it than guessing.
  defp resolve_target(scope, "main") do
    case Agents.main_agent(scope) do
      %{id: id} -> {:ok, id}
      nil -> {:error, "no main agent is running on this project right now"}
    end
  end

  defp resolve_target(_scope, agent_id), do: {:ok, agent_id}

  # Story 1052: coding and QA message a teammate on their own copy; main,
  # product and other copies are reached through a question instead.
  defp reachable(scope, caller_id, target_id) when is_binary(caller_id) do
    with {:ok, %{role: role} = caller} when role in [:coding, :qa] <-
           Agents.fetch_agent(scope, caller_id),
         {:ok, target} <- Agents.fetch_agent(scope, target_id) do
      teammate(caller, target)
    else
      _ -> :ok
    end
  end

  defp reachable(_scope, _caller_id, _target_id), do: :ok

  defp teammate(%{working_copy_id: copy}, %{working_copy_id: copy, role: role})
       when role in [:coding, :qa],
       do: :ok

  # John's decision, issue 0ae29c2a: message_agent reaches main from any
  # copy. The copy restriction stays for every other role.
  defp teammate(_caller, %{role: :main}), do: :ok

  defp teammate(_caller, _target),
    do:
      {:error,
       "You can message only a teammate on your own working copy, or main from any copy. " <>
         "Ask product with ask_question (to: \"product\") instead."}

  # c99aad08: main answered a teammate's question by messaging it, so the
  # question stayed pending and the teammate rightly refused an answer nothing
  # recorded. The message still goes; main is told how to answer so it counts.
  defp with_pending_question(response, scope, caller_id, target_id)
       when is_binary(caller_id) and is_binary(target_id) do
    with {:ok, %{role: :main}} <- Agents.fetch_agent(scope, caller_id),
         [_ | _] = ids <- questions_to_main(scope, target_id) do
      append(response, pending_hint(ids))
    else
      _ -> response
    end
  end

  defp with_pending_question(response, _scope, _caller_id, _target_id), do: response

  defp questions_to_main(scope, target_id) do
    for %{kind: :question, holder: "main_agent", agent_id: ^target_id, id: id} <-
          MainAgent.list_open_questions(scope),
        do: id
  end

  defp pending_hint(ids) do
    "This agent is waiting on question #{Enum.join(ids, ", ")}, addressed to you. " <>
      "A message does not answer it: answer it with `answer_notification` (through " <>
      "`run_script`) so it is recorded and reaches the agent."
  end

  defp withdrawable(response, :queued, sent),
    do:
      append(
        response,
        "Message id: #{sent.delivery_ref}. Take it back with `withdraw_message` " <>
          "until the agent has it."
      )

  defp withdrawable(response, _reply, _sent), do: response

  # A second line under the reply, as a second text part read before.
  # Story 1123: a terminal session reads a message at its next tool call and
  # nothing stops its turn, so send-now says what it did instead.
  defp not_interruptible(response, scope, target_id, true) do
    case Agents.fetch_agent(scope, target_id) do
      {:ok, %{engine: :claude_code}} ->
        append(
          response,
          "This agent is a terminal session: it reads this at its next tool call, " <>
            "and its turn cannot be interrupted."
        )

      {:ok, %{engine: :codex}} ->
        append(
          response,
          "This agent is a Codex terminal session: the message is queued and Codex reads " <>
            "it when it chooses, and its turn cannot be interrupted."
        )

      _ ->
        response
    end
  end

  defp not_interruptible(response, _scope, _target_id, _send_now), do: response

  defp append({:ok, text}, more), do: {:ok, text <> "\n" <> more}
  defp append(other, _more), do: other

  defp agent_id(params), do: MapAccess.get(params, :agent_id)
  defp message(params), do: MapAccess.get(params, :message)
end
