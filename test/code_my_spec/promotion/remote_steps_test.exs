defmodule CodeMySpec.Promotion.RemoteStepsTest do
  use ExUnit.Case, async: true
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Promotion.RemoteSteps

  setup do
    dir = CodeMySpec.TempFile.owned_dir("test")
    origin = Path.join(dir, "origin.git")
    source = Path.join(dir, "source")
    destination = Path.join(dir, "destination")
    git!(dir, ["init", "--bare", "--initial-branch=release", origin])
    git!(dir, ["clone", origin, source])
    git!(source, ["config", "user.email", "test@example.com"])
    git!(source, ["config", "user.name", "Test"])
    base = commit(source, "base", "base")
    git!(source, ["push", "origin", "release"])
    git!(dir, ["clone", origin, destination])
    head = commit(source, "candidate", "candidate")

    %{
      origin: origin,
      source: source,
      destination: destination,
      base: base,
      head: head,
      env: ExecutionContext.new(:local, source)
    }
  end

  test "publishes configured branch and immutable receipt", c do
    assert {:ok, %{head: head, published: true, reconciled: false}} = publish(c)
    assert head == c.head
    assert git!(c.origin, ["rev-parse", "release"]) == c.head
    assert git!(c.origin, ["rev-parse", "refs/codemyspec/promotions/test-promotion"]) == c.head
    assert {:ok, %{reconciled: true}} = publish(c)
  end

  test "publication preserves dirty source files", c do
    File.write!(Path.join(c.source, "candidate"), "unsaved")
    File.write!(Path.join(c.source, "untracked"), "keep")
    assert {:ok, _} = publish(c)
    assert File.read!(Path.join(c.source, "candidate")) == "unsaved"
    assert File.read!(Path.join(c.source, "untracked")) == "keep"
  end

  test "does not claim pre-existing candidate without a receipt", c do
    git!(c.source, ["push", "origin", "release"])
    assert {:ok, %{published: false}} = status(c)
    assert {:error, %{base_moved: true}} = publish(c)
  end

  test "publication status never pushes and reconciles the durable receipt", c do
    assert {:ok, %{published: false}} = status(c)
    assert git!(c.origin, ["rev-parse", "release"]) == c.base
    assert {:ok, _} = publish(c)
    assert {:ok, %{published: true, reconciled: true}} = status(c)
  end

  test "rejects non fast-forward before pushing", c do
    git!(c.source, ["checkout", "--orphan", "unrelated"])
    other = commit(c.source, "other", "other")

    assert {:error, %{status: :rejected}} =
             RemoteSteps.publish(c.env, c.source, "release", c.base, other, "bad")

    assert git!(c.origin, ["rev-parse", "release"]) == c.base
  end

  test "server rejection creates no receipt and does not move branch", c do
    hook = Path.join(c.origin, "hooks/pre-receive")
    File.write!(hook, "#!/bin/sh\necho denied >&2\nexit 1\n")
    File.chmod!(hook, 0o755)
    assert {:error, %{status: :rejected}} = publish(c)
    assert git!(c.origin, ["rev-parse", "release"]) == c.base
    assert git!(c.origin, ["for-each-ref", "refs/codemyspec/promotions"]) == ""
  end

  test "a transient commit_refs failure retries the same atomic publication", c do
    hook = Path.join(c.origin, "hooks/pre-receive")
    marker = Path.join(c.origin, "failed-once")

    File.write!(
      hook,
      "#!/bin/sh\nif [ ! -e '#{marker}' ]; then\n  touch '#{marker}'\n  echo 'fatal error in commit_refs' >&2\n  exit 1\nfi\n"
    )

    File.chmod!(hook, 0o755)
    assert {:ok, %{head: head, published: true}} = publish(c)
    assert head == c.head
    assert File.exists?(marker)
    assert git!(c.origin, ["rev-parse", "release"]) == c.head
    assert git!(c.origin, ["rev-parse", "refs/codemyspec/promotions/test-promotion"]) == c.head
  end

  test "persistent commit_refs failure remains retryable after bounded attempts", c do
    hook = Path.join(c.origin, "hooks/pre-receive")
    attempts = Path.join(c.origin, "push-attempts")

    File.write!(
      hook,
      "#!/bin/sh\nprintf x >> '#{attempts}'\necho 'fatal error in commit_refs' >&2\nexit 1\n"
    )

    File.chmod!(hook, 0o755)
    assert {:error, %{retryable: true, uncertain: true}} = publish(c)
    assert File.read!(attempts) == "xxx"
    assert git!(c.origin, ["rev-parse", "release"]) == c.base
    assert git!(c.origin, ["for-each-ref", "refs/codemyspec/promotions"]) == ""
  end

  test "an origin without atomic push support is refused without partial publication", c do
    git!(c.origin, ["config", "receive.advertiseAtomic", "false"])
    assert {:error, %{status: :rejected}} = publish(c)
    assert git!(c.origin, ["rev-parse", "release"]) == c.base
    assert git!(c.origin, ["for-each-ref", "refs/codemyspec/promotions"]) == ""
  end

  test "lease refuses competing publication between snapshot and push", c do
    git!(c.source, ["push", "origin", "#{c.head}:refs/heads/competitor"])
    hook = Path.join(c.source, ".git/hooks/pre-push")

    File.write!(
      hook,
      "#!/bin/sh\ngit --git-dir='#{c.origin}' update-ref refs/heads/release '#{c.head}' '#{c.base}'\n"
    )

    File.chmod!(hook, 0o755)
    assert {:error, %{base_moved: true}} = publish(c)
    assert git!(c.origin, ["for-each-ref", "refs/codemyspec/promotions"]) == ""
  end

  test "receipt reconciles after later fast-forward", c do
    assert {:ok, _} = publish(c)
    later = commit(c.source, "later", "later")
    git!(c.source, ["push", "origin", "release"])
    assert {:ok, %{reconciled: true, head: head}} = publish(c)
    assert head == c.head
    assert git!(c.origin, ["rev-parse", "release"]) == later
  end

  test "a failed transport response after accepting the push is reconciled by receipt", c do
    wrapper = Path.join(c.origin, "lose-response")
    File.write!(wrapper, "#!/bin/sh\ngit-receive-pack \"$@\"\nexit 1\n")
    File.chmod!(wrapper, 0o755)
    git!(c.source, ["config", "remote.origin.receivepack", wrapper])
    assert {:ok, %{reconciled: true, head: head}} = publish(c)
    assert head == c.head
    assert git!(c.origin, ["rev-parse", "release"]) == c.head
  end

  test "sync fetches origin and fast-forwards exact requested head", c do
    assert {:ok, _} = publish(c)
    assert {:ok, %{head: head, changed_files: ["candidate"]}} = sync(c)
    assert head == c.head
    assert git!(c.destination, ["rev-parse", "HEAD"]) == c.head
  end

  test "sync refuses dirty, wrong-branch and divergent destinations", c do
    assert {:ok, _} = publish(c)
    File.write!(Path.join(c.destination, "unsaved"), "keep")
    assert {:error, %{status: :dirty}} = sync(c)
    File.rm!(Path.join(c.destination, "unsaved"))
    git!(c.destination, ["checkout", "-b", "wrong"])
    assert {:error, %{status: :rejected}} = sync(c)
    git!(c.destination, ["checkout", "release"])
    git!(c.destination, ["config", "user.email", "test@example.com"])
    git!(c.destination, ["config", "user.name", "Test"])
    local = commit(c.destination, "local", "local")
    assert {:error, %{status: :rejected}} = sync(c)
    assert git!(c.destination, ["rev-parse", "HEAD"]) == local
  end

  test "sync does not claim success when the destination changes during its fast-forward", c do
    assert {:ok, _} = publish(c)
    hook = Path.join(c.destination, ".git/hooks/post-merge")
    File.write!(hook, "#!/bin/sh\nprintf 'local edit during synchronization' > base\n")
    File.chmod!(hook, 0o755)

    assert {:error, %{status: :dirty}} = sync(c)
    assert git!(c.destination, ["rev-parse", "HEAD"]) == c.head
    assert File.read!(Path.join(c.destination, "base")) == "local edit during synchronization"
  end

  defp publish(c),
    do: RemoteSteps.publish(c.env, c.source, "release", c.base, c.head, "test-promotion")

  defp sync(c), do: RemoteSteps.sync_remote(c.env, c.destination, "release", c.head)

  defp status(c),
    do:
      RemoteSteps.publication_status(c.env, c.source, "release", c.base, c.head, "test-promotion")

  defp commit(root, file, content) do
    File.write!(Path.join(root, file), content)
    git!(root, ["add", file])
    git!(root, ["commit", "-m", file])
    git!(root, ["rev-parse", "HEAD"])
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
