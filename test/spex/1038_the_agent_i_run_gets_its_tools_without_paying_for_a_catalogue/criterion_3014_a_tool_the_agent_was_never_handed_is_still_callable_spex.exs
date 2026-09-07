defmodule CodeMySpecSpex.Story1038.Criterion3014Spex do
  @moduledoc """
  Story 1038 — The agent I run gets its tools without paying for a catalogue.
  Criterion 3014 — A tool the agent was never handed is still callable.

  Rule: Every tool the server exposes is reachable from the agent.

  What makes the two-tool count honest. Carrying two schemas is only an
  improvement if the other ninety-eight still work; otherwise it is not code
  mode, it is a smaller product.

  So the tool this calls is deliberately one the agent does not carry, and the
  assertion is on the answer rather than on the call succeeding: a `run_script`
  that swallows the failure and returns nil would pass a weaker version of this.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every tool the server exposes is reachable from the agent" do
    scenario "A tool the agent was never handed is still callable" do
      given_ "a tool the agent does not carry", context do
        id = running_agent(context)
        carried = id |> Fixtures.agent_tools() |> Enum.map(& &1.name())

        refute "list_stories" in carried,
               "the premise is a tool the agent was not handed, and it is holding " <>
                 "this one — so calling it proves nothing about reach"

        {:ok, context |> Map.put(:agent_id, id) |> Map.put(:story, authored(context))}
      end

      when_ "the agent runs a script that calls it", context do
        reply =
          Fixtures.run_script("return list_stories({})", agent_context(context))

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it answers as it would have answered a direct call", context do
        assert {:ok, body} = context.reply,
               "the script could not reach a tool the server exposes, so the two the " <>
                 "agent carries are a smaller product rather than a cheaper way in. " <>
                 "Got: #{inspect(context.reply)}"

        assert body =~ context.story.title,
               "the call went through and came back with something other than the " <>
                 "project's stories, so what the agent gets is not what a direct " <>
                 "call would have given it. Got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  # A story to find, so "it answered" is distinguishable from "it answered
  # nothing at all" — an empty list reads as success against a tool that never
  # ran.
  defp authored(context) do
    CodeMySpecSpex.Fixtures.authored_story(context.scope, "a story the script can find")
  end
end
