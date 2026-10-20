defmodule TSpecWeb.Router do
  use TSpecWeb, :router

  import TSpecWeb.UserAuth
  import TSpecWeb.ApiAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TSpecWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: TSpecWeb.ApiSpec
    plug :fetch_api_scope
  end

  pipeline :api_authenticated do
    plug :require_api_user
  end

  pipeline :api_onboarded do
    plug :require_onboarded
  end

  scope "/", TSpecWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api" do
    pipe_through :api

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api", TSpecWeb do
    pipe_through :api

    get "/health", HealthController, :show
    post "/auth/request", AuthController, :request
    post "/auth/verify", AuthController, :verify
    get "/consent/current", ConsentController, :show
    get "/users/:handle", UserController, :show
    get "/content/:id", ContentController, :show
  end

  scope "/api", TSpecWeb do
    pipe_through [:api, :api_authenticated]

    delete "/auth/session", AuthController, :delete
    get "/me", MeController, :show
    post "/onboarding", OnboardingController, :create
  end

  scope "/api", TSpecWeb do
    pipe_through [:api, :api_authenticated, :api_onboarded]

    patch "/me", MeController, :update
    post "/users/:handle/follow", UserController, :follow
    delete "/users/:handle/follow", UserController, :unfollow
    post "/videos", ContentController, :create_video
    post "/posts", ContentController, :create_post
    patch "/content/:id", ContentController, :update
    delete "/content/:id", ContentController, :delete
  end

  # Provider webhooks: signature-verified, no API auth.
  pipeline :webhook do
    plug :accepts, ["json"]
  end

  scope "/api/webhooks", TSpecWeb do
    pipe_through :webhook

    post "/video/:provider", VideoWebhookController, :create
  end

  # Upload endpoint of the dev/test LocalProvider (never in production).
  if Application.compile_env(:tspec, :local_video, false) do
    scope "/dev", TSpecWeb.Dev do
      post "/video-uploads/:token", VideoUploadController, :create
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:tspec, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TSpecWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", TSpecWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", TSpecWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
