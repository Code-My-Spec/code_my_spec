defmodule CodeMySpecSpex.Story963.Criterion2904Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2904 — A new project can be talked to immediately.

  Rule: The main agent is there without anybody starting it.

  What "always on" has to mean for somebody who does not know what starting an
  agent would involve. Today an agent exists because `start_agent` was called
  with a provider, on a working copy that already exists on disk — three things
  a non-technical user has no way to supply.

  The PM's decision was that the main agent is there whenever its harness is.
  This criterion is the user-visible half of that: nothing to start.

  Not "no checkout needed" — the agent runs in one, and a project without one
  is criterion 2906's subject, which requires the opposite of this. The two
  read as contradictory until you notice they are about different
  preconditions: an agent you must start, and a checkout you must have.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

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

  spex "The main agent is there without anybody starting it" do
    scenario "A new project can be talked to immediately" do
      given_ "a project I have just created", context do
        # With a checkout, because "without starting anything" is about not
        # having to start an *agent*. A project with nowhere to run one is
        # criterion 2906's subject, and it demands the opposite of this.
        copy = CodeMySpec.TempFile.dir("spex_2904")
        RealDisk.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the checkout I just made")

        designate_main_copy(context, joined.working_copy_id)

        {:ok, context}
      end

      when_ "I open it", context do
        # No click at all now, where there used to be one. Opening the project
        # *is* opening its agent: the cockpit is the project's page and the
        # conversation it resolves is the project's own. The claim was only
        # ever that nothing had to be started first, and it holds a step
        # earlier than it used to.
        {:ok, live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "I can say something to the main agent without starting anything first",
            context do
        assert context.html =~ "phx-submit=\"send_message\"",
               "a project I just made offers nothing to say something to. Starting an " <>
                 "agent means naming a provider and a checkout that exists, which is " <>
                 "exactly what a non-technical user cannot be asked for."

        {:ok, context}
      end
    end
  end
end
