defmodule CodeMySpec.Support.TestMailbox do
  @moduledoc """
  Cross-process email capture for Wallaby e2e tests.

  `Swoosh.Adapters.Test` sends emails as messages to the *caller's* process —
  which is the Phoenix request handler under Wallaby, not the test process.
  This adapter writes every delivered email into a public ETS table keyed by
  recipient, letting tests poll for the latest message.

  Wire by setting `config :code_my_spec, CodeMySpec.Mailer, adapter: CodeMySpec.Support.TestMailbox`
  in `config/test.exs` (only the e2e flow needs it; non-e2e tests keep
  `Swoosh.Adapters.Test`).
  """

  @behaviour Swoosh.Adapter

  @table :code_my_spec_test_mailbox

  def init do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:duplicate_bag, :public, :named_table])
      _ref -> :ok
    end
  end

  @impl true
  def deliver(%Swoosh.Email{} = email, _config) do
    init()
    {_, recipient} = List.first(email.to)
    :ets.insert(@table, {recipient, System.system_time(:millisecond), email})
    {:ok, %{}}
  end

  @impl true
  def deliver_many(emails, config), do: {:ok, Enum.map(emails, &deliver(&1, config))}

  @impl true
  def validate_config(_config), do: :ok

  @impl true
  def validate_dependency, do: :ok

  @doc """
  Pop the most recent email sent to `recipient`. Blocks (polls every 50ms)
  up to `timeout_ms` waiting for one to appear.
  """
  def assert_received(recipient, timeout_ms \\ 5_000) do
    init()
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for(recipient, deadline)
  end

  defp wait_for(recipient, deadline) do
    case latest(recipient) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "TestMailbox: no email to #{recipient} within timeout (table has: #{inspect(:ets.tab2list(@table))})"
        end

        Process.sleep(50)
        wait_for(recipient, deadline)

      email ->
        email
    end
  end

  defp latest(recipient) do
    case :ets.lookup(@table, recipient) do
      [] ->
        nil

      rows ->
        rows
        |> Enum.max_by(fn {_, ts, _} -> ts end)
        |> elem(2)
    end
  end

  @doc "Clear all captured emails. Call between tests."
  def clear do
    init()
    :ets.delete_all_objects(@table)
  end
end
