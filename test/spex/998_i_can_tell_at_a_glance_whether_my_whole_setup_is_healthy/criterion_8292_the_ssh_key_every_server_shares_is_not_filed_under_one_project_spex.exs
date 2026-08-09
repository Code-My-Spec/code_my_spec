defmodule CodeMySpecSpex.Story998.Criterion8292Spex do
  @moduledoc """
  Story 998 — I can tell at a glance whether my whole setup is healthy
  Criterion 8292 — The SSH key every server shares is not filed under one project.

  An SSH key, a firewall and a bucket are objects in a **provider account**.
  One key opens every box; one firewall fronts all of them. Setup records them
  against whichever project ran first, because that is where the step ran, and
  from then on a shared object wears a single owner's name.

  That is not a filing preference. Delete the project that happened to be
  first and the key stops being visible, while continuing to open every server
  in the account. Story 994 fixed the same shape for credentials — the record
  was right and simply not addressable at the grain being asked.

  Surface: `CodeMySpecWeb.ResourceLive.Index` at `/app/resources`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "The SSH key every server shares is not filed under one project" do
    scenario "one provider-account object, listed once, owned by the account" do
      given_ "one SSH key at the provider, made while setting up the first project",
             context do
        context =
          stage_inventory(context, %{
            hetzner: [
              inventory_resource(%{
                kind: "ssh_key",
                location: "hetzner/codemyspec",
                identifier: "f8:19:90:7d"
              }),
              inventory_resource(%{kind: "server", location: "hetzner/first-uat"}),
              inventory_resource(%{kind: "server", location: "hetzner/second-uat"})
            ]
          })

        {:ok, context}
      end

      when_ "he opens the resources page", context do
        {:ok, view, _html} = live(context.conn, "/app/resources")

        {:ok, Map.put(context, :html, render_async(view))}
      end

      then_ "the SSH key is listed once", context do
        keys =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='resource'][data-kind='ssh_key']")

        assert length(keys) == 1,
               "one key at the provider produced #{length(keys)} rows — it is being " <>
                 "listed per project rather than once for the account"

        {:ok, context |> Map.put(:keys, keys)}
      end

      then_ "it is owned by the account, not by a project", context do
        assert Floki.attribute(context.keys, "data-owner") == ["account"],
               "a key every server shares is filed under a project, so deleting that " <>
                 "project would take it off the screen while it kept opening every box"

        assert Floki.attribute(context.keys, "data-project-id") in [[], [""]],
               "the key was attributed to a project it does not belong to"

        {:ok, context}
      end
    end
  end
end
