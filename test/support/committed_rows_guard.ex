defmodule CodeMySpecSpex.CommittedRowsGuard do
  @moduledoc "Fails a sandboxed spex run when fixture rows were committed outside its tests."

  @tables ~w(users accounts projects stories components requirements requirement_topologies)

  def install! do
    callback = &__MODULE__.check_after_suite!/1
    callbacks = Application.get_env(:ex_unit, :after_suite, [])
    unless callback in callbacks, do: ExUnit.after_suite(callback)
    :ok
  end

  def check_after_suite!(_stats) do
    repo = CodeMySpec.Repo

    if Application.get_env(:code_my_spec, repo, [])[:pool] == Ecto.Adapters.SQL.Sandbox do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo, sandbox: false)

      try do
        dirty =
          Enum.flat_map(@tables, fn table ->
            {:ok, %{rows: [[count]]}} =
              Ecto.Adapters.SQL.query(repo, "SELECT count(*) FROM #{table}", [])

            if count == 0, do: [], else: [{table, count}]
          end)

        if dirty != [] do
          summary = Enum.map_join(dirty, ", ", fn {table, count} -> "#{table}=#{count}" end)
          raise "spex left committed rows outside the sandbox: #{summary}"
        end
      after
        :ok = Ecto.Adapters.SQL.Sandbox.checkin(repo)
      end
    end
  end
end
