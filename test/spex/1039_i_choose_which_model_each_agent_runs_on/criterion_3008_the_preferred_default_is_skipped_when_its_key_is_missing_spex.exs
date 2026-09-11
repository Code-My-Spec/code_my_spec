defmodule CodeMySpecSpex.Story1039.Criterion3008Spex do
  @moduledoc """
  Story 1039 — I choose which model each agent runs on
  Criterion 3008 — The preferred default is skipped when its key is missing

  The default is a preference across providers rather than one value, so the
  same unset type resolves differently depending on what the account holds.

  Asserted by swapping which provider is connected rather than by naming which
  one QA prefers: a spec that hardcoded the order would have to be edited every
  time the order changed, and would pass for the wrong reason if resolution
  were fixed to one provider.

  One scope throughout. The first version used a second account, and it failed
  on setup rather than on the claim — a bare scope fixture has no working copy,
  so the agent was refused by validation before resolution was reached.
  """

  use CodeMySpecSpex.Case

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

      then_ "and holding a different one instead runs on that", context do
        Fixtures.disconnect_provider(context.scope, :zai)
        Fixtures.connect_provider(context.scope, "anthropic")

        {:reply, second, _} = StartAgent.execute(%{role: "qa"}, context.frame)

        refute second.isError, response_text(second)

        assert response_text(second) =~ "anthropic",
               "the default resolved to the same provider regardless of what was " <>
                 "connected, so it is a fixed value rather than a preference"

        {:ok, context}
      end
    end
  end
end
