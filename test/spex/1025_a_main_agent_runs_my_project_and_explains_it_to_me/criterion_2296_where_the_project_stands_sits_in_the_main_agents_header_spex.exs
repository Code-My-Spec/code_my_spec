defmodule CodeMySpecSpex.Story1025.Criterion2296Spex do
  @moduledoc """
  Story 1025 — A main agent runs my project and explains it to me.
  Criterion 2296 — Where the project stands sits in the main agent's header,
  under its name and controls.

  Replaces criterion 1000's sentence: the header carries the project's state
  as the strip, on the one conversation about the whole project.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "The main agent's header carries where the project stands", criterion: 2296 do
    scenario "Where the project stands sits in the main agent's header" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_header")}
      end

      when_ "I open its conversation", context do
        {:ok, _view, html} = live(context.conn, main_conversation_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the strip is inside the agent's header", context do
        [header] =
          Regex.run(~r/<header[^>]*data-test="main-agent".*?<\/header>/s, context.html)

        assert header =~ ~s(data-test="project-timeline"),
               "where the project stands is not in the main agent's header"

        {:ok, Map.put(context, :header, header)}
      end

      then_ "under its name and controls", context do
        name = :binary.match(context.header, "<h1") |> elem(0)
        controls = :binary.match(context.header, ~s(data-test="toggle-agent-working")) |> elem(0)
        strip = :binary.match(context.header, ~s(data-test="project-timeline")) |> elem(0)

        assert strip > name and strip > controls,
               "the strip comes before the agent's name or controls, not under them"

        {:ok, context}
      end
    end
  end
end
