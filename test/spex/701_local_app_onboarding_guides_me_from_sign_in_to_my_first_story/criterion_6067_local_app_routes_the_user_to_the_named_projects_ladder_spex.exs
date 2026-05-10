defmodule CodeMySpecSpex.Story701.Criterion6067Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6067 — Rule: The dashboard's "Open the local workspace"
  link carries `?project=<project_id>`; the local app reads it on
  landing and routes the user directly to that project's ladder.

  Spec asserts that landing on /?project=<id> auto-navigates the user
  to /projects/<project_name>/ for that project rather than dropping
  them on a picker.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_and_log_in_user

  setup context do
    _client_user = Fixtures.client_user_fixture(context.user)
    :ok
  end

  setup :setup_active_account
  setup :setup_active_project

  spex "Handoff URL routes the user directly to the named project's ladder" do
    scenario "Local app routes the user to the named project's ladder" do
      when_ "the user lands on / with the project query param", context do
        result = live(context.conn, "/?project=#{context.project.id}")
        {:ok, Map.put(context, :live_result, result)}
      end

      then_ "the local app navigates the user to that project's home", context do
        assert {:error, {kind, %{to: target}}} = context.live_result,
               "expected a redirect/live-redirect when ?project=<id> is provided; got: #{inspect(context.live_result)}"

        assert kind in [:redirect, :live_redirect]

        assert target =~ "/projects/#{context.project.name}",
               "expected redirect to /projects/#{context.project.name}; got: #{target}"

        {:ok, context}
      end
    end
  end
end
