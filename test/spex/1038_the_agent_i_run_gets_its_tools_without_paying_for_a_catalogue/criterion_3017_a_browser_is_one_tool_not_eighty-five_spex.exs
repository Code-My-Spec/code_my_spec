defmodule CodeMySpecSpex.Story1038.Criterion3017Spex do
  @moduledoc """
  Story 1038 — The agent I run gets its tools without paying for a catalogue.
  Criterion 3017 — A browser is one tool, not eighty-five.

  Rule: A third-party MCP server arrives as one tool, not as its list.

  Our own ninety-eight are the reason this story exists, and they are not the
  worst of it. A QA agent also carries a browser, and a browser is eighty-five
  more schemas — click, fill, type, screenshot, find, find_all, get_text, and
  on — every one of them read on every turn to be told what a click is.

  So a third-party server is mounted the same way ours is: one tool that can
  reach all of it, plus enough of a list to know what exists. Names, not
  arguments — the arguments are what `tool_docs` is for, asked once, when the
  agent has decided which one it wants.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  
  setup :register_log_in_setup_account
  setup :setup_active_project

  # Names only, and eighty-five of them, because the count is the claim. A
  # server offering three would pass a version of this that a browser fails.
  @tools for n <- 1..85, do: "browser_tool_#{n}"

  spex "A third-party MCP server arrives as one tool, not as its list" do
    scenario "A browser is one tool, not eighty-five" do
      given_ "a third-party MCP server offering eighty-five tools", context do
        {:ok, Map.put(context, :offered, @tools)}
      end

      when_ "the agent is configured with it", context do
        id =
          running_agent(context, %{
            "mcp_servers" => [%{"name" => "browser", "tools" => context.offered}]
          })

        {:ok, context |> Map.put(:agent_id, id) |> Map.put(:tools, Fixtures.agent_tools(id))}
      end

      then_ "it carries one tool that can reach all of them", context do
        names = Enum.map(context.tools, & &1.name())
        from_browser = Enum.filter(names, &String.contains?(&1, "browser"))

        assert length(from_browser) == 1,
               "the browser arrived as #{length(from_browser)} tools. Eighty-five " <>
                 "schemas the agent reads every turn to be told what a click is, is " <>
                 "the catalogue this story exists to stop. Got: #{inspect(from_browser)}"

        {:ok, Map.put(context, :gateway, hd(from_browser))}
      end

      then_ "and a short list of what they are, rather than each one's arguments",
            context do
        described = Enum.find(context.tools, &(&1.name() == context.gateway)).description()

        assert described =~ "browser_tool_1" and described =~ "browser_tool_85",
               "the one tool does not say what is behind it, so the agent has to " <>
                 "guess a name before it can look one up. Got: #{inspect(described)}"

        refute described =~ ~r/"type"\s*:\s*"object"|input_schema|properties/,
               "the list carries each tool's arguments, which is the catalogue again " <>
                 "in one string. Names here; arguments from tool_docs, once, after " <>
                 "the agent has picked one."

        {:ok, context}
      end
    end
  end
end
