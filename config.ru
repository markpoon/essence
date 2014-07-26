require 'bundler/setup'
Bundler.require(:default)

use Rack::Session::Cookie, key: 'greatly_deserved_deserts', secret: 'the_dream_within_is_also_without', old_secret: 'telltale_signs_of_old_age'

require './app'
run Api
