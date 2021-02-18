require 'rails_helper'

RSpec.describe "User authentication", type: :feature, js: false do
  it 'succeeds' do
    visit '/'
    expect( page ).to have_http_status :ok
  end

  it 'fails for user not in authorised domain' do
    # skipping for now
    # Using redirect_post it returns a 200, not a 302,
    # which I think means then we don’t ever get the unauthorised
    skip

    original_user = OmniAuth.config.mock_auth[:google_oauth2]
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      {
        provider: 'google_oauth2',
        uid: '12345',
        info: {
          name:  'Charlotte Blackhat',
          email: 'charlotte@blackhat.con'
        }
      }
    )
    visit '/'
    expect( page ).to have_http_status :unauthorized
    OmniAuth.config.mock_auth[:google_oauth2] = original_user
  end
end
