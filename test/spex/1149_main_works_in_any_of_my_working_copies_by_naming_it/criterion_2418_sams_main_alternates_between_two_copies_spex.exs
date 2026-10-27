defmodule CodeMySpecSpex.Story1149.Criterion2418Spex do
  @moduledoc "Main alternates between two copies without changing either destination."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.AttachmentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam's Main alternates between two copies without either replacing the other", criterion: 2418 do
    scenario "each call uses its named copy after switching back and forth" do
      given_ "Main has a laptop copy and a remote copy", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main reads laptop, remote, then laptop again", context do
        results = [
          AttachmentHelpers.read(context, context.one, "identity.txt"),
          AttachmentHelpers.read(context, context.two, "identity.txt"),
          AttachmentHelpers.read(context, context.one, "identity.txt")
        ]

        {:ok, Map.put(context, :results, results)}
      end

      then_ "each result comes from the named copy", context do
        assert Enum.map(context.results, fn result ->
                 result |> String.split("\t", parts: 2) |> List.last() |> String.trim()
               end) == ["laptop", "remote", "laptop"]
        assert AttachmentHelpers.read(context, context.two, "identity.txt") =~ "remote"
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
