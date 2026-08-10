defmodule CodeMySpecSpex.Story700.Criterion6051Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6051 — Rule: The dashboard presents its onboarding steps
  in a fixed order: account, then project.

  Someone who registers without going through the guided intake still
  needs an account and a project, and this page is where they make
  them. That is all it can walk them through: the ladder once carried
  a plugin rung and an application rung, and both were removed because
  neither could be cleared from here. A plugin installed on another
  machine, or a local app signed into somewhere this server cannot
  see, left a working setup reading as unfinished.

  Surface contract assumed:
    * [data-test="account-rung"], [data-test="project-rung"]
    * Each rung's eyebrow contains "// step 0N · <name>" matching its
      position (01 · account, 02 · project)
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "The onboarding steps render on /app in the fixed order" do
    scenario "Newly registered user sees the steps in order on /app" do
      given_ "the user has just registered with no account, no project, no CLI history",
             context do
        {:ok, view, html} = live(context.conn, "/app")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "both step rungs are present", context do
        for rung <- ~w(account-rung project-rung) do
          assert has_element?(context.view, "[data-test='#{rung}']"),
                 "expected [data-test='#{rung}'] to be present on /app"
        end

        {:ok, context}
      end

      then_ "the steps appear in document order", context do
        order =
          ~w(account-rung project-rung)
          |> Enum.map(fn rung ->
            {rung, :binary.match(context.html, ~s|data-test="#{rung}"|)}
          end)

        positions = Enum.map(order, fn {_, m} -> m end)

        refute :nomatch in positions,
               "all four rungs must appear in the initial render; got: #{inspect(order)}"

        sorted = Enum.sort_by(order, fn {_, {at, _}} -> at end)

        assert Enum.map(sorted, fn {rung, _} -> rung end) ==
                 ~w(account-rung project-rung),
               "expected document order account → project → plugin → application; got: #{inspect(sorted)}"

        {:ok, context}
      end

      then_ "each rung's eyebrow declares its step number and name", context do
        # Post-redesign eyebrow format: "Step N · Name" (daisyUI badge), no
        # zero padding, no "//" prefix.
        eyebrows = %{
          "account-rung" => {1, "Account"},
          "project-rung" => {2, "Project"}
        }

        for {rung, {n, name}} <- eyebrows do
          rendered = element(context.view, "[data-test='#{rung}']") |> render()

          assert rendered =~ "Step #{n}",
                 "expected #{rung} eyebrow to contain 'Step #{n}'; got: #{rendered}"

          assert rendered =~ name,
                 "expected #{rung} eyebrow to contain '#{name}'; got: #{rendered}"
        end

        {:ok, context}
      end
    end
  end
end
