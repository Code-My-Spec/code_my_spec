defmodule CodeMySpec.Logging do
  @moduledoc """
  Runtime setup for the `:logger` file handler used by the `cms` server
  binary and the `code_my_spec_cli` CLI binary.

  Replaces `:default_handler` (which writes to stderr) with a
  `:logger_std_h` writing to a file, formatted as logfmt by
  `CodeMySpec.Logging.LogfmtFormatter`, with size-based rotation.

  Call from your `Application.start/2` early — before the supervision
  tree boots — so application logs land in the file from line one.
  """

  alias CodeMySpec.Logging.LogfmtFormatter

  @default_max_bytes 10_485_760
  @default_max_files 3

  @doc """
  Reconfigures `:default_handler` to write logfmt to `path` with rotation.
  Idempotent.

  ## Options

    * `:source` (required) — `"server"`, `"cli"` or `"harness"`. Stamped on every
      line as `src=`.
    * `:instance` — identifies the writing process, stamped as `inst=`. Worth
      setting wherever two processes can share one file: `cms harness` does,
      when two are started on one working copy, and the resulting log is
      unreadable without it.
    * `:path` — file path. Tilde-expanded. Defaults to a source-specific path.
    * `:level` — `:debug | :info | :warning | :error`. Defaults to `:info`.
    * `:max_no_bytes` — rotation byte threshold. Defaults to 10 MB.
    * `:max_no_files` — rotated files retained. Defaults to 3.
    * `:handler_id` — the `:logger` handler to install as. Defaults to `:default`.
    * `:replace_default` — remove the stderr handler first. Defaults to `true`.

      A daemon has no terminal, so replacing is right for `cms server`. A
      foreground process does, and taking its output away to gain a log file is
      a bad trade — pass `false` with a `:handler_id` of its own and both
      exist. `cms harness` does exactly that: a harness whose only record is a
      terminal somebody else is looking at cannot be diagnosed.
  """
  @spec install_file_handler!(keyword()) :: {:ok, Path.t()}
  def install_file_handler!(opts) do
    source = Keyword.fetch!(opts, :source)
    path = opts |> Keyword.get(:path, default_path(source)) |> Path.expand()
    level = Keyword.get(opts, :level, :info)
    max_no_bytes = Keyword.get(opts, :max_no_bytes, @default_max_bytes)
    max_no_files = Keyword.get(opts, :max_no_files, @default_max_files)
    handler_id = Keyword.get(opts, :handler_id, :default)
    replace_default? = Keyword.get(opts, :replace_default, true)

    File.mkdir_p!(Path.dirname(path))

    handler_config = %{
      level: level,
      config: %{
        type: {:file, String.to_charlist(path)},
        file_check: 1_000,
        max_no_bytes: max_no_bytes,
        max_no_files: max_no_files
      },
      formatter: {LogfmtFormatter, formatter_config(source, Keyword.get(opts, :instance))},
      # Default Erlang logger filters drop Elixir-domain events (anything
      # from `Logger.info/2` etc) because they only allow `:undefined` or
      # `[:otp, :sasl]` domains. Switch to log-by-default and keep only the
      # remote group-leader guard, which prevents log loops across nodes.
      filter_default: :log,
      filters: [
        remote_gl: {&:logger_filters.remote_gl/2, :stop}
      ]
    }

    if replace_default?, do: :logger.remove_handler(:default)

    # Idempotent: re-installing after a restart must not fail on the id.
    _ = :logger.remove_handler(handler_id)
    :ok = :logger.add_handler(handler_id, :logger_std_h, handler_config)

    {:ok, path}
  end

  defp formatter_config(source, nil), do: %{source: source}
  defp formatter_config(source, instance), do: %{source: source, instance: to_string(instance)}

  defp default_path("cli"), do: "~/.codemyspec/cli.log"
  defp default_path("harness"), do: "~/.codemyspec/harness.log"
  defp default_path(_), do: "~/.codemyspec/server.log"
end
