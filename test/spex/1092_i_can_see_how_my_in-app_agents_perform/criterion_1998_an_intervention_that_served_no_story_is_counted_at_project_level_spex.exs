defmodule CodeMySpecSpex.Story1092.Criterion1998Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 1998 -- An intervention that served no story is counted at
  project level.

  Rule: Every manual intervention (operator or user nudge, approval,
  restart) is counted against the story it served.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers
  import Phoenix.ChannelTest

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Restarting the app while no team holds a story is a project-level intervention",
    criterion: 1998 do
    scenario "no team is holding a story" do
      given_ "a checkout with no team holding a story", context do
        {reply, socket} =
          join_working_copy_socket(context, "/tmp/spex-1998", "the checkout")

        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}
        {:ok, context |> Map.put(:scope, scope) |> Map.put(:socket, socket)}
      end

      when_ "I restart the application", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        task =
          Task.async(fn ->
            ToolLibrary.run(
              "restart_app",
              %{},
              Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
            )
          end)

        assert_push "restart_app", %{"ref" => ref}, 5_000

        reply_ref =
          Phoenix.ChannelTest.push(context.socket, "restart_app_result", %{
            "ref" => ref,
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => "http://127.0.0.1:4000",
            "app_commit" => "cafef00d"
          })

        receive do
          %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
        after
          1_000 -> flunk("restart_app_result was never acknowledged")
        end

        _response = Task.await(task)
        {:ok, context}
      end

      then_ "the restart is counted as a project-level intervention", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = render_async(index)

        assert html =~ "project" and html =~ "restart",
               "the restart made while no team held a story is not shown as a project-level intervention"

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and it is not attributed to any story", context do
        refute context.html =~ "data-test='intervention'][data-story-id=",
               "the restart is attributed to a story, but no team was holding one"

        {:ok, context}
      end
    end
  end
end
