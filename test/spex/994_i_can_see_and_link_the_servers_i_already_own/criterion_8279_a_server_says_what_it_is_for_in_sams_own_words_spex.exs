defmodule CodeMySpecSpex.Story994.Criterion8279Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8279 — A server says what it is for, in Sam's own words.

  Two boxes running the same image are told apart only by what he does to
  them: Resend belongs on the one carrying real mail and not on the one he
  breaks before lunch. Nothing the provider reports can make that distinction
  — name, size and address are all equally true of both — so the label has to
  be his answer, recorded against the server.

  The label is a **string, not an enum**. `prod` is a value here and never a
  branch. `provisioning_environments` exists because `["prod", "uat"]` had
  been a literal repeated through seven places in `Steps`, and a fixed set on
  this record would put it straight back — while still having nowhere to keep
  `qa-story-812`.

  So the dropdown is seeded with what setup builds today and extended by what
  the account already uses, and **Other…** keeps that list from being the whole
  world. Unlabelled stays representable, because "nobody has said what this is
  for" is the true answer for the box left running since March.

  Surface: `CodeMySpecWeb.ServerLive.Index` at `/app/servers`, editing through
  `CodeMySpecWeb.ServerLive.FormComponent` at `/app/servers/:name/edit`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A server says what it is for, in Sam's own words" do
    scenario "two identical boxes are told apart by what he calls them" do
      given_ "two servers the provider reports identically", context do
        # Same size, same status, same everything the provider knows. If the
        # screen can tell these apart afterwards, it is because Sam said so.
        context =
          stage_servers(context, [
            provider_server(%{name: "box-a", size: "cpx11", status: "running"}),
            provider_server(%{name: "box-b", size: "cpx11", status: "running"})
          ])

        {:ok, view, _html} = live(context.conn, ~p"/app/servers")

        for name <- ["box-a", "box-b"] do
          view
          |> element("[data-test='link-server'][phx-value-name='#{name}']")
          |> render_click()
        end

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he says what each one is for", context do
        set_environment(context.view, "box-a", "prod")
        set_environment(context.view, "box-b", "uat")

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "each server carries the label he gave it", context do
        document = Floki.parse_document!(context.html)

        assert document
               |> Floki.find("[data-test='server'][data-name='box-a']")
               |> Floki.attribute("data-environment") == ["prod"]

        assert document
               |> Floki.find("[data-test='server'][data-name='box-b']")
               |> Floki.attribute("data-environment") == ["uat"],
               "two boxes the provider describes identically are still indistinguishable"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "and it is visible on the row, not only in an attribute", context do
        labels =
          context.document
          |> Floki.find("[data-test='server-environment']")
          |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

        assert "prod" in labels and "uat" in labels,
               "the label is recorded but never shown, so it answers nothing on the screen"

        {:ok, context}
      end

      then_ "and the form closed once it was saved", context do
        refute context.html =~ "data-test=\"server-form\"",
               "the edit form is still open after saving, so he cannot tell it worked"

        {:ok, context}
      end
    end

    scenario "a label the platform has never heard of is accepted" do
      given_ "a linked server and a purpose that is not prod or uat", context do
        context = stage_servers(context, [provider_server(%{name: "story-box"})])

        {:ok, view, html} = live(context.conn, ~p"/app/servers")

        link_server(view, html, "story-box")
        open_edit(view, "story-box")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he picks Other and types one of his own", context do
        # The point of the whole design. John's rule is that uat and prod are
        # not special — "there could be qa or even per story qa" — so anything
        # that refused this would have smuggled the enum back in. The dropdown
        # makes the common answers one click; "Other…" is what stops the list
        # of them from being the whole world.
        html =
          context.view
          |> form("[data-test='server-form']", server: %{environment: "__other__"})
          |> render_change()

        assert html =~ "data-test=\"environment-custom\"",
               "choosing Other did not offer anywhere to type"

        context.view
        |> form("[data-test='server-form']", server: %{custom: "qa-story-812"})
        |> render_submit()

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "it is kept exactly as he wrote it", context do
        assert context.html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='server'][data-name='story-box']")
               |> Floki.attribute("data-environment") == ["qa-story-812"],
               "a per-story environment was rejected or coerced, which is the enum " <>
                 "this field exists to avoid"

        {:ok, context}
      end

      then_ "and choosing Other never becomes the answer itself", context do
        refute context.html =~ "__other__",
               "the select's own sentinel reached the page as if it were a real label"

        {:ok, context}
      end

      then_ "and the dropdown still offers what setup supports today", context do
        html = open_edit(context.view, "story-box")

        offered =
          html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='environment-select'] option")
          |> Floki.attribute("value")

        assert "prod" in offered and "uat" in offered,
               "the common answers should be one click, not something to spell"

        assert "qa-story-812" in offered,
               "a label already in use on the account is not offered for the next box"

        {:ok, context}
      end
    end

    scenario "a box nobody has claimed says so rather than guessing" do
      given_ "a linked server Sam has never labelled", context do
        context = stage_servers(context, [provider_server(%{name: "unclaimed"})])

        {:ok, view, html} = live(context.conn, ~p"/app/servers")

        link_server(view, html, "unclaimed")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he looks at the screen", context do
        {:ok, _view, html} = live(context.conn, ~p"/app/servers")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "no purpose is invented for it", context do
        document = Floki.parse_document!(context.html)
        row = Floki.find(document, "[data-test='server'][data-name='unclaimed']")

        assert row != []

        assert Floki.find(row, "[data-test='server-environment']") == [],
               "an unlabelled box was given a purpose nobody assigned to it"

        # Unlabelled is a real state, not an empty string pretending to be one.
        assert Floki.attribute(row, "data-environment") in [[], [""]]

        {:ok, context}
      end
    end
  end

  defp open_edit(view, name) do
    view
    |> element("[data-test='server'][data-name='#{name}'] [data-test='edit-server']")
    |> render_click()
  end

  # Open the form, choose, save. Three steps because it is a form now, and the
  # save is the point at which he has decided rather than merely looked.
  defp set_environment(view, name, environment) do
    open_edit(view, name)

    view
    |> form("[data-test='server-form']", server: %{environment: environment})
    |> render_submit()
  end

  # Later scenarios inherit the links earlier ones made, so something is
  # already linked and the unlinked rows sit behind the collapse — which is
  # criterion 8263 working, not something to route around silently.
  defp link_server(view, html, name) do
    unless html =~ "phx-value-name=\"#{name}\"" do
      view |> element("[data-test='unlinked-count']") |> render_click()
    end

    view
    |> element("[data-test='link-server'][phx-value-name='#{name}']")
    |> render_click()
  end
end
