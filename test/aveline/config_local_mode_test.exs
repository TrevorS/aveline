defmodule Aveline.ConfigLocalModeTest do
  # Mutates the global :deploy_mode application env, so no async.
  use ExUnit.Case, async: false

  alias Aveline.Config

  setup do
    original = Application.fetch_env(:aveline, :deploy_mode)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:aveline, :deploy_mode, value)
        :error -> Application.delete_env(:aveline, :deploy_mode)
      end
    end)

    :ok
  end

  test "defaults to cloud when deploy_mode is unset" do
    Application.delete_env(:aveline, :deploy_mode)
    refute Config.local_mode?()
  end

  test "local flips the gate on" do
    Application.put_env(:aveline, :deploy_mode, "local")
    assert Config.local_mode?()
  end

  test "any other value stays cloud" do
    Application.put_env(:aveline, :deploy_mode, "cloud")
    refute Config.local_mode?()

    Application.put_env(:aveline, :deploy_mode, "LOCAL")
    refute Config.local_mode?()
  end
end
