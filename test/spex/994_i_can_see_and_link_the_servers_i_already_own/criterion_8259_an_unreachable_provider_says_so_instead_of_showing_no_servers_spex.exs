defmodule CodeMySpecSpex.Story994.Criterion8259Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8259 — An unreachable provider says so instead of showing no servers.

  An empty list is a claim: *you have no servers*. When the real answer is
  "we could not ask", that claim is a lie shaped like data — and the reader
  has no way to tell, because a healthy account with nothing in it looks
  identical.

  This is the failure this whole epic keeps finding in other clothes: a step
  reporting done having checked nothing, a backup covering half the
  environments, a publish that uploaded and told nobody. Here it would be a
  screen that reassures Sam his account is tidy while his credential is dead.

  Surface: `CodeMySpecWeb.ServerLive.Index` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "An unreachable provider says so instead of showing no servers" do
    scenario "a refused credential is reported, not rendered as emptiness" do
      given_ "Sam has servers at his provider", context do
        # Stated so the absence below is a lie rather than a fact: there are
        # servers, we simply cannot see them.
        {:ok, stage_servers(context, {:error, :unauthorized})}
      end

      when_ "the provider cannot be reached or the credential is refused", context do
        {:ok, _view, html} = live(context.conn, "/app/servers")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the screen says it could not reach the provider, and why", context do
        document = Floki.parse_document!(context.html)
        error = Floki.find(document, "[data-test='provider-error']")

        assert error != [],
               "an unreachable provider produced no error on the page"

        assert Floki.text(error) =~ ~r/unauthor|refus|reach/i,
               "the error must say what went wrong, not merely that something did"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "and it does not render an empty list, which would read as 'you have no servers'",
            context do
        empty_state = Floki.find(context.document, "[data-test='no-servers']")

        assert empty_state == [],
               "the page claimed the account has no servers when it had simply failed to ask"

        {:ok, context}
      end
    end

    scenario "a server he already linked survives the provider going dark" do
      given_ "Sam has linked one of his servers", context do
        context = stage_servers(context, [provider_server(%{name: "linked-box"})])

        {:ok, view, _html} = live(context.conn, "/app/servers")

        view
        |> element("[data-test='link-server'][phx-value-name='linked-box']")
        |> render_click()

        {:ok, context}
      end

      when_ "the provider can no longer be asked about it", context do
        # QA found this by switching to a project holding no Hetzner
        # credential. The box was running the whole time; the screen went
        # blank because the provider call failed before our own records were
        # ever consulted.
        context = stage_servers(context, {:error, :unauthorized})

        {:ok, _view, html} = live(context.conn, "/app/servers")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it is still on the screen", context do
        row =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server'][data-name='linked-box']")

        assert row != [],
               "a server the account had linked vanished because the provider was " <>
                 "unreachable — it is still running and still billing, and this screen " <>
                 "is the only thing that would have said so"

        {:ok, Map.put(context, :row, row)}
      end

      then_ "and it says the state could not be checked rather than inventing one", context do
        assert Floki.attribute(context.row, "data-unverified") == ["true"],
               "the row claimed to know a state nobody could have read"

        refute Floki.attribute(context.row, "data-missing") == ["true"],
               "an unreachable provider is not the provider saying the box is gone"

        {:ok, context}
      end
    end
  end
end
