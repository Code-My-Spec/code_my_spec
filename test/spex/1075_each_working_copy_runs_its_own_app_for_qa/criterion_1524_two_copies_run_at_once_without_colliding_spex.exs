defmodule CodeMySpecSpex.Story1108.Criterion1524Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 1524 — Two copies run at once without colliding.

  Rule: A copy's app is not main's — its own port and its own database.

  What this rules out is the failure the story is about: two copies of
  one project sharing a port (the second app fails to bind, or one answers
  in place of the other) or sharing a database schema (each silently
  reading and writing the other's data). The two allocations that prevent
  it are made by the real `AppInstance`: a non-main copy's port comes from
  `Runner.free_port/0`, freshly bound and released, never main's fixed
  address, and its database name is derived from its own root, never
  main's dev database. Both are asserted here off the real launch call.
  The address the copy reports and the database it was launched against
  are each checked against main's own reserved pair — `{4000, 4001}` for
  the address, `fakeapp_dev` for the database — so a copy that borrowed
  either would be caught.

  One copy per rig. `app_instance_rig/1` serves a single root and starts a
  single `AppInstance` for it, and `FakeServer` carries one connected
  harness channel, so two copies cannot both be driven from one spec
  file. What is asserted is that this copy's app is on an address and a
  database of its own, which is the property "both copies run at once"
  rests on; that a *second* copy does not disturb this one is what
  criteria 1543 (main is never stopped for idling) and 1528 (an agent
  cannot reach another copy's app) already cover through the same
  surface.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "A copy's app answers on a port of its own and uses a database of its own",
    criterion: 1524 do
    scenario "a feature copy starting while main's address and database are already spoken for" do
      given_ "a working copy, with main's own port pair and database name reserved", context do
        rig = app_instance_rig(current_commit: "feature1524")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the copy's app is started", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "it answers on a port that is not main's", context do
        assert %{"status" => "ok", "app_status" => "serving", "app_url" => url} = context.result
        assert url =~ ~r{^http://127\.0\.0\.1:(\d+)$}

        [_, port] = Regex.run(~r{^http://127\.0\.0\.1:(\d+)$}, url)

        refute String.to_integer(port) in [4000, 4001],
               "the copy answered on #{port}, one of main's own addresses — " <>
                 "two apps on one port means one of them is not really running"

        {:ok, context}
      end

      then_ "it was launched against a database that is not main's", context do
        assert [{:launch, [_root, _port, _https, database | _rest]}] =
                 Enum.filter(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1))

        assert is_binary(database) and database != "",
               "the copy was launched with no database name"

        refute database == "fakeapp_dev",
               "the copy was launched against main's own dev database (#{database}) — " <>
                 "it would read and write main's data"

        {:ok, context}
      end
    end
  end
end
