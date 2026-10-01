defmodule CodeMySpecSpex.Story964.Criterion1610Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 1610 — Product comes up beside main on the main copy, one of each.

  John, a31f1cd6 step 4c: main and product stay on the main copy. Starting the
  project's main agent brings product up beside it there.
  """
  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.MainAgentHelpers
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup %{scope: scope} do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    # The agents run on a provider; with none connected nothing is started.
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "Product comes up beside main on the main copy, one of each", criterion: 1610 do
    scenario "Opening the project's conversation starts main, and product with it" do
      given_ "a project with a main checkout and no agents yet", context do
        {:ok, MainAgentHelpers.given_a_main_checkout(context, "spex_1610_main")}
      end

      when_ "I open the project's conversation", context do
        _main_id = MainAgentHelpers.main_agent_id(context)
        {:ok, context}
      end

      then_ "the main checkout holds one main agent and one product agent", context do
        {:ok, _live, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{context.copy_id}"
          )

        for role <- ~w(main product) do
          count = length(Regex.scan(~r/data-test="agent"[^>]*data-role="#{role}"/, html))

          assert count == 1,
                 "the main checkout has #{count} #{role} agent(s); it holds one of each"
        end

        {:ok, context}
      end
    end
  end
end
