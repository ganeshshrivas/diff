class Gigs::InquiriesController < Gigs::ApplicationController
    load_and_authorize_resource
  
    respond_to :html, only: %i[new, show]
    respond_to :json, only: %i[create]
  
    before_filter :load_gig, only: %i[create, new]
  
    def new
      @inquiry.deal_possible_fee_min = @inquiry.gig.try(:deal_possible_fee_min)
      @inquiry.artist_contact        = current_profile.last_inquired(:artist_contact)
      @inquiry.travel_party_count    = current_profile.last_inquired(:travel_party_count)
      @inquiry.custom_fields         = @inquiry.gig.try(:custom_fields)
  
     @inquiry.fixed_fee = 0 if @inquiry.gig.try(:fixed_fee_option) && @inquiry.gig.try(:fixed_fee_max) == 0
  
      if @inquiry.gig.try(:fixed_fee_negotiable)
        @inquiry.gig.fixed_fee_option = true
        @inquiry.gig.fixed_fee_max    = 0
      end
  
      # set this rider here for new
      # if user keeps it until create, they will be copied async
      # otherwise he can pseudo delete the riders in the Inquiry#new form and
      # add new ones
      @inquiry.technical_rider = current_profile.technical_rider
      @inquiry.catering_rider  = current_profile.catering_rider
  
      @is_matching = GigTest::Matcher.new(@inquiry.gig, current_profile).matches?
  
      if current_profile.billing_address.blank? || current_profile.tax_rate.blank?
        @profile = current_profile
        @profile.build_billing_address(name: "#{@profile.main_user.first_name} #{@profile.main_user.last_name}") if @profile.billing_address.blank?
      end
  
      GigTest::Intercom::Event::ApplicationSawIncompleteBillingDataWarning.emit(@inquiry.gig.try(:id), current_profile.id) unless current_profile.has_a_complete_billing_address?
      GigTest::Intercom::Event::ApplicationSawIncompleteEpkWarning.emit(@inquiry.gig.try(:id), current_profile.id) unless current_profile.epk_complete?
  
      GigTest::Intercom::Event::ApplicationVisitedGigApplicationForm.emit(@inquiry.gig.try(:id), current_profile.id) if current_profile.complete_for_inquiry?
    end
  
    def create
      @inquiry.artist     = current_profile
      @inquiry.user       = current_profile.main_user
      @inquiry.promoter   = @inquiry.gig.try(:promoter)
      existing_gig_invite = current_profile.gig_invites.find_by(gig_id: params[:gig_id])
  
      #if inquiry is valid, which means we will definitivly after this, copy
      #the riders from the current profile to the inquiry
      if @inquiry.valid?
        if current_profile.technical_rider.present? && current_profile.technical_rider.item_hash == params[:inquiry][:technical_rider_hash]
          @inquiry.build_technical_rider(user_id: current_user.id).save!
          # MediaItemWorker.perform_async(current_profile.technical_rider.id, @inquiry.technical_rider.id)
          schedule_job(current_profile.technical_rider.id, @inquiry.technical_rider.id)
        end
  
        if current_profile.catering_rider.present? && current_profile.catering_rider.item_hash == params[:inquiry][:catering_rider_hash]
          @inquiry.build_catering_rider(user_id: current_user.id).save!
          # MediaItemWorker.perform_async(current_profile.catering_rider.id, @inquiry.catering_rider.id)
          schedule_job(current_profile.catering_rider.id, @inquiry.catering_rider.id)
        end
      end
  
      if @inquiry.save
        #if profile has no rides yet, which means, this is the profiles first inquiry ever
        #copy the riders from the inquiry to the profile
        if current_profile.technical_rider.blank? && @inquiry.technical_rider.present?
          current_profile.build_technical_rider(user_id: current_user.id).save!
          # MediaItemWorker.perform_async(@inquiry.technical_rider.id, current_profile.technical_rider.id)
          schedule_job(@inquiry.technical_rider.id, current_profile.technical_rider.id)
        end
  
        if current_profile.catering_rider.blank? && @inquiry.catering_rider.present?
          current_profile.build_catering_rider(user_id: current_user.id).save!
          # MediaItemWorker.perform_async(@inquiry.catering_rider.id, current_profile.catering_rider.id)
          schedule_job(@inquiry.catering_rider.id, current_profile.catering_rider.id)
        end
  
        Event::WatchlistArtistInquiry.emit(@inquiry.id)
  
        GigTest::Intercom::Event::Simple.emit('gig-received-application', @inquiry.gig.try(:promoter_id))
        IntercomCreateOrUpdateUserWorker.perform_async(@inquiry.gig.try(:promoter_id))
  
        Event::Read.emit(:gig_invite, existing_gig_invite.id) if existing_gig_invite.present?

        render json: @inquiry, status: :created
      else
        render json: @inquiry.errors, status: :unprocessable_entity
      end
    end
  
    #only promoter use this
    def show
      #this redirect is for unfixed legacy links, because artist see inquiries
      #not prefixed with gig in the url
      return Event::Read.emit(:inquiry, @inquiry.id) unless current_profile.artist?
      redirect_to inquiry_path(@inquiry.id)
    end
  
    private
  
    def load_gig
      @inquiry.gig = Gig.find_by(slug: params[:gig_id])
    end
  
    def paywall_chroot
      # subscribe to premium-trial first to be able to use the platform at all
      redirect_to '/ab/gigtest-pro-free-trial' if current_profile.artist? && flash[:bypass_trial_chroot] != true
    end

    def schedule_job(first_rider, second_rider)
      MediaItemWorker.perform_async(first_rider, second_rider)
    end

  end