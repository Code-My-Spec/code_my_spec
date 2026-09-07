defmodule CodeMySpecSpex.Story1038.Criterion3021Spex do
  @moduledoc """
  Story 1038 — The agent I run gets its tools without paying for a catalogue.
  Criterion 3021 — The main agent reaches everything.

  Rule: Each agent type reaches only the tools its job needs.

  The other side of 3020, and the reason the rule is about *needs* rather than
  about least privilege. The main agent's job is the whole project: shaping
  stories, organising epics, handing work over, and checking what came back.
  Scoping it is scoping the thing that checks the others.

  Asked rather than counted against a number. A list of ninety-eight names in
  this file would be a copy of the catalogue that goes stale the day a tool is
  added — which is the same failure as the assertion passing while a tool is
  quietly missing.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.ScriptableTools
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Each agent type reaches only the tools its job needs" do
    scenario "The main agent reaches everything" do
      given_ "the main agent", context do
        {:ok, Map.put(context, :agent_id, running_agent(context, %{"role" => "main"}))}
      end

      when_ "it asks what it can call", context do
        {:ok, Map.put(context, :reply, Fixtures.tool_docs(%{}, agent_context(context)))}
      end

      then_ "it is every tool, because it is the one that checks the others", context do
        assert {:ok, body} = context.reply

        every = ScriptableTools.__components__() |> Enum.count()
        listed = body |> String.split("\n") |> Enum.count(&String.match?(&1, ~r/^\s+\w+ —/))

        assert listed >= every,
               "the main agent is offered #{listed} of #{every} tools. Its job is the " <>
                 "whole project — shaping stories, organising epics, handing work " <>
                 "over, checking what came back — so scoping it is scoping the thing " <>
                 "that checks the others."

        {:ok, context}
      end
    end
  end
end
