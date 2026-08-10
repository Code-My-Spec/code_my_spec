defmodule CodeMySpecSpex.Story994.Criterion8264Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8264 — A forgotten box from a dead project is still on the screen.

  The case the feature is really for. Nobody loses track of the server they
  deployed this morning; they lose track of the one from the project they
  stopped working on in March, which has been quietly charging them since.

  So the screen cannot require Sam to have remembered a box in order to show
  it to him. It lists what the provider reports, and a machine attached to
  nothing is exactly the machine that most needs saying out loud.

  Surface: `CodeMySpecWeb.ServerLive.Index` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A forgotten box from a dead project is still on the screen" do
    scenario "a server linked to nothing is listed with what it is costing" do
      given_ "a server left running from a project Sam abandoned months ago", context do
        # Linked to nothing, named after something he no longer thinks about.
        {:ok,
         stage_servers(context, [
           provider_server(%{
             name: "old-side-project",
             ip: "203.0.113.77",
             size: "cpx31",
             status: "running"
           })
         ])}
      end

      when_ "he opens the servers screen", context do
        {:ok, view, html} = live(context.conn, "/app/servers")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "it appears among the unlinked servers with its size and running state", context do
        # Nothing is linked in this scenario, so there is nothing to
        # de-emphasise the box against and the screen shows it outright. Read
        # straight off that render: expanding first would have described a
        # screen Sam never saw, and clicking the toggle would have collapsed
        # the very thing this is looking for.
        row =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server'][data-name='old-side-project']")

        assert row != [],
               "a running server attached to nothing was not on the screen at all"

        assert Floki.attribute(row, "data-linked") == ["false"]
        assert Floki.attribute(row, "data-size") == ["cpx31"]
        assert Floki.attribute(row, "data-status") == ["running"]

        {:ok, context}
      end

      then_ "and nothing required him to have remembered it existed", context do
        # He never linked it, never named it, and did not search for it. It is
        # on the screen because the provider says it exists, which is the only
        # thing that can be relied on months later.
        assert context.html =~ "old-side-project"

        {:ok, context}
      end
    end
  end
end
