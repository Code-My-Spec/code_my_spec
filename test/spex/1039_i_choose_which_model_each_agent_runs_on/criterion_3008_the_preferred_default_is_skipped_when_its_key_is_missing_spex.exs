defmodule CodeMySpecSpex.Story1039.Criterion3008Spex do
  @moduledoc """
  Story 1039 — I choose which model each agent runs on
  Criterion 3008 — The preferred default is skipped when its key is missing

  The default is a preference across providers rather than one value, so the
  same unset type resolves differently depending on what the account holds.

  Asserted by connecting each provider in turn rather than by naming which one
  QA prefers: a spec that hardcoded the order would have to be edited every
  time the order changed, and would pass for the wrong reason if the resolution
  were hardcoded to one provider.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I choose which model each agent runs on" do
    scenario "The preferred default is skipped when its key is missing" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "the QA type is unset", context do
        # given: already true — nothing has been configured, which is the case
        # the defaults exist for.
        {:ok, context}
      end

      when_ "an account holding only one provider starts QA", context do
        Fixtures.connect_provider(context.scope, "zai")
        {:reply, first, _} = StartAgent.execute(%{role: "qa"}, context.frame)

        {:ok, Map.put(context, :first, first)}
      end

      then_ "it runs on that one", context do
        refute context.first.isError
        assert response_text(context.first) =~ "zai"
        {:ok, context}
      end

      then_ "and an account holding a different one runs on that instead", context do
        other = Fixtures.full_scope_fixture()
        Fixtures.connect_provider(other, "anthropic")

        {:reply, second, _} =
          StartAgent.execute(%{role: "qa"}, %Frame{assigns: %{current_scope: other}})

        refute second.isError
        assert response_text(second) =~ "anthropic",
               "the default resolved to the same provider regardless of what was " <>
                 "connected, so it is a fixed value rather than a preference"

        {:ok, context}
      end
    end
  end
end
