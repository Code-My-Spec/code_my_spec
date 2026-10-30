defmodule CodeMySpec.Provisioning.ExceptionDiagnostic do
  @moduledoc "A secret-safe, durable diagnosis for exceptions inside setup steps."

  @visible_frames 4

  def build(step, error, stacktrace) do
    phase = phase(step, stacktrace)
    message = safe_message(error)
    frames = Enum.map(stacktrace, &frame/1)

    heading =
      "Provisioning exception: #{step} step raised in #{phase}: #{inspect(error.__struct__)}: #{message}"

    %{
      detail: Enum.join([heading | Enum.take(frames, @visible_frames)], "\n"),
      trace: Enum.join([heading | frames], "\n")
    }
  end

  defp safe_message(%KeyError{key: key, term: term}) when is_map(term) do
    keys = term |> Map.keys() |> Enum.filter(&is_atom/1) |> Enum.sort()
    "key #{safe_key(key)} not found; available keys: #{inspect(keys)}"
  end

  defp safe_message(%KeyError{key: key}), do: "key #{safe_key(key)} not found"

  # Arbitrary exception text can include credentials. Preserve its words while
  # removing quoted values and inspected map contents before persistence.
  defp safe_message(error) do
    error
    |> Exception.message()
    |> String.replace(~r/%\{[^}]*\}/s, "%{[values redacted]}")
    |> String.replace(~r/\"[^\"]*\"/, "[value redacted]")
    |> String.replace(~r/'[^']*'/, "[value redacted]")
  end

  defp safe_key(key) when is_atom(key), do: inspect(key)
  defp safe_key(_key), do: "[value redacted]"

  defp phase(:deploy, stacktrace) do
    cond do
      Enum.any?(stacktrace, &builder_frame?/1) -> "build bootstrap"
      Enum.any?(stacktrace, &deploy_frame?/1) -> "deploy"
      true -> "deploy"
    end
  end

  defp phase(step, _stacktrace), do: to_string(step)

  defp builder_frame?({module, _, _, _}),
    do: module in [CodeMySpec.Provisioning.Builder, CodeMySpec.Provisioning.Builder.Remote]

  defp builder_frame?(_), do: false

  defp deploy_frame?({CodeMySpec.Provisioning.Deploy, _, _, _}), do: true
  defp deploy_frame?(_), do: false

  defp frame({module, function, arity, location}) do
    file = location |> Keyword.get(:file, "unknown") |> to_string()
    line = Keyword.get(location, :line, 0)
    arity = if is_list(arity), do: length(arity), else: arity
    "  at #{inspect(module)}.#{function}/#{arity} #{file}:#{line}"
  end

  defp frame(_), do: "  at unknown frame"
end
