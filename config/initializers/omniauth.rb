Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2, ENV.fetch('GOOGLE_OAUTH_CLIENT_ID', nil), ENV.fetch('GOOGLE_OAUTH_CLIENT_SECRET', nil)
end
