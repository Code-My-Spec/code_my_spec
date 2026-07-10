defmodule CodeMySpecSpex.Story701.Criterion6060Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6060 — Rule: The local app shows a local-install ladder
  on `/` whose two rungs are *authed with the dashboard* and *has a
  linked project* — the ladder is rendered while either rung is
  incomplete and hidden once both are done.

  An authed user with no project carrying a `local_path` sees the
  auth rung as done and the linked-project rung as active.

  Forward-looking helper: `CodeMySpecSpex.Fixtures.client_user_fixture/1`
  seeds a `client_users` row with a non-expired token for the test
  user — the predicate the auth rung's done-check evaluates against.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_and_log_in_user

  setup context do
    # The ladder is the muster-connected (server-sync) onboarding path —
    # opt-in since the independence work made local-first the default.
    Application.put_env(:code_my_spec, :muster_sync_enabled, true)
    on_exit(fn -> Application.delete_env(:code_my_spec, :muster_sync_enabled) end)

    _client_user = Fixtures.client_user_fixture(context.user)
    :ok
  end

  spex "Authed user with no linked project sees auth done and linked-project active" do
    scenario "Authed user with no linked project sees only the linked-project rung as active" do
      given_ "the user is authed locally but has no project with a local_path", context do
        {:ok, view, _html} = live(context.conn, "/")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the auth rung is in the done state", context do
        assert has_element?(context.view, "[data-test='auth-rung'][data-state='done']"),
               "expected auth-rung in 'done' state for an authed user"

        {:ok, context}
      end

      then_ "the linked-project rung is in the active state", context do
        assert has_element?(
                 context.view,
                 "[data-test='linked-project-rung'][data-state='active']"
               ),
               "expected linked-project-rung in 'active' state when no project has a local_path"

        {:ok, context}
      end
    end
  end
end
