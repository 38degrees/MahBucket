# Sessions controller
class SessionsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :create

  def create
    if auth_hash and auth_hash['info']['email'].split('@')[1] == ENV['GOOGLE_OAUTH_DOMAIN']
      session[ :email ] = auth_hash['info']['email']
      session[ :name  ] = auth_hash['info']['name' ]
      redirect_to '/'
    else
      render html: '<p>Unauthori<blink>s</blink>ed</p>', status: :unauthorized
    end
  end

  protected

  def auth_hash
    request.env['omniauth.auth']
  end
end
