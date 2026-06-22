require 'rails_helper'

RSpec.describe 'Flow announcement popup' do
  before do
    allow_any_instance_of( ItemsController ).to receive( :authenticate ).and_return(nil)
  end

  context 'on the 38degrees theme' do
    before do
      allow_any_instance_of( ApplicationHelper ).to receive( :theme ).and_return( '38degrees' )
    end

    it 'renders the announcement modal pointing at the Flow media library' do
      get '/'

      expect( response.body ).to have_css '#flow-announce.hidden'
      expect( response.body ).to have_css(
        '#flow-announce[data-flow-url="https://act.38degrees.org.uk/admin/#media-library/items"]'
      )
      expect( response.body ).to have_css '#flow-now', text: 'Try it now'
    end
  end

  context 'on the default theme' do
    before do
      allow_any_instance_of( ApplicationHelper ).to receive( :theme ).and_return( 'default' )
    end

    it 'does not render the announcement modal' do
      get '/'

      expect( response.body ).not_to have_css '#flow-announce'
    end
  end
end
