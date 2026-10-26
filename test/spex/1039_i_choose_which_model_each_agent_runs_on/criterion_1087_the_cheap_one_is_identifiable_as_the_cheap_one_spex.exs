defmodule CodeMySpecSpex.Story1039.Criterion3012Spex do
  @moduledoc """
  The compact model form preserves role-specific defaults in editable fields.
  Pricing prose under each field was removed by the onboarding redesign.
  """
  use CodeMySpecSpex.Case
  @endpoint CodeMySpecWeb.Endpoint
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The compact form exposes the cheaper QA default", criterion: 1087 do
    scenario "Codex models are balanced by role" do
      given_ "Codex is connected", context do
        Fixtures.connect_provider(context.scope, :openai)
        {:ok, context}
      end

      when_ "the user opens model settings", context do
        {:ok, view, _} = live(context.conn, "/app/agent-models")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "QA uses Luna and coding uses Sol in editable model fields", context do
        assert has_element?(context.view, "input[name='qa[model]'][value='gpt-6-luna']")
        assert has_element?(context.view, "input[name='coding[model]'][value='gpt-6-sol']")
        refute has_element?(context.view, "[data-test='model-cost']")
        {:ok, context}
      end
    end
  end
end
