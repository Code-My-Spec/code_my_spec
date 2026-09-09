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

  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # The agent runs on a provider, and refusing without one is deliberate — an
  # agent started on a credential that does not resolve fails on its first
  # model call, minutes later, in a log nobody reads.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "No agent other than the main agent runs in the main working copy" do
    scenario "A second agent cannot be started in the main checkout" do
      given_ "a project whose main agent is running in its main working copy", context do
        copy = CodeMySpec.TempFile.dir("spex_2915")
        RealDisk.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        designate_main_copy(context, joined.working_copy_id)

        {:ok, _live, before} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok,
         context
         |> Map.put(:copy, copy)
         |> Map.put(:copy_id, joined.working_copy_id)
         |> Map.put(:before, before)}
      end

      # Both spellings, because a caller who does not name the checkout still
      # lands in one. That is the ordinary call — the MCP tool drops nil keys,
      # so nothing about a plain `start_agent` mentions a destination — and it
      # used to be allowed while the named call was refused. Asserting only the
      # named one is asserting the half that already worked.
      when_ "something tries to start another agent in that same copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, named, _frame} =
          StartAgent.execute(
            %{"provider" => "openai-codex", "working_copy" => context.copy},
            frame
          )

        # A harness on the main checkout asks from that checkout, so its scope
        # already points there and it has no reason to say so again.
        from_the_copy = %Frame{
          assigns: %{
            current_scope: %{
              context.scope
              | cwd: context.copy,
                active_working_copy_id: context.copy_id
            }
          }
        }

        {:reply, unnamed, _frame} =
          StartAgent.execute(%{"provider" => "openai-codex"}, from_the_copy)

        {:ok, context |> Map.put(:reply, named) |> Map.put(:unnamed, unnamed)}
      end

      then_ "it is refused", context do
        assert context.reply.isError,
               "a second agent was started in the main working copy. Two agents in one " <>
                 "checkout are two processes editing one tree, and the user now has two " <>
                 "conversations where the design says one."

        {:ok, context}
      end

      then_ "and so is one that lands there without saying so", context do
        assert context.unnamed.isError,
               "naming the main checkout was refused and landing in it silently was not, " <>
                 "so the rule held only against callers who volunteered where they were " <>
                 "going. Every ordinary start omits it."

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
