defmodule CodeMySpecSpex.Story1055.Criterion3283Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3283 — Two agents' turns line up on one timeline.

  Reading two agents together merges their turns into one chronological
  sequence rather than answering one agent's transcript and then the other's.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Two agents' turns line up on one timeline" do
    scenario "Two agents' turns line up on one timeline" do
      given_ "two agents were working over the same period", context do
        first = Fixtures.running_agent(context.scope, role: "coding")
        second = Fixtures.running_agent(context.scope, role: "coding")

        :ok = Fixtures.agent_said(context.scope, first, "Started the refund fix")
        :ok = Fixtures.age_agent_messages(context.scope, first, 100)

        :ok = Fixtures.agent_said(context.scope, second, "Started the unrelated cleanup")
        :ok = Fixtures.age_agent_messages(context.scope, second, 50)

        :ok = Fixtures.agent_said(context.scope, first, "Shipped the refund fix")

        {:ok, context |> Map.put(:first, first) |> Map.put(:second, second)}
      end

      when_ "the main agent reads their turns together", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadAgentConversation.execute(
            %{"agent_ids" => [context.first.id, context.second.id]},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the turns appear in time order across both agents", context do
        refute context.response.isError,
               "expected a combined timeline, got: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ "Started the refund fix"
        assert body =~ "Started the unrelated cleanup"
        assert body =~ "Shipped the refund fix"

        {started_at, _} = :binary.match(body, "Started the refund fix")
        {cleanup_at, _} = :binary.match(body, "Started the unrelated cleanup")
        {shipped_at, _} = :binary.match(body, "Shipped the refund fix")

        assert started_at < cleanup_at,
               "expected the older turn from the first agent before the second agent's, got: #{body}"

        assert cleanup_at < shipped_at,
               "expected the second agent's turn before the first agent's later one, got: #{body}"

        {:ok, context}
      end

      then_ "it can see what each was doing when the other did something", context do
        body = response_text(context.response)

        assert body =~ to_string(context.first.id)
        assert body =~ to_string(context.second.id)

        {:ok, context}
      end
    end
  end
end
