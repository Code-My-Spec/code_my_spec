# Run every Postgres migration against a fresh SQLite file; record failures and keep going.
Logger.configure(level: :error)
repo = CodeMySpec.Repo
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = repo.start_link(pool_size: 1)
dir = "priv/repo/migrations"

results =
  for {version, name, file} <- Ecto.Migrator.migrations(repo, [dir]) |> Enum.map(fn {_s, v, n} -> {v, n, nil} end) |> Enum.map(fn {v, n, _} -> {v, n, Path.wildcard(Path.join(dir, "#{v}_*.exs")) |> hd()} end) do
    try do
      [{mod, _} | _] = Code.compile_file(file) |> Enum.filter(fn {m, _} -> function_exported?(m, :__migration__, 0) end)
      Ecto.Migrator.up(repo, version, mod, log: false)
      {:ok, version, name}
    rescue
      e -> {:error, version, name, Exception.message(e) |> String.split("\n") |> hd() |> String.slice(0, 220)}
    end
  end

failed = Enum.filter(results, &match?({:error, _, _, _}, &1))
IO.puts("TOTAL #{length(results)}  OK #{length(results) - length(failed)}  FAILED #{length(failed)}")
for {:error, v, n, msg} <- failed, do: IO.puts("FAIL #{v} #{n}: #{msg}")
