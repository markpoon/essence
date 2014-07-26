require 'krypt'
require 'json'
require 'pathname'
require 'base64'
require 'securerandom'

# generates a hundred test accounts
def seed
  100.times do |i|
    u = User.new(name:"#{SecureRandom.hex(4)}",
                 email:"#{SecureRandom.hex(2)}@#{SecureRandom.hex(2)}.#{SecureRandom.hex(1)}",
                 password: "a",
                 age: 21,
                 coordinates: [(43.607+rand(-10..10)).round(6), (-79.708+rand(-10..10)).round(6)],
                 tags: ["a", "b", "c", "d", "e", "f"].sample(2))
    rand(2..6).times do
      u.photos << Photo.new(path: "essence#{rand(1..25)}.jpg",
                            tags: ["a", "b", "c", "d", "e", "f"].sample(2))
    end
    u.save!
  end
  user = User.first
  user.name = "markpoon"
  user.email = "markpoon@me.com"
  user.password ="some phrase"
  user.save
end

# extends the Array class to allow for conversion between float and bigdecimal
# so that i can calculate with BigDecimal objects to eliminate float inaccuracies
class Array
  def to_d(d=6)
    self.map{|i|BigDecimal(i,9).floor d}
  end
  def to_f
    self.map(&:to_f)
  end
end

# A convience method to remove nil value objects from a hash
class Hash
  def compact
    self.delete_if{|k, v|v==nil||v==0}
  end
end

if settings.development?
  require "sinatra/reloader"
  require 'benchmark'
  require 'pry'
end

class Api < Sinatra::Base
  set :public_folder, 'public'
  set :root, File.dirname(__FILE__)
  enable :inline_templates
  Mongoid.load! "config/mongoid.yml"
 
  configure :development do
    register Sinatra::Reloader
    include Benchmark
    Bundler.require(:development)
    get '/binding' do
      Binding.pry
    end
  end

  configure :production do
    Bundler.require(:production)
  end

  #ensures that I only reply to application/json requests, I can simply subsitute
  #to enable html to access as well, and xml encoding if need be.
  before do
    content_type 'application/json'
    data = request.env["rack.input"].read
    @params = JSON.parse(data) unless data.empty?
  end
  
  #http route to sign-in as a user
  get '/login' do
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    unless authorized? and @auth.provided? and @auth.basic? and @auth.credentials 
      email, password = @auth.credentials
      user = User.authenticate(email, password)
      if user.class == User
        status 200
        session[:user] = user.id
        return user.to_json(:methods => [:latitude, :longitude], :only =>[:_id, :n, :l])
      else
        status 401
        return {error: "User does not exist"}.to_json
      end
    else
      status 200
      return {error: "You're already signed in"}.to_json
    end
  end
  
  # simple logout call, accesses a sinatra helper to clear out session.
  get '/logout' do
    logout!
  end
  
  #search for a list of 33 users around a set of coordinates, returns limited
  #account information and photos, pagination is enabled when the client passes
  #the skip parameter
  get '/user/' do
    if @params["coordinates"].nil?
      status 400
    else
      status 200
      users = User.only(:id, :name, :coordinates, :love, :photos)
                  .slice(photos:2).limit(33).skip(params["skip"]||0)
                  .near(coordinates: @params["coordinates"])
                  .max_distance(coordinates:params["distance"]||0.5).entries
      return users.to_json(:methods => [:latitude, :longitude], :only =>[:_id, :n, :l], :include => {:photos => {:only => [:_id, :l], :methods => :image}})
    end
  end

  # to create a user, post a name, email and password, checks if name or email
  # already exists else returns a new user as confirmation that it has been
  # created
  post '/user/new' do
    binding.pry
    name, email, password = @params["name"], @params["email"], @params["password"]
    @user = User.where(name: name, email: email)
    if user.exists? 
      status 409
      return {error: "A user with the email: #{email}, already exists."}
    else
      status 201
      user.create!
      user.to_json
    end
  end

  # route to query for a user's profile, makes sure that you are signed in and
  # has a session first.
  get '/user/:id' do
    unless authorized?
      User.find_by(name:@params["id"]).to_json(:methods => [:latitude, :longitude, :total_love], :only =>[:_id, :n], :include => {:photos => {:only => [:_id, :l], :methods => :image}})
    end
  end

  # deletes user
  delete '/user/:id' do
    User.delete! if authorized? and my_account? @params["id"]
  end

  # method to send atomic writes to mongodb, synonmous with a "like system"
  put '/user/:id/love' do
    binding.pry
    user = User.find(@params["id"])
    if user
      user.inc(:love, @params["amount"].to_i||1)
      status 200
    else
      status 404
    end
  end

  # query route for a user's photos
  get '/user/:id/photos/' do
    unless authorized?
      binding.pry
      user = User.find(params["id"])
      photos = User.photos.to_json(:methods => :image, :only =>:_id)
      return user.photos
    end
  end

  # query route for individual photos
  get '/user/:user_id/photos/:image_id' do
    unless authorized?
      binding.pry
      redirect 'public'
      user = User.find(params["user_id"]).photos.find(params["image_id"]).base64
    end
  end

  #templates for html request errors
  not_found{haml :'404'}
  error{@error = request.env['sinatra_error']; haml :'500'}

  def authorized?; !session[:user].nil?; end
  def authorize!; redirect '/user/login' unless authorized?; end  
  def logout!; session[:user] = false; @user = nil; end
end

#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~# # Models # #~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#

# module that provides the coordinates mongoid fields, indexing and validation
# to any object
module Coordinates
  def self.included(reciever)
    reciever.class_eval do
      field :c, as: :coordinates, type: Array
      index({c: "2d"}, {min: -180, max: 180, unique: true, background: true})
      validates_presence_of :coordinates
    end
  end
  def coordinates=(coordinates)
    self.c = coordinates if coordinates.all?{|i| i.is_a? Float}
  end
end

# provides the "love" metric to users and photos and potentially other objects
module Lovable
  def self.included(reciever)
    reciever.class_eval do
      field :l, as: :love, type: Integer, default: ->{rand(20)}
    end
  end
end
module Tags
  def self.included(reciever)
    reciever.class_eval do
      field :t, as: :tags, type: Array
      index({tags:1},{background:true})
    end
  end
end

# The monolithic user class
class User
  include Mongoid::Document
  include Mongoid::Timestamps::Created
  include Coordinates
  #iOS wants the coordinates as a hash rather than an Array, to be used
  #in conjuction with as_json
  def latitude
    coordinates[0];
  end
  def longitude
    coordinates[1];
  end
  
  include Lovable
  include Tags

  validates_presence_of :email, :salt, :hashed_password, :tags
  validates_uniqueness_of :email, :name

  field :e, as: :email, type: String
  field :s, as: :salt, type: String
  field :h, as: :hashed_password, type: String
  field :n, as: :name, type: String

  embeds_many :photos, store_as: :p

  has_and_belongs_to_many :questions, inverse_of: nil
  field :a, as: :answers, type:Array
  def question_answer(num);
    # returns an array with the question and which answer this user choose
    [self.question(num), self.questions.answers(self.answer(num))]
  end
  def question(num);self.questions[num];end
  def answer(num);(self.answers(num));end
 
    
  def total_love
    self.photos.collect(&:love).sum + self.l
  end
  def password=(pass)
    digest = Krypt::Digest.new("sha256")
    self.salt = SecureRandom.hex(32)
    pdkdf = Krypt::PBKDF2.new(digest)
    self.hashed_password = pdkdf.generate_hex(pass, self.salt, 3000, 256)
  end
  def self.authenticate(name, pass)
    begin
      user = User.find_by(name: name)
      digest = Krypt::Digest.new("sha256")
      pbkdf = Krypt::PBKDF2.new(digest)
      hex = pbkdf.generate_hex(pass, user.salt, 3000, 256)
      if User.slow_compare user.hashed_password, hex
        return user
      end
    rescue
      return "Access Denied, Invalid Password"
    end
  end
  protected
  def self.slow_compare(hash1, hash2)
    return true if 0 == hash1.hex ^ hash2.hex
  end
end

class Photo
  include Mongoid::Document
  include Mongoid::Timestamps::Created
  include Lovable
  include Tags 
  # note to self : look at the difference between storing files as a glob
  # and files in subdirectories, indexing, what is the most efficient structure
  PATH = "./public/images/"
  
  belongs_to :user
  field :p, as: :path, type: String
  
  # encodes the image in base64 to be sent as json
  def image
    Pathname.new("#{PATH}#{self.path}").open{|file|
      return Base64.strict_encode64(file.read)
    }
  end
  
  #recieves base64 data and decodes into an image
  def image=(string)
    binding.pry
    o = Base64.decode64 string
    self.path = self.path||(SecureRandom.hex(20)+".jpg")
    File.open("#{PATH}#{self.path}", "w+"){|file|
      file.write(string)
    }
  end
end

clas Question
  include Mongoid::Document
  field :s, as: :string, type: String
  embeds_many :answers
end

class Answer
  include Mongoid::Document
  embedded_in :question
  field :s, as: :string, type: String
end

class Dialog
end
__END__
@@layout
!!! 5
%html
  %head
    %title= @title
    %meta{name: "viewport", content: "width=device-width,user-scalable=0,initial-scale=1.0,minimum-scale=0.5,maximum-scale=1.0"}
  %body
  %footer

  @@index

@@404
.warning
  %h1 404
  %hr 
  Apologies, there were no results found for your query.
  %hr
  
@@500
.warning
  %h1 500
  %hr
  %p @error.message
  %hr
