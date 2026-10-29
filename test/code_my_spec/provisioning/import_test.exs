defmodule CodeMySpec.Provisioning.ImportTest do
  @moduledoc """
  Issue b6daceee: adopting an existing app had no path to move its data into
  cms-postgres, and the first deploy landed on an empty database. `:import`
  copies a legacy database on the same box in — dump, restore, reassign
  ownership, compare row counts — and is a no-op for every project that never
  named one.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Steps

  setup do
    %{scope: provisioning_scope_fixture()}
  end

  defp configure_source(scope) do
    {:ok, _} =
      Environments.put(scope, "uat", %{
        import_source_container: "legacy-pg",
        import_source_database: "legacy_db"
      })

    :ok
  end

  # Both sides answer the same row-count query; `source_count`/`target_count`
  # are keyed off which container the query actually ran against.
  defp counting_run(source_count, target_count) do
    fn [command] ->
      cond do
        not String.contains?(command, "json_object_agg") ->
          {"", 0}

        String.contains?(command, "'legacy-pg'") ->
          {Jason.encode!(%{"t" => source_count}), 0}

        true ->
          {Jason.encode!(%{"t" => target_count}), 0}
      end
    end
  end

  describe "verify/3 — never configured" do
    test "is satisfied with nothing to show for a project that never named a source", %{
      scope: scope
    } do
      assert {:ok, :satisfied, [resource]} =
               Steps.verify(:import, scope, environments: ["uat"], run: fn _ -> {"", 0} end)

      assert resource.identifier =~ "not_configured"
    end
  end

  describe "verify/3 — configured" do
    setup %{scope: scope}, do: configure_source(scope)

    test "is absent while the target is still behind the source", %{scope: scope} do
      assert {:ok, :absent} =
               Steps.verify(:import, scope,
                 environments: ["uat"],
                 run: counting_run(3, 0)
               )
    end

    test "is satisfied once the target already matches the source", %{scope: scope} do
      assert {:ok, :satisfied, [resource]} =
               Steps.verify(:import, scope,
                 environments: ["uat"],
                 run: counting_run(3, 3)
               )

      assert resource.kind == "database_import"
      assert resource.location == "legacy-pg/legacy_db"
      assert resource.identifier == "environment=uat"
    end

    # A provider error is "could not confirm", not "gone" or "done" — the
    # step must ask the real box, never trust that "configured" already
    # means "copied".
    test "a provider error halts rather than reporting satisfied or absent", %{scope: scope} do
      assert {:error, reason} =
               Steps.verify(:import, scope, environments: ["uat"], run: fn _ -> {"boom", 1} end)

      assert reason =~ "database_row_counts_failed"
    end
  end

  describe "run/3 — never configured" do
    test "succeeds without touching any box", %{scope: scope} do
      run = fn _ -> flunk("a project with nothing to import must never reach the box") end

      assert {:ok, [resource]} = Steps.run(:import, scope, environments: ["uat"], run: run)
      assert resource.identifier =~ "not_configured"
    end
  end

  describe "run/3 — configured" do
    setup %{scope: scope}, do: configure_source(scope)

    test "dumps, restores and reassigns ownership, then reports the new resource", %{
      scope: scope
    } do
      owner = self()

      run = fn [command] ->
        send(owner, {:ran, command})

        if String.contains?(command, "json_object_agg") do
          counting_run(3, 3).([command])
        else
          {"", 0}
        end
      end

      assert {:ok, [resource]} = Steps.run(:import, scope, environments: ["uat"], run: run)
      assert resource.kind == "database_import"
      assert resource.location == "legacy-pg/legacy_db"

      commands = collect(owner)
      assert Enum.any?(commands, &(&1 =~ "pg_dump" and &1 =~ "pg_restore"))
      assert Enum.any?(commands, &(&1 =~ "OWNER TO"))
    end

    test "a row-count mismatch after the restore fails the step", %{scope: scope} do
      assert {:error, reason, []} =
               Steps.run(:import, scope, environments: ["uat"], run: counting_run(3, 1))

      assert reason =~ "database_import_row_counts_mismatched" or reason =~ "mismatched"
    end
  end

  defp collect(owner, acc \\ []) do
    receive do
      {:ran, command} -> collect(owner, [command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
