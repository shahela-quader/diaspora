class ConversationsController < ApplicationController
  before_action :authenticate_user!

  layout ->(c) { request.format == :mobile ? "application" : "with_header" }
  respond_to :html, :mobile, :json, :js

  def index
    @visibilities = ConversationVisibility.includes(:conversation)
                                          .order("conversations.updated_at DESC")
                                          .where(person_id: current_user.person_id)
                                          .paginate(page: params[:page], per_page: 15)

    if params[:conversation_id]
      @conversation = Conversation.joins(:conversation_visibilities)
                                  .where(conversation_visibilities: {
                                           person_id:       current_user.person_id,
                                           conversation_id: params[:conversation_id]
                                         }).first

      if @conversation
        @first_unread_message_id = @conversation.first_unread_message(current_user).try(:id)
        @conversation.set_read(current_user)
      end
    end

    gon.contacts = contacts_data

    respond_with do |format|
      format.html
      format.json { render json: @visibilities.map(&:conversation), status: 200 }
    end
  end

  def create
    contact_ids = params[:contact_ids]

    # Can't split nil
    if contact_ids
      contact_ids = contact_ids.split(',') if contact_ids.is_a? String
      person_ids = current_user.contacts.where(id: contact_ids).pluck(:person_id)
    end

    opts = params.require(:conversation).permit(:subject)
    opts[:participant_ids] = person_ids
    opts[:message] = { text: params[:conversation][:text] }
    @conversation = current_user.build_conversation(opts)

    @response = {}
    if person_ids.present? && @conversation.save
      Postzord::Dispatcher.build(current_user, @conversation).post
      @response[:success] = true
      @response[:message] = I18n.t('conversations.create.sent')
      @response[:conversation_id] = @conversation.id
    else
      @response[:success] = false
      @response[:message] = I18n.t('conversations.create.fail')
      if person_ids.blank?
        @response[:message] = I18n.t('conversations.create.no_contact')
      end
    end
    respond_to do |format|
      format.js
    end
  end

  def show
    respond_to do |format|
      format.html do
        redirect_to conversations_path(:conversation_id => params[:id])
        return
      end

      if @conversation = current_user.conversations.where(id: params[:id]).first
        @first_unread_message_id = @conversation.first_unread_message(current_user).try(:id)
        @conversation.set_read(current_user)

        format.js
        format.json { render :json => @conversation, :status => 200 }
      else
        redirect_to conversations_path
      end
    end
  end

  def new
    if !params[:modal] && !session[:mobile_view] && request.format.html?
      redirect_to conversations_path
      return
    end

    @contacts_json = contacts_data.to_json
    @contact_ids = ""

    if params[:contact_id]
      @contact_ids = current_user.contacts.find(params[:contact_id]).id
    elsif params[:aspect_id]
      @contact_ids = current_user.aspects.find(params[:aspect_id]).contacts.map{|c| c.id}.join(',')
    end
    if session[:mobile_view] == true && request.format.html?
      render :layout => true
    else
      render :layout => false
    end
  end

  private

  def contacts_data
    current_user.contacts.sharing.joins(person: :profile)
      .pluck(*%w(contacts.id profiles.first_name profiles.last_name people.diaspora_handle))
      .map {|contact_id, *name_attrs|
        {value: contact_id, name: ERB::Util.h(Person.name_from_attrs(*name_attrs)) }
      }
  end
end
