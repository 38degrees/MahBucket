require 'rails_helper'

RSpec.describe 'Flow announcement popup' do
  context 'with the 38degrees theme' do
    before do
      allow( Rails.application.secrets ).to receive( :theme ).and_return( '38degrees' )
    end

    it 'renders the announcement modal pointing at the Flow media library' do
      get '/'

      expect( response.body ).to have_css '#flow-announce.hidden'
      expect( response.body ).to have_css(
        '#flow-announce[data-flow-url="https://act.38degrees.org.uk/admin/#media-library/items"]'
      )
      expect( response.body ).to have_css '#flow-now', text: 'Try it now'
    end

    it 'includes a hidden "drop @ian a note" stage shown after Maybe later' do
      get '/'

      expect( response.body ).to have_css '[data-flow-stage="later"].hidden'
      expect( response.body ).to have_css(
        '[data-flow-stage="later"]',
        text: 'drop @ian a note so he knows what\'s missing in the new version'
      )
      expect( response.body ).to have_css '.flow-done', text: 'Got it'
    end
  end

  context 'with the default theme' do
    before do
      allow( Rails.application.secrets ).to receive( :theme ).and_return( 'default' )
    end

    it 'does not render the announcement modal' do
      get '/'

      expect( response.body ).not_to have_css '#flow-announce'
    end
  end
end
