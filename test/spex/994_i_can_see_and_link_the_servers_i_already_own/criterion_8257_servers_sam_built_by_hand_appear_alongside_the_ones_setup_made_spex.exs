defmodule CodeMySpecSpex.Story994.Criterion8257Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8257 — Servers Sam built by hand appear alongside the ones setup made.

  The reason the screen exists. Today a server is two strings on a
  provisioning environment row, so the only boxes CodeMySpec can name are the
  ones it created — and Sam's own machines, the ones he has been running since
  before he used any of this, are invisible.

  So the list is the provider's, not ours, and a box's origin does not decide
  whether it is shown or how prominently.

  Surface: `CodeMySpecWeb.ServerLive.Index` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Servers Sam built by hand appear alongside the ones setup made" do
    scenario "a hand-built server is listed like any other" do
      given_ "Sam runs two servers he created himself before using CodeMySpec", context do
        {:ok,
         stage_servers(context, [
           provider_server(%{name: "fuellytics", ip: "46.225.105.88", size: "cax11"}),
           provider_server(%{name: "fuellytics-prod", ip: "178.156.143.212", size: "cpx21"})
         ])}
      end

      when_ "he opens the servers screen", context do
        {:ok, _view, html} = live(context.conn, ~p"/app/servers")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "both are listed with their name, address, size and running state", context do
        rows =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server']")

        names = rows |> Floki.attribute("data-name") |> Enum.sort()
        assert names == ["fuellytics", "fuellytics-prod"]

        for {name, ip, size} <- [
              {"fuellytics", "46.225.105.88", "cax11"},
              {"fuellytics-prod", "178.156.143.212", "cpx21"}
            ] do
          row = Enum.find(rows, &(Floki.attribute([&1], "data-name") == [name]))

          assert Floki.attribute([row], "data-ip") == [ip]
          assert Floki.attribute([row], "data-size") == [size]
          assert Floki.attribute([row], "data-status") == ["running"]
        end

        {:ok, Map.put(context, :rows, rows)}
      end

      then_ "nothing marks them as second-class for not having been created here", context do
        # The criterion's real content. A box CodeMySpec did not create is not
        # a lesser box — if the screen sorted, dimmed or footnoted them by
        # origin, Sam's own machines would read as someone else's problem.
        origins =
          context.rows
          |> Floki.attribute("data-origin")
          |> Enum.uniq()

        assert origins in [[], ["adopted"]],
               "a server's origin must not change how it is presented, got: #{inspect(origins)}"

        {:ok, context}
      end
    end
  end
end
