defmodule QuadmanWeb.Router do
  use QuadmanWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {QuadmanWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug QuadmanWeb.AuthPlug
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Auth routes (unauthenticated)
  scope "/", QuadmanWeb do
    pipe_through :browser

    get "/login", AuthController, :login
    post "/login", AuthController, :login_submit
    get "/register", AuthController, :register
    post "/register", AuthController, :register_submit
    delete "/logout", AuthController, :logout
  end

  # Authenticated live routes
  scope "/", QuadmanWeb do
    pipe_through :browser

    live_session :authenticated,
      on_mount: {QuadmanWeb.AuthHook, :require_authenticated_user} do
      live "/", DashboardLive
      live "/services", ServicesLive
      live "/services/:id", ServiceDetailLive
      live "/services/:id/logs", ServiceLogsLive
      live "/stacks", StacksLive
      live "/stacks/:id", StackDetailLive
      live "/deployments/:id", DeploymentDetailLive
      live "/users", UsersLive
      live "/settings", SettingsLive
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:quadman, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: QuadmanWeb.Telemetry
    end
  end
end
