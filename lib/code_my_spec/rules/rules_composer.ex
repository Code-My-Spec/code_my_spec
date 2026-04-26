defmodule CodeMySpec.Rules.RulesComposer do
  @moduledoc false
  @default_separator "\n\n"

  def compose_rules(rules) do
    compose_rules(rules, @default_separator)
  end

  def compose_rules(rules, separator) when is_list(rules) and is_binary(separator) do
    rules
    |> Enum.map(& &1.content)
    |> Enum.filter(&content_present?/1)
    |> Enum.join(separator)
  end

  defp content_present?(content) when is_binary(content) do
    String.trim(content) != ""
  end

  defp content_present?(_), do: false
end
