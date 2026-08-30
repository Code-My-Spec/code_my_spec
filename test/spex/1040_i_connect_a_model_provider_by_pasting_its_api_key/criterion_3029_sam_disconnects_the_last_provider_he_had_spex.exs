defmodule CodeMySpecSpex.Story1040.Criterion3029Spex do
  @moduledoc """
  Story 1040 — I connect a model provider by pasting its API key
  Criterion 3029 — Sam disconnects the last provider he had

  The end of the fall-back chain. With nothing connected there is no model to
  resolve to, and the honest thing on the page is to say so — naming one anyway
  is the mismatch story 1039's QA found from the other direction, where the
  screen named a default the launcher would never start on.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account

  spex "I connect a model provider by pasting its API key" do
    scenario "Sam disconnects the last provider he had" do
      given_ "Z.ai is the only provider he has connected", context do
        Fixtures.connect_provider(context.scope, "zai")
        {:ok, context}
      end

      when_ "he disconnects it", context do
        conn = delete(context.conn, ~p"/auth/zai")
        {:ok, Map.put(context, :conn, recycle(conn))}
      end

      then_ "every agent type says it has nothing to run on", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/accounts/#{context.account.id}/agents")

        for role <- ~w(main product coding qa) do
          rendered = view |> element("[data-test='agent-type-#{role}']") |> render()

          assert rendered =~ "Nothing to run on",
                 "#{role} named a model with no provider connected to run it"
        end

        {:ok, context}
      end
    end
  end
end
