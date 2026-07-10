defmodule Aveline.Config do
  @client_base_url Application.compile_env!(:aveline, :client_base_url)
  @landing_page_url Application.compile_env!(:aveline, :landing_page_url)
  @session_options Application.compile_env!(:aveline, :session_options)

  @moduledoc """
  Helper functions for accessing application configuration.
  """

  @doc """
  Returns the landing page URL for the application.
  Defaults to "https://aveline.ai" if not configured.
  """
  def landing_page_url!, do: @landing_page_url

  @doc """
  Returns the client base URL for the application.
  """
  def client_base_url!, do: @client_base_url

  @doc """
  Returns the session options for the application.
  """
  def session_options!, do: @session_options

  @doc """
  The deploy mode: `"local"` for a single-user Docker deployment, `"cloud"`
  (the default) otherwise. Set from the `DEPLOY_MODE` env var in runtime.exs.
  """
  def deploy_mode, do: Application.get_env(:aveline, :deploy_mode, "cloud")

  @doc """
  True in a single-user local deployment (`DEPLOY_MODE=local`). Gates
  first-boot seeding today; code-cell execution later.
  """
  def local_mode?, do: deploy_mode() == "local"
end
