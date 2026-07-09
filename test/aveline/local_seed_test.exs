defmodule Aveline.LocalSeedTest do
  use Aveline.DataCase, async: true

  alias Aveline.Accounts
  alias Aveline.Accounts.User
  alias Aveline.LocalSeed
  alias Aveline.Tokens
  alias Aveline.Workspaces

  test "first run seeds one user + workspace + verifiable token" do
    assert {:ok, %{user: user, workspace: ws, token: plaintext}} = LocalSeed.run()

    assert user.username == "local"
    assert Workspaces.member?(ws.id, user.id)

    # the token verifies, so the CLI can log in with it as-is
    assert %{user_id: uid} = Tokens.verify(plaintext)
    assert uid == user.id
  end

  test "second run seeds nothing" do
    assert {:ok, _} = LocalSeed.run()
    assert :already_seeded = LocalSeed.run()
    assert Repo.aggregate(User, :count) == 1
  end

  test "boot runs the seed and reports, never raises" do
    assert :ok = LocalSeed.boot()
    assert %User{} = Accounts.get_user_by_username("local")
  end

  test "boot on a seeded database is a no-op" do
    {:ok, _} = LocalSeed.run()

    assert :ok = LocalSeed.boot()
    assert Repo.aggregate(User, :count) == 1
  end

  test "any pre-existing user blocks the seed" do
    {:ok, _} = Accounts.signup(%{"username" => "existing", "workspace_name" => "Existing Co"})

    assert :already_seeded = LocalSeed.run()
    refute Accounts.get_user_by_username("local")
  end
end
