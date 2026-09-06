defmodule CmsHarness.Agents.Tools.SendMessage do
  @moduledoc """
  The way an agent reaches a person, carried directly.

  `CodeMode.Catalog` excludes `ask_user` from scripts, and its reason is about
  scripts: "it waits on a person, and a loop around it is questions nobody
  agreed to answer". Sound — and it left our agents with nothing, because
  `Engine.tools/1` did not carry it either. `LocalServer`'s rule names this
  exact case: *a tool excluded from scripts and absent from here would be
  reachable by no route at all.*

  So the refusal every stop printed —

      If you need something from the user to go further, call `ask_user`

  — named a tool the agent did not have, on every single refusal.

  What that produced is on the record. The product agent, working
  `three_amigos_complete` on story 994, reached a question it needed answered
  (whether open borders are bilateral and revocable), wrote it into its reply,
  and stopped. It looked like an agent ignoring an affordance. It was an agent
  doing the only thing left: there was no `ask_user` in its catalog, and asking
  in prose is what remains when the tool you are told to call does not exist.

  The lesson is not about this tool. Three times now a capability has been added
  at the spine and not to the Alloy agents, and each time the symptom was a
  model that looked disobedient. An instruction to call a tool the agent does
  not carry is indistinguishable, from the outside, from an agent that will not
  follow instructions.

  ## Answers come back as a message

  `check_answer` exists and polls, which is right for a Claude Code agent that
  is going to keep running anyway. It is wrong here: an agent that stops while
  waiting has nothing to poll *with*, and holding it open to poll burns a turn
  per check on a person who is not typing yet.

  So an agent that asks is allowed to stop, and the answer is dispatched to it
  as a message when it lands — `Notifications.answer_question_request/2` does
  the sending, `Agents.StopDecision` does the allowing. The agent does not have
  to arrange any of it, which is why this tool's own text tells it to stop
  rather than to wait.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "send_message",
    nothing_to: "nobody it can ask"

  @impl true
  def description do
    """
    Ask the person a question and stop. Use this the moment you need a decision
    only they can make — not at the end, and never by writing the question into
    your reply, which reaches nobody.

    You do not wait and you do not poll. Stop after asking; their answer is
    delivered to you as a message, and you pick up from there.

    Ask about a real fork in the work — a rule that could go two ways, a scope
    call, a preference the code cannot imply. If you can answer it by reading
    the project, read the project.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        message: %{
          type: "string",
          description:
            "The question, in prose. Give them what they need to answer it — " <>
              "what you are doing, what the options are, and what you will do " <>
              "with each. They cannot see your transcript."
        }
      },
      required: ["message"]
    }
  end
end
