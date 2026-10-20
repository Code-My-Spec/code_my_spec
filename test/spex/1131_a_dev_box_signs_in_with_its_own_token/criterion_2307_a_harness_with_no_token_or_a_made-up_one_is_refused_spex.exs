defmodule CodeMySpecSpex.Story1131.Criterion2307Spex do
  @moduledoc """
  Story 1131 — A dev box signs in with its own token.
  Criterion 2307 — A harness with no token or a made-up one is refused.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A harness without a real token is refused", criterion: 2307 do
    scenario "no token, and a token CodeMySpec never minted" do
      given_ "a harness starts with no token, or a token CodeMySpec never minted", context do
        {:ok, Map.put(context, :made_up, "cbt_" <> String.duplicate("x", 43))}
      end

      when_ "it tries to sign in", context do
        {:ok,
         Map.merge(context, %{
           without: exchange(nil),
           forged: exchange(context.made_up)
         })}
      end

      then_ "it is refused and told why", context do
        for conn <- [context.without, context.forged] do
          body = json_response(conn, 401)

          assert is_binary(body["error"]) and body["error"] != "",
                 "a refused harness was given no reason: #{inspect(body)}"
        end

        {:ok, context}
      end
    end
  end
end
