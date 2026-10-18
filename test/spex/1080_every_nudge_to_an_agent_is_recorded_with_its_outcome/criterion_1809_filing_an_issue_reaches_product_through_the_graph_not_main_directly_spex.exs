defmodule CodeMySpecSpex.Story1080.Criterion1809Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1809 — Filing an issue reaches product through the graph, not main
  directly.

  John (2026-10-02): the widget's "an issue was filed" message to main is gone.
  Main and product sit on the main copy; a new issue is triage work, and the
  graph offers triage to product.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A filed issue is triage work for product, not a message to main", criterion: 1809 do
    scenario "an end user files an issue through the app's widget" do
      given_ "a shipped project, with main and product on its main copy", context do
        context = FullSatisfactionFixtures.apply(context)

        {:ok, _} =
          CodeMySpec.WorkingCopies.designate_main(
            context.scope,
            context.scope.active_working_copy_id
          )

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        product = Fixtures.running_agent(context.scope, role: "product", continuous: false)
        key = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
        Fixtures.set_project_deploy_key(context.scope, context.scope.active_project, key)

        {:ok, Map.merge(context, %{main: main, product: product, deploy_key: key})}
      end

      when_ "an end user files an issue through the widget", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{context.deploy_key}")
        |> post(~p"/api/widget/issues", %{
          "issue" => %{
            "title" => "the export button does nothing",
            "description" => "twice",
            "severity" => "medium"
          }
        })
        |> Phoenix.ConnTest.json_response(201)

        {:ok, context}
      end

      then_ "main is sent nothing about it", context do
        main_id = context.main.id
        refute_receive {:agent_message, ^main_id, _text}, 1_000
        {:ok, context}
      end

      then_ "and product is offered its triage, not main", context do
        text = Slice.next(context, %{agent_id: context.product.id})
        assert text =~ "requirement_name=`issues_triaged`", text
        {:ok, context}
      end
    end
  end
end
