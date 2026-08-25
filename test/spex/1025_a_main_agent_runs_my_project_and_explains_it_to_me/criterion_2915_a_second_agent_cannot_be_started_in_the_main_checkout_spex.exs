defmodule CodeMySpecSpex.Story963.Criterion2915Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2915 — A second agent cannot be started in the main checkout.

  Rule: No agent other than the main agent runs in the main working copy.

  The PM was explicit: "we don't wanna have multiple agents in the main
  checkout — there should only be one conversation and one agent."

  Nothing stops it today. `just agent` will start one there, `Engine.start/1`
  has no notion of a protected copy, and two agents in one checkout means two
  processes editing one tree — which is the failure the whole working-copy
  grain exists to prevent.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "No agent other than the main agent runs in the main working copy" do
    scenario "A second agent cannot be started in the main checkout" do
      given_ "a project whose main agent is running in its main working copy", context do
        copy = CodeMySpec.TempFile.dir("spex_2915")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{joined.working_copy_id}"
          )

        live |> element("[data-test=designate-main-copy]") |> render_click()

        {:ok, _live, before} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, context |> Map.put(:copy, copy) |> Map.put(:before, before)}
      end

      when_ "something tries to start another agent in that same copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, reply, _frame} =
          StartAgent.execute(
            %{"provider" => "openai-codex", "working_copy" => context.copy},
            frame
          )

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is refused", context do
        assert context.reply.isError,
               "a second agent was started in the main working copy. Two agents in one " <>
                 "checkout are two processes editing one tree, and the user now has two " <>
                 "conversations where the design says one."

        {:ok, context}
      end

      then_ "and the main agent and its conversation are untouched", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        assert html =~ "data-test=\"main-agent\"",
               "the refused start took the main agent with it"

        {:ok, context}
      end
    end
  end
end
