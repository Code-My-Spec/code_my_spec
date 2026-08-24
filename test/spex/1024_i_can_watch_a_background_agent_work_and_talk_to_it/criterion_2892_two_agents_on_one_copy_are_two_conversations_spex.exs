defmodule CodeMySpecSpex.Story1024.Criterion2892Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2892 — Two agents on one copy are two conversations.

  Rule: Every agent has its own conversation.

  This replaces a deliberate design rather than correcting a mistake.
  `Conversations.find_or_create_agent_conversation/3` keyed on the working copy
  and said so: "the shared id for the whole Pi team — the whole team's
  transcript lands here."

  That was reasonable when a copy ran one lane and the transcript was the
  copy's story. It is not reasonable now. Story 1023 keeps a rule about
  stopping one agent and leaving its siblings running, precisely because a copy
  runs several — and their turns interleaving into one thread means following
  either is impossible, and a reply cannot say who spoke.

  So the conversation belongs to the agent, which is the thing that has an id,
  can be started and stopped, and does the talking.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A conversation belongs to an agent, not to a checkout" do
    scenario "Two agents on one copy are two conversations" do
      given_ "one working copy", context do
        copy = CodeMySpec.TempFile.dir("spex_2892")
        File.mkdir_p!(copy)

        {:ok, Map.put(context, :copy, copy)}
      end

      when_ "two agents are started on it", context do
        coding = Fixtures.running_agent(context.scope, role: "coding", working_copy: context.copy)
        qa = Fixtures.running_agent(context.scope, role: "qa", working_copy: context.copy)

        start_agent(coding.id, working_copy: context.copy)
        start_agent(qa.id, working_copy: context.copy)

        {:ok, context |> Map.put(:coding, coding) |> Map.put(:qa, qa)}
      end

      then_ "each has a conversation of its own", context do
        coding_conversation = Fixtures.agent_conversation(context.scope, context.coding)
        qa_conversation = Fixtures.agent_conversation(context.scope, context.qa)

        assert coding_conversation, "the coding agent has no conversation of its own"
        assert qa_conversation, "the QA agent has no conversation of its own"

        refute coding_conversation.id == qa_conversation.id,
               "both agents share one conversation. Their turns interleave into a " <>
                 "single thread, following either is impossible, and a reply cannot " <>
                 "say which of them spoke."

        {:ok, context}
      end

      then_ "and what one did is not mixed into the other's", context do
        coding_conversation = Fixtures.agent_conversation(context.scope, context.coding)

        assert coding_conversation.agent_id == context.coding.id,
               "the conversation does not name the agent it belongs to, so nothing " <>
                 "downstream can tell whose work it is holding"

        {:ok, context}
      end
    end
  end
end
