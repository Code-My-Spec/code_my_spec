defmodule CodeMySpecSpex.Story538.Criterion3109Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 3109 — Continuous intent can change without changing the durable roster.

  Both supported controls address existing coding and QA agents. Only QA has
  eligible work. Enabling admits one QA turn; disabling preserves that in-flight
  turn and both agents instead of treating intent as process lifecycle.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The user changes intent without changing the roster", criterion: 1168 do
    scenario "Only eligible QA starts a turn, and disabling does not interrupt it" do
      given_ "both engines exist with continuous off and only QA has eligible work", context do
        context = given_a_staffed_checkout(context, "spex_3109_0")
        context = FullSatisfactionFixtures.apply_without_qa_story(context)

        graph =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, graph), response_text(graph)

        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        qa = Fixtures.running_agent(context.scope, role: "qa", continuous: false)
        assert Fixtures.role_queue_size(context.scope, coding.id) == 0
        assert Fixtures.role_queue_size(context.scope, qa.id) > 0

        base_url = HeldProvider.start()
        HeldProvider.hold()

        for id <- [coding.id, qa.id] do
          assert {:ok, _} = Machine.start_agent(id, context.copy, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(id) end)
          assert {:ok, %{busy?: false}} = Machine.status(id)
        end

        {:ok, coding_view, _} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, coding))

        {:ok, qa_view, _} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, qa))

        for view <- [coding_view, qa_view] do
          assert has_element?(view, "[data-test='toggle-agent-working'][data-working='false']")
        end

        {:ok,
         Map.merge(context, %{
           coding_id: coding.id,
           qa_id: qa.id,
           coding_view: coding_view,
           qa_view: qa_view,
           running_before: Enum.sort(Machine.running())
         })}
      end

      when_ "the user enables continuous for both agents", context do
        for view <- [context.coding_view, context.qa_view] do
          view |> element("[data-test='toggle-agent-working']") |> render_click()
        end

        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "QA alone takes one turn and both continuous controls show enabled", context do
        assert {:ok, %{busy?: true}} = Machine.status(context.qa_id)
        assert {:ok, %{busy?: false}} = Machine.status(context.coding_id)
        assert length(HeldProvider.seen()) == 1
        assert Enum.sort(Machine.running()) == context.running_before

        for view <- [context.coding_view, context.qa_view] do
          assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        end

        {:ok, context}
      end

      when_ "the user disables continuous while QA is still in its turn", context do
        for view <- [context.coding_view, context.qa_view] do
          view |> element("[data-test='toggle-agent-working']") |> render_click()
        end

        {:ok, context}
      end

      then_ "only intent changes; QA is not interrupted and neither agent disappears", context do
        for view <- [context.coding_view, context.qa_view] do
          assert has_element?(view, "[data-test='toggle-agent-working'][data-working='false']")
        end

        assert Enum.sort(Machine.running()) == context.running_before
        assert {:ok, %{busy?: true}} = Machine.status(context.qa_id)
        assert {:ok, %{busy?: false}} = Machine.status(context.coding_id)
        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end
    end
  end

  spex "The main agent changes intent without changing the roster" do
    scenario "Only eligible QA starts a turn, and disabling does not interrupt it" do
      given_ "both engines exist with continuous off and only QA has eligible work", context do
        context = given_a_staffed_checkout(context, "spex_3109_1")
        context = FullSatisfactionFixtures.apply_without_qa_story(context)

        graph =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, graph), response_text(graph)

        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        qa = Fixtures.running_agent(context.scope, role: "qa", continuous: false)
        assert Fixtures.role_queue_size(context.scope, coding.id) == 0
        assert Fixtures.role_queue_size(context.scope, qa.id) > 0

        base_url = HeldProvider.start()
        HeldProvider.hold()

        for id <- [coding.id, qa.id] do
          assert {:ok, _} = Machine.start_agent(id, context.copy, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(id) end)
          assert {:ok, %{busy?: false}} = Machine.status(id)
        end

        {:ok, coding_view, _} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, coding))

        {:ok, qa_view, _} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, qa))

        for view <- [coding_view, qa_view] do
          assert has_element?(view, "[data-test='toggle-agent-working'][data-working='false']")
        end

        {:ok,
         Map.merge(context, %{
           coding_id: coding.id,
           qa_id: qa.id,
           coding_view: coding_view,
           qa_view: qa_view,
           running_before: Enum.sort(Machine.running())
         })}
      end

      when_ "the main agent enables continuous for both agents", context do
        for id <- [context.coding_id, context.qa_id] do
          {:reply, response, _} =
            SetAgentContinuous.execute(%{agent_id: id, continuous: true}, frame(context))

          refute response.isError, response_text(response)
        end

        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "QA alone takes one turn and both continuous controls show enabled", context do
        assert {:ok, %{busy?: true}} = Machine.status(context.qa_id)
        assert {:ok, %{busy?: false}} = Machine.status(context.coding_id)
        assert length(HeldProvider.seen()) == 1
        assert Enum.sort(Machine.running()) == context.running_before

        for id <- [context.coding_id, context.qa_id] do
          {:ok, view, _} =
            live(context.conn, Fixtures.agent_conversation_path(context.scope, %{id: id}))

          assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        end

        {:ok, context}
      end

      when_ "the main agent disables continuous while QA is still in its turn", context do
        for id <- [context.coding_id, context.qa_id] do
          {:reply, response, _} =
            SetAgentContinuous.execute(%{agent_id: id, continuous: false}, frame(context))

          refute response.isError, response_text(response)
        end

        {:ok, context}
      end

      then_ "only intent changes; QA is not interrupted and neither agent disappears", context do
        for id <- [context.coding_id, context.qa_id] do
          {:ok, view, _} =
            live(context.conn, Fixtures.agent_conversation_path(context.scope, %{id: id}))

          assert has_element?(view, "[data-test='toggle-agent-working'][data-working='false']")
        end

        assert Enum.sort(Machine.running()) == context.running_before
        assert {:ok, %{busy?: true}} = Machine.status(context.qa_id)
        assert {:ok, %{busy?: false}} = Machine.status(context.coding_id)
        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end
    end
  end
end
