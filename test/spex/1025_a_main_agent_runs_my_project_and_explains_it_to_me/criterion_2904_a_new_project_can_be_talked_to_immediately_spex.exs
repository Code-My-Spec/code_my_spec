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
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent is there without anybody starting it" do
    scenario "A new project can be talked to immediately" do
      given_ "a project I have just created", context do
        {:ok, context}
      end

      when_ "I open it", context do
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
