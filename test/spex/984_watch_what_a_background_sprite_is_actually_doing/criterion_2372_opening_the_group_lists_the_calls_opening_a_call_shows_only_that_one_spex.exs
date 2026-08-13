defmodule CodeMySpecSpex.Story984.Criterion2372Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2372 — Opening the group lists the calls; opening a call shows only
  that one.

  Two levels, and the second is the point. Opening a group to be handed five
  tools' arguments at once is the wall again with an extra click in front of it.
  What the reader wants is the list, then the one call they care about.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The group opens to a list, and each call opens alone" do
    scenario "Opening the group lists the calls; opening a call shows only that one" do
      when_ "the agent takes a turn that calls three tools", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("look around"),
          Fixtures.model_response([
            Fixtures.tool_block("Read", %{"file_path" => "mix.exs"}),
            Fixtures.tool_block("Grep", %{"pattern" => "defmodule Foo"}),
            Fixtures.tool_block("Bash", %{"command" => "mix compile --warnings-as-errors"})
          ])
        )

        {:ok, context}
      end

      then_ "every call in the group is listed by the tool it used", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        for tool <- ~w(Read Grep Bash) do
          assert has_element?(view, "[data-test='tool-call-group'] [data-tool='#{tool}']"),
                 "the list is what the group opens to, so every call belongs in it"
        end

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "no call's arguments are shown with the list", context do
        refute has_element?(
                 context.view,
                 "[data-test='tool-call-group'] [data-test='tool-call'] details[open]"
               ),
               "handing over three tools' arguments at once is the wall with a click in front"

        {:ok, context}
      end

      then_ "each call carries its own disclosure rather than one for the group", context do
        assert context.html =~ "mix compile --warnings-as-errors",
               "a call's arguments stay reachable"

        {:ok, context}
      end
    end
  end
end
