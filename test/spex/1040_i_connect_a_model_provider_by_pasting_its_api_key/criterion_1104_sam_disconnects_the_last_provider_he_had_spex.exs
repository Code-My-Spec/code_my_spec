defmodule CodeMySpecSpex.Story1040.Criterion3029Spex do
  @moduledoc "Disconnecting the last API credential preserves the local Claude Code option."

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account

  spex "I connect a model provider by pasting its API key", criterion: 1104 do
    scenario "Sam disconnects the last API provider he had" do
      given_ "Z.ai is the only provider he has connected", context do
        Fixtures.connect_provider(context.scope, "zai")
        {:ok, context}
      end

      when_ "he disconnects it", context do
        conn = delete(context.conn, ~p"/auth/zai")
        {:ok, Map.put(context, :conn, recycle(conn))}
      end

      then_ "agent types fall back to the independently authenticated local CLI", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/agent-models")

        for role <- ~w(main product coding qa) do
          rendered = view |> element("[data-test='agent-type-#{role}']") |> render()

          assert rendered =~ "claude-code"
          assert has_element?(view, "[data-test='agent-type-#{role}'] input[value^='claude-']")
        end

        {:ok, context}
      end
    end
  end
end
