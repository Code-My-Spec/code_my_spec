defmodule CodeMySpecSpex.Story812.Criterion6538Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6538 — Rule 5 (hybrid): Server MP sign_up carries the
  gtag client_id from the _ga cookie so it stitches to the browser
  session.

  The `_ga` cookie format is `GA1.1.<X>.<Y>` — the client_id is the
  `<X>.<Y>` tail. When the cookie is absent, the MP builder falls back
  to a deterministic per-user hash. This criterion proves the cookie path.

  Test-subscriber pattern: seed a synthetic `_ga` cookie on the conn
  before the registration form is submitted. Attach the GA test subscriber
  to receive the MP payload as `{:ga_measurement_protocol, payload}`.
  Assert the payload's `client_id` equals the `<X>.<Y>` tail of the
  seeded cookie — not "anonymous" and not the old "cms-<user_id>" format.

  This is the client_id sibling of criterion 6539 (session_id).
  No cassette, no real GA round-trip.
  """

  use CodeMySpecSpex.Case

  # /users/register lives on the main web router, not LocalWeb.
  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  # A synthetic _ga cookie value. Format: GA1.1.<X>.<Y>
  # The extracted client_id that the MP payload must carry is "<X>.<Y>".
  @ga_cookie_value "GA1.1.987654321.1700000000"
  @expected_client_id "987654321.1700000000"

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "Server MP sign_up carries gtag client_id from the _ga cookie" do
    scenario "sign_up MP payload uses the _ga cookie client_id, not anonymous or cms-<user_id>" do
      given_ "a fresh email and a conn seeded with a _ga cookie", context do
        email = "spex-812-stitch-#{System.unique_integer([:positive])}@codemyspec.test"

        conn = Plug.Test.put_req_cookie(context.conn, "_ga", @ga_cookie_value)

        {:ok, context |> Map.put(:email, email) |> Map.put(:conn, conn)}
      end

      when_ "the visitor submits the magic-link registration form", context do
        {:ok, lv, _html} = live(context.conn, "/users/register")

        lv
        |> form("#registration_form", user: %{email: context.email})
        |> render_submit()

        {:ok, context}
      end

      then_ "the sign_up MP payload carries the _ga cookie's client_id", context do
        assert_receive {:ga_measurement_protocol, %{client_id: client_id} = payload}, 1_000

        [sign_up_event | _] = payload.events
        assert sign_up_event.name == "sign_up"

        assert client_id == @expected_client_id,
               """
               Expected sign_up MP payload to carry client_id=#{@expected_client_id}
               (parsed from _ga cookie #{@ga_cookie_value}).

               Got: #{inspect(client_id)}

               The MP payload builder must read the _ga cookie and parse
               the <X>.<Y> tail as the client_id.
               """

        # Stash the client_id so the next then_ step can assert negative conditions
        # without issuing a second assert_receive on an already-consumed message.
        {:ok, Map.put(context, :sign_up_client_id, client_id)}
      end

      then_ "the client_id is not anonymous and not the cms-<user_id> format", context do
        client_id = context.sign_up_client_id

        refute client_id == "anonymous",
               "sign_up MP client_id must not be \"anonymous\" — it must stitch to the browser session via the _ga cookie"

        refute is_binary(client_id) and String.starts_with?(client_id, "cms-"),
               "sign_up MP client_id must not use the old cms-<user_id> format — use the _ga cookie instead"

        {:ok, context}
      end
    end
  end
end
