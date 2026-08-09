defmodule CodeMySpecSpex.Story994.Criterion8261Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8261 — A second project sees the server the first one linked.

  The grain decision, made checkable. Servers belong to the account, not to a
  project — which is what lets one box host several projects, and what makes
  "show me my servers" a coherent request rather than "show me this project's
  servers, and separately those, and hope you remember the rest".

  Today the opposite is true: a server is `server_name` and `ip` on a
  project-scoped environment row, so the same machine linked from two projects
  would be two records that know nothing about each other.

  Surface: `CodeMySpecWeb.ServerLive.Index` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A second project sees the server the first one linked" do
    scenario "one link is enough for the whole account" do
      given_ "Sam linked a server while working on one project", context do
        context = stage_servers(context, [provider_server(%{name: "shared-box"})])

        {:ok, view, _html} = live(context.conn, "/app/servers")

        view
        |> element("[data-test='link-server'][phx-value-name='shared-box']")
        |> render_click()

        {:ok, context}
      end

      given_ "and he also owns a second project in the same account", context do
        {:ok, form, _html} = live(context.conn, "/app/projects/new")

        form
        |> form("[data-test='project-form']", project: %{name: "second-project-994"})
        |> render_submit()

        {:ok, context}
      end

      when_ "he opens the servers screen from that other project", context do
        {:ok, _view, html} = live(context.conn, "/app/servers")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the same server is listed, still linked", context do
        row =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server'][data-name='shared-box']")

        assert row != [], "the server linked from another project is not visible here"

        assert Floki.attribute(row, "data-linked") == ["true"],
               "he would have had to link the same machine twice"

        {:ok, context}
      end
    end
  end
end
