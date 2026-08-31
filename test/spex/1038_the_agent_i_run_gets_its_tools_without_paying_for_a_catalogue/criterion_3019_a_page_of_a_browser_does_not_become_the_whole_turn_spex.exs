defmodule CodeMySpecSpex.Story1038.Criterion3019Spex do
  @moduledoc """
  Story 1038 — The agent I run gets its tools without paying for a catalogue.
  Criterion 3019 — A page of a browser does not become the whole turn.

  Rule: A result the agent cannot carry is cut before it reaches it.

  The saving this story exists for is undone by one answer. A page of HTML, a
  full architecture dump, a thousand-row listing — any of them arrives larger
  than everything the agent was going to think about, and the turn is then
  mostly a document nobody asked to read.

  Two halves, and the second is the one that gets forgotten. Cutting silently
  is worse than not cutting: the agent reasons about a truncated answer as if it
  were the whole one, and nothing in the transcript says otherwise.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  
  setup :register_log_in_setup_account
  setup :setup_active_project

  # Built in the script rather than fetched, so the size is the point and not a
  # fixture's incidental length. Nothing here depends on which tool produced it.
  #
  # Comfortably over what the agent can carry and comfortably under the Lua
  # sandbox's own string ceiling — the sandbox refuses to build one past 256KB
  # at all, which is a different refusal about a different limit and would be
  # asserting on the wrong one.
  @oversized """
  local page = string.rep("x", 100000)
  return page
  """

  spex "A result the agent cannot carry is cut before it reaches it" do
    scenario "A page of a browser does not become the whole turn" do
      given_ "a tool that answers with more than the agent can hold", context do
        {:ok,
         context |> Map.put(:agent_id, running_agent(context)) |> Map.put(:script, @oversized)}
      end

      when_ "a script calls it", context do
        reply = Fixtures.run_script(context.script, agent_context(context))

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "what comes back is cut to what the agent can carry", context do
        assert {:ok, body} = context.reply
        limit = Fixtures.max_result_chars()

        assert String.length(body) <= limit,
               "a #{String.length(body)}-character answer reached the agent against a " <>
                 "limit of #{limit}. One reply larger than the turn undoes the saving " <>
                 "two tools were carried for."

        {:ok, Map.put(context, :body, body)}
      end

      then_ "and the agent is told it was cut", context do
        assert context.body =~ ~r/truncat|cut|shortened/i,
               "the answer was cut and says nothing about it, so the agent reasons " <>
                 "about a fragment as though it were the whole thing. Got the last " <>
                 "of it: #{inspect(String.slice(context.body, -120, 120))}"

        {:ok, context}
      end
    end
  end
end
