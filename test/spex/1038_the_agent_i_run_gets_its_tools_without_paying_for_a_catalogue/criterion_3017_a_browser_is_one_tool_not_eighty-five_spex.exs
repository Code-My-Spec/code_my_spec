defmodule CodeMySpecSpex.Story1038.Criterion3017Spex do
  @moduledoc """
  Story 1038 — The agent I run gets its tools without paying for a catalogue.
  Criterion 3017 — A browser is no extra tools, not eighty-five.

  Rule: A third-party MCP server arrives as one tool, not as its list.

  Our own ninety-eight are the reason this story exists, and they are not the
  worst of it. A QA agent also carries a browser, and asking vibium's own MCP
  server what it offers returns **eighty-five** tools — every one of them a
  schema read on every turn to be told what a click is.

  ## Rewritten once, and a correction inside that

  This said "one tool, not eighty-five", and I changed the number to twenty-nine
  on the strength of `plugins/claude/agents/qa.md`, which grants twenty-nine
  `mcp__vibium__browser_*` tools. That was the wrong source: twenty-nine is what
  the plugin hands a QA agent, eighty-five is what the browser has, and the
  criterion was always about the second. `vibium mcp` answers `tools/list` with
  eighty-five, which is where this number comes from and where to re-check it.

  What did need rewriting is the answer, which turned out better than the rule
  asked for. John's design
  mounts a third-party server the way ours is mounted: `vibium mcp` speaks
  JSON-RPC over stdio to the harness, its tools join the catalog a script
  already reaches, and the agent carries *nothing* extra for them. "Arrives as
  one tool, not as its list" is satisfied by arriving as none — the one tool it
  arrives through is `run_script`, which was already there.

  So what this asserts is reach without cost: the browser's tools are callable,
  and the agent's own tool list did not grow to make that true.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A third-party MCP server arrives as one tool, not as its list" do
    scenario "A browser is no extra tools, not twenty-nine" do
      given_ "a machine whose browser offers its tools", context do
        offered = fake_browser(context)

        {:ok, Map.put(context, :offered, offered)}
      end

      when_ "an agent is started on it", context do
        id = running_agent(context)

        {:ok,
         context
         |> Map.put(:agent_id, id)
         |> Map.put(:carried, id |> Fixtures.agent_tools() |> Enum.map(& &1.name()))}
      end

      then_ "it carries nothing extra for them", context do
        browsery = Enum.filter(context.carried, &String.contains?(&1, "browser"))

        assert browsery == [],
               "the browser arrived as #{length(browsery)} tools on the agent. " <>
                 "Twenty-nine schemas read every turn to be told what a click is, " <>
                 "on top of our own ninety-eight, is the catalogue this story " <>
                 "exists to stop. Got: #{inspect(browsery)}"

        {:ok, context}
      end

      then_ "and can reach all of them through the one it already had", context do
        listed = Fixtures.tool_docs(%{}, agent_context(context))

        assert {:ok, body} = listed

        for name <- context.offered do
          assert body =~ name,
                 "#{name} is on this machine's browser and the agent cannot find it, " <>
                   "so the tools it did not carry are unreachable rather than merely " <>
                   "uncounted — which is a smaller product, not a cheaper way in."
        end

        {:ok, context}
      end
    end
  end
end
